#!/usr/bin/env bash
# crush-task — Task picker for Crush with MCP profile management
#
# Writes a project-level .crush.json with the right MCP servers enabled
# for the selected task, then launches Crush.
#
# Profiles:
#   coding  — no MCP servers (code tools + LSP only)
#   review  — Qwen3-Coder model, no MCP (different perspective)
#   docs    — office authoring (docx/pptx/xlsx) via the 'office' skill: the model writes
#             python-docx/python-pptx/openpyxl and runs it with uv (no document MCP servers)
#   image   — imagegen-mcp (image generation)
set -euo pipefail

# ── Provider gating (local Ollama / remote CachyOS server) ────────────────────
# Baked in by the installer; falls back to both if the placeholder was not substituted.
LL_PROVIDERS="__LL_PROVIDERS__"
[[ "$LL_PROVIDERS" == *"__"* || -z "$LL_PROVIDERS" ]] && LL_PROVIDERS="local,server"
_ll_has() { [[ ",${LL_PROVIDERS}," == *",$1,"* ]]; }

# Switch the CachyOS server's active model via the accountless web endpoint (:4090). The server
# loads one model at a time, so POST the mode then poll /status until it is loaded before launching
# Crush (so we never hand Crush a not-yet-ready model).
squire_switch() {
    local mode="$1" ip="__SQUIRE_SERVER_IP__" port="4090" i st
    if ! curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
            -d "{\"mode\":\"${mode}\"}" "http://${ip}:${port}/switch" >/dev/null 2>&1; then
        echo "  WARN: could not reach the model-switch service at http://${ip}:${port}/ - is the server up?"
        return 0
    fi
    printf '  ... switching server to %s' "$mode"
    for i in $(seq 1 30); do
        st="$(curl -fsS -m 5 "http://${ip}:${port}/status" 2>/dev/null || true)"
        if [[ "$st" == *"\"mode\": \"${mode}\""* && "$st" == *'"api_up": true'* ]]; then
            echo " - ready."
            return 0
        fi
        printf '.'
        sleep 3
    done
    echo " (still loading; give it a few more seconds)"
}

write_crush_config() {
    local imagegen_disabled="$1"
    local system_prompt="${2:-}"
    local model_override="${3:-}"
    local provider="${4:-ollama}"
    local active_label="${5:-}"   # server mode: friendly label for the single 'active-model' entry

    local providers_block=""
    local models_block=""

    # Output cap + assumed window, by provider. The server (vLLM on the 4090) runs SMALL windows
    # (coder/devstral/image 32K, glm 44K, mistral 64K), so cap output at 8K to avoid starving agentic
    # context and assume the 32K floor. Local Ollama runs 128K-256K windows, so a larger 32K cap is cheap.
    local max_tok=16384 ctx_win=65536
    if [[ "$provider" == "server" ]]; then
        max_tok=8192
        case "$active_label" in
            mistral-small)  ctx_win=65536 ;;
            glm-4.7-flash)  ctx_win=45056 ;;
            *)              ctx_win=32768 ;;
        esac
    fi

    # Per-provider override. For the server provider we expose ONE 'active-model' entry (so crush's
    # /model can never pick a not-yet-loaded model), and relabel it "Active: <model>" for visibility.
    local prov_inner=""
    if [[ -n "$active_label" ]]; then
        prov_inner="\"models\": [
        { \"name\": \"Active: ${active_label}\", \"id\": \"active-model\", \"context_window\": ${ctx_win}, \"default_max_tokens\": ${max_tok} }
      ]"
    fi
    if [[ -n "$system_prompt" ]]; then
        local sp_json
        sp_json="$(printf '%s' "$system_prompt" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')"
        if [[ -n "$prov_inner" ]]; then
            prov_inner="${prov_inner},
      \"system_prompt_prefix\": ${sp_json}"
        else
            prov_inner="\"system_prompt_prefix\": ${sp_json}"
        fi
    fi
    if [[ -n "$prov_inner" ]]; then
        providers_block=",
  \"providers\": {
    \"${provider}\": {
      ${prov_inner}
    }
  }"
    fi
    if [[ -n "$model_override" ]]; then
        models_block=",
  \"models\": {
    \"large\": {
      \"model\": \"${model_override}\",
      \"provider\": \"${provider}\",
      \"max_tokens\": ${max_tok}
    },
    \"small\": {
      \"model\": \"${model_override}\",
      \"provider\": \"${provider}\",
      \"max_tokens\": ${max_tok}
    }
  }"
    fi

    cat > .crush.json <<EOF
{
  "mcp": {
    "imagegen-mcp": { "disabled": ${imagegen_disabled} }
  }${providers_block}${models_block}
}
EOF
}

