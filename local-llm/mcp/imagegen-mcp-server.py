"""
Image Generation MCP Server.

Provides generate_image and imagegen_status tools via MCP (stdio).
Works cross-platform (Windows + Linux) and supports local or remote backends.

Configuration via environment variables:
  IMAGEGEN_URL  — Base URL of the imagegen API (default: http://127.0.0.1:8001)

When targeting localhost, automatically manages the server lifecycle:
  - Starts server on demand if not running (~15-20s cold start)
  - Shuts down server after 5 min idle to free ~16GB VRAM

When targeting a remote server, lifecycle management is skipped
(the remote systemd service handles its own lifecycle).
"""

import asyncio
import base64
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

from urllib.parse import urlparse

import httpx
from fastmcp import FastMCP

mcp = FastMCP("imagegen-mcp")

IMAGEGEN_URL = os.environ.get("IMAGEGEN_URL", "http://127.0.0.1:8001")
IDLE_TIMEOUT_SECONDS = 300  # 5 minutes
STARTUP_TIMEOUT_SECONDS = 300  # max wait for server to become ready (headless cold start can be slow)

_server_process: subprocess.Popen | None = None
_last_request_time: float = 0
_idle_checker_task: asyncio.Task | None = None

_LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1", "0.0.0.0"}


def _is_local() -> bool:
    """Check if we're targeting a local server (eligible for auto-start)."""
    hostname = urlparse(IMAGEGEN_URL).hostname or ""
    return hostname in _LOCAL_HOSTS


def _get_ai_tools_dir() -> Path:
    """Get the ai-tools directory (AI_TOOLS_DIR env override, else platform default)."""
    env_dir = os.environ.get("AI_TOOLS_DIR")
    if env_dir:
        return Path(env_dir)
    if sys.platform == "win32":
        return Path(os.environ.get("LOCALAPPDATA", "")) / "ai-tools"
    return Path.home() / ".local" / "share" / "ai-tools"


def _default_output_dir() -> Path:
    """Default directory for generated images: the caller's Downloads folder (both platforms)."""
    return Path.home() / "Downloads"


def _resolve_output_path(output_path: str, prompt: str) -> Path:
    """Resolve where to save the image.

    - Empty/omitted -> a timestamped auto-name in ~/Downloads (derived from the prompt).
    - A bare filename (no directory) -> placed in ~/Downloads.
    - An absolute path or one with a directory -> used as given.
    A ``.png`` suffix is enforced in all cases.
    """
    raw = (output_path or "").strip()
    if not raw:
        slug = "".join(c if c.isalnum() else "_" for c in prompt[:40]).strip("_") or "image"
        name = f"{slug}_{time.strftime('%Y%m%d-%H%M%S')}.png"
        return _default_output_dir() / name
    p = Path(raw)
    if not p.is_absolute() and p.parent == Path("."):
        p = _default_output_dir() / p.name
    if p.suffix.lower() != ".png":
        p = p.with_suffix(".png")
    return p


async def _check_server_health() -> bool:
    """Check if the imagegen server is running and healthy."""
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            resp = await client.get(f"{IMAGEGEN_URL}/health")
            return resp.status_code == 200
    except (httpx.ConnectError, httpx.TimeoutException):
        return False


async def _start_server() -> bool:
    """Start the imagegen server if not already running (local only)."""
    global _server_process, _last_request_time, _idle_checker_task

    if await _check_server_health():
        _last_request_time = time.time()
        return True

    if not _is_local():
        return False  # remote server must be managed externally

    imagegen_dir = _get_ai_tools_dir() / "imagegen"
    if sys.platform == "win32":
        venv_python = imagegen_dir / ".venv" / "Scripts" / "python.exe"
    else:
        venv_python = imagegen_dir / ".venv" / "bin" / "python"
    server_script = imagegen_dir / "imagegen-server.py"

    if not venv_python.exists():
        return False
    if not server_script.exists():
        return False

    log_path = imagegen_dir / "server.log"
    _server_log = open(log_path, "w")

    popen_kwargs = {
        "cwd": str(imagegen_dir),
        "stdin": subprocess.DEVNULL,
        "stdout": _server_log,
        "stderr": subprocess.STDOUT,
        "env": {
            **os.environ,
            "PYTHONIOENCODING": "utf-8",
            "TQDM_DISABLE": "1",
            "TRANSFORMERS_NO_ADVISORY_WARNINGS": "1",
        },
    }
    if sys.platform == "win32":
        popen_kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW

    _server_process = subprocess.Popen(
        [str(venv_python), str(server_script), "--port", "8001"],
        **popen_kwargs,
    )

    # Wait for server to become ready
    for _ in range(STARTUP_TIMEOUT_SECONDS):
        if _server_process.poll() is not None:
            return False
        if await _check_server_health():
            _last_request_time = time.time()
            if _idle_checker_task is None or _idle_checker_task.done():
                _idle_checker_task = asyncio.create_task(_idle_shutdown_loop())
            return True
        await asyncio.sleep(1)

    return False


