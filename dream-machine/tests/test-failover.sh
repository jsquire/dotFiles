#!/bin/bash
#
# test-failover.sh — Tier 2: AdGuard service down, host still up.
#
# Simulates the container-down failure mode by REJECTing the UDM's own DNS
# queries to AdGuard. Nothing is stopped, rebooted or reconfigured on the
# AdGuard host, and no client loses access to it — the rule lives in the UDM's
# OUTPUT chain, which forwarded client traffic never traverses.
#
# What this proves that the offline harness cannot:
#
#   * the daemon really binds FAILOVER_IP to the LAN bridge
#   * dnsmasq, running with bind-dynamic, really picks the address up via
#     netlink without being restarted or reconfigured
#   * a real client on the LAN really gets answers from it
#
# That chain is the design's single hard gate and it has no fallback.
#
# Induction is udp/53 ONLY, so the AdGuard host stays fully reachable from the
# UDM. That is the point of this scenario as distinct from test-host-down.sh.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

hdr "Tier 2 — AdGuard DNS service down, host up"

t2_preflight

require_window "Blocks the UDM's DNS queries to ${ADGUARD_IP} (udp/53 only), waits for failover, then restores."

t2_init
_t2_start_watchdog

# ------------------------------------------------------------------
hdr "Baseline"
# ------------------------------------------------------------------

assert "AdGuard answers from this workstation" adguard_answers
refute "standby ${FAILOVER_IP} does not answer yet" standby_answers
assert "UDM can reach the AdGuard host" udm_can_reach_adguard

log_mark="$(daemon_log_lines)"

# ------------------------------------------------------------------
hdr "Induce: AdGuard stops serving DNS to the UDM"
# ------------------------------------------------------------------

induce_rule iptables "-d ${ADGUARD_IP} -p udp --dport 53" \
    "REJECT --reject-with icmp-port-unreachable" || exit 1
induce_rule iptables "-d ${ADGUARD_IP} -p tcp --dport 53" \
    "REJECT --reject-with icmp-port-unreachable" || exit 1

# The premise of this scenario, asserted rather than assumed: the host is still
# up. If this fails the test has silently become test-host-down.sh.
assert "AdGuard host is still reachable from the UDM (service down, host up)" \
    udm_can_reach_adguard

# Blast-radius check. The induction is UDM-local, so a real client must be
# entirely unaffected and AdGuard must keep answering it normally.
assert "AdGuard still answers this workstation (induction did not leave the UDM)" \
    adguard_answers

# ------------------------------------------------------------------
hdr "Failover engages"
# ------------------------------------------------------------------

started="$(date +%s)"
if wait_for "$ENGAGE_DEADLINE" "standby ${FAILOVER_IP} bound on ${LAN_IF}" standby_bound; then
    mark_engaged
fi
info "detection budget was ${DETECT_SECS}s (INTERVAL x FAIL_THRESHOLD + PROBE_TIMEOUT)"

# The assertion that actually matters: not that the address exists, but that a
# client gets an answer from it. The retired suite checked the former.
wait_for "$INTERVAL" "standby answers DNS from this workstation" standby_answers

assert "standby resolves a name it cannot have cached" standby_resolves_fresh

info "engage-to-answering took $(( $(date +%s) - started ))s end to end"

# ------------------------------------------------------------------
hdr "AdGuard is never impersonated"
# ------------------------------------------------------------------
#
# The previous design impersonated ADGUARD_IP on the UDM, which severed SSH to
# the AdGuard host at exactly the moment an operator needed it. This is a
# standing regression check, asserted directly rather than inferred.

assert "no UDM interface has claimed ${ADGUARD_IP}" adguard_ip_unbound_on_udm

if [ -n "$ADGUARD_SSH_USER" ]; then
    assert "AdGuard host still administrable over SSH" adguard_host_reachable
else
    _skip "SSH check (ADGUARD_SSH_USER not set)"
fi

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
if printf '%s' "$log_new" | grep -qF 'SUPPRESSED'; then
    _fail "failover was SUPPRESSED — the UDM's own resolver is also failing"
    note "the corroborating path is broken; this test cannot conclude anything"
else
    _pass "failover was not suppressed (UDM upstream healthy, as expected)"
fi

# ------------------------------------------------------------------
hdr "Self-heal — an externally removed standby is restored"
# ------------------------------------------------------------------
#
# The daemon bound the address once, on the UP → FAILED_OVER edge, and never
# looked at it again. Anything that rewrites br0 takes it away, and on this
# device firmware updates are automatic and unattended — so "an AdGuard outage
# overlapping a bridge rewrite" is a scheduled event, not a freak one. Without
# the self-heal, clients spend the rest of the outage with no fallback and the
# log never mentions it: nothing reports the disappearance, and disengage
# returns early when the address is already gone, so recovery logs
# "FAILED_OVER → UP" and the episode reads as clean.
#
# Induction stays in place here, so the daemon is genuinely still FAILED_OVER
# rather than merely being raced into re-adding during recovery. This removal
# is the same operation the external agent would perform, so it changes only
# the UDM's own view of the world.

selfheal_mark="$(daemon_log_lines)"

if udm "ip addr del '${FAILOVER_IP}/32' dev '${LAN_IF}'" </dev/null >/dev/null 2>&1; then
    _pass "standby externally removed while failover was engaged"

    # Must not already be back: that would mean the removal never took effect
    # and the restore assertion below would pass without proving anything.
    if standby_bound; then
        _fail "standby still bound immediately after removal — removal did not take"
    else
        _pass "standby is genuinely gone before the daemon reacts"
    fi

    if wait_for "$ENGAGE_DEADLINE" "standby ${FAILOVER_IP} restored by the daemon" standby_bound; then
        assert "restored standby resolves a name it cannot have cached" standby_resolves_fresh
    fi

    daemon_log_settle
    selfheal_log="$(daemon_log_since "$selfheal_mark")"
    if printf '%s' "$selfheal_log" | grep -qF 'SELF-HEAL'; then
        _pass "daemon logged the disappearance and the repair"
    else
        _fail "daemon restored the address without saying so, or not at all"
        note "$selfheal_log"
    fi
else
    _fail "could not remove the standby to induce the self-heal"
fi

# ------------------------------------------------------------------
hdr "Restore and recover"
# ------------------------------------------------------------------

remove_induction
assert "AdGuard reachable from the UDM again" adguard_answers

if wait_for_false "$RECOVER_DEADLINE" "standby ${FAILOVER_IP} withdrawn" standby_bound; then
    mark_disengaged
fi
refute "standby no longer answers" standby_answers
assert "AdGuard answers from this workstation" adguard_answers

summary
