#!/usr/bin/env bash
# Verifies mcp/imagegen-mcp-server.py::_resolve_output_path anchors relative paths under the HOME
# Downloads folder (never the caller's cwd) and expands "~". Stub-imports the module so no real
# deps (fastmcp/httpx) or GPU/server are needed.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

MOD="$REPO_DIR/mcp/imagegen-mcp-server.py"

# Sandbox HOME + a DIFFERENT cwd, so a cwd-relative bug would be caught (result would contain WORK).
SB="$(mktemp -d)"
export HOME="$SB"
mkdir -p "$SB/Downloads" "$SB/work"

resolve() {   # <input> -> resolved absolute path (printed by the driver)
    ( cd "$SB/work" && HOME="$SB" python3 - "$MOD" "$1" <<'PY'
import sys, types, importlib.util
# Stub the optional deps the module imports at load time.
_m = types.ModuleType("fastmcp")
class _MCP:
    def __init__(self, *a, **k): pass
    def tool(self, *a, **k):
        def deco(fn): return fn
        return deco
    def run(self, *a, **k): pass
_m.FastMCP = _MCP
sys.modules["fastmcp"] = _m
sys.modules["httpx"] = types.ModuleType("httpx")

spec = importlib.util.spec_from_file_location("imagegen_mcp_server", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(str(mod._resolve_output_path(sys.argv[2], "a test prompt")))
PY
    )
}

DL="$SB/Downloads"

# relative WITH a directory -> under $HOME (never cwd)
assert_eq "relative-with-dir -> ~/Downloads" "$DL/cat.png"        "$(resolve 'Downloads/cat.png')"
# bare filename -> ~/Downloads
assert_eq "bare filename -> ~/Downloads"     "$DL/cat.png"        "$(resolve 'cat.png')"
# ~ expansion
assert_eq "tilde expands"                    "$DL/cat.png"        "$(resolve '~/Downloads/cat.png')"
# absolute path -> unchanged
assert_eq "absolute path unchanged"          "/tmp/abs/cat.png"   "$(resolve '/tmp/abs/cat.png')"
# nested relative dir -> under $HOME, .png enforced
assert_eq "nested relative under HOME"       "$SB/sub/dir/cat.png" "$(resolve 'sub/dir/cat.jpg')"

# never resolves under the working directory
got="$(resolve 'Downloads/cat.png')"
case "$got" in
    "$SB/work"/*) assert_eq "must not be under cwd" "not-under-cwd" "under-cwd:$got" ;;
    *)            assert_eq "must not be under cwd" "not-under-cwd" "not-under-cwd" ;;
esac

# empty path -> auto-named png in ~/Downloads
empty="$(resolve '')"
case "$empty" in
    "$DL/"*.png) assert_eq "empty -> ~/Downloads auto png" "ok" "ok" ;;
    *)           assert_eq "empty -> ~/Downloads auto png" "$DL/<auto>.png" "$empty" ;;
esac

rm -rf "$SB"
ll_summary "imagegen-path"
