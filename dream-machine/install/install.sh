#!/bin/bash
#
# install.sh — deploy the AdGuard failover daemon to the UDM SE.
#
# Run this from your workstation, NOT on the UDM. It:
#   1. Reads config from ../scripts/config.env (created from
#      config.env.example).
#   2. Verifies SSH reachability of the UDM.
#   3. Installs the community `unifi-common` package on the UDM (idempotent).
#   4. Copies health-check.sh, boot-hook.sh, and config.env into place under
#      /data/ on the UDM.
#   5. Sets executable bits.
#   6. Launches the boot hook once to start the daemon without rebooting.
#   7. Tails the log to confirm a healthy start.
#   8. Prints follow-up instructions (UniFi DHCP DNS setting).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$REPO_DIR/scripts/config.env"

# ------------------------------------------------------------------
# Load config
# ------------------------------------------------------------------

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: $CONFIG_FILE not found." >&2
    echo "       Copy scripts/config.env.example → scripts/config.env" >&2
    echo "       and edit it for your environment first." >&2
    exit 1
fi

# shellcheck disable=SC1090
. "$CONFIG_FILE"

: "${UDM_HOST:?UDM_HOST must be set in config.env}"
: "${UDM_SSH_USER:?UDM_SSH_USER must be set in config.env}"
: "${ADGUARD_IP:?ADGUARD_IP must be set in config.env}"

SSH_TARGET="${UDM_SSH_USER}@${UDM_HOST}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------
# Step 1: SSH reachability
# ------------------------------------------------------------------

say "Verifying SSH reachability to ${SSH_TARGET}"
if ! ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'echo ok' >/dev/null 2>&1; then
    die "Cannot SSH to ${SSH_TARGET}. Enable SSH on the UDM (UniFi Network → Settings → Control Plane → Console) and try again."
fi
ok "SSH works"

# ------------------------------------------------------------------
# Step 2: Install unifi-common (idempotent; upstream installer detects
#         existing install).
# ------------------------------------------------------------------

say "Installing unifi-common boot-script framework on the UDM (idempotent)"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" '
    set -e
    if systemctl is-enabled udm-boot.service >/dev/null 2>&1; then
        echo "unifi-common already installed"
    else
        curl -fsL "https://raw.githubusercontent.com/unifi-utilities/unifi-common/HEAD/remote_install.sh" | /bin/bash
    fi
'
ok "unifi-common ready"

# ------------------------------------------------------------------
# Step 3: Deploy scripts + config
# ------------------------------------------------------------------

say "Creating /data directories on the UDM"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'mkdir -p /data/adguard-failover /data/on_boot.d'
ok "Directories present"

say "Copying scripts and config to the UDM"
scp "${SSH_OPTS[@]}" \
    "$REPO_DIR/scripts/health-check.sh" \
    "$REPO_DIR/scripts/config.env" \
    "$SSH_TARGET":/data/adguard-failover/
scp "${SSH_OPTS[@]}" \
    "$REPO_DIR/scripts/boot-hook.sh" \
    "$SSH_TARGET":/data/on_boot.d/15-adguard-failover.sh
ok "Files deployed"

say "Setting executable bits"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" '
    chmod +x /data/adguard-failover/health-check.sh
    chmod +x /data/on_boot.d/15-adguard-failover.sh
'
ok "Permissions set"

# ------------------------------------------------------------------
# Step 4: First launch (no reboot required)
# ------------------------------------------------------------------

say "Stopping any previous supervisor and starting fresh"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" '
    if [ -f /run/adguard-failover.pid ]; then
        pid=$(cat /run/adguard-failover.pid 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" || true
            sleep 1
        fi
        rm -f /run/adguard-failover.pid
    fi
    # Explicit stdio redirection is belt-and-suspenders on top of the
    # detachment inside boot-hook.sh, so the SSH session cannot hang on
    # any inherited fd from the backgrounded supervisor.
    nohup /data/on_boot.d/15-adguard-failover.sh </dev/null >/dev/null 2>&1
    sleep 3
'
ok "Daemon launched"

# ------------------------------------------------------------------
# Step 5: Tail the log
# ------------------------------------------------------------------

say "Recent log output from /data/adguard-failover.log:"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'tail -n 20 /data/adguard-failover.log || true'
echo

# ------------------------------------------------------------------
# Follow-up instructions
# ------------------------------------------------------------------

cat <<EOF

$(ok "Install complete.")

Next steps (manual, GUI only):

  1. Open the UniFi Network app.
  2. Settings → Networks → your LAN network.
  3. Under DHCP Service Management → DNS Server, set:
         ${ADGUARD_IP}
     (single entry; remove any other DNS entries in this list — the DNAT
      rule handles failover, so the DHCP list should NOT contain Quad9.)
  4. Save. Clients will pick up the new DNS on their next lease renewal
     (or immediately if you release/renew).

To verify end-to-end behavior, run the scripts in ../verify/:
  ./verify/test-normal.sh
  ./verify/test-failover.sh
  ./verify/test-recovery.sh

EOF
