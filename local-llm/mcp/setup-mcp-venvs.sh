#!/usr/bin/env bash
# Office authoring library warm-up — Linux
#
# Office authoring no longer uses always-on MCP servers (their tool schemas cost
# ~37K tokens per request, exceeding most served context windows). Instead, the
# vendored 'office' skill instructs the model to write python-docx / python-pptx /
# openpyxl code and run it via 'uv run --with ...'.
#
# This script primes the uv cache so document authoring works offline afterward.
# Run AFTER install-cachyos.sh has installed uv and Python.
#
# Usage:
#   chmod +x setup-mcp-venvs.sh
#   ./setup-mcp-venvs.sh

set -euo pipefail

echo "── Warming office authoring libraries (python-docx, python-pptx, openpyxl) ──"
if uv run --python 3.12 --with python-docx --with python-pptx --with openpyxl \
    python -c "import docx, pptx, openpyxl"; then
    echo "  ✓ Office libraries cached"
else
    echo "  ✗ Warm-up failed — libraries will resolve on first use via 'uv run --with ...'" >&2
fi

echo ""
echo "── Done ──"
echo "Office authoring runs via the 'office' skill: 'uv run --with python-docx --with python-pptx --with openpyxl script.py'."