task="${1:-}"
SELECTED_MODEL=""
OFFLOAD_MODE=0
PROVIDER="ollama"
SWITCH_MODE=""
SRV_IMG=""

# ── Tier-aware Ollama alias/label registry ────────────────────────────────────
# Source the installer-generated tier config (~/.config/local-llm/ollama-tier.sh) so this
# picker presents the aliases that actually exist for the installed GPU tier (4090|5090).
# Fall back to the 5090 roster if the file is absent.
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
# Server (CachyOS vLLM) labels — added unconditionally so the banner resolves them regardless of
# whether the tier config was sourced (which would otherwise redefine LL_LABEL).
LL_LABEL[mistral-small]="Mistral-Small (CachyOS vLLM)"
LL_LABEL[glm-4.7-flash]="GLM-4.7-Flash (CachyOS vLLM)"
LL_LABEL[qwen3-coder]="Qwen3-Coder (CachyOS vLLM)"
LL_LABEL[devstral]="Devstral-2 24B (CachyOS vLLM)"
LL_LABEL[qwen3-4b]="Qwen3-4B image companion (CachyOS vLLM)"
_alias() { echo "${LL_ALIAS[$1]:-$1}"; }

DEFAULT_MODEL="$(_alias heavy)"
REVIEW_MODEL="$(_alias review)"

# Model assignments per task profile (tier-resolved).
model_for_task() {
    case "$1" in
        coding)   _alias heavy ;;   # heavy coding default
        review)   _alias review ;;  # Qwen3-Coder 30B-A3B
        docs)     _alias agentic ;; # GLM-4.7-Flash for office authoring (roomy, capable)
        image)    _alias image_llm ;;    # image-gen companion
        *)        _alias heavy ;;
    esac
}

if [[ -z "$task" ]]; then
    echo
    if _ll_has local; then
    echo "  --- Coding ---"
    echo "  [1] Heavy coding        (Qwen3.6 27B dense, no MCP)"
    echo "  [2] Light coding        (Qwen3-Coder 30B, no MCP)"
    echo "  [3] Code review         (Qwen3-Coder 30B, no MCP)"
    echo
    echo "  --- Writing & Documents ---"
    echo "  [4] Documents           (GLM-4.7-Flash + office skill: docx/pptx/xlsx via Python)"
    echo
    echo "  --- Visual ---"
    echo "  [5] Image generation    (Qwen3 8B + HiDream MCP)"
    echo
    echo "  ══ EXPERIMENTAL · models under evaluation ($LL_OLLAMA_TIER tier) ══════════"
    echo "  --- Heavy-coding bench (coding profile, swap model) ---"
    echo "  [H1] Qwen3.6 27B dense (default)"
    echo "  [H2] Qwen3.6 35B-A3B MoE"
    echo "  [H3] Gemma 4 31B dense"
    echo "  [H4] Qwen3-Coder 30B-A3B"
    echo "  [H5] GLM-4.7-Flash"
    echo "  [H6] North Mini Code 1.0    (Cohere, agentic coding)"
    echo "  [H7] Nemotron Cascade 2 30B (NVIDIA, reasoning/agentic)"
    echo "  [H8] Ornith-1.0-35B         (MIT, agentic-coding reasoning)"
    echo
    echo "  --- Big-MoE expert-offload bench (experts->RAM; partial offload, slower) ---"
    echo "  [O2] Qwen3-Next-80B-A3B     (offload, Q4_K_M ~45 GB)"
    echo
    fi
    if _ll_has server; then
    echo "  --- Remote (CachyOS server - one standing model, switch only when needed) ---"
    echo "  [S] CachyOS: Mistral-Small   (default - office/authoring, 64K)"
    echo "  [G] CachyOS: GLM-4.7-Flash   (agentic/reasoning - switches server)"
    echo "  [C] CachyOS: Qwen3-Coder     (coding-first - switches server)"
    echo "  [D] CachyOS: Devstral-2 24B  (coding-alt, agentic - switches server)"
    echo "  [I] CachyOS: Image gen       (HiDream + Qwen3-4B - switches server)"
    echo
    fi
    if _ll_has local; then default_choice=1; else default_choice=S; fi
    read -rp "  Select profile [$default_choice]: " choice
    choice="${choice:-$default_choice}"

    case "$choice" in
        1) task="coding" ;;
        2) task="coding"; SELECTED_MODEL="$(_alias coder)" ;;
        3) task="review" ;;
        4) task="docs" ;;
        5) task="image" ;;
        [Hh]1) task="coding"; SELECTED_MODEL="$(_alias h1)" ;;
        [Hh]2) task="coding"; SELECTED_MODEL="$(_alias h2)" ;;
        [Hh]3) task="coding"; SELECTED_MODEL="$(_alias h3)" ;;
        [Hh]4) task="coding"; SELECTED_MODEL="$(_alias h4)" ;;
        [Hh]5) task="coding"; SELECTED_MODEL="$(_alias h5)" ;;
        [Hh]6) task="coding"; SELECTED_MODEL="$(_alias h6)" ;;
        [Hh]7) task="coding"; SELECTED_MODEL="$(_alias h7)" ;;
        [Hh]8) task="coding"; SELECTED_MODEL="$(_alias h8)" ;;
        [Oo]2) task="coding"; SELECTED_MODEL="$(_alias o2)"; OFFLOAD_MODE=1 ;;
        [Ss]) PROVIDER="server"; SWITCH_MODE="mistral";   SELECTED_MODEL="mistral-small"; SRV_IMG=true ;;
        [Gg]) PROVIDER="server"; SWITCH_MODE="glm";       SELECTED_MODEL="glm-4.7-flash"; SRV_IMG=true ;;
        [Cc]) PROVIDER="server"; SWITCH_MODE="coder";     SELECTED_MODEL="qwen3-coder";   SRV_IMG=true ;;
        [Dd]) PROVIDER="server"; SWITCH_MODE="coder-alt"; SELECTED_MODEL="devstral";      SRV_IMG=true ;;
        [Ii]) PROVIDER="server"; SWITCH_MODE="image";     SELECTED_MODEL="qwen3-4b";      SRV_IMG=false ;;
        *)
            echo "  Invalid selection, defaulting to heavy coding."
            task="coding"
            ;;
    esac
