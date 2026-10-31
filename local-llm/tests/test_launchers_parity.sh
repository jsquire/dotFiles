#!/usr/bin/env bash
# Exercises every canonical Bash launcher row against the shared semantic oracle.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

COP="$REPO_DIR/scripts/copilot-local.sh"
ORACLE="$TESTS_DIR/semantic_oracle.py"
EXPECTED="$TESTS_DIR/expected-launcher-semantics.json"
SERVER_IP="10.9.9.9"
export LL_TEST_SQUIRE_IP="$SERVER_IP"

required_safety=(
    "--deny-tool=shell(git add)"
    "--deny-tool=shell(git commit)"
    "--deny-tool=shell(git push)"
    "--deny-tool=shell(git merge)"
    "--deny-tool=shell(git rebase)"
    "--deny-tool=shell(git reset)"
    "--deny-tool=shell(git stash)"
    "--deny-tool=shell(git cherry-pick)"
    "--deny-tool=shell(git revert)"
    "--deny-tool=shell(git tag)"
)

assert_argv() {
    local name="$1" model="$2" imagegen="$3" argv_json="$4"
    local required; required="$(printf '%s\n' "${required_safety[@]}")"
    if REQUIRED="$required" python3 - "$model" "$imagegen" "$argv_json" <<'PY'
import json, os, sys
model, imagegen, raw = sys.argv[1:]
argv = json.loads(raw)
required = os.environ["REQUIRED"].splitlines()
assert "--" not in argv
i = argv.index("--model")
assert argv[i + 1] == model
for flag in required:
    assert flag in argv
disabled = any(
    argv[i:i + 2] == ["--disable-mcp-server", "imagegen-mcp"]
    for i in range(len(argv) - 1)
)
assert disabled == (imagegen == "off")
PY
    then
        LL_PASS=$((LL_PASS + 1))
    else
        LL_FAIL=$((LL_FAIL + 1))
        printf '  FAIL: %s argv=%s\n' "$name" "$argv_json"
    fi
}

check_row() {
    local name="$1" first="$2" second="$3" model="$4" base="$5"
    local prompt="$6" out="$7" imagegen="$8" host="$9"
    ll_run_sh "$COP" "local,server" "$(printf '%s\n%s' "$first" "$second")"
    local expected actual
    expected="CAPTURE model=$model base=$base prompt=$prompt out=$out imagegen=$imagegen office=no"
    actual="$(ll_capture_line)"
    assert_eq "$name semantics" "$expected" "$actual"
    assert_eq "$name image host" "$host" "$(grep -m1 '^IMAGEGEN_HOST=' <<<"$LL_LAST_OUT" | cut -d= -f2-)"
    assert_argv "$name" "$model" "$imagegen" "$(ll_argv_json)"
}

local_rows="$(mktemp)"
server_rows="$(mktemp)"
trap 'rm -f "$local_rows" "$server_rows"' EXIT

if ! ORACLE_KIND=local ORACLE_PLATFORM=bash ORACLE_EXPECTED="$EXPECTED" \
    python3 "$ORACLE" < "$REPO_DIR/scripts/local-models.json" > "$local_rows"; then
    echo "  FAIL: local semantic oracle rejected the canonical roster"
    LL_FAIL=$((LL_FAIL + 1))
fi
while IFS=$'\t' read -r name first second model base prompt out imagegen host; do
    check_row "$name" "$first" "$second" "$model" "$base" "$prompt" "$out" "$imagegen" "$host"
done < "$local_rows"

if ! ORACLE_KIND=server ORACLE_PLATFORM=bash ORACLE_SERVER_IP="$SERVER_IP" ORACLE_EXPECTED="$EXPECTED" \
    python3 "$ORACLE" < "$REPO_DIR/cachyos/server-models.json" > "$server_rows"; then
    echo "  FAIL: server semantic oracle rejected the canonical roster"
    LL_FAIL=$((LL_FAIL + 1))
fi
while IFS=$'\t' read -r name first second model base prompt out imagegen host; do
    check_row "$name" "$first" "$second" "$model" "$base" "$prompt" "$out" "$imagegen" "$host"
done < "$server_rows"

ll_run_sh "$COP" "local,server" "" "" "" "qwen3:8b"
assert_eq "direct semantics" \
    "CAPTURE model=qwen3:8b base=http://localhost:11435/v1 prompt=24576 out=8192 imagegen=on office=no" \
    "$(ll_capture_line)"
assert_argv "direct" "qwen3:8b" "on" "$(ll_argv_json)"

ll_summary "launcher-semantics"
