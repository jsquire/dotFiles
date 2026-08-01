#!/usr/bin/env bash
# Local token budgets are derived from the roster's registry ctx, not from a global constant.
#
# Bash-side mirror of test_token_budgets.ps1. Both launchers implement the same rule, so both need
# the same assertions; this suite covers what test_launchers_parity.sh deliberately excludes. Parity
# asserts that the launchers resolve selections identically to the pre-refactor baseline (cf852ee^),
# so it cannot also assert a value that was intentionally changed after that baseline. The parity
# tuple masks prompt=/out= and the crush JSON masks max_tokens; those fields are asserted here
# instead, against explicit numbers rather than a re-derivation of the launcher's own formula.
#
# The rule under test:
#   copilot  prompt = floor(ctx * 0.75),  output = min(16384, ctx - prompt)
#   crush    max_tokens = min(16384, floor(ctx / 4))
#
# Crush gets only the reply cap locally: its context_window rides on the providers block, which the
# launcher writes only in server mode, so crush keeps managing the local window itself.
#
# Why it exists: one global 51200/16384 pair was applied to every local model regardless of its
# window. That over-committed small-context models (Ollama silently drops the oldest turns to make
# the prompt fit, so a session quietly loses its own history with no error) and simultaneously
# throttled the 128K-256K models the roster was assembled to exploit. The image_llm slot is the
# clearest case: qwen3:8b holds 40960 tokens and was being handed a 51200 prompt cap.
#
#   tests/test_token_budgets.sh

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

COP="$REPO_DIR/scripts/copilot-local.sh"
CRU="$REPO_DIR/scripts/crush-task.sh"

echo "== token budgets (derived from registry ctx) =="

# "<prompt>/<output>" for a copilot selection. Args: <input> [launcher_args]
copilot_budget() {
    ll_run_sh "$COP" "local,server" "$1" "" "" "${2:-}"
    local line p o
    line="$(ll_capture_line)"
    p="$(sed -n 's/.* prompt=\([^ ]*\).*/\1/p' <<<"$line")"
    o="$(sed -n 's/.* out=\([^ ]*\).*/\1/p' <<<"$line")"
    printf '%s/%s' "${p:-?}" "${o:-?}"
}

# "<max_tokens>" for a crush selection.
crush_budget() {
    ll_run_sh "$CRU" "local,server" "$1"
    if [[ -z "$LL_CRUSH_JSON" ]]; then printf 'NONE'; return; fi
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["models"]["large"]["max_tokens"])' \
        "$LL_CRUSH_JSON" 2>/dev/null || printf 'NONE'
}

# -- copilot: production menu (page 1) -------------------------------------------------------
assert_eq "copilot prod 1 heavy 212K"   "162816/16384" "$(copilot_budget "$(printf '1\n1')")"
assert_eq "copilot prod 2 coder 144K"   "110592/16384" "$(copilot_budget "$(printf '1\n2')")"
assert_eq "copilot prod 6 agentic 198K" "152064/16384" "$(copilot_budget "$(printf '1\n6')")"
# The regression case: an 8B at 40960 must not be handed the old 51200 prompt cap.
assert_eq "copilot prod 7 image 40K"    "30720/10240"  "$(copilot_budget "$(printf '1\n7')")"

# -- copilot: experimental menu (page 2), spanning every distinct window in the fixture -------
assert_eq "copilot exp 2 256K" "196608/16384" "$(copilot_budget "$(printf '2\n2')")"
assert_eq "copilot exp 3 128K" "98304/16384"  "$(copilot_budget "$(printf '2\n3')")"
assert_eq "copilot exp 9 128K" "98304/16384"  "$(copilot_budget "$(printf '2\n9')")"

# -- copilot: direct model arg resolves through the registry too -------------------------------
assert_eq "copilot direct qwen3:8b" "30720/10240" "$(copilot_budget "" "qwen3:8b")"

# -- crush: the reply cap is a quarter of the model's window, capped at 16K --------------------
assert_eq "crush prod 1 heavy 212K" "16384" "$(crush_budget "$(printf '1\n1')")"
assert_eq "crush prod 2 coder 144K" "16384" "$(crush_budget "$(printf '1\n2')")"
# The regression case again: a 40K model must not be promised the full 16K reply budget.
assert_eq "crush prod 5 image 40K"  "10240" "$(crush_budget "$(printf '1\n5')")"
assert_eq "crush exp 2 256K"        "16384" "$(crush_budget "$(printf '2\n2')")"
assert_eq "crush exp 3 128K"        "16384" "$(crush_budget "$(printf '2\n3')")"

# -- the squire-server provider keeps its roster-advertised caps, unchanged by this rule -------
# 54272/8192 comes from server-models.json, not from any registry ctx, and must stay that way.
assert_eq "copilot server keeps roster caps" "54272/8192" "$(copilot_budget "$(printf '3\n1')")"

ll_summary "token-budgets-sh"
