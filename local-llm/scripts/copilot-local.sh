#!/usr/bin/env bash
# copilot-local — Launch GitHub Copilot CLI with local Ollama models
set -euo pipefail

# Which provider groups this install enabled (baked in by the installer). Falls back to both.
LL_PROVIDERS="__LL_PROVIDERS__"
[[ "$LL_PROVIDERS" == *"__"* || -z "$LL_PROVIDERS" ]] && LL_PROVIDERS="local,squire-server"
_ll_has() { [[ ",${LL_PROVIDERS}," == *",$1,"* ]]; }

export COPILOT_PROVIDER_MAX_PROMPT_TOKENS=51200
export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=16384

# Friendly labels for the launch-identity banner — keyed on the resolved alias so the banner is
# correct for every path (picker slot, direct first-arg, or default fallback). Doubles as the
# human-readable registry of the bench roster.
declare -A MODEL_LABEL=(
    [qwen36-27b-212k]="Qwen3.6 27B (+MTP)"
    [qwen36-35b-256k]="Qwen3.6 35B-A3B MoE"
    [gemma4-31b-128k]="Gemma 4 31B dense"
    [qwen3coder-144k]="Qwen3-Coder 30B-A3B"
    [glm47-flash-198k]="GLM-4.7-Flash"
    [northmini-code-256k]="North Mini Code 1.0"
    [nemotron-c2-256k]="Nemotron Cascade 2 30B-A3B"
    [ornith-35b-256k]="Ornith-1.0-35B"
    [qwen3next-80b-offload]="Qwen3-Next-80B-A3B (partial offload)"
    [qwen3:8b]="Qwen3 8B"
)
model_label() { echo "${MODEL_LABEL[$1]:-$1}"; }

# Switch the Squire server's active model via the accountless web endpoint (:4090) — no SSH account
# needed. The server loads one model at a time, so we POST the desired mode then poll /status until it
# is loaded (bounded), so the client isn't launched against a not-yet-ready model.
squire_switch() {
    local mode="$1" ip="__SQUIRE_SERVER_IP__" port="4090" i st
    if ! curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
            -d "{\"mode\":\"${mode}\"}" "http://${ip}:${port}/switch" >/dev/null 2>&1; then
        echo "  ⚠  Could not reach the model-switch service at http://${ip}:${port}/ — is the server up?"
        return 0
    fi
    printf '  ⋯ switching server to %s' "$mode"
    for i in $(seq 1 30); do
        st="$(curl -fsS -m 5 "http://${ip}:${port}/status" 2>/dev/null || true)"
        if [[ "$st" == *"\"mode\": \"${mode}\""* && "$st" == *'"api_up": true'* ]]; then
            echo " — ready."
            return 0
        fi
        printf '.'
        sleep 3
    done
    echo " (still loading; give it a few more seconds)"
}

# If a model was passed as first argument (contains ':'), use it directly
if [[ "${1:-}" == *":"* ]]; then
    COPILOT_MODEL="$1"
    shift
    echo "  ▶ $(model_label "$COPILOT_MODEL")  ·  alias=$COPILOT_MODEL"
    export COPILOT_PROVIDER_BASE_URL="http://localhost:11434/v1"
    exec copilot --model "$COPILOT_MODEL" -- "$@"
fi

# No model specified — show picker
echo
if _ll_has local; then
echo "  --- Coding ---"
echo "  [1] Heavy coding        (qwen36-27b-212k)"
echo "  [2] Light coding        (qwen3coder-144k)"
echo "  [3] Code review         (qwen3coder-144k)"
echo
echo "  --- Writing & Documents ---"
echo "  [4] Technical docs      (qwen36-27b-212k)"
echo "  [5] Creative writing    (qwen36-27b-212k)"
echo "  [6] Office documents    (glm47-flash-198k)"
echo
echo "  --- Visual ---"
echo "  [7] Image generation    (qwen3:8b + HiDream via MCP)"
echo
echo "  ══ EXPERIMENTAL · models under evaluation ════════════════"
echo "  --- Heavy-coding bench (VRAM-resident; swap model, all MCP off) ---"
echo "  [H1] Qwen3.6 27B+MTP        (qwen36-27b-212k)"
echo "  [H2] Qwen3.6 35B-A3B MoE    (qwen36-35b-256k)"
echo "  [H3] Gemma 4 31B dense      (gemma4-31b-128k)"
echo "  [H4] Qwen3-Coder 30B-A3B    (qwen3coder-144k)"
echo "  [H5] GLM-4.7-Flash          (glm47-flash-198k)"
echo "  [H6] North Mini Code 1.0    (northmini-code-256k)"
echo "  [H7] Nemotron Cascade 2 30B (nemotron-c2-256k)"
echo "  [H8] Ornith-1.0-35B         (ornith-35b-256k)"
echo
echo "  --- Big-MoE expert-offload bench (experts->RAM; partial offload, slower) ---"
echo "  [O2] Qwen3-Next-80B-A3B     (offload, Q4_K_M ~45 GB)"
fi
echo
if _ll_has squire-server; then
echo "  --- Remote (CachyOS server — one standing model, switch only when needed) ---"
echo "  [S] CachyOS: Mistral-Small   (default — office/authoring, 64K)"
echo "  [G] CachyOS: GLM-4.7-Flash   (agentic/reasoning — switches server)"
echo "  [C] CachyOS: Qwen3-Coder     (coding-first — switches server)"
echo "  [D] CachyOS: Devstral-2 24B   (coding-alt, agentic — switches server)"
echo "  [I] CachyOS: Image gen        (HiDream + Qwen3-4B — switches server)"
fi
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
    [Hh][1-8])
        MCP_FLAGS=(--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server pptx-mcp-xplat --disable-mcp-server imagegen-mcp)
        ;;
    s|S|g|G)
        MCP_FLAGS=(--disable-mcp-server imagegen-mcp)
        ;;
    c|C|d|D)
        MCP_FLAGS=(--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server pptx-mcp-xplat --disable-mcp-server imagegen-mcp)
        ;;
    i|I)
        MCP_FLAGS=(--disable-mcp-server word-mcp --disable-mcp-server pptx-mcp --disable-mcp-server pptx-mcp-xplat)
        ;;
