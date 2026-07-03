#!/bin/bash
#
# uninstall.sh — remove the AdGuard failover daemon from the UDM.
#
# Leaves the unifi-common package in place (that's a separate decision;
# see ReadMe.md for instructions on removing it).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$(cd "$SCRIPT_DIR/../scripts" && pwd)/config.env"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: $CONFIG_FILE not found." >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$CONFIG_FILE"

SSH_TARGET="${UDM_SSH_USER}@${UDM_HOST}"
SSH_OPTS=(-o ConnectTimeout=5)

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m✓\033[0m %s\n' "$*"; }

say "Stopping supervisor on ${SSH_TARGET}"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" '
    if [ -f /run/adguard-failover.pid ]; then
        pid=$(cat /run/adguard-failover.pid 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            # Kill the whole process group so the loop and any child daemon go too.
            kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
            sleep 2
            kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        fi
        rm -f /run/adguard-failover.pid
    fi
    # Extra sweep — kill any lingering health-check.sh processes.
    for p in $(pgrep -f /data/adguard-failover/health-check.sh 2>/dev/null); do
        kill -TERM "$p" 2>/dev/null || true
    done
'
ok "Supervisor stopped"

say "Removing boot hook and daemon files"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" '
    rm -f /data/on_boot.d/15-adguard-failover.sh
    rm -rf /data/adguard-failover
'
ok "Files removed"

say "Flushing any lingering DNAT rule for ${ADGUARD_IP}:53"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "
    for proto in udp tcp; do
        while iptables -t nat -C PREROUTING -d ${ADGUARD_IP} -p \$proto --dport 53 -j DNAT --to-destination ${FALLBACK_PRIMARY}:53 2>/dev/null; do
            iptables -t nat -D PREROUTING -d ${ADGUARD_IP} -p \$proto --dport 53 -j DNAT --to-destination ${FALLBACK_PRIMARY}:53 || break
        done
    done
"
ok "DNAT rules flushed"

cat <<EOF

$(ok "Uninstall complete.")

The unifi-common package is still installed. To remove it entirely, on the
UDM run:

    systemctl disable --now udm-boot.service
    rm -f /etc/systemd/system/udm-boot.service
    rm -rf /data/on_boot.d
    systemctl daemon-reload

Also revisit UniFi Network → Settings → Networks → LAN → DHCP → DNS Server
and change it back to whatever you want clients to use directly (e.g. your
router, or Quad9 without failover).

EOF
