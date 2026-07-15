#!/usr/bin/env bash
# Behavioural parity suite for the .sh launchers.
#
# For every menu selection (and the direct/arg paths) it captures the FUNCTIONAL result the launcher
# would produce — the resolved model, provider base URL, token caps, MCP/imagegen flags, office skill,
# offload, and (for crush) the emitted .crush.json — and asserts it equals a frozen golden.
#
# The golden is generated ONCE from the PRE-REFACTOR launchers (git ref cf852ee^, the commit before
# the data-drive refactor) via `--rebuild-golden`, then committed. So "no functional behaviour changed"
# is proven against the real old scripts, and the frozen golden guards against future drift.
#
# Cosmetic output (banner label/tag text, the "Profile:" line) is deliberately NOT part of the tuple —
# only functional resolution is asserted.

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

GIT_ROOT="$(cd "$REPO_DIR/.." && pwd)"
BASELINE_REF="${LL_BASELINE_REF:-cf852ee^}"
GOLDEN_COPILOT="$FIX_DIR/golden-copilot.tsv"
GOLDEN_CRUSH="$FIX_DIR/golden-crush.tsv"

# ── Functional-tuple extractors ──────────────────────────────────────────────
copilot_tuple() {   # <src> <providers> <input> <args>
    ll_run_sh "$1" "$2" "$3" "" "" "$4"
    local cap; cap="$(ll_capture_line)"; cap="${cap#CAPTURE }"
    local off=no; [[ "$LL_LAST_OUT" == *"Offload mode:"* ]] && off=yes
    printf '%s offload=%s' "$cap" "$off"
}
crush_tuple() {     # <src> <providers> <input> <args>
    ll_run_sh "$1" "$2" "$3" "" "" "$4"
    local off=no; [[ "$LL_LAST_OUT" == *"Offload mode:"* ]] && off=yes
    local js="NONE"; [[ -n "$LL_CRUSH_JSON" ]] && js="$(norm_crush_json "$LL_CRUSH_JSON")"
    printf 'json=%s offload=%s' "$js" "$off"
}

do_copilot() {      # <mode> <name> <src> <providers> <input> <args>
    local mode="$1" name="$2"; shift 2
    local t; t="$(copilot_tuple "$@")"
    if [[ "$mode" == "golden" ]]; then
        printf '%s\t%s\n' "$name" "$t" >> "$GOLDEN_COPILOT"
    else
        local exp; exp="$(grep -m1 -F "$name"$'\t' "$GOLDEN_COPILOT" | cut -f2-)"
        assert_eq "copilot/$name" "$exp" "$t"
    fi
}
do_crush() {        # <mode> <name> <src> <providers> <input> <args>
    local mode="$1" name="$2"; shift 2
    local t; t="$(crush_tuple "$@")"
    if [[ "$mode" == "golden" ]]; then
        printf '%s\t%s\n' "$name" "$t" >> "$GOLDEN_CRUSH"
    else
        local exp; exp="$(grep -m1 -F "$name"$'\t' "$GOLDEN_CRUSH" | cut -f2-)"
        assert_eq "crush/$name" "$exp" "$t"
    fi
}

run_copilot_matrix() {  # <mode> <src>
    local mode="$1" src="$2" k
    for k in 1 2 3 4 5 6 7;            do do_copilot "$mode" "cl-$k" "$src" "local,server" "$(printf '1\n%s' "$k")" ""; done
    for k in 1 2 3 4 5 6 7 8 9 10;     do do_copilot "$mode" "ce-$k" "$src" "local,server" "$(printf '2\n%s' "$k")" ""; done
    for k in 1 2 3 4 5;                do do_copilot "$mode" "cs-$k" "$src" "local,server" "$(printf '3\n%s' "$k")" ""; done
    do_copilot "$mode" "cdirect" "$src" "local,server" "" "qwen3:8b"
}
run_crush_matrix() {    # <mode> <src>
    local mode="$1" src="$2" k t
    for k in 1 2 3 4 5;                do do_crush "$mode" "kl-$k" "$src" "local,server" "$(printf '1\n%s' "$k")" ""; done
    for k in 1 2 3 4 5 6 7 8 9 10;     do do_crush "$mode" "ke-$k" "$src" "local,server" "$(printf '2\n%s' "$k")" ""; done
    for k in 1 2 3 4 5;                do do_crush "$mode" "ks-$k" "$src" "local,server" "$(printf '3\n%s' "$k")" ""; done
    for t in coding review docs image; do do_crush "$mode" "karg-$t" "$src" "local,server" "" "$t"; done
}

extract_baseline() {    # <script-name> -> echoes temp path (empty on failure)
    local name="$1" tmp; tmp="$(mktemp)"
    if git -C "$GIT_ROOT" show "${BASELINE_REF}:local-llm/scripts/${name}" > "$tmp" 2>/dev/null; then
        # The baseline has a latent `set -u` bug in box_center (`local s="$1" p=$((...${#s}...))`
        # expands ${#s} before s is assigned) that crashes it in a clean sandbox. Patch ONLY that
        # cosmetic line so the baseline runs; it cannot affect the functional resolution we compare.
        sed -i 's/local s="$1" p=$((/local s="$1"; local p=$((/' "$tmp"
        printf '%s' "$tmp"
    else
        rm -f "$tmp"; printf ''
    fi
}

if [[ "${1:-}" == "--rebuild-golden" ]]; then
    [[ -n "${2:-}" ]] && BASELINE_REF="$2"
    echo "Rebuilding golden from baseline: $BASELINE_REF"
    cp_src="$(extract_baseline copilot-local.sh)"
    cr_src="$(extract_baseline crush-task.sh)"
    if [[ -z "$cp_src" || -z "$cr_src" ]]; then
        echo "ERROR: could not extract baseline launchers at $BASELINE_REF" >&2; exit 1
    fi
    : > "$GOLDEN_COPILOT"; : > "$GOLDEN_CRUSH"
    run_copilot_matrix golden "$cp_src"
    run_crush_matrix   golden "$cr_src"
    rm -f "$cp_src" "$cr_src"
    echo "Golden written: $(wc -l < "$GOLDEN_COPILOT") copilot + $(wc -l < "$GOLDEN_CRUSH") crush selections."
    exit 0
fi

echo "== launcher parity (current vs frozen golden) =="
if [[ ! -s "$GOLDEN_COPILOT" || ! -s "$GOLDEN_CRUSH" ]]; then
    echo "  golden missing — run: $0 --rebuild-golden" >&2; exit 1
fi
run_copilot_matrix check "$REPO_DIR/scripts/copilot-local.sh"
run_crush_matrix   check "$REPO_DIR/scripts/crush-task.sh"
ll_summary "launcher-parity"
