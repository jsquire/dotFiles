#!/usr/bin/env bash
# Installer roster-generation tests: exercise the REAL populate_ollama_tier + write_local_models_json
# from install-cachyos.sh (extracted, no full install) for both tiers, with and without --test-profiles.
# Runs in a temp HOME; never pulls models, touches systemd/sudo, or writes to /etc.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

INSTALLER="$REPO_DIR/cachyos/install-cachyos.sh"

# Extract a shell function up to its column-0 closing brace, skipping any embedded <<'PY' heredoc
# (whose python contains column-0 braces that would otherwise look like the function end).
extract_fn() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\) \\{" {p=1}
        p{
            print
            if (index($0,"<<")>0 && index($0,"PY")>0) { inpy=1; next }
            if (inpy) { if ($0=="PY") inpy=0; next }
            if ($0=="}") exit
        }' "$INSTALLER"
}

SHIMLIB="$(mktemp)"
{ extract_fn populate_ollama_tier; echo; extract_fn write_local_models_json; } > "$SHIMLIB"

gen_one() {  # <tier> <tp> <out>
    local tier="$1" tp="$2" out="$3" home; home="$(mktemp -d)"
    SHIMLIB="$SHIMLIB" TIER="$tier" TP="$tp" SDIR="$REPO_DIR/cachyos" HHOME="$home" bash -c '
        set -uo pipefail
        declare -A OLLAMA_ALIAS_FROM OLLAMA_ALIAS_CTX OLLAMA_SLOT OLLAMA_ALIAS_LABEL OLLAMA_ALIAS_TEMPLATE
        OLLAMA_PULL_TAGS=()
        success(){ :;}; add_warning(){ :;}; add_failure(){ :;}; info(){ :;}; step(){ :;}; warn(){ :;}
        export HOME="$HHOME"
        SCRIPT_DIR="$SDIR"
        LOCAL_MODELS_PATH="$HOME/.config/local-llm/local-models.json"
        OLLAMA_TIER="$TIER"; TEST_PROFILES="$TP"
        source "$SHIMLIB"
        write_local_models_json >/dev/null 2>&1
    '
    cp "$home/.config/local-llm/local-models.json" "$out" 2>/dev/null || true
    rm -rf "$home"
}

validate() {  # <file> <tier> <tp> <label>
    python3 - "$@" <<'PY'
import json, sys
f, tier, tp, label = sys.argv[1:5]
P = F = 0
def ok(c, m):
    global P, F
    if c: P += 1
    else:
        F += 1; print(f"  FAIL[{label}]:", m)
try:
    d = json.load(open(f))
except Exception as e:
    print(f"  FAIL[{label}]: invalid JSON ({e})"); print(f"{label}: 0 passed, 1 failed"); sys.exit(1)
ok(d.get("tier") == tier, f"tier {d.get('tier')} != {tier}")
ta = d.get("task_alias", {}); reg = d.get("registry", {})
for s in ("heavy", "coder", "review", "agentic", "image_llm", "h1", "h5"):
    ok(s in ta, f"missing production/base slot '{s}'")
for s in ("h6", "h9", "o2"):
    if tp == "true": ok(s in ta, f"expected experimental slot '{s}' with --test-profiles")
    else:            ok(s not in ta, f"slot '{s}' should be gated off without --test-profiles")
for s, a in ta.items():
    ok(a in reg, f"task_alias {s}={a} not in registry")
for a, e in reg.items():
    ok("label" in e and "ctx" in e, f"registry {a} missing label/ctx")
ok("copilot" in d.get("launchers", {}) and "crush" in d.get("launchers", {}), "launcher menus not preserved")
# tier-specific spot check
if tier == "5090": ok(ta.get("heavy") == "qwen36-27b-212k", f"5090 heavy alias {ta.get('heavy')}")
if tier == "4090": ok(ta.get("heavy") == "qwen36-27b-96k",  f"4090 heavy alias {ta.get('heavy')}")
print(f"{label}: {P} passed, {F} failed")
sys.exit(1 if F else 0)
PY
}

overall=0
for combo in "5090 true" "5090 false" "4090 true" "4090 false"; do
    set -- $combo; tier="$1"; tp="$2"
    out="$(mktemp)"
    gen_one "$tier" "$tp" "$out"
    if [[ -s "$out" ]]; then
        validate "$out" "$tier" "$tp" "gen-${tier}-tp${tp}" || overall=1
    else
        echo "  FAIL: gen-${tier}-tp${tp} produced no local-models.json"; overall=1
    fi
    rm -f "$out"
done
rm -f "$SHIMLIB"

if [[ $overall -eq 0 ]]; then echo -e "\ninstaller-gen: all tier/profile combinations OK"; else echo -e "\ninstaller-gen: FAILURES"; fi
exit $overall
