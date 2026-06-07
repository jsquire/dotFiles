@echo off
setlocal enabledelayedexpansion

set COPILOT_PROVIDER_MAX_PROMPT_TOKENS=51200
set COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=16384

:: If a model was passed as first argument, use it
if not "%~1"=="" (
    echo %~1 | findstr /C:":" >nul 2>&1
    if !errorlevel!==0 (
        set COPILOT_MODEL=%~1
        shift
        goto :launch
    )
)

:: No model specified — show picker
echo.
echo   --- Coding ---
echo   [1] Heavy coding        (qwen36-128k^)
echo   [2] Light coding        (qwen3:14b^)
echo   [3] Code review         (qwen3coder-65k^)
echo.
echo   --- Writing ^& Documents ---
echo   [4] Technical docs      (qwen36-128k^)
echo   [5] Creative writing    (qwen36-128k^)
echo   [6] Office documents    (qwen36-128k^)
echo.
echo   --- Visual ---
echo   [7] Image generation    (HiDream-O1 via MCP^)
echo.
echo   --- Remote ---
echo   [S] CachyOS server      (Qwen3.6 27B via vLLM^)
echo.
set /p choice="  Select task [1]: "

if "%choice%"=="" set choice=1

if "%choice%"=="1" set COPILOT_MODEL=qwen36-128k
if "%choice%"=="2" set COPILOT_MODEL=qwen3:14b
if "%choice%"=="3" set COPILOT_MODEL=qwen3coder-65k
if "%choice%"=="4" set COPILOT_MODEL=qwen36-128k
if "%choice%"=="5" set COPILOT_MODEL=qwen36-128k
if "%choice%"=="6" set COPILOT_MODEL=qwen36-128k
if "%choice%"=="7" set COPILOT_MODEL=qwen3:4b
if /i "%choice%"=="S" (
    set COPILOT_PROVIDER_BASE_URL=http://__SQUIRE_SERVER_IP__:8000/v1
    set COPILOT_MODEL=Qwen/Qwen3.6-27B-Instruct-GPTQ
)

:: Set MCP flags based on task category
:: Coding (1-3): disable all MCP servers — max context for code
:: Docs (4-6): enable word + pptx, disable imagegen
:: Image (7): enable imagegen, disable word + pptx
:: Server (S): disable all MCP (remote, no local MCP)
set MCP_FLAGS=
if "%choice%"=="1" set MCP_FLAGS=--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server pptx-mcp-xplat --disable-mcp-server imagegen-mcp
if "%choice%"=="2" set MCP_FLAGS=--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server pptx-mcp-xplat --disable-mcp-server imagegen-mcp
if "%choice%"=="3" set MCP_FLAGS=--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server pptx-mcp-xplat --disable-mcp-server imagegen-mcp
if "%choice%"=="4" set MCP_FLAGS=--disable-mcp-server imagegen-mcp
if "%choice%"=="5" set MCP_FLAGS=--disable-mcp-server imagegen-mcp
if "%choice%"=="6" set MCP_FLAGS=--disable-mcp-server imagegen-mcp
if "%choice%"=="7" set MCP_FLAGS=--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server pptx-mcp-xplat
if /i "%choice%"=="S" set MCP_FLAGS=--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server pptx-mcp-xplat --disable-mcp-server imagegen-mcp

if not defined COPILOT_MODEL (
    echo   Invalid selection.
    set COPILOT_MODEL=qwen36-128k
)

:: Git safety: block git write operations
set GIT_SAFETY=--deny-tool="shell(git add)" --deny-tool="shell(git commit)" --deny-tool="shell(git push)" --deny-tool="shell(git merge)" --deny-tool="shell(git rebase)" --deny-tool="shell(git reset)" --deny-tool="shell(git stash)" --deny-tool="shell(git cherry-pick)" --deny-tool="shell(git revert)" --deny-tool="shell(git tag)"

:: Set PPTX instructions for doc profiles (6 = Office documents)
set EXTRA_FLAGS=
if "%choice%"=="6" set EXTRA_FLAGS=--custom-instructions "D:\personal\dotFiles\local-llm\config\pptx-instructions.md"

:launch
echo   Using model: %COPILOT_MODEL%
if defined COPILOT_PROVIDER_BASE_URL (
    echo   Remote: %COPILOT_PROVIDER_BASE_URL%
    echo.
    copilot --model %COPILOT_MODEL% -- %MCP_FLAGS% %GIT_SAFETY% %EXTRA_FLAGS% %1 %2 %3 %4 %5 %6 %7 %8 %9
) else (
    echo.
    ollama launch copilot --model %COPILOT_MODEL% --yes -- %MCP_FLAGS% %GIT_SAFETY% %EXTRA_FLAGS% %1 %2 %3 %4 %5 %6 %7 %8 %9
)
