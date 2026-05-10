#!/usr/bin/env bash
# crush-task — Task picker for Crush with MCP profile management
#
# Writes a project-level .crush.json with the right MCP servers enabled
# for the selected task, then launches Crush.
#
# Profiles:
#   coding  — no MCP servers (code tools only)
#   office  — word-mcp + pptx-mcp (document editing)
#   image   — imagegen-mcp (image generation)
#   all     — everything enabled (may degrade with smaller models)
set -euo pipefail

write_crush_config() {
    local word_disabled="$1"
    local pptx_disabled="$2"
    local imagegen_disabled="$3"
    cat > .crush.json <<EOF
{
  "mcp": {
    "word-mcp": { "disabled": ${word_disabled} },
    "pptx-mcp": { "disabled": ${pptx_disabled} },
    "imagegen-mcp": { "disabled": ${imagegen_disabled} }
  }
}
EOF
}

task="${1:-}"

if [[ -z "$task" ]]; then
    echo
    echo "  --- Crush Task Profiles ---"
    echo "  [1] Coding          (no MCP - fast, all context for code)"
    echo "  [2] Office docs     (Word + PowerPoint MCP)"
    echo "  [3] Image gen       (FLUX.1-schnell MCP)"
    echo "  [4] All tools       (all MCP servers - may be slow)"
    echo
    read -rp "  Select profile [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        1) task="coding" ;;
        2) task="office" ;;
        3) task="image" ;;
        4) task="all" ;;
        *)
            echo "  Invalid selection, defaulting to coding."
            task="coding"
            ;;
    esac
fi

case "$task" in
    coding)
        write_crush_config true true true
        echo "  Profile: Coding (no MCP servers)"
        ;;
    office)
        write_crush_config false false true
        echo "  Profile: Office (Word + PowerPoint)"
        ;;
    image)
        write_crush_config true true false
        echo "  Profile: Image generation (FLUX.1-schnell)"
        ;;
    all)
        write_crush_config false false false
        echo "  Profile: All tools (93 MCP tools - may be slow with smaller models)"
        ;;
    *)
        echo "  Unknown profile '$task', defaulting to coding."
        write_crush_config true true true
        echo "  Profile: Coding (no MCP servers)"
        ;;
esac

echo "  Config: $(pwd)/.crush.json"
echo

exec crush
