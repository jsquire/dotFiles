#!/usr/bin/env bash
# Orchestrator for the bash-side suites (schema, daemon, launcher parity, installer generation).
# Prints a per-suite result and an isolation check, and exits nonzero if anything failed.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$DIR"/*.sh "$DIR"/stubs/* 2>/dev/null || true

before="$(stat -c %Y "$HOME/.config/local-llm" 2>/dev/null || echo none)"
fail=0
for s in test_schema.sh test_daemon.sh test_launchers_parity.sh test_installer_gen.sh test_imagegen_context.sh test_imagegen_path.sh test_office_skill.sh; do
    echo "########## $s ##########"
    if bash "$DIR/$s"; then echo "-> $s OK"; else echo "-> $s FAILED"; fail=1; fi
    echo
done
after="$(stat -c %Y "$HOME/.config/local-llm" 2>/dev/null || echo none)"
if [[ "$before" != "$after" ]]; then
    echo "!! ISOLATION VIOLATION: ~/.config/local-llm was modified during the run"; fail=1
else
    echo "isolation OK: real ~/.config/local-llm untouched"
fi

echo
if [[ $fail -eq 0 ]]; then echo "==== ALL BASH SUITES PASSED ===="; else echo "==== BASH SUITE FAILURES ===="; fi
exit $fail
