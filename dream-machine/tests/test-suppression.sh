#!/bin/bash
#
# test-suppression.sh — Tier 2: AdGuard down DURING a WAN outage.
#
# Failing over is only useful if the UDM can actually resolve. During a genuine
# internet outage the standby would answer nothing, so engaging it would swap a
# filtered dead resolver for an unfiltered dead one — and, worse, would leave
# clients pointed at a resolver that bypasses AdGuard once connectivity
# returned but before the daemon noticed.
#
# The daemon therefore corroborates before engaging. This test asserts that it
# holds during the outage, and engages promptly once the outage clears.
#
# Everything is induced UDM-locally. The WAN link is not touched; the rules are
# OUTPUT-scoped, so forwarded client traffic — including AdGuard's own upstream
# queries — is unaffected and clients keep resolving normally throughout.
#
# ------------------------------------------------------------------------
# The validity of this entire test rests on upstream enumeration being
# COMPLETE. dnsmasq runs with `all-servers`, so it queries every upstream in
# parallel; a single unblocked resolver means corroboration succeeds, failover
# engages, and the test reports a failure that is really an enumeration bug.
# Worse, the inverse error is silent: a test that never induced the condition
# it claims to test will pass.
#
# Hence the precondition gate below, which aborts loudly rather than concluding
# anything from an un-induced state.
# ------------------------------------------------------------------------

set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

hdr "Tier 2 — failover suppressed during a WAN outage"

t2_preflight

require_window "Blocks the UDM's DNS to ${ADGUARD_IP} and to every upstream resolver, then restores."

t2_init
_t2_start_watchdog

# ------------------------------------------------------------------
hdr "Enumerate upstreams"
# ------------------------------------------------------------------

mapfile -t UPSTREAMS < <(enumerate_upstreams)

if [ "${#UPSTREAMS[@]}" -eq 0 ]; then
    echo "ERROR: no upstream resolvers found in ${RESOLV_FILE} or ${DNSMASQ_CONF_DIR}." >&2
    echo "       Cannot induce a WAN outage without knowing what to block." >&2
    exit 2
fi

v4=0; v6=0
for u in "${UPSTREAMS[@]}"; do
    if [ "$(upstream_family "$u")" = "inet6" ]; then
        v6=$((v6 + 1)); info "upstream (inet6): $u"
    else
        v4=$((v4 + 1)); info "upstream (inet):  $u"
    fi
done
info "enumerated ${#UPSTREAMS[@]} upstream(s): ${v4} IPv4, ${v6} IPv6"

# Non-53 ports mean a --dport 53 rule would miss the path entirely.
nonstd="$(enumerate_nonstandard_transports)"
if [ -n "$nonstd" ]; then
    echo "ERROR: upstreams configured on non-standard ports:" >&2
    printf '  %s\n' "$nonstd" >&2
    echo "       A --dport 53 rule would not block these, and the test would" >&2
    echo "       silently fail to induce the condition it claims to test." >&2
    exit 2
fi

if [ "$v6" -gt 0 ]; then
    if ! udm 'command -v ip6tables >/dev/null 2>&1'; then
        echo "ERROR: ${v6} IPv6 upstream(s) are configured but ip6tables is unavailable." >&2
        echo "       Blocking IPv4 only would leave dnsmasq a working path and produce" >&2
        echo "       exactly the false confidence this gate exists to prevent." >&2
        exit 2
    fi
fi

log_mark="$(daemon_log_lines)"

# ------------------------------------------------------------------
hdr "Induce: AdGuard down AND the UDM cannot resolve"
# ------------------------------------------------------------------

induce_rule iptables "-d ${ADGUARD_IP}" "DROP" || exit 1

for u in "${UPSTREAMS[@]}"; do
    if [ "$(upstream_family "$u")" = "inet6" ]; then
        induce_rule ip6tables "-d ${u} -p udp --dport 53" "DROP" || exit 1
        induce_rule ip6tables "-d ${u} -p tcp --dport 53" "DROP" || exit 1
    else
        induce_rule iptables "-d ${u} -p udp --dport 53" "DROP" || exit 1
        induce_rule iptables "-d ${u} -p tcp --dport 53" "DROP" || exit 1
    fi
done

# ------------------------------------------------------------------
hdr "Precondition: the corroborating path really is broken"
# ------------------------------------------------------------------
#
# Asserted BEFORE any test logic runs. Without this gate, an incomplete
# enumeration produces a test that silently never induced its own premise.

