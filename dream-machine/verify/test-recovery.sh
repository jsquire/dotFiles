#!/bin/bash
#
# test-recovery.sh — after a simulated outage (test-failover.sh), verify the
# daemon detects AdGuard is back UP within RECOVER_THRESHOLD * INTERVAL and
# removes the DNAT rule.
#
# Run this AFTER test-failover.sh has completed (which auto-removes its block
# on exit). This test just confirms the recovery path.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$(cd "$SCRIPT_DIR/../scripts" && pwd)/config.env"
# shellcheck disable=SC1090
. "$CONFIG_FILE"

SSH_TARGET="${UDM_SSH_USER}@${UDM_HOST}"
SSH_OPTS=(-o ConnectTimeout=5)

echo "=== test-recovery.sh — AdGuard back UP ==="
echo

# Belt & suspenders: make sure no leftover block is present.
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
    "iptables -D OUTPUT -d ${ADGUARD_IP} -j DROP 2>/dev/null; true" || true

wait_secs=$(( RECOVER_THRESHOLD * INTERVAL + INTERVAL ))
echo "Waiting ${wait_secs}s for daemon to declare UP"
sleep "$wait_secs"

ok=1
for proto in udp tcp; do
    if ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
        "iptables -t nat -C PREROUTING -d ${ADGUARD_IP} -p ${proto} --dport 53 -j DNAT --to-destination ${FALLBACK_PRIMARY}:53" 2>/dev/null; then
        printf '  \033[1;31m✗\033[0m DNAT rule STILL present (%s) — recovery failed\n' "$proto"
        ok=0
    else
        printf '  \033[1;32m✓\033[0m DNAT rule removed (%s)\n' "$proto"
    fi
done

if dig @"$ADGUARD_IP" "$PROBE_NAME" +time=3 +tries=1 +short | grep -q '.'; then
    printf '  \033[1;32m✓\033[0m dig against AdGuard returns answers\n'
else
    printf '  \033[1;31m✗\033[0m dig against AdGuard failed\n'
    ok=0
fi

echo
echo "Recent daemon log:"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'tail -n 8 /data/adguard-failover.log'

echo
if [ "$ok" -eq 1 ]; then
    printf '\033[1;32mPASS\033[0m  — recovery clean; AdGuard is once again the resolver\n'
    echo "Confirm in the AdGuard dashboard that the query above shows"
    echo "your workstation's real LAN IP as the client."
    exit 0
else
    printf '\033[1;31mFAIL\033[0m\n'
    exit 1
fi
