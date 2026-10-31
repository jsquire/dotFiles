#!/usr/bin/env bash
# Local token budgets are derived from the roster's registry ctx, not from a global constant.
#
# Bash-side mirror of test_token_budgets.ps1. This suite covers what
# test_launchers_parity.sh deliberately excludes. Parity
# asserts that the launchers resolve selections identically to the pre-refactor baseline (cf852ee^),
# so it cannot also assert a value that was intentionally changed after that baseline. The parity
# tuple masks prompt=/out=; those fields are asserted here against explicit numbers rather than a
# re-derivation of the launcher's own formula.
#
# The rule under test:
#   copilot  prompt = floor(ctx * 0.75),  output = min(16384, ctx - prompt)
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

# -- copilot: production menu (page 1) -------------------------------------------------------
assert_eq "copilot prod 1 heavy 192K"   "147456/16384" "$(copilot_budget "$(printf '1\n1')")"
assert_eq "copilot prod 2 coder 144K"   "110592/16384" "$(copilot_budget "$(printf '1\n2')")"
assert_eq "copilot prod 6 agentic 128K" "98304/16384"  "$(copilot_budget "$(printf '1\n6')")"
# The regression case: an 8B at 32768 must not be handed the old 51200 prompt cap.
assert_eq "copilot prod 7 image 32K"    "24576/8192"   "$(copilot_budget "$(printf '1\n7')")"
assert_eq "copilot prod 8 computer 192K" "147456/16384" "$(copilot_budget "$(printf '1\n8')")"
assert_eq "copilot prod 9 research 256K" "196608/16384" "$(copilot_budget "$(printf '1\n9')")"

# -- copilot: experimental menu (page 2), spanning every distinct window in the fixture -------
assert_eq "copilot exp 1 256K"  "196608/16384" "$(copilot_budget "$(printf '2\n1')")"
assert_eq "copilot exp 3 128K"  "98304/16384"  "$(copilot_budget "$(printf '2\n3')")"
assert_eq "copilot exp 9 256K"  "196608/16384" "$(copilot_budget "$(printf '2\n9')")"
assert_eq "copilot exp 10 128K" "98304/16384"  "$(copilot_budget "$(printf '2\n10')")"

# -- copilot: direct model arg resolves through the registry too -------------------------------
assert_eq "copilot direct qwen3:8b" "24576/8192" "$(copilot_budget "" "qwen3:8b")"

# -- the squire-server provider keeps its roster-advertised caps, unchanged by this rule -------
# 54272/8192 comes from server-models.json, not from any registry ctx, and must stay that way.
assert_eq "copilot server keeps roster caps" "54272/8192" "$(copilot_budget "$(printf '3\n1')")"
assert_eq "copilot server Nemotron caps"      "54272/8192" "$(copilot_budget "$(printf '3\n6')")"
assert_eq "copilot server KAT caps"           "10240/4096" "$(copilot_budget "$(printf '3\n7')")"
assert_eq "copilot server Ornith caps"        "46080/8192" "$(copilot_budget "$(printf '3\n8')")"

ll_summary "token-budgets-sh"
