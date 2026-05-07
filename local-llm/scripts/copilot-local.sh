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
    echo "  [1] Heavy coding        (qwen2.5-coder:32b)"
    echo "  [2] Light coding        (qwen2.5-coder:14b)"
    echo "  [3] Code review         (deepseek-r1:32b)"
    echo
    echo "  --- Writing & Documents ---"
    echo "  [4] Technical docs      (mistral-small3.2:24b)"
    echo "  [5] Creative writing    (mistral-small3.2:24b)"
    echo "  [6] Office documents    (mistral-small3.2:24b)"
else
    echo "  [1] Heavy coding        (gemma4:31b)"
    echo "  [2] Light coding        (qwen3:14b)"
    echo "  [3] Code review         (deepseek-r1:32b)"
    echo
    echo "  --- Writing & Documents ---"
    echo "  [4] Technical docs      (gemma3:27b)"
    echo "  [5] Creative writing    (llama3.3:70b-instruct-q2_K)"
    echo "  [6] Office documents    (qwen3-coder:30b)"
fi
echo
echo "  --- Visual ---"
echo "  [7] Image generation    (ComfyUI - launches separately)"
echo
read -rp "  Select task [1]: " choice
choice="${choice:-1}"

if [[ "$PROFILE" == "Server" ]]; then
    case "$choice" in
        1) export COPILOT_MODEL="qwen2.5-coder:32b" ;;
        2) export COPILOT_MODEL="qwen2.5-coder:14b" ;;
        3) export COPILOT_MODEL="deepseek-r1:32b" ;;
        4|5|6) export COPILOT_MODEL="mistral-small3.2:24b" ;;
        7) echo; echo "  Image generation requires ComfyUI."; exit 0 ;;
        *) echo "  Invalid. Using qwen2.5-coder:32b"; export COPILOT_MODEL="qwen2.5-coder:32b" ;;
    esac
else
    case "$choice" in
        1) export COPILOT_MODEL="gemma4:31b" ;;
        2) export COPILOT_MODEL="qwen3:14b" ;;
        3) export COPILOT_MODEL="deepseek-r1:32b" ;;
        4) export COPILOT_MODEL="gemma3:27b" ;;
        5) export COPILOT_MODEL="llama3.3:70b-instruct-q2_K" ;;
        6) export COPILOT_MODEL="qwen3-coder:30b" ;;
        7) echo; echo "  Image generation requires ComfyUI."; exit 0 ;;
        *) echo "  Invalid. Using gemma4:31b"; export COPILOT_MODEL="gemma4:31b" ;;
    esac
fi

echo "  Using model: $COPILOT_MODEL"
echo
exec copilot "$@"