esac

case "$choice" in
    1) export COPILOT_MODEL="qwen36-27b-212k" ;;
    2) export COPILOT_MODEL="qwen3coder-144k" ;;
    3) export COPILOT_MODEL="qwen3coder-144k" ;;
    4|5) export COPILOT_MODEL="qwen36-27b-212k" ;;
    6) export COPILOT_MODEL="glm47-flash-198k" ;;
    7) export COPILOT_MODEL="qwen3:8b" ;;
    [oO]2) export COPILOT_MODEL="qwen3next-80b-offload"; OFFLOAD_MODE=1 ;;
    [Hh]1) export COPILOT_MODEL="qwen36-27b-212k" ;;
    [Hh]2) export COPILOT_MODEL="qwen36-35b-256k" ;;
    [Hh]3) export COPILOT_MODEL="gemma4-31b-128k" ;;
    [Hh]4) export COPILOT_MODEL="qwen3coder-144k" ;;
    [Hh]5) export COPILOT_MODEL="glm47-flash-198k" ;;
    [Hh]6) export COPILOT_MODEL="northmini-code-256k" ;;
    [Hh]7) export COPILOT_MODEL="nemotron-c2-256k" ;;
    [Hh]8) export COPILOT_MODEL="ornith-35b-256k" ;;
    s|S)
        squire_switch mistral
        export COPILOT_PROVIDER_BASE_URL="http://__SQUIRE_SERVER_IP__:8000/v1"
        export COPILOT_MODEL="mistral-small"
        ;;
    g|G)
        squire_switch glm
        export COPILOT_PROVIDER_BASE_URL="http://__SQUIRE_SERVER_IP__:8000/v1"
        export COPILOT_MODEL="glm-4.7-flash"
        ;;
    c|C)
        squire_switch coder
        export COPILOT_PROVIDER_BASE_URL="http://__SQUIRE_SERVER_IP__:8000/v1"
        export COPILOT_MODEL="qwen3-coder"
        ;;
    d|D)
        squire_switch coder-alt
        export COPILOT_PROVIDER_BASE_URL="http://__SQUIRE_SERVER_IP__:8000/v1"
        export COPILOT_MODEL="devstral"
        ;;
    i|I)
        squire_switch image
        export COPILOT_PROVIDER_BASE_URL="http://__SQUIRE_SERVER_IP__:8000/v1"
        export COPILOT_MODEL="qwen3-4b"
        ;;
    *) echo "  Invalid. Using qwen36-27b-212k"; export COPILOT_MODEL="qwen36-27b-212k" ;;
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

case "$choice" in
    [Hh]*) SLOT="[${choice^^}] experimental · heavy bench" ;;
    [Oo]*) SLOT="[${choice^^}] experimental · offload bench" ;;
    [1-9]) SLOT="[$choice] task profile" ;;
    *)     SLOT="" ;;
esac
echo "  ▶ $(model_label "$COPILOT_MODEL")  ·  alias=$COPILOT_MODEL${SLOT:+  ·  $SLOT}"
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
    echo "  Offload mode: experts -> system RAM (partial; slower than VRAM-resident)"
    offload_start 24
    trap 'offload_stop' EXIT
    export COPILOT_PROVIDER_BASE_URL="http://localhost:11434/v1"
    copilot --model "$COPILOT_MODEL" -- "${MCP_FLAGS[@]}" "${GIT_SAFETY[@]}" "${EXTRA_FLAGS[@]}" "$@"
else
    export COPILOT_PROVIDER_BASE_URL="http://localhost:11434/v1"
    exec copilot --model "$COPILOT_MODEL" -- "${MCP_FLAGS[@]}" "${GIT_SAFETY[@]}" "${EXTRA_FLAGS[@]}" "$@"
fi
