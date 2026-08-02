#!/bin/bash
#
# dns-failover.sh — AdGuard Home liveness probe with absent-standby DNS failover.
#
# Runs continuously on the UDM SE. Clients are handed two DNS servers by DHCP:
# AdGuard (primary) and FAILOVER_IP (secondary). FAILOVER_IP does not exist on
# the network while AdGuard is healthy, which is what forces every client onto
# AdGuard and leaves its per-client attribution and filtering undisturbed.
#
# When AdGuard stops serving usable answers, this daemon binds FAILOVER_IP to
# the LAN bridge. The UDM's dnsmasq runs with `bind-dynamic`, so it picks the
# address up automatically and begins answering DNS on it. When AdGuard
# recovers, the address is removed and the standby vanishes again.
#
# No iptables rules. No changes to any UniFi-generated file. ADGUARD_IP is never
# impersonated, so SSH and every other service on the AdGuard host stay
# reachable throughout an outage.
#
# Deployed to /data/adguard-failover/dns-failover.sh on the UDM.
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
: "${FAILOVER_IP:=192.168.1.2}"
: "${LAN_IF:=br0}"
: "${PROBE_NAME:=dns.quad9.net}"
: "${CORROBORATE_SERVER:=127.0.0.1}"
: "${CORROBORATE_ZONE:=example.com}"
: "${PROBE_TIMEOUT:=2}"
: "${INTERVAL:=10}"
: "${FAIL_THRESHOLD:=3}"
: "${RECOVER_THRESHOLD:=3}"
: "${RESOLV_FILE:=/run/resolv.conf.d/main}"
: "${LOG_FILE:=/data/adguard-failover/failover.log}"
: "${LOG_MAX_BYTES:=5242880}"

# ------------------------------------------------------------------
# Logging (self-contained, size-based rotation)
# ------------------------------------------------------------------

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

log() {
    local ts size
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s  %s\n' "$ts" "$1" >>"$LOG_FILE"

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
# dig parsing contract
# ------------------------------------------------------------------
#
# RCODE is read from the response header line, which dig emits as:
#
#     ;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 12345
#
# The contract, which must not be "tidied up" into something else:
#
#   1. Select the line containing '->>HEADER<<-'.
#   2. Extract the token following 'status: ', up to the next comma. That
#      value is the RCODE and the SOLE input to classification.
#   3. If no such line exists, the result is TIMEOUT. On no reply dig prints
#      ";; connection timed out; no servers could be reached" and emits no
#      header, so absence of the field is itself the timeout signal.
#
# Explicitly NOT part of the contract, and not to be reintroduced: dig's exit
# status, +short output, and emptiness of the answer section. Each conflates
# cases the RCODE separates. The retired daemon's
# `[ $? -eq 0 ] && [ -n "$out" ]` test is precisely the pattern this replaces.

dig_rcode() {
    local server="$1" name="$2" out rcode
    out="$(dig @"$server" "$name" A +tries=1 +time="$PROBE_TIMEOUT" 2>/dev/null)"
    rcode="$(printf '%s\n' "$out" | awk '
        /->>HEADER<<-/ {
            if (match($0, /status: [A-Z]+/)) {
                print substr($0, RSTART + 8, RLENGTH - 8)
                exit
            }
        }')"
    [ -n "$rcode" ] || rcode="TIMEOUT"
    printf '%s\n' "$rcode"
}

# NOERROR and NXDOMAIN are success: both prove the resolver processed the query
# and the resolution chain worked. SERVFAIL, REFUSED and TIMEOUT are failures —
# all three are client-visible outages, regardless of being well-formed
# responses.
rcode_ok() {
    case "$1" in
        NOERROR|NXDOMAIN) return 0 ;;
        *)                return 1 ;;
    esac
}

# ------------------------------------------------------------------
# Probes
# ------------------------------------------------------------------

PRIMARY_RCODE=""
CORROBORATE_RCODE=""

# Is AdGuard serving usable answers?
probe_primary() {
    PRIMARY_RCODE="$(dig_rcode "$ADGUARD_IP" "$PROBE_NAME")"
    rcode_ok "$PRIMARY_RCODE"
}

# Random label, so the corroborating query cannot be answered from cache.
# Prefixed with a letter so the label is never all-numeric.
random_label() {
    if [ -r /dev/urandom ]; then
        printf 'x%s' "$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    else
        printf 'x%s%s' "$$" "$(date +%s)"
    fi
}

