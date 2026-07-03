#!/bin/bash
#
# test-failover.sh — simulate AdGuard being unreachable from the UDM, wait
# for the debounce threshold, and confirm the DNAT rule engages and clients
# still get DNS answers (from Quad9).
#
# Requires SSH access to the UDM. Automatically restores the block at the
# end even on failure (via trap).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$(cd "$SCRIPT_DIR/../scripts" && pwd)/config.env"
# shellcheck disable=SC1090
. "$CONFIG_FILE"

SSH_TARGET="${UDM_SSH_USER}@${UDM_HOST}"
SSH_OPTS=(-o ConnectTimeout=5)

BLOCK_RULE=(OUTPUT -d "$ADGUARD_IP" -j DROP)

cleanup() {
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
        "iptables -D ${BLOCK_RULE[*]} 2>/dev/null; true" || true
}
trap cleanup EXIT

echo "=== test-failover.sh — simulated AdGuard outage ==="
echo

echo "Step 1: Block AdGuard (${ADGUARD_IP}) from the UDM's perspective"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "iptables -I ${BLOCK_RULE[*]}"

# Wait FAIL_THRESHOLD × INTERVAL + a buffer for state transition.
wait_secs=$(( FAIL_THRESHOLD * INTERVAL + INTERVAL ))
echo "Step 2: Wait ${wait_secs}s for daemon to declare DOWN"
sleep "$wait_secs"

echo "Step 3: Verify DNAT rule is now present"
ok=1
for proto in udp tcp; do
    if ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
        "iptables -t nat -C PREROUTING -d ${ADGUARD_IP} -p ${proto} --dport 53 -j DNAT --to-destination ${FALLBACK_PRIMARY}:53" 2>/dev/null; then
        printf '  \033[1;32m✓\033[0m DNAT rule present (%s)\n' "$proto"
    else
        printf '  \033[1;31m✗\033[0m DNAT rule missing (%s)\n' "$proto"
        ok=0
    fi
done

echo "Step 4: Confirm client-side DNS still resolves (should now be Quad9)"
if dig @"$ADGUARD_IP" "$PROBE_NAME" +time=3 +tries=1 +short | grep -q '.'; then
    printf '  \033[1;32m✓\033[0m dig still returns answers via %s\n' "$ADGUARD_IP"
else
    printf '  \033[1;31m✗\033[0m dig failed — failover not working\n'
    ok=0
fi

echo "Step 5: Recent daemon log"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'tail -n 8 /data/adguard-failover.log'

echo
if [ "$ok" -eq 1 ]; then
    printf '\033[1;32mPASS\033[0m  — failover engaged and traffic is being redirected\n'
    echo "The trap will now remove the block. Run test-recovery.sh next."
    exit 0
else
    printf '\033[1;31mFAIL\033[0m\n'
    exit 1
fi
