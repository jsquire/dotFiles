#!/usr/bin/env bash
# copilot-local — Launch GitHub Copilot CLI with local Ollama models
set -euo pipefail

# Which provider groups this install enabled (baked in by the installer). Falls back to both.
LL_PROVIDERS="__LL_PROVIDERS__"
[[ "$LL_PROVIDERS" == *"__"* || -z "$LL_PROVIDERS" ]] && LL_PROVIDERS="local,server"
_ll_has() { [[ ",${LL_PROVIDERS}," == *",$1,"* ]]; }

export COPILOT_PROVIDER_MAX_PROMPT_TOKENS=51200
export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=16384

# ── Tier-aware Ollama alias/label registry ────────────────────────────────────
# The installer generates ~/.config/local-llm/ollama-tier.sh with the tier's task->alias
# SLOT map (LL_ALIAS) + alias->label registry (LL_LABEL). Sourcing it makes this launcher
# present the correct aliases for whichever GPU tier (4090|5090) was installed. If the file
# is absent (e.g. a copy not deployed by the installer), fall back to the 5090 roster.
declare -A LL_ALIAS
declare -A LL_LABEL
LL_OLLAMA_TIER="5090"
_LL_TIER_CONFIG="${HOME}/.config/local-llm/ollama-tier.sh"
if [[ -f "$_LL_TIER_CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$_LL_TIER_CONFIG"
else
    LL_ALIAS=(
        [heavy]=qwen36-27b-212k [coder]=qwen3coder-144k [review]=qwen3coder-144k
        [agentic]=glm47-flash-198k [image_llm]=qwen3:8b
        [h1]=qwen36-27b-212k [h2]=qwen36-35b-256k [h3]=gemma4-31b-128k [h4]=qwen3coder-144k
        [h5]=glm47-flash-198k [h6]=northmini-code-256k [h7]=nemotron-c2-256k [h8]=ornith-35b-256k
        [o2]=qwen3next-80b-offload
    )
    LL_LABEL=(
        [qwen36-27b-212k]="Qwen3.6 27B (+MTP)" [qwen36-35b-256k]="Qwen3.6 35B-A3B MoE"
        [gemma4-31b-128k]="Gemma 4 31B dense" [qwen3coder-144k]="Qwen3-Coder 30B-A3B"
        [glm47-flash-198k]="GLM-4.7-Flash" [northmini-code-256k]="North Mini Code 1.0"
        [nemotron-c2-256k]="Nemotron Cascade 2 30B-A3B" [ornith-35b-256k]="Ornith-1.0-35B"
        [qwen3next-80b-offload]="Qwen3-Next-80B-A3B (partial offload)" [qwen3:8b]="Qwen3 8B"
    )
fi
model_label() { echo "${LL_LABEL[$1]:-$1}"; }
_alias() { echo "${LL_ALIAS[$1]:-$1}"; }

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
echo "  [1] Heavy coding        ($(_alias heavy))"
echo "  [2] Light coding        ($(_alias coder))"
echo "  [3] Code review         ($(_alias review))"
echo
echo "  --- Writing & Documents ---"
echo "  [4] Technical docs      ($(_alias heavy))"
echo "  [5] Creative writing    ($(_alias heavy))"
echo "  [6] Office documents    ($(_alias agentic))"
echo
echo "  --- Visual ---"
echo "  [7] Image generation    ($(_alias image_llm) + HiDream via MCP)"
echo
echo "  ══ EXPERIMENTAL · models under evaluation ($LL_OLLAMA_TIER tier) ══════════"
echo "  --- Heavy-coding bench (VRAM-resident; swap model, all MCP off) ---"
echo "  [H1] Qwen3.6 27B+MTP        ($(_alias h1))"
echo "  [H2] Qwen3.6 35B-A3B MoE    ($(_alias h2))"
echo "  [H3] Gemma 4 31B dense      ($(_alias h3))"
echo "  [H4] Qwen3-Coder 30B-A3B    ($(_alias h4))"
echo "  [H5] GLM-4.7-Flash          ($(_alias h5))"
echo "  [H6] North Mini Code 1.0    ($(_alias h6))"
echo "  [H7] Nemotron Cascade 2 30B ($(_alias h7))"
echo "  [H8] Ornith-1.0-35B         ($(_alias h8))"
echo
echo "  --- Big-MoE expert-offload bench (experts->RAM; partial offload, slower) ---"
echo "  [O2] Qwen3-Next-80B-A3B     (offload, Q4_K_M ~45 GB)"
fi
echo
if _ll_has server; then
echo "  --- Remote (CachyOS server — one standing model, switch only when needed) ---"
echo "  [S] CachyOS: Mistral-Small   (default — office/authoring, 64K)"
echo "  [G] CachyOS: GLM-4.7-Flash   (agentic/reasoning — switches server)"
echo "  [C] CachyOS: Qwen3-Coder     (coding-first — switches server)"
echo "  [D] CachyOS: Devstral-2 24B   (coding-alt, agentic — switches server)"
echo "  [I] CachyOS: Image gen        (HiDream + Qwen3-4B — switches server)"
fi
echo
if _ll_has local; then default_choice=1; else default_choice=S; fi
read -rp "  Select task [$default_choice]: " choice
choice="${choice:-$default_choice}"
OFFLOAD_MODE=0

case "$choice" in
    7)
        # Image generation — keep imagegen-mcp enabled
        MCP_FLAGS=()
        ;;
    i|I)
        # Remote image mode — keep imagegen-mcp enabled
        MCP_FLAGS=()
        ;;
    *)
        # Everything else: no document MCP servers (office authoring uses the code-gen skill);
        # imagegen-mcp is the only MCP server and is off outside the image profiles.
        MCP_FLAGS=(--disable-mcp-server imagegen-mcp)
        ;;
