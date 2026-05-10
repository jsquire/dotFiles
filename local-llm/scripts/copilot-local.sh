#!/usr/bin/env bash
# copilot-local — Launch GitHub Copilot CLI with local Ollama models
set -euo pipefail

export COPILOT_PROVIDER_BASE_URL="http://localhost:11434/v1"
export COPILOT_PROVIDER_MAX_PROMPT_TOKENS=14000
export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=8000

# If a model was passed as first argument (contains ':'), use it directly
if [[ "${1:-}" == *":"* ]]; then
    export COPILOT_MODEL="$1"
    shift
    echo "  Using model: $COPILOT_MODEL"
    exec copilot "$@"
fi

# Detect profile from environment or default to Desktop
PROFILE="${COPILOT_LOCAL_PROFILE:-Desktop}"

# No model specified — show picker
echo
echo "  --- Coding ---"
if [[ "$PROFILE" == "Server" ]]; then
    echo "  [1] Heavy coding        (glm-4.7-flash)"
    echo "  [2] Light coding        (qwen2.5-coder:14b)"
    echo "  [3] Code review         (deepseek-r1:32b)"
    echo
    echo "  --- Writing & Documents ---"
    echo "  [4] Technical docs      (glm-4.7-flash)"
    echo "  [5] Creative writing    (glm-4.7-flash)"
    echo "  [6] Office documents    (glm-4.7-flash)"
else
    echo "  [1] Heavy coding        (glm-4.7-flash)"
    echo "  [2] Light coding        (qwen3:14b)"
    echo "  [3] Code review         (deepseek-r1:32b)"
    echo
    echo "  --- Writing & Documents ---"
    echo "  [4] Technical docs      (glm-4.7-flash)"
    echo "  [5] Creative writing    (glm-4.7-flash)"
    echo "  [6] Office documents    (glm-4.7-flash)"
fi
echo
echo "  --- Visual ---"
echo "  [7] Image generation    (FLUX.1-schnell via MCP)"
echo
read -rp "  Select task [1]: " choice
choice="${choice:-1}"

# Set MCP flags based on task category
MCP_FLAGS=()
case "$choice" in
    1|2|3)
        MCP_FLAGS=(--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server imagegen-mcp)
        ;;
    4|5|6)
        MCP_FLAGS=(--disable-mcp-server imagegen-mcp)
        ;;
    7)
        MCP_FLAGS=(--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp)
        ;;
esac

if [[ "$PROFILE" == "Server" ]]; then
    case "$choice" in
        1) export COPILOT_MODEL="glm-4.7-flash" ;;
        2) export COPILOT_MODEL="qwen2.5-coder:14b" ;;
        3) export COPILOT_MODEL="deepseek-r1:32b" ;;
        4|5|6) export COPILOT_MODEL="glm-4.7-flash" ;;
        7) export COPILOT_MODEL="glm-4.7-flash" ;;
        *) echo "  Invalid. Using glm-4.7-flash"; export COPILOT_MODEL="glm-4.7-flash" ;;
    esac
else
    case "$choice" in
        1) export COPILOT_MODEL="glm-4.7-flash" ;;
        2) export COPILOT_MODEL="qwen3:14b" ;;
        3) export COPILOT_MODEL="deepseek-r1:32b" ;;
        4|5|6) export COPILOT_MODEL="glm-4.7-flash" ;;
        7) export COPILOT_MODEL="glm-4.7-flash" ;;
        *) echo "  Invalid. Using glm-4.7-flash"; export COPILOT_MODEL="glm-4.7-flash" ;;
    esac
fi

echo "  Using model: $COPILOT_MODEL"
echo
exec copilot "${MCP_FLAGS[@]}" "$@"
