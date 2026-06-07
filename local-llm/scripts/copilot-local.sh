#!/usr/bin/env bash
# copilot-local — Launch GitHub Copilot CLI with local Ollama models
set -euo pipefail

export COPILOT_PROVIDER_MAX_PROMPT_TOKENS=51200
export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=16384

# If a model was passed as first argument (contains ':'), use it directly
if [[ "${1:-}" == *":"* ]]; then
    COPILOT_MODEL="$1"
    shift
    echo "  Using model: $COPILOT_MODEL"
    exec ollama launch copilot --model "$COPILOT_MODEL" --yes -- "$@"
fi

# No model specified — show picker
echo
echo "  --- Coding ---"
echo "  [1] Heavy coding        (qwen36-128k)"
echo "  [2] Light coding        (qwen3:14b)"
echo "  [3] Code review         (qwen3coder-65k)"
echo
echo "  --- Writing & Documents ---"
echo "  [4] Technical docs      (qwen36-128k)"
echo "  [5] Creative writing    (qwen36-128k)"
echo "  [6] Office documents    (qwen36-128k)"
echo
echo "  --- Visual ---"
echo "  [7] Image generation    (HiDream-O1 via MCP)"
echo
echo "  --- Remote ---"
echo "  [S] CachyOS server      (Qwen3.6 27B via vLLM)"
echo
read -rp "  Select task [1]: " choice
choice="${choice:-1}"

case "$choice" in
    1|2|3)
        MCP_FLAGS=(--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server pptx-mcp-xplat --disable-mcp-server imagegen-mcp)
        ;;
    4|5|6)
        MCP_FLAGS=(--disable-mcp-server imagegen-mcp)
        ;;
    7)
        MCP_FLAGS=(--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server pptx-mcp-xplat)
        ;;
    s|S)
        MCP_FLAGS=(--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server pptx-mcp-xplat --disable-mcp-server imagegen-mcp)
        ;;
esac

case "$choice" in
    1) export COPILOT_MODEL="qwen36-128k" ;;
    2) export COPILOT_MODEL="qwen3:14b" ;;
    3) export COPILOT_MODEL="qwen3coder-65k" ;;
    4|5|6) export COPILOT_MODEL="qwen36-128k" ;;
    7) export COPILOT_MODEL="qwen3:4b" ;;
    s|S)
        export COPILOT_PROVIDER_BASE_URL="http://__SQUIRE_SERVER_IP__:8000/v1"
        export COPILOT_MODEL="Qwen/Qwen3.6-27B-Instruct-GPTQ"
        ;;
    *) echo "  Invalid. Using qwen36-128k"; export COPILOT_MODEL="qwen36-128k" ;;
esac

# Git safety: block git write operations
GIT_SAFETY=(
    --deny-tool='shell(git add)' --deny-tool='shell(git commit)'
    --deny-tool='shell(git push)' --deny-tool='shell(git merge)'
    --deny-tool='shell(git rebase)' --deny-tool='shell(git reset)'
    --deny-tool='shell(git stash)' --deny-tool='shell(git cherry-pick)'
    --deny-tool='shell(git revert)' --deny-tool='shell(git tag)'
)

# PPTX instructions for doc profiles
EXTRA_FLAGS=()
if [[ "$choice" == "6" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    EXTRA_FLAGS=(--custom-instructions "$SCRIPT_DIR/../config/pptx-instructions.md")
fi

echo "  Using model: $COPILOT_MODEL"
echo
if [[ -n "${COPILOT_PROVIDER_BASE_URL:-}" ]]; then
    # Remote mode: launch copilot directly (skip ollama wrapper)
    echo "  Remote: $COPILOT_PROVIDER_BASE_URL"
    exec copilot --model "$COPILOT_MODEL" -- "${MCP_FLAGS[@]}" "${GIT_SAFETY[@]}" "${EXTRA_FLAGS[@]}" "$@"
else
    exec ollama launch copilot --model "$COPILOT_MODEL" --yes -- "${MCP_FLAGS[@]}" "${GIT_SAFETY[@]}" "${EXTRA_FLAGS[@]}" "$@"
fi