esac

case "$choice" in
    1) export COPILOT_MODEL="$(_alias heavy)" ;;
    2) export COPILOT_MODEL="$(_alias coder)" ;;
    3) export COPILOT_MODEL="$(_alias review)" ;;
    4|5) export COPILOT_MODEL="$(_alias heavy)" ;;
    6) export COPILOT_MODEL="$(_alias agentic)" ;;
    7) export COPILOT_MODEL="$(_alias image_llm)" ;;
    [oO]2) export COPILOT_MODEL="$(_alias o2)"; OFFLOAD_MODE=1 ;;
    [Hh]1) export COPILOT_MODEL="$(_alias h1)" ;;
    [Hh]2) export COPILOT_MODEL="$(_alias h2)" ;;
    [Hh]3) export COPILOT_MODEL="$(_alias h3)" ;;
    [Hh]4) export COPILOT_MODEL="$(_alias h4)" ;;
    [Hh]5) export COPILOT_MODEL="$(_alias h5)" ;;
    [Hh]6) export COPILOT_MODEL="$(_alias h6)" ;;
    [Hh]7) export COPILOT_MODEL="$(_alias h7)" ;;
    [Hh]8) export COPILOT_MODEL="$(_alias h8)" ;;
    s|S)
        squire_switch mistral
        export COPILOT_PROVIDER_BASE_URL="http://__SQUIRE_SERVER_IP__:8000/v1"
        export COPILOT_MODEL="mistral-small"
        # Server window 64K. Cap prompt+output under it (output 8192 leaves ~54K prompt); mirrors crush.
        export COPILOT_PROVIDER_MAX_PROMPT_TOKENS=54272
        export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=8192
        ;;
    g|G)
        squire_switch glm
        export COPILOT_PROVIDER_BASE_URL="http://__SQUIRE_SERVER_IP__:8000/v1"
        export COPILOT_MODEL="glm-4.7-flash"
        # Server window 54K. Cap prompt+output under it (output 8192 leaves ~44K prompt); mirrors crush.
        export COPILOT_PROVIDER_MAX_PROMPT_TOKENS=44032
        export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=8192
        ;;
    c|C)
        squire_switch coder
        export COPILOT_PROVIDER_BASE_URL="http://__SQUIRE_SERVER_IP__:8000/v1"
        export COPILOT_MODEL="qwen3-coder"
        # Server window 56K. Cap prompt+output under it (output 8192 leaves ~46K prompt); mirrors crush.
        export COPILOT_PROVIDER_MAX_PROMPT_TOKENS=46080
        export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=8192
        ;;
    d|D)
        squire_switch coder-alt
        export COPILOT_PROVIDER_BASE_URL="http://__SQUIRE_SERVER_IP__:8000/v1"
        export COPILOT_MODEL="devstral"
        # Server window 56K. Cap prompt+output under it (output 8192 leaves ~46K prompt); mirrors crush.
        export COPILOT_PROVIDER_MAX_PROMPT_TOKENS=46080
        export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=8192
        ;;
    i|I)
        squire_switch image
        export COPILOT_PROVIDER_BASE_URL="http://__SQUIRE_SERVER_IP__:8000/v1"
        export COPILOT_MODEL="qwen3-4b"
        # Image companion serves a 16K window (desktop-up 1.7B tier; headless 4B >= this). Shrink the
        # global caps so prompt+output stay under it (mirrors the crush ctx_win=16384 floor).
        export COPILOT_PROVIDER_MAX_PROMPT_TOKENS=10240
        export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=4096
        ;;
    *) echo "  Invalid. Using $(_alias heavy)"; export COPILOT_MODEL="$(_alias heavy)" ;;
esac

# Git safety: block git write operations
GIT_SAFETY=(
    --deny-tool='shell(git add)' --deny-tool='shell(git commit)'
    --deny-tool='shell(git push)' --deny-tool='shell(git merge)'
    --deny-tool='shell(git rebase)' --deny-tool='shell(git reset)'
    --deny-tool='shell(git stash)' --deny-tool='shell(git cherry-pick)'
    --deny-tool='shell(git revert)' --deny-tool='shell(git tag)'
)

# Office authoring guidance for the Office documents profile: inject the vendored 'office' skill
# (deployed by the installer) as custom instructions — Copilot CLI has no native skill discovery.
EXTRA_FLAGS=()
if [[ "$choice" == "6" ]]; then
    OFFICE_SKILL="${HOME}/.config/crush/skills/office/SKILL.md"
    [[ -f "$OFFICE_SKILL" ]] && EXTRA_FLAGS=(--custom-instructions "$OFFICE_SKILL")
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
