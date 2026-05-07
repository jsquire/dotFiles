@echo off
setlocal enabledelayedexpansion

set COPILOT_PROVIDER_BASE_URL=http://localhost:11434/v1
set COPILOT_PROVIDER_MAX_PROMPT_TOKENS=14000
set COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=8000

:: If a model was passed as first argument, use it
if not "%~1"=="" (
    echo %~1 | findstr /C:":" >nul 2>&1
    if !errorlevel!==0 (
        set COPILOT_MODEL=%~1
        shift
        goto :launch
    )
)

:: Detect profile from environment (set by installer) or default to Desktop
if not defined COPILOT_LOCAL_PROFILE set COPILOT_LOCAL_PROFILE=Desktop

:: No model specified — show picker
echo.
if /i "%COPILOT_LOCAL_PROFILE%"=="Server" (
    echo   --- Coding ---
    echo   [1] Heavy coding        (qwen2.5-coder:32b^)
    echo   [2] Light coding        (qwen2.5-coder:14b^)
    echo   [3] Code review         (deepseek-r1:32b^)
    echo.
    echo   --- Writing ^& Documents ---
    echo   [4] Technical docs      (mistral-small3.2:24b^)
    echo   [5] Creative writing    (mistral-small3.2:24b^)
    echo   [6] Office documents    (mistral-small3.2:24b^)
) else (
    echo   --- Coding ---
    echo   [1] Heavy coding        (gemma4:31b^)
    echo   [2] Light coding        (qwen3:14b^)
    echo   [3] Code review         (deepseek-r1:32b^)
    echo.
    echo   --- Writing ^& Documents ---
    echo   [4] Technical docs      (gemma3:27b^)
    echo   [5] Creative writing    (llama3.3:70b-instruct-q2_K^)
    echo   [6] Office documents    (qwen3-coder:30b^)
)
echo.
echo   --- Visual ---
echo   [7] Image generation    (ComfyUI - launches separately)
echo.
set /p choice="  Select task [1]: "

if "%choice%"=="" set choice=1

if /i "%COPILOT_LOCAL_PROFILE%"=="Server" (
    if "%choice%"=="1" set COPILOT_MODEL=qwen2.5-coder:32b
    if "%choice%"=="2" set COPILOT_MODEL=qwen2.5-coder:14b
    if "%choice%"=="3" set COPILOT_MODEL=deepseek-r1:32b
    if "%choice%"=="4" set COPILOT_MODEL=mistral-small3.2:24b
    if "%choice%"=="5" set COPILOT_MODEL=mistral-small3.2:24b
    if "%choice%"=="6" set COPILOT_MODEL=mistral-small3.2:24b
) else (
    if "%choice%"=="1" set COPILOT_MODEL=gemma4:31b
    if "%choice%"=="2" set COPILOT_MODEL=qwen3:14b
    if "%choice%"=="3" set COPILOT_MODEL=deepseek-r1:32b
    if "%choice%"=="4" set COPILOT_MODEL=gemma3:27b
    if "%choice%"=="5" set COPILOT_MODEL=llama3.3:70b-instruct-q2_K
    if "%choice%"=="6" set COPILOT_MODEL=qwen3-coder:30b
)

if "%choice%"=="7" (
    echo.
    echo   Image generation requires ComfyUI - not available via Copilot CLI.
    echo   Launch ComfyUI Desktop from Start Menu for image tasks.
    exit /b 0
)

if not defined COPILOT_MODEL (
    echo   Invalid selection.
    if /i "%COPILOT_LOCAL_PROFILE%"=="Server" (
        set COPILOT_MODEL=qwen2.5-coder:32b
    ) else (
        set COPILOT_MODEL=gemma4:31b
    )
)

:launch
echo   Using model: %COPILOT_MODEL%
echo.
copilot %1 %2 %3 %4 %5 %6 %7 %8 %9
