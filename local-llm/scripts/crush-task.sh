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

write_crush_config() {
    local word_disabled="$1"
    local pptx_disabled="$2"
    local imagegen_disabled="$3"
    local system_prompt="${4:-}"
    local model_override="${5:-}"

    local providers_block=""
    local models_block=""
    if [[ -n "$system_prompt" ]]; then
        providers_block=",
  \"providers\": {
    \"ollama\": {
      \"system_prompt_prefix\": $(printf '%s' "$system_prompt" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
    }
  }"
    fi
    if [[ -n "$model_override" ]]; then
        models_block=",
  \"models\": {
    \"large\": {
      \"model\": \"${model_override}\",
      \"provider\": \"ollama\",
      \"max_tokens\": 32000
    },
    \"small\": {
      \"model\": \"${model_override}\",
      \"provider\": \"ollama\",
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
DEFAULT_MODEL="qwen36-128k"
REVIEW_MODEL="qwen3coder-65k"
SELECTED_MODEL=""
OFFLOAD_MODE=0

# 5090 model assignments per task profile
model_for_task() {
    case "$1" in
        coding)                 echo "qwen36-27b-212k" ;;   # heavy coding default
        review)                 echo "qwen3coder-144k" ;;   # Qwen3-Coder 30B-A3B
        general|word|pptx|docs|all) echo "glm47-flash-198k" ;;  # GLM-4.7-Flash tool/MCP
        image)                  echo "qwen3:8b" ;;          # image-gen companion
        *)                      echo "qwen36-27b-212k" ;;
    esac
}

if [[ -z "$task" ]]; then
    echo
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
    echo "  ══ EXPERIMENTAL · models under evaluation ════════════════"
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
    echo "  --- Big-MoE expert-offload bench (experts->RAM; slower, for models that don't fit) ---"
    echo "  [O1] gpt-oss-120b           (offload, ~65 GB MXFP4)"
    echo "  [O2] Qwen3-Next-80B-A3B     (offload, Q4_K_M ~45 GB)"
    echo
    read -rp "  Select profile [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        1) task="coding" ;;
        2) task="coding"; SELECTED_MODEL="qwen3coder-144k" ;;
        3) task="review" ;;
        4) task="general" ;;
        5) task="word" ;;
        6) task="pptx" ;;
        7) task="docs" ;;
        8) task="image" ;;
        9) task="all" ;;
        [Hh]1) task="coding"; SELECTED_MODEL="qwen36-27b-212k" ;;
        [Hh]2) task="coding"; SELECTED_MODEL="qwen36-35b-256k" ;;
        [Hh]3) task="coding"; SELECTED_MODEL="gemma4-31b-128k" ;;
        [Hh]4) task="coding"; SELECTED_MODEL="qwen3coder-144k" ;;
        [Hh]5) task="coding"; SELECTED_MODEL="glm47-flash-198k" ;;
        [Hh]6) task="coding"; SELECTED_MODEL="northmini-code-256k" ;;
        [Hh]7) task="coding"; SELECTED_MODEL="nemotron-c2-256k" ;;
        [Hh]8) task="coding"; SELECTED_MODEL="ornith-35b-256k" ;;
        [Oo]1) task="coding"; SELECTED_MODEL="gptoss-120b-offload";   OFFLOAD_MODE=1 ;;
        [Oo]2) task="coding"; SELECTED_MODEL="qwen3next-80b-offload"; OFFLOAD_MODE=1 ;;
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

# Friendly labels for the launch-identity banner (keyed on the resolved alias; doubles as the
# human-readable bench roster registry).
declare -A MODEL_LABEL=(
    [qwen36-27b-212k]="Qwen3.6 27B (+MTP)"
    [qwen36-35b-256k]="Qwen3.6 35B-A3B MoE"
    [gemma4-31b-128k]="Gemma 4 31B dense"
    [qwen3coder-144k]="Qwen3-Coder 30B-A3B"
    [glm47-flash-198k]="GLM-4.7-Flash"
    [northmini-code-256k]="North Mini Code 1.0"
    [nemotron-c2-256k]="Nemotron Cascade 2 30B-A3B"
    [ornith-35b-256k]="Ornith-1.0-35B"
    [gptoss-120b-offload]="gpt-oss-120b (offload)"
    [qwen3next-80b-offload]="Qwen3-Next-80B-A3B (offload)"
)
MODEL_FRIENDLY="${MODEL_LABEL[$DEFAULT_MODEL]:-$DEFAULT_MODEL}"
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

echo "  Config: $(pwd)/.crush.json"
echo

if [[ "$OFFLOAD_MODE" == "1" ]]; then
    # Big-MoE offload mode: run a dedicated Ollama serve with expert CPU-offload, then
    # restore the managed server when Crush exits.
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=offload-serve.sh
    source "$SCRIPT_DIR/offload-serve.sh"
    echo "  Offload mode: experts -> system RAM (slower; for models that don't fit)"
    offload_start
    trap 'offload_stop' EXIT
    crush
else
    exec crush
fi
