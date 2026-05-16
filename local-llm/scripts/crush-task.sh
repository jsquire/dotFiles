#!/usr/bin/env bash
# crush-task — Task picker for Crush with MCP profile management
#
# Writes a project-level .crush.json with the right MCP servers enabled
# for the selected task, then launches Crush.
#
# Profiles:
#   coding  — no MCP servers (code tools only)
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
    }
  }"
    fi

    cat > .crush.json <<EOF
{
  "mcp": {
    "word-mcp": { "disabled": ${word_disabled} },
    "pptx-mcp": { "disabled": ${pptx_disabled} },
    "imagegen-mcp": { "disabled": ${imagegen_disabled} }
  }${providers_block}${models_block}
}
EOF
}

task="${1:-}"
DEFAULT_MODEL="gemma4-65k"

if [[ -z "$task" ]]; then
    echo
    echo "  --- Crush Task Profiles ---"
    echo "  [1] Coding          (no MCP - fast, all context for code)"
    echo "  [2] Word docs       (Word MCP only - 54 tools)"
    echo "  [3] PowerPoint      (PPTX MCP only - 37 tools)"
    echo "  [4] Document create (guided co-authoring workflow)"
    echo "  [5] Image gen       (FLUX.1-schnell MCP)"
    echo "  [6] All tools       (all MCP servers - may be slow)"
    echo
    read -rp "  Select profile [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        1) task="coding" ;;
        2) task="word" ;;
        3) task="pptx" ;;
        4) task="docs" ;;
        5) task="image" ;;
        6) task="all" ;;
        *)
            echo "  Invalid selection, defaulting to coding."
            task="coding"
            ;;
    esac
fi

PPTX_GUIDE="IMPORTANT: Be concise. Do not explain what you will do — just do it. Minimize output.

ppt-mcp controls a live PowerPoint instance via COM automation (154 tools).

WORKFLOW: Open file in PowerPoint → ppt_activate_presentation → edit → ppt_save_presentation

ESSENTIAL TOOLS:
- ppt_activate_presentation (CALL FIRST after opening a file!)
- ppt_find_replace_text, ppt_set_text, ppt_get_text, ppt_get_all_text
- ppt_get_slide_info, ppt_list_slides, ppt_add_slide, ppt_delete_slide
- ppt_save_presentation, ppt_save_presentation_as (export to PDF/PNG)

ADVANCED TOOLS (use these for professional results):
- Charts: ppt_add_chart (20+ types: column, bar, line, pie, scatter, area, doughnut, radar)
  → ppt_set_chart_data → ppt_format_chart
- SmartArt: ppt_add_smartart (any layout: Process, Org Chart, Cycle, Funnel, Venn, Timeline)
  → ppt_modify_smartart (set_text, add_node, change_layout, change_color)
- Tables: ppt_add_table → ppt_set_table_data (batch write) → ppt_merge_table_cells
  → ppt_set_table_borders → ppt_set_table_style
- Themes: ppt_set_theme_colors (17 presets: corporate_blue, executive, nord_light, etc.
  OR auto-generate harmonious palette from one brand color)
- Animations: ppt_add_animation (entrance/exit/emphasis/motion path, 50+ effects)
  → ppt_set_slide_transition (fade, push, wipe, dissolve)
- Layout: ppt_align_shapes, ppt_distribute_shapes, ppt_merge_shapes (boolean ops)
- Icons: ppt_add_svg_icon (2500+ Material Symbols) → ppt_search_icons to find by keyword
- Typography: ppt_check_typography (auto-fix widow lines, shrunk text)

DESIGN PRINCIPLES:
- Set a bold color palette FIRST with ppt_set_theme_colors (don't default to blue)
- Every slide needs a visual element: image, chart, icon, SmartArt, or shape
- Don't repeat the same layout on consecutive slides
- Typography: Title 36-44pt bold, Body 14-16pt, Captions 10-12pt
- Use two-column, icon+text, grid, or half-bleed image layouts for variety

QA: After editing, use ppt_get_slide_preview on modified slides to verify visually.
Check for: overlapping elements, text overflow, low-contrast text, misaligned columns."

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
    word)
        write_crush_config false true true "$WORD_GUIDE" "$DEFAULT_MODEL"
        echo "  Profile: Word (docx-mcp-server, 45 tools)"
        ;;
    pptx)
        export CRUSH_SHORT_TOOL_DESCRIPTIONS=1
        write_crush_config true false true "$PPTX_GUIDE" "$DEFAULT_MODEL"
        echo "  Profile: PowerPoint (ppt-mcp COM, 154 tools, short descriptions)"
        ;;
    docs)
        # Download latest doc-coauthoring skill in background
        DOC_SKILL_DIR="${HOME}/.config/crush/skills/doc-coauthoring"
        DOC_SKILL_FILE="${DOC_SKILL_DIR}/SKILL.md"
        (
            mkdir -p "$DOC_SKILL_DIR"
            curl -fsSL --max-time 5 \
                "https://raw.githubusercontent.com/anthropics/skills/main/skills/doc-coauthoring/SKILL.md" \
                -o "$DOC_SKILL_FILE" 2>/dev/null
        ) &

        # Load skill content into system prompt if available
        DOCS_GUIDE="You are a document co-authoring assistant. Guide the user through structured document creation."
        if [[ -f "$DOC_SKILL_FILE" ]]; then
            DOCS_GUIDE="$(cat "$DOC_SKILL_FILE")"
        fi
        write_crush_config false true true "$DOCS_GUIDE" "$DEFAULT_MODEL"
        echo "  Profile: Document creation (doc-coauthoring skill + Word MCP)"
        ;;
    image)
        write_crush_config true true false "" "qwen3:14b"
        echo "  Profile: Image generation (FLUX.1-schnell) — using qwen3:14b for VRAM headroom"
        ;;
    all)
        export CRUSH_SHORT_TOOL_DESCRIPTIONS=1
        write_crush_config false false false "" "$DEFAULT_MODEL"
        echo "  Profile: All tools (93 MCP tools - may be slow with smaller models)"
        ;;
    *)
        echo "  Unknown profile '$task', defaulting to coding."
        write_crush_config true true true "" "$DEFAULT_MODEL"
        echo "  Profile: Coding (no MCP servers)"
        ;;
esac

echo "  Config: $(pwd)/.crush.json"
echo

exec crush
