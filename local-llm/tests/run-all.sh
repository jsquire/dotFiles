#!/usr/bin/env bash
# Orchestrator for the Bash-side suites with recursive protected-root isolation validation.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$DIR"/*.sh "$DIR"/stubs/* 2>/dev/null || true

snapshot="$(mktemp)"
after_snapshot="$(mktemp)"
cleanup() { rm -f "$snapshot" "$after_snapshot"; }
trap cleanup EXIT

snapshot_protected() {
    python3 - "$HOME/.config/local-llm" "$HOME/.copilot/mcp-config.json" "$HOME/.copilot/skills/office" <<'PY'
import hashlib
import json
import os
import stat
import sys

rows = []
for root in sys.argv[1:]:
    if not os.path.lexists(root):
        rows.append({"path": root, "type": "missing", "size": 0, "sha256": ""})
        continue
    paths = [root]
    if os.path.isdir(root) and not os.path.islink(root):
        for base, dirs, files in os.walk(root):
            dirs.sort()
            files.sort()
            paths.extend(os.path.join(base, name) for name in dirs + files)
    for path in paths:
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode):
            kind, digest = "link", hashlib.sha256(os.readlink(path).encode()).hexdigest()
        elif stat.S_ISDIR(info.st_mode):
            kind, digest = "directory", ""
        else:
            kind = "file"
            h = hashlib.sha256()
            with open(path, "rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    h.update(chunk)
            digest = h.hexdigest()
        rows.append({"path": path, "type": kind, "size": info.st_size, "sha256": digest})
print(json.dumps(sorted(rows, key=lambda row: row["path"]), separators=(",", ":")))
PY
}

snapshot_protected > "$snapshot"
fail=0
for s in test_schema.sh test_daemon.sh test_launchers_parity.sh test_launcher_switch.sh test_token_budgets.sh test_installer_gen.sh test_imagegen_context.sh test_imagegen_path.sh test_office_skill.sh test_ollama_proxy.sh run-python-tests.sh; do
    echo "########## $s ##########"
    if bash "$DIR/$s"; then echo "-> $s OK"; else echo "-> $s FAILED"; fail=1; fi
    echo
done
snapshot_protected > "$after_snapshot"
if ! cmp -s "$snapshot" "$after_snapshot"; then
    echo "!! ISOLATION VIOLATION: a protected configuration root changed during the run"
    diff -u "$snapshot" "$after_snapshot" || true
    fail=1
else
    echo "isolation OK: protected configuration roots unchanged"
fi

echo
if [[ $fail -eq 0 ]]; then echo "==== ALL BASH SUITES PASSED ===="; else echo "==== BASH SUITE FAILURES ===="; fi
exit $fail
