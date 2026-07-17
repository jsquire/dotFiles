#!/usr/bin/env bash
# Guards the office-skill wiring: the skill must ship in the repo, BOTH installers must deploy it to
# Copilot's personal skills dir (~/.copilot/skills/office), and the Copilot launchers must NOT use the
# broken COPILOT_CUSTOM_INSTRUCTIONS_DIRS mechanism (Copilot ignores SKILL.md there; it discovers skills
# from ~/.copilot/skills instead).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

WIN="$REPO_DIR/windows/install-windows.ps1"
CACHY="$REPO_DIR/cachyos/install-cachyos.sh"
CL_SH="$REPO_DIR/scripts/copilot-local.sh"
CL_PS="$REPO_DIR/scripts/copilot-local.ps1"

# The skill itself ships in the repo.
assert_true "office SKILL.md present in repo" test -f "$REPO_DIR/config/skills/office/SKILL.md"

# Both installers deploy it to Copilot's personal skills dir.
assert_true "windows installer deploys office skill to ~/.copilot/skills" \
    grep -q '\.copilot[\\/]skills[\\/]office' "$WIN"
assert_true "cachyos installer deploys office skill to ~/.copilot/skills" \
    grep -q '\.copilot/skills/office' "$CACHY"

# The uninstaller cleans it up.
assert_true "cachyos remover cleans ~/.copilot/skills/office" \
    grep -q '\.copilot/skills/office' "$REPO_DIR/cachyos/remove-cachyos.sh"

# Neither Copilot launcher uses the broken custom-instructions mechanism any more.
assert_eq "copilot-local.sh drops COPILOT_CUSTOM_INSTRUCTIONS_DIRS export" "0" \
    "$(grep -c 'export COPILOT_CUSTOM_INSTRUCTIONS_DIRS' "$CL_SH")"
assert_eq "copilot-local.ps1 drops COPILOT_CUSTOM_INSTRUCTIONS_DIRS assignment" "0" \
    "$(grep -c 'COPILOT_CUSTOM_INSTRUCTIONS_DIRS =' "$CL_PS")"

# The skill must steer the model to WRITE THE SCRIPT AS A FILE (via its editor), not compose it through
# the shell — echo/here-doc quoting breaks under PowerShell (the §BI cover-letter failure).
SKILL="$REPO_DIR/config/skills/office/SKILL.md"
assert_true "skill says create a new file with the file tool" \
    grep -qi 'create.*new.*file' "$SKILL"
assert_true "skill warns against composing the script through the shell" \
    grep -qi 'do .*not.* compose the script through the shell' "$SKILL"
assert_true "skill warns against literal escape sequences in the file" \
    grep -q '\\r\\n' "$SKILL"

ll_summary "office-skill"
