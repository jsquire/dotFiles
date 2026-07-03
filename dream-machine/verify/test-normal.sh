#!/bin/bash
#
# test-normal.sh — baseline: confirm DNS via AdGuard works and no failover
# rule is currently engaged.
#
# Run from your workstation.

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

pass=0
fail=0
check() {
    local desc="$1" cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        printf '  \033[1;32m✓\033[0m %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf '  \033[1;31m✗\033[0m %s\n' "$desc"
        fail=$((fail + 1))
    fi
}

echo "=== test-normal.sh — AdGuard baseline ==="

check "dig against AdGuard (${ADGUARD_IP}) resolves ${PROBE_NAME}" \
    "dig @${ADGUARD_IP} ${PROBE_NAME} +time=3 +tries=1 +short | grep -q '.'"

check "daemon supervisor PID file exists on UDM" \
    "ssh -o ConnectTimeout=5 ${SSH_TARGET} 'test -f /run/adguard-failover.pid'"

check "daemon supervisor process is running" \
    "ssh -o ConnectTimeout=5 ${SSH_TARGET} 'kill -0 \$(cat /run/adguard-failover.pid)'"

check "no DNAT failover rule currently engaged (UDP)" \
    "! ssh -o ConnectTimeout=5 ${SSH_TARGET} 'iptables -t nat -C PREROUTING -d ${ADGUARD_IP} -p udp --dport 53 -j DNAT --to-destination ${FALLBACK_PRIMARY}:53 2>/dev/null'"

check "no DNAT failover rule currently engaged (TCP)" \
    "! ssh -o ConnectTimeout=5 ${SSH_TARGET} 'iptables -t nat -C PREROUTING -d ${ADGUARD_IP} -p tcp --dport 53 -j DNAT --to-destination ${FALLBACK_PRIMARY}:53 2>/dev/null'"

echo
if [ "$fail" -eq 0 ]; then
    printf '\033[1;32mPASS\033[0m  (%d checks)\n' "$pass"
    echo "Also: open the AdGuard Home dashboard — the query above for"
    echo "${PROBE_NAME} should appear in the query log, sourced from"
    echo "your workstation's LAN IP."
    exit 0
else
    printf '\033[1;31mFAIL\033[0m  (%d passed, %d failed)\n' "$pass" "$fail"
    exit 1
fi