# Would failing over actually help?
#
# Queries the UDM's own dnsmasq rather than the upstream directly, because that
# is the exact path FAILOVER_IP will serve during an outage; testing anything
# else tests the wrong thing.
#
# The randomised label is MANDATORY. dnsmasq runs with a large cache, so a fixed
# name could be answered from cache and vouch for an upstream that is entirely
# unreachable — the precise false positive that would let failover engage during
# a WAN outage. A fresh label cannot be in cache, positive or negative, and so
# forces real recursion.
#
# What makes this probe valid is that CACHE IS BYPASSED, not which success code
# comes back. Either NOERROR or NXDOMAIN is accepted, because producing either
# one requires the full resolution chain to have worked. Do not narrow this to a
# single expected RCODE: measured against example.com the answer is NOERROR with
# an empty answer section, not NXDOMAIN, and a stricter check would suppress
# failover permanently while looking more rigorous.
probe_corroborate() {
    CORROBORATE_RCODE="$(dig_rcode "$CORROBORATE_SERVER" "$(random_label).${CORROBORATE_ZONE}")"
    rcode_ok "$CORROBORATE_RCODE"
}

# ------------------------------------------------------------------
# Failover address management
# ------------------------------------------------------------------

failover_ip_present() {
    ip -4 -o addr show dev "$LAN_IF" 2>/dev/null | awk -v ip="$FAILOVER_IP" '
        { split($4, a, "/"); if (a[1] == ip) found = 1 }
        END { exit !found }'
}

engage_error_logged=0
selfheal_active=0

engage_failover() {
    if failover_ip_present; then
        log "engage: ${FAILOVER_IP} already present on ${LAN_IF}, nothing to do"
        return 0
    fi

    if ! ip addr add "${FAILOVER_IP}/32" dev "$LAN_IF" 2>/dev/null; then
        # Edge-triggered: a persistently failing bind is retried every INTERVAL,
        # and logging each attempt would flood the log exactly when it most
        # needs to be readable.
        if [ "$engage_error_logged" -eq 0 ]; then
            log "ERROR  failed to add ${FAILOVER_IP}/32 to ${LAN_IF}; clients have NO fallback. Retrying every ${INTERVAL}s, silently."
            engage_error_logged=1
        fi
        return 1
    fi
    engage_error_logged=0
    selfheal_active=0

    # Log the state change as soon as the bind succeeds, BEFORE the best-effort
    # arping. The failover is engaged the moment the address is on the
    # interface; arping is a courtesy to clients holding a negative ARP entry
    # and takes ~3s. Logging after it left a window in which the address was
    # live and serving while the log still said PENDING — the log would
    # understate when the switch actually happened, which is precisely the
    # figure anyone reads this log to find out.
    log "FAILOVER ENGAGED  → AdGuard ${ADGUARD_IP} DOWN (${PRIMARY_RCODE}); ${FAILOVER_IP} bound to ${LAN_IF}"

    # Optional: nudge clients that may hold a negative ARP entry for the
    # address. Harmless if arping is unavailable.
    if command -v arping >/dev/null 2>&1; then
        arping -U -c 3 -I "$LAN_IF" "$FAILOVER_IP" >/dev/null 2>&1 || true
    fi

    return 0
}

disengage_failover() {
    if ! failover_ip_present; then
        return 0
    fi

    if ip addr del "${FAILOVER_IP}/32" dev "$LAN_IF" 2>/dev/null; then
        log "FAILOVER CLEARED  ← AdGuard ${ADGUARD_IP} UP; ${FAILOVER_IP} removed from ${LAN_IF}"
    else
        log "ERROR  failed to remove ${FAILOVER_IP}/32 from ${LAN_IF}; clients may keep bypassing AdGuard"
    fi
}

