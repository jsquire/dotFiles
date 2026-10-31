#!/usr/bin/env bash
# Proves the Bash launcher sends the correct switch request and handles success, failure, and timeout.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

COP="$REPO_DIR/scripts/copilot-local.sh"
export LL_TEST_SQUIRE_IP="10.9.9.9"

run_switch_case() {
    local mode="$1" log="$2" state="$3"
    : > "$log"
    rm -f "$state"
    ll_run_sh "$COP" "local,server" $'3\n1' "" \
        "LL_STUB_SWITCH_MODE=$mode LL_STUB_SWITCH_LOG=$log LL_STUB_SWITCH_STATE=$state LL_SWITCH_POLL_ATTEMPTS=2 LL_SWITCH_POLL_DELAY=0"
}

log="$(mktemp)"
state="$(mktemp)"
rm -f "$state"
trap 'rm -f "$log" "$state"' EXIT

run_switch_case success "$log" "$state"
assert_contains "success switch URL" "$(cat "$log")" "SWITCH_URL=http://10.9.9.9:4090/switch"
assert_contains "success switch body" "$(cat "$log")" 'SWITCH_BODY={"mode":"mistral"}'
assert_contains "success polls status" "$(cat "$log")" "STATUS_URL=http://10.9.9.9:4090/status"
assert_contains "success reports ready" "$LL_LAST_OUT" "ready."

run_switch_case failure "$log" "$state"
assert_contains "failure reports unreachable" "$LL_LAST_OUT" "Could not reach the model-switch service"
assert_eq "failure does not poll" "0" "$(grep -c '^STATUS_URL=' "$log" || true)"

run_switch_case timeout "$log" "$state"
assert_eq "timeout performs bounded polls" "2" "$(grep -c '^STATUS_URL=' "$log" || true)"
assert_contains "timeout reports loading" "$LL_LAST_OUT" "still loading"

ll_summary "launcher-switch"
