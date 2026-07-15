#!/usr/bin/env bash
# Schema/invariant checks on the roster data files (python side; PowerShell parse is covered by run-all.ps1).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"

python3 - "$REPO/scripts/local-models.json" "$REPO/cachyos/server-models.json" <<'PY'
import json, sys
lm = json.load(open(sys.argv[1]))
sm = json.load(open(sys.argv[2]))
P = F = 0
def ok(c, m):
    global P, F
    if c: P += 1
    else:
        F += 1; print("  FAIL:", m)

reg = lm["registry"]; ta = lm["task_alias"]
for slot, al in ta.items():
    ok(al in reg, f"task_alias[{slot}]={al} not in registry")
for lname, ldef in lm["launchers"].items():
    for which, wdef in ldef.items():
        keys = []
        for cat in wdef["categories"]:
            for r in cat["rows"]:
                keys.append(r["key"])
                if "slot" in r:
                    ok(r["slot"] in ta, f"{lname}/{which} row [{r['key']}] slot '{r.get('slot')}' not in task_alias")
        ok(len(keys) == len(set(keys)), f"{lname}/{which} duplicate keys: {keys}")
for al, e in reg.items():
    ok("label" in e, f"registry[{al}] missing label")

need = ("mode", "key", "label", "task", "model_id", "ctx", "max_output", "max_prompt", "unit", "imagegen_disabled")
skeys = []; ndef = 0
for m in sm["modes"]:
    skeys.append(m["key"])
    for k in need:
        ok(k in m, f"server mode '{m.get('mode')}' missing '{k}'")
    if m.get("default"): ndef += 1
ok(len(skeys) == len(set(skeys)), f"server duplicate keys: {skeys}")
ok(ndef == 1, f"server default count {ndef} != 1")
ok(sm.get("default_mode") in [m["mode"] for m in sm["modes"]], "default_mode is not a known mode")

# server-models.json client-vs-daemon: the daemon reads this exact file, so the modes it will
# advertise are these modes. Assert model_ids are unique too (clients address by model_id).
mids = [m["model_id"] for m in sm["modes"]]
ok(len(mids) == len(set(mids)), f"server model_id not unique: {mids}")

for f in (sys.argv[1], sys.argv[2]):
    ok("__" not in open(f).read(), f"{f} contains a residual __placeholder__")

print(f"\nschema: {P} passed, {F} failed")
sys.exit(1 if F else 0)
PY