pre_rcode="$(corroborate_rcode_from_udm)"
if rcode_is_ok "$pre_rcode"; then
    printf '\n\033[1;31mPRECONDITION FAILED\033[0m\n' >&2
    printf 'The corroborating probe still SUCCEEDS (%s) with every enumerated\n' "$pre_rcode" >&2
    printf 'upstream blocked. The WAN-outage condition was never induced, so no\n' >&2
    printf 'conclusion drawn from this run would be valid.\n\n' >&2
    printf 'Enumerated upstreams (%s):\n' "${#UPSTREAMS[@]}" >&2
    printf '  %s\n' "${UPSTREAMS[@]}" >&2
    printf '\nRules installed:\n' >&2
    udm "iptables-save 2>/dev/null | grep -F -- '${INDUCE_TAG}'; ip6tables-save 2>/dev/null | grep -F -- '${INDUCE_TAG}'" >&2
    printf '\nLikely causes, in order:\n' >&2
    printf '  1. an upstream that appears in neither %s nor %s\n' "$RESOLV_FILE" "$DNSMASQ_CONF_DIR" >&2
    printf '  2. an upstream reached over a non-53 transport (DoT/DoH)\n' >&2
    printf '  3. a stale cache entry — should be impossible, the probe label is random\n' >&2
    printf '\nAborting without drawing a conclusion.\n\n' >&2
    exit 2
fi
_pass "corroborating probe fails as required (${pre_rcode})"

# Blast radius: clients still reach AdGuard normally throughout.
assert "AdGuard still answers this workstation (clients unaffected)" adguard_answers

# ------------------------------------------------------------------
hdr "Failover must NOT engage"
# ------------------------------------------------------------------

hold_window=$(( DETECT_SECS + INTERVAL * 2 ))
stays_false "$hold_window" "standby stayed unbound while the WAN was down" standby_bound

daemon_log_settle
log_new="$(daemon_log_since "$log_mark")"
if printf '%s' "$log_new" | grep -qF 'SUPPRESSED'; then
    _pass "daemon logged SUPPRESSED with a distinct explanation"
else
    _fail "daemon did not log SUPPRESSED"
    note "$log_new"
fi

# Edge-triggered: one line for the episode, not one per iteration.
sup_lines="$(printf '%s' "$log_new" | grep -cF 'SUPPRESSED  AdGuard is down' || true)"
assert_eq "SUPPRESSED logged exactly once for the episode" "1" "$sup_lines"

if printf '%s' "$log_new" | grep -qF 'FAILOVER ENGAGED'; then
    _fail "failover engaged during a WAN outage — corroboration did not hold"
else
    _pass "failover did not engage"
fi

# ------------------------------------------------------------------
hdr "WAN recovers — failover engages within one INTERVAL"
# ------------------------------------------------------------------
#
# PENDING re-corroborates on every iteration and does not re-accumulate a
# failure threshold, so engagement follows upstream recovery immediately. An
# implementation that required a fresh FAIL_THRESHOLD run would take
# FAIL_THRESHOLD x INTERVAL longer, which this deadline is tight enough to
# catch.

# Remove ONLY the upstream blocks; AdGuard stays down.
adguard_rule="OUTPUT -d ${ADGUARD_IP} -m comment --comment ${INDUCE_TAG} -j DROP"
for u in "${UPSTREAMS[@]}"; do
    if [ "$(upstream_family "$u")" = "inet6" ]; then
        udm "ip6tables -D OUTPUT -d ${u} -p udp --dport 53 -m comment --comment ${INDUCE_TAG} -j DROP" >/dev/null 2>&1 || true
        udm "ip6tables -D OUTPUT -d ${u} -p tcp --dport 53 -m comment --comment ${INDUCE_TAG} -j DROP" >/dev/null 2>&1 || true
    else
        udm "iptables -D OUTPUT -d ${u} -p udp --dport 53 -m comment --comment ${INDUCE_TAG} -j DROP" >/dev/null 2>&1 || true
        udm "iptables -D OUTPUT -d ${u} -p tcp --dport 53 -m comment --comment ${INDUCE_TAG} -j DROP" >/dev/null 2>&1 || true
    fi
done
# Teardown must now only know about the AdGuard rule.
printf 'iptables\t%s\n' "$adguard_rule" >"$T2_STATE/rules"

post_rcode="$(corroborate_rcode_from_udm)"
if rcode_is_ok "$post_rcode"; then
    _pass "corroborating probe recovered (${post_rcode})"
else
    _fail "corroborating probe still failing (${post_rcode}) — upstream blocks not fully removed"
fi

engage_deadline=$(( INTERVAL * 2 + PROBE_TIMEOUT + 10 ))
if wait_for "$engage_deadline" "failover engaged promptly after the WAN returned" standby_bound; then
    mark_engaged
fi
info "budget was ${engage_deadline}s; a fresh FAIL_THRESHOLD cycle would have needed $(( DETECT_SECS + INTERVAL ))s"

log_new="$(daemon_log_since "$log_mark")"
if printf '%s' "$log_new" | grep -qF 'SUPPRESSION CLEARED'; then
    _pass "daemon logged SUPPRESSION CLEARED"
else
    _fail "daemon did not log SUPPRESSION CLEARED"
    note "$log_new"
fi

wait_for "$INTERVAL" "standby answers DNS from this workstation" standby_answers
assert "no UDM interface has claimed ${ADGUARD_IP}" adguard_ip_unbound_on_udm

# ------------------------------------------------------------------
hdr "Restore and recover"
# ------------------------------------------------------------------

remove_induction
if wait_for_false "$RECOVER_DEADLINE" "standby ${FAILOVER_IP} withdrawn" standby_bound; then
    mark_disengaged
fi
assert "AdGuard answers from this workstation" adguard_answers

summary
