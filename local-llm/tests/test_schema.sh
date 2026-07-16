#!/usr/bin/env bash
# Schema/invariant checks on the roster data files (python side; PowerShell parse is covered by run-all.ps1).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"

python3 - "$REPO/scripts/local-models.json" "$REPO/cachyos/server-models.json" "$REPO/cachyos/vllm-switch-web.py" <<'PY'
import json, sys, os, importlib.util
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

# menu (schema v2): the TASK picker. Every row.mode must resolve to a real mode; keys unique across it.
modes_set = {m["mode"] for m in sm["modes"]}
menu = (sm.get("menu") or {}).get("categories")
ok(menu is not None, "server-models.json missing menu.categories")
if menu:
    mkeys = []
    for cat in menu:
        ok("heading" in cat, "menu category missing heading")
        for r in cat.get("rows", []):
            mkeys.append(r["key"])
            ok(r.get("mode") in modes_set, f"menu row [{r.get('key')}] mode '{r.get('mode')}' not a real mode")
            ok("label" in r, f"menu row [{r.get('key')}] missing label")
    ok(len(mkeys) == len(set(mkeys)), f"menu duplicate keys: {mkeys}")
ok("glm" not in modes_set, "GLM was retired from the server roster but is still present in modes")

for f in (sys.argv[1], sys.argv[2]):
    ok("__" not in open(f).read(), f"{f} contains a residual __placeholder__")

# Guard: the daemon's built-in _FALLBACK_ROSTER (used only if the roster file is missing) must stay
# identical to server-models.json, so a client hitting the fallback sees the same modes. Import the
# daemon module with a bogus roster path so its module-level load is deterministic (uses the fallback).
import importlib.util
os.environ["VLLM_SERVER_MODELS"] = "/nonexistent-roster-for-schema-test"
spec = importlib.util.spec_from_file_location("vsw_under_test", sys.argv[3])
vsw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vsw)
fb = vsw._FALLBACK_ROSTER
ok(fb.get("default_mode") == sm.get("default_mode"), "fallback default_mode != server-models.json")
ok(fb.get("api_port") == sm.get("api_port"), "fallback api_port != server-models.json")
ok(fb.get("schema_version") == sm.get("schema_version"), "fallback schema_version != server-models.json")
ok(fb.get("menu") == sm.get("menu"), "_FALLBACK_ROSTER menu != server-models.json menu")
fb_by = {m["mode"]: m for m in fb["modes"]}
ok(len(fb["modes"]) == len(sm["modes"]), f"fallback mode count {len(fb['modes'])} != {len(sm['modes'])}")
_fields = ("mode", "key", "label", "task", "model_id", "ctx", "max_output",
           "max_prompt", "unit", "imagegen_disabled", "default")
for m in sm["modes"]:
    fm = fb_by.get(m["mode"])
    ok(fm is not None, f"_FALLBACK_ROSTER missing mode '{m['mode']}'")
    if fm:
        for k in _fields:
            ok(fm.get(k) == m.get(k),
               f"_FALLBACK_ROSTER[{m['mode']}].{k}={fm.get(k)!r} != server-models.json {m.get(k)!r}")

print(f"\nschema: {P} passed, {F} failed")
sys.exit(1 if F else 0)
PY
