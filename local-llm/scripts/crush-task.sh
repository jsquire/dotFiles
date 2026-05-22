#!/usr/bin/env bash
# crush-task — Task picker for Crush with MCP profile management
#
# Writes a project-level .crush.json with the right MCP servers enabled
# for the selected task, then launches Crush.
#
# Profiles:
#   general — Word MCP + gh CLI (default — research & document authoring)
#   coding  — no MCP servers (code tools only)
#   docs    — doc-coauthoring skill + Word MCP (structured workflow)
#   review  — Qwen2.5-Coder model, no MCP (different perspective)
#   word    — word-mcp only (Word document editing)
#   pptx    — pptx-mcp only (PowerPoint editing)
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
      \"max_tokens\": 8000
    },
    \"small\": {
      \"model\": \"${model_override}\",
      \"provider\": \"ollama\",
      \"max_tokens\": 8000
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
DEFAULT_MODEL="gemma4-65k"
REVIEW_MODEL="qwen3coder-65k"

if [[ -z "$task" ]]; then
    echo
    echo "  --- Crush Task Profiles ---"
    echo "  [1] General           (Research and document authoring)"
    echo "  [2] Coding            (Gemma 4, no MCP servers)"
    echo "  [3] Guided Authoring  (Guided document authoring workflow)"
    echo "  [4] Code review       (Qwen2.5-Coder, no MCP servers)"
    echo "  [5] Word              (Word MCP only)"
    echo "  [6] PowerPoint        (PPTX MCP only)"
    echo "  [7] Image Generation  (HiDream-O1 MCP)"
    echo "  [8] All tools         (All MCP servers, may be slow)"
    echo
    read -rp "  Select profile [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        1) task="general" ;;
        2) task="coding" ;;
        3) task="docs" ;;
        4) task="review" ;;
        5) task="word" ;;
        6) task="pptx" ;;
        7) task="image" ;;
        8) task="all" ;;
        *)
            echo "  Invalid selection, defaulting to general."
            task="general"
            ;;
    esac
fi

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
        echo "  Profile: Coding (no MCP servers)"
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
        echo "  Profile: Code review (Qwen2.5-Coder 14B)"
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
        write_crush_config true true false "" "qwen3:4b"
        echo "  Profile: Image generation (HiDream-O1) — using qwen3:4b for VRAM headroom"
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

exec crush
