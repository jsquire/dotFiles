#!/usr/bin/env bash
# crush-task — Task picker for Crush with MCP profile management
#
# Writes a project-level .crush.json with the right MCP servers enabled
# for the selected task, then launches Crush.
#
# Profiles:
#   coding  — no MCP servers (code tools + LSP only)
#   review  — Qwen3-Coder model, no MCP (different perspective)
#   general — Word MCP + gh CLI (research & document authoring)
#   word    — word-mcp only (Word document editing)
#   pptx    — pptx-mcp only (PowerPoint editing)
#   docs    — doc-coauthoring skill + Word MCP (structured workflow)
#   image   — imagegen-mcp (image generation)
#   all     — everything enabled (may degrade with smaller models)
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
    local word_disabled="$1"
    local pptx_disabled="$2"
    local imagegen_disabled="$3"
    local system_prompt="${4:-}"
    local model_override="${5:-}"
    local provider="${6:-ollama}"

    local providers_block=""
    local models_block=""
    if [[ -n "$system_prompt" ]]; then
        providers_block=",
  \"providers\": {
    \"${provider}\": {
      \"system_prompt_prefix\": $(printf '%s' "$system_prompt" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
    }
  }"
    fi
    if [[ -n "$model_override" ]]; then
        models_block=",
  \"models\": {
    \"large\": {
      \"model\": \"${model_override}\",
      \"provider\": \"${provider}\",
      \"max_tokens\": 32000
    },
    \"small\": {
      \"model\": \"${model_override}\",
      \"provider\": \"${provider}\",
      \"max_tokens\": 32000
    }
  }"
    fi

    cat > .crush.json <<EOF
{
  "mcp": {
    "word-mcp": { "disabled": ${word_disabled} },
    "pptx-mcp": { "disabled": true },
    "pptx-mcp-xplat": { "disabled": ${pptx_disabled} },
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
SRV_WORD=""
SRV_PPTX=""
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
        coding)                 _alias heavy ;;   # heavy coding default
        review)                 _alias review ;;  # Qwen3-Coder 30B-A3B
        general|word|pptx|docs|all) _alias agentic ;;  # GLM-4.7-Flash tool/MCP
        image)                  _alias image_llm ;;    # image-gen companion
        *)                      _alias heavy ;;
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
    echo "  [4] General research    (GLM-4.7-Flash + Word MCP)"
    echo "  [5] Word editing        (GLM-4.7-Flash + Word MCP)"
    echo "  [6] PowerPoint          (GLM-4.7-Flash + PPTX MCP)"
    echo "  [7] Guided authoring    (GLM-4.7-Flash + doc skill)"
    echo
    echo "  --- Visual ---"
    echo "  [8] Image generation    (Qwen3 8B + HiDream MCP)"
    echo
    echo "  --- Everything ---"
    echo "  [9] All tools           (GLM-4.7-Flash, all MCP, may be slow)"
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
        4) task="general" ;;
        5) task="word" ;;
        6) task="pptx" ;;
        7) task="docs" ;;
        8) task="image" ;;
        9) task="all" ;;
        [Hh]1) task="coding"; SELECTED_MODEL="$(_alias h1)" ;;
        [Hh]2) task="coding"; SELECTED_MODEL="$(_alias h2)" ;;
        [Hh]3) task="coding"; SELECTED_MODEL="$(_alias h3)" ;;
        [Hh]4) task="coding"; SELECTED_MODEL="$(_alias h4)" ;;
        [Hh]5) task="coding"; SELECTED_MODEL="$(_alias h5)" ;;
        [Hh]6) task="coding"; SELECTED_MODEL="$(_alias h6)" ;;
        [Hh]7) task="coding"; SELECTED_MODEL="$(_alias h7)" ;;
        [Hh]8) task="coding"; SELECTED_MODEL="$(_alias h8)" ;;
        [Oo]2) task="coding"; SELECTED_MODEL="$(_alias o2)"; OFFLOAD_MODE=1 ;;
        [Ss]) PROVIDER="server"; SWITCH_MODE="mistral";   SELECTED_MODEL="mistral-small"; SRV_WORD=false; SRV_PPTX=false; SRV_IMG=true ;;
        [Gg]) PROVIDER="server"; SWITCH_MODE="glm";       SELECTED_MODEL="glm-4.7-flash"; SRV_WORD=false; SRV_PPTX=false; SRV_IMG=true ;;
        [Cc]) PROVIDER="server"; SWITCH_MODE="coder";     SELECTED_MODEL="qwen3-coder";   SRV_WORD=true;  SRV_PPTX=true;  SRV_IMG=true ;;
        [Dd]) PROVIDER="server"; SWITCH_MODE="coder-alt"; SELECTED_MODEL="devstral";      SRV_WORD=true;  SRV_PPTX=true;  SRV_IMG=true ;;
        [Ii]) PROVIDER="server"; SWITCH_MODE="image";     SELECTED_MODEL="qwen3-4b";      SRV_WORD=true;  SRV_PPTX=true;  SRV_IMG=false ;;
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

