#!/bin/bash
#
# health-check.sh — AdGuard Home liveness probe with iptables DNAT failover.
#
# Runs continuously on the UDM SE. On every INTERVAL seconds it issues a DNS
# query against AdGuard. After FAIL_THRESHOLD consecutive failures it inserts
# a nat/PREROUTING DNAT rule that transparently redirects traffic destined
# for the AdGuard IP on port 53 (UDP+TCP) to the configured Quad9 fallback.
# After RECOVER_THRESHOLD consecutive successes it removes the rule.
#
# Clients continue using AdGuard's IP as their DNS server throughout; the
# switch is invisible to them thanks to conntrack un-NAT'ing the reply.
#
# Deployed to /data/adguard-failover/health-check.sh on the UDM.
# See dream-machine/docs/how-it-works.md for the full write-up.

set -u

# ------------------------------------------------------------------
# Config
# ------------------------------------------------------------------

CONFIG_FILE="/data/adguard-failover/config.env"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

# Defaults (overridden by config.env if present)
: "${ADGUARD_IP:=192.168.1.99}"
: "${PROBE_NAME:=dns.quad9.net}"
: "${FALLBACK_PRIMARY:=9.9.9.9}"
: "${INTERVAL:=10}"
: "${FAIL_THRESHOLD:=3}"
: "${RECOVER_THRESHOLD:=2}"
: "${LOG_FILE:=/data/adguard-failover.log}"
: "${LOG_MAX_BYTES:=5242880}"

# ------------------------------------------------------------------
# Logging (self-contained, size-based rotation)
# ------------------------------------------------------------------

log() {
    local ts msg size
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    msg="$1"
    printf '%s  %s\n' "$ts" "$msg" >>"$LOG_FILE"

    if [ -f "$LOG_FILE" ]; then
        size=$(stat -c '%s' "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
            tail -c $((LOG_MAX_BYTES / 2)) "$LOG_FILE" >"${LOG_FILE}.tmp" \
                && mv "${LOG_FILE}.tmp" "$LOG_FILE"
            printf '%s  --- log truncated (size limit reached) ---\n' \
                "$ts" >>"$LOG_FILE"
        fi
    fi
}

# ------------------------------------------------------------------
# Probe
# ------------------------------------------------------------------

# Prefer dig; fall back to drill or nslookup if dig is not on the UDM.
if command -v dig >/dev/null 2>&1; then
    PROBE_CMD='dig @"$ADGUARD_IP" "$PROBE_NAME" +time=2 +tries=1 +short'
elif command -v drill >/dev/null 2>&1; then
    PROBE_CMD='drill -Q "$PROBE_NAME" @"$ADGUARD_IP"'
else
    PROBE_CMD='nslookup -timeout=2 "$PROBE_NAME" "$ADGUARD_IP"'
fi

probe() {
    # Success == exit 0 AND non-empty output. Suppress noise.
    local out
    out="$(eval "$PROBE_CMD" 2>/dev/null)"
    [ $? -eq 0 ] && [ -n "$out" ]
}

# ------------------------------------------------------------------
# iptables rule management (idempotent)
# ------------------------------------------------------------------

# Arguments used for both insert and delete (must match exactly).
rule_args() {
    local proto="$1"
    printf 'PREROUTING -d %s -p %s --dport 53 -j DNAT --to-destination %s:53' \
        "$ADGUARD_IP" "$proto" "$FALLBACK_PRIMARY"
}

rule_present() {
    local proto="$1"
    # shellcheck disable=SC2046
    iptables -t nat -C $(rule_args "$proto") 2>/dev/null
}

rule_insert() {
    local proto="$1"
    if ! rule_present "$proto"; then
        # shellcheck disable=SC2046
        iptables -t nat -I $(rule_args "$proto")
    fi
}

rule_delete() {
    local proto="$1"
    # Delete all matching copies (defensive against accidental duplicates).
    while rule_present "$proto"; do
        # shellcheck disable=SC2046
        iptables -t nat -D $(rule_args "$proto") 2>/dev/null || break
    done
}

engage_failover() {
    rule_insert udp
    rule_insert tcp
    log "FAILOVER ENGAGED  → AdGuard ${ADGUARD_IP} DOWN; DNAT :53 → ${FALLBACK_PRIMARY}"
}

disengage_failover() {
    rule_delete udp
    rule_delete tcp
    log "FAILOVER CLEARED  ← AdGuard ${ADGUARD_IP} UP; DNAT rules removed"
}

# ------------------------------------------------------------------
# Signal handling — remove DNAT on exit so we don't strand traffic.
# ------------------------------------------------------------------

cleanup() {
    log "signal received; cleaning up DNAT rules and exiting"
    rule_delete udp
    rule_delete tcp
    exit 0
}
trap cleanup TERM INT HUP

# ------------------------------------------------------------------
# Startup: reconcile any stale rules from a prior run.
# ------------------------------------------------------------------

log "===== health-check starting  (pid $$) ====="
log "  ADGUARD_IP=${ADGUARD_IP}  PROBE=${PROBE_NAME}  FALLBACK=${FALLBACK_PRIMARY}"
log "  INTERVAL=${INTERVAL}s  FAIL_THRESHOLD=${FAIL_THRESHOLD}  RECOVER_THRESHOLD=${RECOVER_THRESHOLD}"

if rule_present udp || rule_present tcp; then
    log "startup: stale DNAT rules present, removing before entering loop"
    rule_delete udp
    rule_delete tcp
fi

# ------------------------------------------------------------------
# Main loop
# ------------------------------------------------------------------

state="UP"       # UP or DOWN — assume UP until proven otherwise
fail_count=0
success_count=0

while true; do
    if probe; then
        success_count=$((success_count + 1))
        fail_count=0
        if [ "$state" = "DOWN" ] && [ "$success_count" -ge "$RECOVER_THRESHOLD" ]; then
            state="UP"
            success_count=0
            disengage_failover
        fi
    else
        fail_count=$((fail_count + 1))
        success_count=0
        if [ "$state" = "UP" ] && [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
            state="DOWN"
            fail_count=0
            engage_failover
        fi
    fi
    sleep "$INTERVAL"
done
