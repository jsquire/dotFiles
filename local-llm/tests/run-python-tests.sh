#!/usr/bin/env bash
# Runs the Python suites in an isolated uv environment.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v uv >/dev/null 2>&1 || { echo "ERROR: uv is required for Python tests." >&2; exit 1; }
uv run --no-project \
    --with fastmcp \
    --with httpx \
    --with fastapi \
    --with pillow \
    --with python-multipart \
    python -m unittest discover -s "$DIR" -p "test_*image*.py"