# Re-assert the standby while failover is engaged.
#
# engage_failover() binds the address once, on the UP → FAILED_OVER edge, and
# nothing re-checked it afterwards. That left the daemon believing it was
# protecting clients while the address was gone: anything that rewrites the LAN
# bridge removes it, and on this device that is not hypothetical — UniFi
# regenerates interface configuration on settings writes and firmware updates,
# and firmware updates here are automatic and unattended. The failure is silent
# in both directions: nothing logs the disappearance, and disengage_failover()
# returns early when the address is already absent, so the eventual recovery
# logs "state: FAILED_OVER → UP" with no matching FAILOVER CLEARED and the log
# reads like a clean episode.
#
# Consequence without this: during an AdGuard outage that overlaps a firmware
# update, clients get no fallback for the remainder of the outage — the standby
# is only restored by the startup reconcile on the next daemon restart.
#
# Called on every iteration that ENDS still in FAILED_OVER, so it cannot fire
# against an episode that is already disengaging.
reassert_failover() {
    if failover_ip_present; then
        selfheal_active=0
        return 0
    fi

    # Edge-triggered on the disappearance, not on the iteration: if the re-add
    # keeps failing it is retried every INTERVAL, silently. A stuck re-add would
    # otherwise flood the log at precisely the moment it most needs to be
    # readable — the same reasoning as engage_error_logged above.
    local announce=0
    if [ "$selfheal_active" -eq 0 ]; then
        selfheal_active=1
        announce=1
        log "SELF-HEAL  ${FAILOVER_IP} disappeared from ${LAN_IF} while failover was ENGAGED — removed by something other than this daemon (UniFi settings write, firmware update, interface bounce). Clients had NO fallback. Re-adding."
    fi

    if ip addr add "${FAILOVER_IP}/32" dev "$LAN_IF" 2>/dev/null; then
        selfheal_active=0
        log "SELF-HEAL COMPLETE  ${FAILOVER_IP} restored to ${LAN_IF}"
        # Re-announce: the address changed hands, so any client that cached a
        # negative ARP entry during the gap needs the same nudge a fresh engage
        # gives it.
        if command -v arping >/dev/null 2>&1; then
            arping -U -c 3 -I "$LAN_IF" "$FAILOVER_IP" >/dev/null 2>&1 || true
        fi
        return 0
    fi

    if [ "$announce" -eq 1 ]; then
        log "ERROR  self-heal could not re-add ${FAILOVER_IP}/32 to ${LAN_IF}; clients have NO fallback. Retrying every ${INTERVAL}s, silently."
    fi
    return 1
}

# ------------------------------------------------------------------
# Upstream drift guard
# ------------------------------------------------------------------
#
# UniFi regenerates its DNS configuration on settings changes, firmware updates
# and WAN lease renewals, and can reintroduce AdGuard as the UDM's own upstream.
# If that happens the fallback forwards into the same dead resolver and the
# whole design is inert.
#
# Logging is EDGE-TRIGGERED: only on transition, plus one line at startup to
# record the initial state. Logging every iteration would bury the transition in
# thousands of identical lines and defeat the purpose.

upstream_drifted() {
    [ -r "$RESOLV_FILE" ] || return 1
    awk -v ip="$ADGUARD_IP" '
        $1 == "nameserver" && $2 == ip { found = 1 }
        END { exit !found }' "$RESOLV_FILE"
}

drift_state="unknown"

check_upstream_drift() {
    local now
    if upstream_drifted; then now="drifted"; else now="clean"; fi

    if [ "$now" != "$drift_state" ]; then
        if [ "$now" = "drifted" ]; then
            log "DRIFT  ${RESOLV_FILE} now lists ${ADGUARD_IP} as an upstream — failover would forward into the dead resolver. Fix in UniFi."
        elif [ "$drift_state" = "unknown" ]; then
            log "upstream check: ${RESOLV_FILE} clean (does not list ${ADGUARD_IP})"
        else
            log "DRIFT CLEARED  ${RESOLV_FILE} no longer lists ${ADGUARD_IP}"
        fi
        drift_state="$now"
    fi
}

# ------------------------------------------------------------------
# Signal handling — never leave the standby address stranded.
# ------------------------------------------------------------------

cleanup() {
    log "signal received; removing ${FAILOVER_IP} if present and exiting"
    disengage_failover
    exit 0
}
trap cleanup TERM INT HUP

# ------------------------------------------------------------------
# Startup
# ------------------------------------------------------------------

log "===== dns-failover starting  (pid $$) ====="
log "  ADGUARD_IP=${ADGUARD_IP}  FAILOVER_IP=${FAILOVER_IP}  LAN_IF=${LAN_IF}"
log "  PROBE_NAME=${PROBE_NAME}  CORROBORATE=${CORROBORATE_SERVER}/${CORROBORATE_ZONE}"
log "  INTERVAL=${INTERVAL}s  FAIL_THRESHOLD=${FAIL_THRESHOLD}  RECOVER_THRESHOLD=${RECOVER_THRESHOLD}"
log "  detection latency = INTERVAL x FAIL_THRESHOLD + probe timeout = $((INTERVAL * FAIL_THRESHOLD + PROBE_TIMEOUT))s worst case"

if ! command -v dig >/dev/null 2>&1; then
    log "FATAL  dig is not available. RCODE parsing is not portable across drill/nslookup, so there is no fallback. Exiting."
    exit 1
fi

# Reconcile: a crash or reboot must never leave the standby bound, because that
# would silently route clients around AdGuard with no indication.
if failover_ip_present; then
    log "startup: stale ${FAILOVER_IP} present on ${LAN_IF}, removing before entering loop"
    disengage_failover
