@echo off
:: imagegen-start.cmd — Start the image generation server (FLUX.1-schnell)
:: Creates a uv venv on first run, installs dependencies, then starts the server.

setlocal
set VENV_DIR=%LOCALAPPDATA%\ai-tools\imagegen\.venv
set SCRIPT_DIR=%~dp0

:: Check for uv
where uv >nul 2>&1
if errorlevel 1 (
    echo   ERROR: uv is not installed. Run: winget install astral-sh.uv
    exit /b 1
)

:: Create venv if it doesn't exist
if not exist "%VENV_DIR%\Scripts\python.exe" (
    echo   Creating image generation venv...
    uv venv "%VENV_DIR%" --python 3.12 --quiet
    echo   Installing dependencies (first run only, this may take a few minutes^)...
    set VIRTUAL_ENV=%VENV_DIR%
    uv pip install --quiet ^
        torch --index-url https://download.pytorch.org/whl/cu128
    uv pip install --quiet ^
        "diffusers[torch]" ^
        transformers ^
        fastapi ^
        uvicorn ^
        accelerate ^
        pydantic ^
        sentencepiece ^
        protobuf ^
        bitsandbytes
    echo   Dependencies installed.
)

echo.
echo   Starting image generation server on http://127.0.0.1:8001
echo   Model: FLUX.1-schnell
echo   Mode: FAST (NF4 quantized, ~9GB VRAM, ~5-20s/image^)
echo   Use --quality hq for full bf16 (best quality, ~2.5 min/image^)
echo.
echo   Usage:
echo     curl http://localhost:8001/v1/images/generations ^
echo       -H "Content-Type: application/json" ^
echo       -d "{\"prompt\": \"a cat\", \"size\": \"1024x1024\"}"
echo.
echo   Press Ctrl+C to stop.
echo.

"%VENV_DIR%\Scripts\python.exe" "%SCRIPT_DIR%imagegen-server.py" %*
