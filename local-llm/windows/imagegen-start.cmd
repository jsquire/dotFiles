@echo off
:: imagegen-start.cmd — Start the image generation server (HiDream-O1-Image-Dev)
:: Creates a uv venv on first run, installs dependencies, then starts the server.

setlocal
set VENV_DIR=%LOCALAPPDATA%\ai-tools\imagegen\.venv
set REPO_DIR=%LOCALAPPDATA%\ai-tools\imagegen\HiDream-O1-Image
set SCRIPT_DIR=%~dp0

:: Check for uv
where uv >nul 2>&1
if errorlevel 1 (
    echo   ERROR: uv is not installed. Run: winget install astral-sh.uv
    exit /b 1
)

:: Clone inference repo if missing
if not exist "%REPO_DIR%\models\pipeline.py" (
    echo   Cloning HiDream-O1-Image inference repo...
    git clone --depth 1 https://github.com/HiDream-ai/HiDream-O1-Image.git "%REPO_DIR%"
)

:: Create venv if it doesn't exist
if not exist "%VENV_DIR%\Scripts\python.exe" (
    echo   Creating image generation venv...
    uv venv "%VENV_DIR%" --quiet
    echo   Installing dependencies (first run only, this may take a few minutes^)...
    set VIRTUAL_ENV=%VENV_DIR%
    uv pip install --quiet ^
        torch torchvision --index-url https://download.pytorch.org/whl/cu128
    uv pip install --quiet ^
        "transformers==4.57.1" ^
        diffusers ^
        accelerate ^
        einops ^
        scipy ^
        numpy ^
        pillow ^
        tqdm ^
        fastapi ^
        uvicorn ^
        pydantic
    echo   Dependencies installed.
)

echo.
echo   Starting image generation server on http://127.0.0.1:8001
echo   Model: HiDream-O1-Image-Dev (8B, bf16, ~16GB VRAM^)
echo   Generation time: ~15-25s per image
echo.
echo   Usage:
echo     curl http://localhost:8001/v1/images/generations ^
echo       -H "Content-Type: application/json" ^
echo       -d "{\"prompt\": \"a cat\", \"size\": \"1024x1024\"}"
echo.
echo   Press Ctrl+C to stop.
echo.

"%VENV_DIR%\Scripts\python.exe" "%SCRIPT_DIR%imagegen-server.py" %*