PPTX_GUIDE="IMPORTANT: Be concise. Do not explain what you will do — just do it. Minimize output.

office-powerpoint-mcp-server provides cross-platform PPTX editing via python-pptx (32 tools).

WORKFLOW: create_presentation or open existing → edit slides → save
Operates on .pptx files directly (no live PowerPoint needed).

KEY TOOLS:
- create_presentation, add_slide, update_slide, delete_slide
- add_text_box, update_text_box, add_image, add_shape
- add_table, update_table, add_chart
- apply_theme, set_slide_layout
- get_presentation_info, get_slide_info
- export_to_pdf, export_to_images (if LibreOffice available)

DESIGN PRINCIPLES:
- Set a consistent theme before adding content
- Every slide needs a visual element: image, chart, shape, or table
- Don't repeat the same layout on consecutive slides
- Typography: Title 36-44pt bold, Body 14-16pt, Captions 10-12pt"

WORD_GUIDE="docx-mcp-server Tool Guide:
This server edits Word documents via direct OOXML manipulation. Key tools:
- Open/create documents, then edit with tracked changes visible in Word
- search_and_replace: Find and replace text
- add_paragraph / add_heading / add_table: Add content
- format_text: Apply formatting
- Supports footnotes, endnotes, comments, headers/footers, sections
- All edits create real tracked changes (visible in Word's Review tab)"

if [[ "$PROVIDER" == "server" ]]; then
    [[ -n "$SWITCH_MODE" ]] && squire_switch "$SWITCH_MODE"
    write_crush_config "$SRV_WORD" "$SRV_PPTX" "$SRV_IMG" "" "$SELECTED_MODEL" "server"
    echo "  Profile: Remote CachyOS server ($SELECTED_MODEL via vLLM)"
else
case "$task" in
    coding)
        write_crush_config true true true "" "$DEFAULT_MODEL"
        echo "  Profile: Coding ($DEFAULT_MODEL, no MCP servers)"
        ;;
    general)
        write_crush_config false true true "" "$DEFAULT_MODEL"
        echo "  Profile: General (Word MCP + gh CLI)"
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
        write_crush_config true true true "$REVIEW_GUIDE" "$REVIEW_MODEL"
        echo "  Profile: Code review (Qwen3-Coder 30B)"
        ;;
    word)
        write_crush_config false true true "$WORD_GUIDE" "$DEFAULT_MODEL"
        echo "  Profile: Word (docx-mcp-server, 45 tools)"
        ;;
    pptx)
        write_crush_config true false true "$PPTX_GUIDE" "$DEFAULT_MODEL"
        echo "  Profile: PowerPoint (office-powerpoint-mcp-server, 32 tools)"
        ;;
    docs)
        # Download latest doc-coauthoring skill
        DOC_SKILL_DIR="${HOME}/.config/crush/skills/doc-coauthoring"
        DOC_SKILL_FILE="${DOC_SKILL_DIR}/SKILL.md"
        mkdir -p "$DOC_SKILL_DIR"
        if [[ -f "$DOC_SKILL_FILE" ]]; then
            # Cached version exists — update in background, use cached now
            (curl -fsSL --max-time 5 \
                "https://raw.githubusercontent.com/anthropics/skills/main/skills/doc-coauthoring/SKILL.md" \
                -o "$DOC_SKILL_FILE" 2>/dev/null) &
            DOCS_GUIDE="$(cat "$DOC_SKILL_FILE")"
        else
            # No cached version — block on download
            echo "  Downloading doc-coauthoring skill..."
            if curl -fsSL --max-time 10 \
                "https://raw.githubusercontent.com/anthropics/skills/main/skills/doc-coauthoring/SKILL.md" \
                -o "$DOC_SKILL_FILE" 2>/dev/null && [[ -f "$DOC_SKILL_FILE" ]]; then
                DOCS_GUIDE="$(cat "$DOC_SKILL_FILE")"
            else
                DOCS_GUIDE="You are a document co-authoring assistant. Guide the user through structured document creation."
            fi
        fi
        write_crush_config false true true "$DOCS_GUIDE" "$DEFAULT_MODEL"
        echo "  Profile: Guided document authoring (doc-coauthoring skill + Word MCP)"
        ;;
    image)
        write_crush_config true true false "" "$SELECTED_MODEL"
        echo "  Profile: Image generation (HiDream) — using $SELECTED_MODEL for VRAM headroom"
        ;;
    all)
        write_crush_config false false false "" "$DEFAULT_MODEL"
        echo "  Profile: All tools (93 MCP tools - may be slow with smaller models)"
        ;;
    *)
        echo "  Unknown profile '$task', defaulting to general."
        write_crush_config false true true "" "$DEFAULT_MODEL"
        echo "  Profile: General (Word MCP + gh CLI)"
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
