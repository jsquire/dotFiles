#!/usr/bin/env bash
# Verifies the imagegen MCP target follows the local/server selection. Uses a DISTINCT test server IP
# (10.9.9.9) so local (127.0.0.1) and server hosts are unambiguously different.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
export LL_TEST_SQUIRE_IP="10.9.9.9"

crush_url() {   # <stdin_input> -> IMAGEGEN_URL from the generated .crush.json
    ll_run_sh "$REPO_DIR/scripts/crush-task.sh" "local,server" "$1"
    if [[ -n "$LL_CRUSH_JSON" ]]; then
        python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mcp"]["imagegen-mcp"]["env"]["IMAGEGEN_URL"])' "$LL_CRUSH_JSON"
    else
        echo "NONE"
    fi
}
copilot_host() {   # <stdin_input> -> exported COPILOT_MCP_IMAGEGEN_HOST
    ll_run_sh "$REPO_DIR/scripts/copilot-local.sh" "local,server" "$1"
    grep -m1 '^IMAGEGEN_HOST=' <<<"$LL_LAST_OUT" | cut -d= -f2-
}
copilot_sep() {    # <stdin_input> -> ARGV_HAS_SEP (must be 'no'; a bare '--' breaks copilot arg parsing)
    ll_run_sh "$REPO_DIR/scripts/copilot-local.sh" "local,server" "$1"
    grep -m1 '^ARGV_HAS_SEP=' <<<"$LL_LAST_OUT" | cut -d= -f2-
}

# crush: local image profile -> localhost, server image profile -> the squire-server
assert_eq "crush local image url"   "http://127.0.0.1:8001" "$(crush_url $'1\n5')"
assert_eq "crush server image url"  "http://10.9.9.9:8001"  "$(crush_url $'3\n5')"
# crush non-image profile still carries a sane local default (imagegen disabled anyway)
assert_eq "crush local coding url"  "http://127.0.0.1:8001" "$(crush_url $'1\n1')"
assert_eq "crush server coding url" "http://10.9.9.9:8001"  "$(crush_url $'3\n3')"

# copilot: the launcher exports the right imagegen host per environment
assert_eq "copilot local image host"   "127.0.0.1" "$(copilot_host $'1\n7')"
assert_eq "copilot server image host"  "10.9.9.9"  "$(copilot_host $'3\n5')"

# copilot invocation must not pass a bare '--' (copilot would treat the flags as positional args)
assert_eq "copilot local no -- separator"  "no" "$(copilot_sep $'1\n1')"
assert_eq "copilot server no -- separator" "no" "$(copilot_sep $'3\n1')"

ll_summary "imagegen-context"
