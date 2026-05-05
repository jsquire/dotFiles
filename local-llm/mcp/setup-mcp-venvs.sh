#!/usr/bin/env bash
# MCP Venv Setup — Linux
#
# Creates isolated uv virtual environments for each MCP server.
# Run this AFTER install-cachyos.sh has installed uv and Python.
#
# Usage:
#   chmod +x setup-mcp-venvs.sh
#   ./setup-mcp-venvs.sh

set -euo pipefail

AI_TOOLS_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/ai-tools"

declare -A MCP_SERVERS=(
    ["mcp-office"]="office-mcp"
    ["mcp-word"]="python-docx-mcp"
    ["mcp-pptx"]="python-pptx-mcp"
)

for name in "${!MCP_SERVERS[@]}"; do
    package="${MCP_SERVERS[$name]}"
    venv_path="$AI_TOOLS_ROOT/$name"
    echo ""
    echo "── Setting up $name ($package) ──"

    mkdir -p "$venv_path"

    echo "  Initializing uv project..."
    uv init --directory "$venv_path" --no-readme 2>/dev/null || true

    echo "  Installing $package..."
    if uv add --directory "$venv_path" "$package"; then
        echo "  ✓ $name ready"
    else
        echo "  ✗ Failed to install $package" >&2
    fi
done

echo ""
echo "── Done ──"
echo "MCP venvs are at: $AI_TOOLS_ROOT"
echo "Update ~/.crush/mcp-servers.json to point to these paths."
