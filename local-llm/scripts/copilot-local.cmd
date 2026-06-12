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
echo   [1] Heavy coding        (qwen36-27b-256k^)
echo   [2] Light coding        (qwen3coder-256k^)
echo   [3] Code review         (qwen3coder-256k^)
echo.
echo   --- Writing ^& Documents ---
echo   [4] Technical docs      (qwen36-27b-256k^)
echo   [5] Creative writing    (qwen36-27b-256k^)
echo   [6] Office documents    (glm47-flash-198k^)
echo.
echo   --- Visual ---
echo   [7] Image generation    (qwen3:8b + HiDream via MCP^)
echo.
echo   --- Big-MoE expert-offload bench (experts-^>RAM; slower, for models that don't fit^) ---
echo   [O1] gpt-oss-120b           (offload, ~65 GB MXFP4^)
echo   [O2] Qwen3-Next-80B-A3B     (offload, Q4_K_M ~45 GB^)
echo.
echo   --- Remote (CachyOS server — one standing model, switch only when needed) ---
echo   [S] CachyOS: GLM-4.7-Flash   (default — coding + review + office MCP^)
echo   [C] CachyOS: Qwen3-Coder     (coding-first — switches server^)
echo   [V] CachyOS: Qwen3.6-35B      (vision — switches server^)
echo   [I] CachyOS: Image gen        (HiDream + Qwen3-4B — switches server^)
echo.
set /p choice="  Select task [1]: "

if "%choice%"=="" set choice=1

if "%choice%"=="1" set COPILOT_MODEL=qwen36-27b-256k
if "%choice%"=="2" set COPILOT_MODEL=qwen3coder-256k
if "%choice%"=="3" set COPILOT_MODEL=qwen3coder-256k
if "%choice%"=="4" set COPILOT_MODEL=qwen36-27b-256k
if "%choice%"=="5" set COPILOT_MODEL=qwen36-27b-256k
if "%choice%"=="6" set COPILOT_MODEL=glm47-flash-198k
if "%choice%"=="7" set COPILOT_MODEL=qwen3:8b
if /i "%choice%"=="O1" set COPILOT_MODEL=gptoss-120b-offload
if /i "%choice%"=="O1" set OFFLOAD=1
if /i "%choice%"=="O2" set COPILOT_MODEL=qwen3next-80b-offload
if /i "%choice%"=="O2" set OFFLOAD=1
if /i "%choice%"=="S" (
    ssh __SQUIRE_SSH_TARGET__ "cachyos-switch-model glm" 2>nul
    set COPILOT_PROVIDER_BASE_URL=http://__SQUIRE_SERVER_IP__:8000/v1
    set COPILOT_MODEL=glm-4.7-flash
)
if /i "%choice%"=="C" (
    ssh __SQUIRE_SSH_TARGET__ "cachyos-switch-model coder" 2>nul
    set COPILOT_PROVIDER_BASE_URL=http://__SQUIRE_SERVER_IP__:8000/v1
    set COPILOT_MODEL=qwen3-coder
)
if /i "%choice%"=="V" (
    ssh __SQUIRE_SSH_TARGET__ "cachyos-switch-model vision" 2>nul
    set COPILOT_PROVIDER_BASE_URL=http://__SQUIRE_SERVER_IP__:8000/v1
    set COPILOT_MODEL=qwen3.6-35b
)
if /i "%choice%"=="I" (
    ssh __SQUIRE_SSH_TARGET__ "cachyos-switch-model image" 2>nul
    set COPILOT_PROVIDER_BASE_URL=http://__SQUIRE_SERVER_IP__:8000/v1
    set COPILOT_MODEL=qwen3-4b
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
if /i "%choice%"=="O1" set MCP_FLAGS=--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server pptx-mcp-xplat --disable-mcp-server imagegen-mcp
if /i "%choice%"=="O2" set MCP_FLAGS=--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server pptx-mcp-xplat --disable-mcp-server imagegen-mcp
if /i "%choice%"=="S" set MCP_FLAGS=--disable-mcp-server imagegen-mcp
if /i "%choice%"=="C" set MCP_FLAGS=--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server pptx-mcp-xplat --disable-mcp-server imagegen-mcp
if /i "%choice%"=="V" set MCP_FLAGS=--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server pptx-mcp-xplat --disable-mcp-server imagegen-mcp
if /i "%choice%"=="I" set MCP_FLAGS=--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server pptx-mcp-xplat

if not defined COPILOT_MODEL (
    echo   Invalid selection.
    set COPILOT_MODEL=qwen36-27b-256k
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
    if defined OFFLOAD (
        echo   Offload mode: experts -^> system RAM ^(slower; for models that don't fit^)
        echo.
        powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0offload-serve.ps1" -Action start
        ollama launch copilot --model %COPILOT_MODEL% --yes -- %MCP_FLAGS% %GIT_SAFETY% %EXTRA_FLAGS% %1 %2 %3 %4 %5 %6 %7 %8 %9
        powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0offload-serve.ps1" -Action stop
    ) else (
        echo.
        ollama launch copilot --model %COPILOT_MODEL% --yes -- %MCP_FLAGS% %GIT_SAFETY% %EXTRA_FLAGS% %1 %2 %3 %4 %5 %6 %7 %8 %9
    )
)