fi

# Resolve model: explicit picker selection wins, else per-task default.
if [[ -z "$SELECTED_MODEL" ]]; then SELECTED_MODEL="$(model_for_task "$task")"; fi
DEFAULT_MODEL="$SELECTED_MODEL"
REVIEW_MODEL="$SELECTED_MODEL"

# Friendly label for the launch-identity banner (keyed on the resolved alias; LL_LABEL comes
# from the sourced tier config or the fallback above).
MODEL_FRIENDLY="${LL_LABEL[$DEFAULT_MODEL]:-$DEFAULT_MODEL}"
echo
echo "  ▶ $MODEL_FRIENDLY  ·  alias=$DEFAULT_MODEL"

if [[ "$PROVIDER" == "server" ]]; then
    [[ -n "$SWITCH_MODE" ]] && squire_switch "$SWITCH_MODE"
    write_crush_config "$SRV_IMG" "" "active-model" "server" "$SELECTED_MODEL"
    echo "  Profile: Remote CachyOS server ($SELECTED_MODEL via vLLM, addressed as active-model)"
else
case "$task" in
    coding)
        write_crush_config true "" "$DEFAULT_MODEL"
        echo "  Profile: Coding ($DEFAULT_MODEL, no MCP servers)"
        ;;
    review)
        REVIEW_GUIDE="You are a code reviewer. Focus on:
- Bugs, logic errors, and edge cases
- Security vulnerabilities (injection, auth, data exposure)
- Performance issues (N+1 queries, unnecessary allocations, blocking calls)
- API contract violations and type mismatches
- Concurrency issues (race conditions, deadlocks)
Do NOT comment on style, formatting, or naming conventions unless they cause bugs.
Be direct. If the code is correct, say so briefly."
        write_crush_config true "$REVIEW_GUIDE" "$REVIEW_MODEL"
        echo "  Profile: Code review (Qwen3-Coder 30B)"
        ;;
    docs)
        # Office authoring uses the vendored 'office' skill (discovered natively by crush from
        # ~/.config/crush/skills/office). The model writes python-docx/python-pptx/openpyxl and
        # runs it via `uv run --with ...` — no document MCP servers, near-zero context cost.
        write_crush_config true "" "$DEFAULT_MODEL"
        echo "  Profile: Documents / office authoring ($DEFAULT_MODEL + office skill: docx/pptx/xlsx via Python)"
        ;;
    image)
        write_crush_config false "" "$SELECTED_MODEL"
        echo "  Profile: Image generation (HiDream) — using $SELECTED_MODEL for VRAM headroom"
        ;;
    *)
        echo "  Unknown profile '$task', defaulting to coding."
        write_crush_config true "" "$DEFAULT_MODEL"
        echo "  Profile: Coding ($DEFAULT_MODEL, no MCP servers)"
        ;;
esac
fi

echo "  Config: $(pwd)/.crush.json"
echo

if [[ "$OFFLOAD_MODE" == "1" ]]; then
    # Big-MoE offload mode: run a dedicated Ollama serve with expert CPU-offload, then
    # restore the managed server when Crush exits.
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=offload-serve.sh
    source "$SCRIPT_DIR/offload-serve.sh"
    echo "  Offload mode: experts -> system RAM (partial; slower than VRAM-resident)"
    offload_start 24
    trap 'offload_stop' EXIT
    crush
else
    exec crush
fi
