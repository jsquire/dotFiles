#!/usr/bin/env bash
# MCP Tool Setup — Linux
#
# Installs MCP servers as uv tools (globally accessible via uvx).
# Run this AFTER install-cachyos.sh has installed uv and Python.
#
# Note: ppt-mcp (COM automation) is Windows-only.
# On Linux, docx-mcp-server handles Word editing; PPTX editing is
# done on Windows clients connecting to the headless server.
#
# Usage:
#   chmod +x setup-mcp-venvs.sh
#   ./setup-mcp-venvs.sh

set -euo pipefail

echo "── Installing docx-mcp-server (Word OOXML editing, 45 tools) ──"
if uv tool install docx-mcp-server --python 3.12; then
    echo "  ✓ docx-mcp-server ready"
else
    echo "  ✗ Failed to install docx-mcp-server" >&2
fi

echo ""
echo "── Done ──"
echo "MCP tools installed globally via uv. Use 'uvx <tool>' to run."
echo "Note: ppt-mcp (PowerPoint COM) is Windows-only — not installed on Linux."