async def _stop_server():
    """Stop the imagegen server to free VRAM."""
    global _server_process
    if _server_process and _server_process.poll() is None:
        _server_process.terminate()
        try:
            _server_process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            _server_process.kill()
    _server_process = None


async def _idle_shutdown_loop():
    """Background task that shuts down the server after idle timeout."""
    global _server_process
    while True:
        await asyncio.sleep(30)
        if _server_process is None or _server_process.poll() is not None:
            return
        if time.time() - _last_request_time > IDLE_TIMEOUT_SECONDS:
            await _stop_server()
            return


@mcp.tool()
async def generate_image(
    prompt: str,
    output_path: str = "",
    width: int = 1024,
    height: int = 1024,
) -> str:
    """Generate an image from a text prompt using HiDream-O1-Image-Dev.

    The image is saved as a PNG file and the saved path is returned.
    The imagegen server is started automatically if not running (~15-20s cold start).
    Subsequent generations take ~15-25 seconds depending on resolution.

    Args:
        prompt: Detailed text description of the image to generate.
        output_path: Optional. Where to save the PNG. If omitted, the image is saved to the
            user's Downloads folder with an auto-generated name. A bare filename (e.g. "cat.png")
            is also placed in Downloads; an absolute/relative path with a directory is used as-is.
        width: Image width in pixels (default 1024). Rendered at 2048 native and downscaled.
        height: Image height in pixels (default 1024). Rendered at 2048 native and downscaled.
    """
    global _last_request_time

    # Ensure server is running
    if not await _start_server():
        if _is_local():
            return (
                "Error: Could not start image generation server. "
                "Check that imagegen-server.py and its venv exist at "
                f"{_get_ai_tools_dir() / 'imagegen'}"
            )
        else:
            return (
                f"Error: Remote image generation server at {IMAGEGEN_URL} is not responding. "
                "Check that the server is running."
            )

    _last_request_time = time.time()

    try:
        async with httpx.AsyncClient(timeout=180) as client:
            resp = await client.post(
                f"{IMAGEGEN_URL}/v1/images/generations",
                json={
                    "prompt": prompt,
                    "size": f"{width}x{height}",
                    "n": 1,
                    "response_format": "b64_json",
                },
            )
            resp.raise_for_status()
            data = resp.json()

        b64_data = data["data"][0]["b64_json"]
        img_bytes = base64.b64decode(b64_data)

        out = _resolve_output_path(output_path, prompt)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(img_bytes)

        return f"Image saved to {out} ({len(img_bytes):,} bytes, {width}x{height})"
    except httpx.TimeoutException:
        return "Error: Image generation timed out (>120s). The model may still be loading."
    except Exception as e:
        return f"Error generating image: {e}"


@mcp.tool()
async def imagegen_status() -> str:
    """Check whether the image generation server is running.

    Returns the server status including model info, quality mode, and VRAM usage.
    """
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            resp = await client.get(f"{IMAGEGEN_URL}/health")
            if resp.status_code == 200:
                info = resp.json()
                return (
                    f"Image generation server is RUNNING.\n"
                    f"  Model: {info.get('model', 'unknown')}\n"
                    f"  Quality: {info.get('quality', 'unknown')}\n"
                    f"  Pipeline loaded: {info.get('pipeline_loaded', False)}\n"
                    f"  URL: {IMAGEGEN_URL}"
                )
            return f"Server responded with status {resp.status_code}"
    except (httpx.ConnectError, httpx.TimeoutException):
        managed = _server_process is not None and _server_process.poll() is None
        if _is_local():
            return (
                "Image generation server is NOT running.\n"
                f"  Managed process: {'yes (starting?)' if managed else 'no'}\n"
                "  It will be started automatically on the next generate_image call (~15-20s)."
            )
        else:
            return (
                f"Image generation server at {IMAGEGEN_URL} is NOT responding.\n"
                "  This is a remote server — check that the service is running."
            )


if __name__ == "__main__":
    mcp.run(transport="stdio")
