#!/usr/bin/env bash
# Live daemon tests against a PRIVATE vllm-switch-web on a throwaway port. VLLM_SWITCH_CMD=/bin/true
# so a "successful" switch runs /bin/true (never cachyos-switch-model / systemctl / sudo / GPU / :4090).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

DAEMON="$REPO_DIR/cachyos/vllm-switch-web.py"
PORT=45090
LOCK="$(mktemp)"; rm -f "$LOCK"
DPID=""
cleanup() { [[ -n "$DPID" ]] && kill "$DPID" 2>/dev/null; rm -f "$LOCK"; }
trap cleanup EXIT

start_daemon() {  # <roster_path> <port>
    VLLM_SERVER_MODELS="$1" VLLM_SWITCH_WEB_PORT="$2" VLLM_SWITCH_CMD=/bin/true VLLM_SWITCH_LOCK="$LOCK" \
        python3 "$DAEMON" >/dev/null 2>&1 &
    DPID=$!
    local i
    for i in $(seq 1 30); do
        curl -fsS "http://127.0.0.1:$2/models" >/dev/null 2>&1 && return 0
        sleep 0.3
    done
    return 1
}
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
jq_count() { python3 -c 'import json,sys;print(len(json.load(sys.stdin)["modes"]))'; }

# ── Roster-backed daemon ──
assert_true "daemon starts (roster)" start_daemon "$FIX_DIR/server-models.json" "$PORT"
BASE="http://127.0.0.1:$PORT"
models="$(curl -fsS "$BASE/models")"
assert_eq "GET /models mode count" "5" "$(jq_count <<<"$models")"
assert_eq "GET /models default_mode" "mistral" "$(python3 -c 'import json,sys;print(json.load(sys.stdin)["default_mode"])' <<<"$models")"
assert_eq "GET /models withholds unit" "0" "$(python3 -c 'import json,sys;print(sum("unit" in m for m in json.load(sys.stdin)["modes"]))' <<<"$models")"
page="$(curl -fsS "$BASE/")"
assert_contains "GET / has mistral button" "$page" 'data-m="mistral"'
if [[ "$page" != *"__BUTTONS__"* && "$page" != *"__NAMES__"* ]]; then LL_PASS=$((LL_PASS+1)); else LL_FAIL=$((LL_FAIL+1)); echo "  FAIL: GET / still has a template placeholder"; fi
assert_eq "GET /status is valid json" "ok" "$(curl -fsS "$BASE/status" | python3 -c 'import json,sys;json.load(sys.stdin);print("ok")')"
assert_eq "POST /switch valid ->200" "200" "$(code -X POST -H 'Content-Type: application/json' -d '{"mode":"glm"}' "$BASE/switch")"
assert_eq "POST /switch injection ->400" "400" "$(code -X POST -H 'Content-Type: application/json' -d '{"mode":"evil;rm -rf"}' "$BASE/switch")"
assert_eq "POST /switch wrong ctype ->415" "415" "$(code -X POST -d '{"mode":"glm"}' "$BASE/switch")"
big="$(head -c 5000 /dev/zero | tr '\0' 'a')"
assert_eq "POST /switch oversize ->413" "413" "$(code -X POST -H 'Content-Type: application/json' -d "$big" "$BASE/switch")"
assert_eq "GET /nope ->404" "404" "$(code "$BASE/nope")"
kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null || true; DPID=""

# ── Missing roster -> built-in fallback ──
assert_true "daemon starts (missing roster)" start_daemon "/nonexistent/server-models.json" "45091"
fb="$(curl -fsS http://127.0.0.1:45091/models)"
assert_eq "fallback roster 5 modes" "5" "$(jq_count <<<"$fb")"
kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null || true; DPID=""

# ── Malformed roster -> built-in fallback (no crash) ──
bad="$(mktemp)"; echo '{ this is not json' > "$bad"
assert_true "daemon starts (malformed roster)" start_daemon "$bad" "45092"
mf="$(curl -fsS http://127.0.0.1:45092/models)"
assert_eq "malformed -> fallback 5 modes" "5" "$(jq_count <<<"$mf")"
kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null || true; DPID=""
rm -f "$bad"

ll_summary "daemon"
