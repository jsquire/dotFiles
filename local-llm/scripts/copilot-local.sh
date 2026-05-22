#!/usr/bin/env bash
# copilot-local — Launch GitHub Copilot CLI with local Ollama models
set -euo pipefail

export COPILOT_PROVIDER_MAX_PROMPT_TOKENS=14000
export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=8000

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
echo "  [1] Heavy coding        (gemma4-65k)"
echo "  [2] Light coding        (qwen3:14b)"
echo "  [3] Code review         (qwen3coder-65k)"
echo
echo "  --- Writing & Documents ---"
echo "  [4] Technical docs      (gemma4-65k)"
echo "  [5] Creative writing    (gemma4-65k)"
echo "  [6] Office documents    (gemma4-65k)"
echo
echo "  --- Visual ---"
echo "  [7] Image generation    (HiDream-O1 via MCP)"
echo
read -rp "  Select task [1]: " choice
choice="${choice:-1}"

# Set MCP flags based on task category
MCP_FLAGS=()
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
esac

case "$choice" in
    1) export COPILOT_MODEL="gemma4-65k" ;;
    2) export COPILOT_MODEL="qwen3:14b" ;;
    3) export COPILOT_MODEL="qwen3coder-65k" ;;
    4|5|6) export COPILOT_MODEL="gemma4-65k" ;;
    7) export COPILOT_MODEL="qwen3:4b" ;;
    *) echo "  Invalid. Using gemma4-65k"; export COPILOT_MODEL="gemma4-65k" ;;
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
exec ollama launch copilot --model "$COPILOT_MODEL" --yes -- "${MCP_FLAGS[@]}" "${GIT_SAFETY[@]}" "${EXTRA_FLAGS[@]}" "$@"
