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
echo "  [1] Heavy coding        (qwen36-27b-256k)"
echo "  [2] Light coding        (qwen3coder-256k)"
echo "  [3] Code review         (qwen3coder-256k)"
echo
echo "  --- Writing & Documents ---"
echo "  [4] Technical docs      (qwen36-27b-256k)"
echo "  [5] Creative writing    (qwen36-27b-256k)"
echo "  [6] Office documents    (glm47-flash-198k)"
echo
echo "  --- Visual ---"
echo "  [7] Image generation    (qwen3:8b + HiDream via MCP)"
echo
echo "  --- Big-MoE expert-offload bench (experts->RAM; slower, for models that don't fit) ---"
echo "  [O1] gpt-oss-120b           (offload, ~65 GB MXFP4)"
echo "  [O2] Qwen3-Next-80B-A3B     (offload, needs imported Q4 GGUF)"
echo
echo "  --- Remote (CachyOS server — one standing model, switch only when needed) ---"
echo "  [S] CachyOS: GLM-4.7-Flash   (default — coding + review + office MCP)"
echo "  [C] CachyOS: Qwen3-Coder     (coding-first — switches server)"
echo "  [V] CachyOS: Qwen3.6-35B      (vision — switches server)"
echo "  [I] CachyOS: Image gen        (HiDream + Qwen3-4B — switches server)"
echo
read -rp "  Select task [1]: " choice
choice="${choice:-1}"
OFFLOAD_MODE=0

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
    [oO]1|[oO]2)
        MCP_FLAGS=(--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server pptx-mcp-xplat --disable-mcp-server imagegen-mcp)
        ;;
    s|S)
        MCP_FLAGS=(--disable-mcp-server imagegen-mcp)
        ;;
    c|C|v|V)
        MCP_FLAGS=(--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server pptx-mcp-xplat --disable-mcp-server imagegen-mcp)
        ;;
    i|I)
        MCP_FLAGS=(--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server pptx-mcp-xplat)
        ;;
esac

case "$choice" in
    1) export COPILOT_MODEL="qwen36-27b-256k" ;;
    2) export COPILOT_MODEL="qwen3coder-256k" ;;
    3) export COPILOT_MODEL="qwen3coder-256k" ;;
    4|5) export COPILOT_MODEL="qwen36-27b-256k" ;;
    6) export COPILOT_MODEL="glm47-flash-198k" ;;
    7) export COPILOT_MODEL="qwen3:8b" ;;
    [oO]1) export COPILOT_MODEL="gptoss-120b-offload"; OFFLOAD_MODE=1 ;;
    [oO]2) export COPILOT_MODEL="qwen3next-80b-offload"; OFFLOAD_MODE=1 ;;
    s|S)
        ssh __SQUIRE_SSH_TARGET__ "cachyos-switch-model glm" 2>/dev/null || true
        export COPILOT_PROVIDER_BASE_URL="http://__SQUIRE_SERVER_IP__:8000/v1"
        export COPILOT_MODEL="glm-4.7-flash"
        ;;
    c|C)
        ssh __SQUIRE_SSH_TARGET__ "cachyos-switch-model coder" 2>/dev/null || true
        export COPILOT_PROVIDER_BASE_URL="http://__SQUIRE_SERVER_IP__:8000/v1"
        export COPILOT_MODEL="qwen3-coder"
        ;;
    v|V)
        ssh __SQUIRE_SSH_TARGET__ "cachyos-switch-model vision" 2>/dev/null || true
        export COPILOT_PROVIDER_BASE_URL="http://__SQUIRE_SERVER_IP__:8000/v1"
        export COPILOT_MODEL="qwen3.6-35b"
        ;;
    i|I)
        ssh __SQUIRE_SSH_TARGET__ "cachyos-switch-model image" 2>/dev/null || true
        export COPILOT_PROVIDER_BASE_URL="http://__SQUIRE_SERVER_IP__:8000/v1"
        export COPILOT_MODEL="qwen3-4b"
        ;;
    *) echo "  Invalid. Using qwen36-27b-256k"; export COPILOT_MODEL="qwen36-27b-256k" ;;
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
elif [[ "$OFFLOAD_MODE" == "1" ]]; then
    # Big-MoE offload mode: dedicated Ollama serve with expert CPU-offload, restored on exit.
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=offload-serve.sh
    source "$SCRIPT_DIR/offload-serve.sh"
    echo "  Offload mode: experts -> system RAM (slower; for models that don't fit)"
    offload_start
    trap 'offload_stop' EXIT
    ollama launch copilot --model "$COPILOT_MODEL" --yes -- "${MCP_FLAGS[@]}" "${GIT_SAFETY[@]}" "${EXTRA_FLAGS[@]}" "$@"
else
    exec ollama launch copilot --model "$COPILOT_MODEL" --yes -- "${MCP_FLAGS[@]}" "${GIT_SAFETY[@]}" "${EXTRA_FLAGS[@]}" "$@"
fi
