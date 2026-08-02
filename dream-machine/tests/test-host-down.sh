#!/bin/bash
#
# test-host-down.sh — Tier 2: AdGuard host entirely absent.
#
# Simulates the host-down failure mode by blocking ALL traffic from the UDM to
# the AdGuard address — not just DNS. From the UDM's point of view the host has
# vanished: no ICMP, no SSH, no DNS. Nothing is rebooted; the rule is a
# reversible entry in the UDM's own OUTPUT chain and no client is affected.
#
# Why this is a separate scenario from test-failover.sh:
#
# It is NOT because the two produce different RCODEs. They do not. A REJECTed
# query and a DROPped query both fail to produce a ->>HEADER<<- line, so both
# classify as TIMEOUT — verified against real dig output. Assuming otherwise
# would be exactly the kind of unexamined premise that made the retired design
# fail.
#
# The real differences are:
#
#   1. The wire behaviour. A DROP produces genuine silence, so the probe
#      consumes the full PROBE_TIMEOUT rather than failing instantly. Detection
#      is measurably slower, and the documented worst case includes that term.
#   2. The reachability premise. Here the address is wholly gone from the UDM's
#      view, which is the condition under which the previous design's
#      impersonation approach would have been most tempting and most harmful.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

hdr "Tier 2 — AdGuard host entirely unreachable"

t2_preflight

require_window "Blocks ALL traffic from the UDM to ${ADGUARD_IP}, waits for failover, then restores."

t2_init
_t2_start_watchdog

# ------------------------------------------------------------------
hdr "Baseline"
# ------------------------------------------------------------------

assert "AdGuard answers from this workstation" adguard_answers
assert "UDM can reach the AdGuard host" udm_can_reach_adguard
refute "standby ${FAILOVER_IP} does not answer yet" standby_answers

log_mark="$(daemon_log_lines)"

# ------------------------------------------------------------------
hdr "Induce: the host disappears from the UDM's view"
# ------------------------------------------------------------------

induce_rule iptables "-d ${ADGUARD_IP}" "DROP" || exit 1

# The premise of this scenario, asserted rather than assumed.
refute "AdGuard host is now unreachable from the UDM" udm_can_reach_adguard

# Blast-radius check: the host is only gone from the UDM. A real client must
# still see it, healthy and answering.
assert "AdGuard still answers this workstation (host is genuinely still up)" \
    adguard_answers

# ------------------------------------------------------------------
hdr "Failover engages on silence"
# ------------------------------------------------------------------

started="$(date +%s)"
if wait_for "$ENGAGE_DEADLINE" "standby ${FAILOVER_IP} bound on ${LAN_IF}" standby_bound; then
    mark_engaged
fi
info "detection budget was ${DETECT_SECS}s; silence costs a full PROBE_TIMEOUT (${PROBE_TIMEOUT}s) per probe"

wait_for "$INTERVAL" "standby answers DNS from this workstation" standby_answers
assert "standby resolves a name it cannot have cached" standby_resolves_fresh

info "engage-to-answering took $(( $(date +%s) - started ))s end to end"

# ------------------------------------------------------------------
hdr "AdGuard is never impersonated"
# ------------------------------------------------------------------
#
# Most important here of all the scenarios: with the address absent from the
# UDM's view, binding it would look harmless and would be catastrophic the
# moment the host returned.

assert "no UDM interface has claimed ${ADGUARD_IP}" adguard_ip_unbound_on_udm

# ------------------------------------------------------------------
hdr "Daemon log"
# ------------------------------------------------------------------

daemon_log_settle
log_new="$(daemon_log_since "$log_mark")"
if printf '%s' "$log_new" | grep -qF 'FAILOVER ENGAGED'; then
    _pass "daemon logged FAILOVER ENGAGED"
else
    _fail "daemon did not log FAILOVER ENGAGED"
    note "$log_new"
fi
if printf '%s' "$log_new" | grep -qE 'returned TIMEOUT'; then
    _pass "daemon classified the silence as TIMEOUT"
else
    _fail "daemon did not record a TIMEOUT probe result"
    note "$log_new"
fi

# ------------------------------------------------------------------
hdr "Restore and recover"
# ------------------------------------------------------------------

remove_induction
assert "UDM can reach the AdGuard host again" udm_can_reach_adguard

if wait_for_false "$RECOVER_DEADLINE" "standby ${FAILOVER_IP} withdrawn" standby_bound; then
    mark_disengaged
fi
refute "standby no longer answers" standby_answers
assert "AdGuard answers from this workstation" adguard_answers

summary
