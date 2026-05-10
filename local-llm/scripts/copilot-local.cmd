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
    echo   [1] Heavy coding        (glm-4.7-flash^)
    echo   [2] Light coding        (qwen2.5-coder:14b^)
    echo   [3] Code review         (deepseek-r1:32b^)
    echo.
    echo   --- Writing ^& Documents ---
    echo   [4] Technical docs      (glm-4.7-flash^)
    echo   [5] Creative writing    (glm-4.7-flash^)
    echo   [6] Office documents    (glm-4.7-flash^)
) else (
    echo   --- Coding ---
    echo   [1] Heavy coding        (glm-4.7-flash^)
    echo   [2] Light coding        (qwen3:14b^)
    echo   [3] Code review         (deepseek-r1:32b^)
    echo.
    echo   --- Writing ^& Documents ---
    echo   [4] Technical docs      (glm-4.7-flash^)
    echo   [5] Creative writing    (glm-4.7-flash^)
    echo   [6] Office documents    (glm-4.7-flash^)
)
echo.
echo   --- Visual ---
echo   [7] Image generation    (FLUX.1-schnell via MCP^)
echo.
set /p choice="  Select task [1]: "

if "%choice%"=="" set choice=1

if /i "%COPILOT_LOCAL_PROFILE%"=="Server" (
    if "%choice%"=="1" set COPILOT_MODEL=glm-4.7-flash
    if "%choice%"=="2" set COPILOT_MODEL=qwen2.5-coder:14b
    if "%choice%"=="3" set COPILOT_MODEL=deepseek-r1:32b
    if "%choice%"=="4" set COPILOT_MODEL=glm-4.7-flash
    if "%choice%"=="5" set COPILOT_MODEL=glm-4.7-flash
    if "%choice%"=="6" set COPILOT_MODEL=glm-4.7-flash
) else (
    if "%choice%"=="1" set COPILOT_MODEL=glm-4.7-flash
    if "%choice%"=="2" set COPILOT_MODEL=qwen3:14b
    if "%choice%"=="3" set COPILOT_MODEL=deepseek-r1:32b
    if "%choice%"=="4" set COPILOT_MODEL=glm-4.7-flash
    if "%choice%"=="5" set COPILOT_MODEL=glm-4.7-flash
    if "%choice%"=="6" set COPILOT_MODEL=glm-4.7-flash
)

if "%choice%"=="7" set COPILOT_MODEL=glm-4.7-flash

:: Set MCP flags based on task category
:: Coding (1-3): disable all MCP servers — max context for code
:: Docs (4-6): enable word + pptx, disable imagegen
:: Image (7): enable imagegen, disable word + pptx
set MCP_FLAGS=
if "%choice%"=="1" set MCP_FLAGS=--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server imagegen-mcp
if "%choice%"=="2" set MCP_FLAGS=--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server imagegen-mcp
if "%choice%"=="3" set MCP_FLAGS=--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server imagegen-mcp
if "%choice%"=="4" set MCP_FLAGS=--disable-mcp-server imagegen-mcp
if "%choice%"=="5" set MCP_FLAGS=--disable-mcp-server imagegen-mcp
if "%choice%"=="6" set MCP_FLAGS=--disable-mcp-server imagegen-mcp
if "%choice%"=="7" set MCP_FLAGS=--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp

if not defined COPILOT_MODEL (
    echo   Invalid selection.
    if /i "%COPILOT_LOCAL_PROFILE%"=="Server" (
        set COPILOT_MODEL=glm-4.7-flash
    ) else (
        set COPILOT_MODEL=glm-4.7-flash
    )
)

:launch
echo   Using model: %COPILOT_MODEL%
echo.
copilot %MCP_FLAGS% %1 %2 %3 %4 %5 %6 %7 %8 %9
