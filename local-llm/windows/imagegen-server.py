"""
Image Generation Server — OpenAI-compatible API using HiDream-O1-Image-Dev.

Provides POST /v1/images/generations matching the OpenAI Images API format.

Model: HiDream-ai/HiDream-O1-Image-Dev (8B params, MIT license, bf16, ~16GB VRAM)
Native resolution: 2048×2048 (smaller requests are rendered at native res and downscaled)
Requires inference repo at: %LOCALAPPDATA%/ai-tools/imagegen/HiDream-O1-Image

Start: python imagegen-server.py [--port 8001] [--host 127.0.0.1]
"""

import argparse
import base64
import io
import logging
import os
import sys
import time
from contextlib import asynccontextmanager

import torch
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
import uvicorn

logger = logging.getLogger("imagegen")

# Add HiDream repo to path for custom model imports
HIDREAM_REPO = os.path.join(os.environ.get("LOCALAPPDATA", ""), "ai-tools", "imagegen", "HiDream-O1-Image")
if not os.path.isdir(HIDREAM_REPO):
    HIDREAM_REPO = os.path.join(os.path.dirname(__file__), "HiDream-O1-Image")
sys.path.insert(0, HIDREAM_REPO)

MODEL_ID = "HiDream-ai/HiDream-O1-Image-Dev"

model = None
processor = None


class ImageRequest(BaseModel):
    prompt: str
    model: str = "hidream-o1"
    n: int = Field(default=1, ge=1, le=4)
    size: str = "1024x1024"
    response_format: str = "b64_json"
    num_inference_steps: int = Field(default=28, ge=1, le=50)
    seed: int | None = None


def parse_size(size_str: str) -> tuple[int, int]:
    """Parse 'WIDTHxHEIGHT' — returns requested output size (may differ from render size)."""
    try:
        w, h = size_str.lower().split("x")
        w, h = int(w), int(h)
    except (ValueError, AttributeError):
        raise HTTPException(400, f"Invalid size format: {size_str}. Use WIDTHxHEIGHT (e.g., 1024x1024)")
    if w < 256 or h < 256 or w > 2048 or h > 2048:
        raise HTTPException(400, f"Size must be between 256 and 2048. Got {w}x{h}")
    return w, h


def load_model():
    global model, processor
    if model is not None:
        return

    from transformers import AutoProcessor
    from models.qwen3_vl_transformers import Qwen3VLForConditionalGeneration

    logger.info("Loading HiDream-O1-Image-Dev (bf16)...")
    processor = AutoProcessor.from_pretrained(MODEL_ID)
    model = Qwen3VLForConditionalGeneration.from_pretrained(
        MODEL_ID, torch_dtype=torch.bfloat16, device_map="cuda"
    ).eval()
    logger.info("Model loaded (~16GB VRAM).")

    # Attach special tokens the pipeline expects
    tokenizer = processor.tokenizer if hasattr(processor, 'tokenizer') else processor
    tokenizer.boi_token = "<|boi_token|>"
    tokenizer.bor_token = "<|bor_token|>"
    tokenizer.eor_token = "<|eor_token|>"
    tokenizer.bot_token = "<|bot_token|>"
    tokenizer.tms_token = "<|tms_token|>"


@asynccontextmanager
async def lifespan(app: FastAPI):
    load_model()
    yield


app = FastAPI(title="Image Generation Server", lifespan=lifespan)


@app.get("/v1/models")
async def list_models():
    return {
        "object": "list",
        "data": [
            {
                "id": "hidream-o1",
                "object": "model",
                "created": 1700000000,
                "owned_by": "hidream-ai",
            }
        ],
    }


@app.post("/v1/images/generations")
async def generate_image_endpoint(request: ImageRequest):
    if model is None:
        raise HTTPException(503, "Model not loaded yet")

    from models.pipeline import generate_image, DEFAULT_TIMESTEPS
    from models.utils import find_closest_resolution

    requested_w, requested_h = parse_size(request.size)
    # Model renders at predefined high resolutions; downscale output to requested size
    render_w, render_h = find_closest_resolution(requested_w, requested_h)
    seed = request.seed if request.seed is not None else int(time.time()) % 2**32
    logger.info(f"Generating {request.n} image(s): requested={requested_w}x{requested_h}, "
                f"render={render_w}x{render_h}, steps={request.num_inference_steps}, seed={seed}")
    start = time.time()

    data = []
    try:
        for i in range(request.n):
            img = generate_image(
                model=model,
                processor=processor,
                prompt=request.prompt,
                height=render_h,
                width=render_w,
                num_inference_steps=request.num_inference_steps,
                guidance_scale=0.0,
                shift=1.0,
                timesteps_list=DEFAULT_TIMESTEPS,
                scheduler_name="flash",
                seed=seed + i,
                noise_scale_start=7.5,
                noise_scale_end=7.5,
                noise_clip_std=2.5,
            )
            # Downscale to requested size if different from render size
            if img.width != requested_w or img.height != requested_h:
                from PIL import Image as PILImage
                img = img.resize((requested_w, requested_h), PILImage.LANCZOS)
            buf = io.BytesIO()
            img.save(buf, format="PNG")
            b64 = base64.b64encode(buf.getvalue()).decode("utf-8")
            data.append({"b64_json": b64, "revised_prompt": request.prompt})
    except torch.cuda.OutOfMemoryError:
        raise HTTPException(507, "GPU out of memory. Close other GPU applications or reduce image size.")
    except Exception as e:
        logger.error(f"Generation failed: {e}")
        raise HTTPException(500, f"Generation failed: {e}")

    elapsed = time.time() - start
    logger.info(f"Generated {request.n} image(s) in {elapsed:.1f}s")

    return JSONResponse({"created": int(time.time()), "data": data})


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "model": "HiDream-O1-Image-Dev",
        "model_loaded": model is not None,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Image Generation Server")
    parser.add_argument("--host", default="127.0.0.1", help="Bind address (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8001, help="Port (default: 8001)")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    logger.info(f"Starting image generation server on {args.host}:{args.port}")
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")
