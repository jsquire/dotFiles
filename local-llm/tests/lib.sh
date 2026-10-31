#!/usr/bin/env bash
# Shared helpers for the local-llm test harness: a tiny assert framework + headless launcher runner.
#
# ISOLATION: every launcher run happens in a throwaway sandbox. HOME points at the sandbox (seeded
# with canonical rosters), CWD is a sandbox work dir, and PATH is prefixed with tests/stubs. Nothing
# touches the real ~/.config/local-llm, the real :4090 endpoint, systemd, sudo, ollama, or the network.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"          # local-llm/
STUBS_DIR="$TESTS_DIR/stubs"

# Self-heal exec bits (Windows checkouts / git modes may drop them).
chmod +x "$STUBS_DIR"/* "$TESTS_DIR"/*.sh 2>/dev/null || true

LL_PASS=0
LL_FAIL=0

assert_eq() {   # <name> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        LL_PASS=$((LL_PASS + 1))
    else
        LL_FAIL=$((LL_FAIL + 1))
        printf '  FAIL: %s\n        expected: [%s]\n        actual:   [%s]\n' "$1" "$2" "$3"
    fi
}

assert_contains() {   # <name> <haystack> <needle>
    if [[ "$2" == *"$3"* ]]; then
        LL_PASS=$((LL_PASS + 1))
    else
        LL_FAIL=$((LL_FAIL + 1))
        printf '  FAIL: %s\n        expected to contain: [%s]\n        in: [%s]\n' "$1" "$3" "$2"
    fi
}

assert_true() {   # <name> <cmd...>  (passes if cmd exits 0)
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        LL_PASS=$((LL_PASS + 1))
    else
        LL_FAIL=$((LL_FAIL + 1))
        printf '  FAIL: %s (command failed: %s)\n' "$name" "$*"
    fi
}

ll_summary() {   # <suite-name>  -> exits nonzero if any failure
    printf '\n%-28s %d passed, %d failed\n' "$1:" "$LL_PASS" "$LL_FAIL"
    [[ $LL_FAIL -eq 0 ]]
}

# Normalise a JSON file to a stable, comparable string (sorted keys, no whitespace).
norm_json() {
    python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True, separators=(",",":")))' "$1"
}

# Headless-run a .sh launcher. Call DIRECTLY (not in $(...)) so the globals below survive.
# Sets LL_LAST_OUT to launcher stdout.
#   ll_run_sh <launcher_src> <providers> <stdin_input> [server_json] [extra_env] [launcher_args] [local_json]
LL_LAST_OUT=""
ll_run_sh() {
    local src="$1" providers="$2" input="$3"
    local server_json="${4:-$REPO_DIR/cachyos/server-models.json}"
    local extra_env="${5:-}"
    local largs="${6:-}"
    local local_json="${7:-$REPO_DIR/scripts/local-models.json}"
    local sb; sb="$(mktemp -d)"
    mkdir -p "$sb/.config/local-llm" "$sb/work"
    [[ -f "$server_json" ]] || server_json="$REPO_DIR/cachyos/server-models.json"
    cp "$local_json" "$sb/.config/local-llm/local-models.json"
    cp "$server_json" "$sb/.config/local-llm/server-models.json"
    sed -e "s|__SQUIRE_SERVER_IP__|${LL_TEST_SQUIRE_IP:-127.0.0.1}|g" \
        -e "s|__SQUIRE_SSH_TARGET__|test@127.0.0.1|g" \
        -e "s|__LL_PROVIDERS__|${providers}|g" \
        "$src" > "$sb/launcher.sh"
    LL_LAST_OUT="$(cd "$sb/work" && env HOME="$sb" PATH="$STUBS_DIR:$PATH" LL_TEST=1 \
        LL_STUB_SERVER_JSON="$sb/.config/local-llm/server-models.json" $extra_env \
        bash "$sb/launcher.sh" $largs <<<"$input" 2>&1)"
    rm -rf "$sb"
}

# Extract the single CAPTURE line a copilot run produced (from LL_LAST_OUT).
ll_capture_line() { grep -m1 '^CAPTURE ' <<<"$LL_LAST_OUT" || true; }
ll_argv_json() { grep -m1 '^ARGV_JSON=' <<<"$LL_LAST_OUT" | cut -d= -f2- || true; }