fi

check_upstream_drift

# ------------------------------------------------------------------
# Main loop
# ------------------------------------------------------------------
#
# Three states. Suppression is a boolean FLAG on PENDING, not a fourth state:
# it records whether corroboration has failed at least once in the current
# PENDING episode, exists only to make logging edge-triggered, has no
# transitions of its own, and never alters behaviour.
#
#   UP           Run the primary probe ONLY. At FAIL_THRESHOLD failures, move
#                to PENDING.
#   PENDING      Run primary AND corroboration EVERY iteration. Corroboration
#                success engages failover; failure holds. A suppressed failover
#                therefore engages within one INTERVAL of the upstream
#                recovering: PENDING does not re-accumulate a failure threshold,
#                so there is no fresh FAIL_THRESHOLD cycle to wait through.
#                (fail_count is a UP-state counter only and is not read here.)
#   FAILED_OVER  Run the primary probe ONLY. At RECOVER_THRESHOLD successes,
#                remove the address and return to UP.
#
# Corroboration runs on NO 'UP' iteration. Normal operation is exactly one
# query per cycle, against AdGuard.
#
# The primary probe is hoisted to the top of the loop and its result reused,
# so that a UP → PENDING transition can evaluate corroboration in the SAME
# iteration without issuing a second query. Deferring it to the next iteration
# would silently add one INTERVAL to the documented detection latency of
# INTERVAL x FAIL_THRESHOLD + PROBE_TIMEOUT.

state="UP"
fail_count=0
success_count=0
suppressed=0

while true; do
    check_upstream_drift

    if probe_primary; then primary_ok=1; else primary_ok=0; fi

    if [ "$state" = "UP" ]; then
        if [ "$primary_ok" -eq 1 ]; then
            fail_count=0
        else
            fail_count=$((fail_count + 1))
            log "probe: AdGuard ${ADGUARD_IP} returned ${PRIMARY_RCODE} (${fail_count}/${FAIL_THRESHOLD})"
            if [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
                state="PENDING"
                success_count=0
                suppressed=0
                log "state: UP → PENDING (AdGuard failed ${FAIL_THRESHOLD} consecutive probes)"
            fi
        fi
    fi

    # Deliberately not 'elif': a fresh UP → PENDING transition falls through
    # and is corroborated immediately.
    if [ "$state" = "PENDING" ]; then
        if [ "$primary_ok" -eq 1 ]; then
            success_count=$((success_count + 1))
            if [ "$success_count" -ge "$RECOVER_THRESHOLD" ]; then
                if [ "$suppressed" -eq 1 ]; then
                    log "SUPPRESSION CLEARED  AdGuard recovered before failover was needed"
                    suppressed=0
                fi
                state="UP"
                fail_count=0
                success_count=0
                log "state: PENDING → UP (AdGuard recovered without failover)"
            fi
        else
            success_count=0
            if probe_corroborate; then
                if [ "$suppressed" -eq 1 ]; then
                    log "SUPPRESSION CLEARED  upstream reachable again (${CORROBORATE_RCODE}); engaging failover"
                    suppressed=0
                fi
                if engage_failover; then
                    state="FAILED_OVER"
                    fail_count=0
                fi
            else
                if [ "$suppressed" -eq 0 ]; then
                    log "SUPPRESSED  AdGuard is down (${PRIMARY_RCODE}) but the UDM's own resolver also failed (${CORROBORATE_RCODE}). This is an internet outage, not an AdGuard outage — failover would not help. Holding."
                    suppressed=1
                fi
            fi
        fi

    elif [ "$state" = "FAILED_OVER" ]; then
        if [ "$primary_ok" -eq 1 ]; then
            success_count=$((success_count + 1))
            if [ "$success_count" -ge "$RECOVER_THRESHOLD" ]; then
                disengage_failover
                state="UP"
                fail_count=0
                success_count=0
                selfheal_active=0
                log "state: FAILED_OVER → UP"
            fi
        else
            success_count=0
        fi

        # Guarded on the state AFTER the recovery check, not before it: an
        # iteration that just disengaged must not re-add the address it removed.
        if [ "$state" = "FAILED_OVER" ]; then
            reassert_failover || true
        fi
    fi

    # Backgrounded sleep + wait, rather than a plain sleep: bash defers trap
    # handlers until the current foreground command finishes, so a plain sleep
    # would delay TERM handling — and therefore removal of the standby address
    # — by up to one INTERVAL during uninstall or shutdown.
    sleep "$INTERVAL" &
    wait $! 2>/dev/null || true
done
