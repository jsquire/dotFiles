#!/bin/bash
#
# test-normal.sh — NON-DISRUPTIVE. Asserts the steady state is actually the
# steady state: AdGuard serving, standby absent, daemon healthy, and — the
# part the retired suite never checked — that the daemon is not doing anything
# it should only do during an outage.
#
# Run from your workstation, on the LAN.

VERIFY_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$VERIFY_DIR/lib.sh"

require_udm

hdr "test-normal.sh — steady state"

# ------------------------------------------------------------------
# AdGuard is serving
# ------------------------------------------------------------------

hdr "Primary resolver"

rcode="$(rcode_of "$ADGUARD_IP" "$PROBE_NAME" 3)"
assert_eq "AdGuard ${ADGUARD_IP} answers ${PROBE_NAME} with NOERROR" "NOERROR" "$rcode"

# PROBE_NAME must not be filtered by AdGuard. A blocked name returns NXDOMAIN
# or a sinkhole address, which the daemon classifies as SUCCESS — so a filtered
# probe name would mean failover never fires, silently, forever.
sinkholed="$(dig @"$ADGUARD_IP" "$PROBE_NAME" A +short +time=3 +tries=1 2>/dev/null | grep -cE '^(0\.0\.0\.0|127\.0\.0\.1)$' || true)"
assert_eq "PROBE_NAME ${PROBE_NAME} is not sinkholed by AdGuard" "0" "$sinkholed"

# ------------------------------------------------------------------
# The standby is absent
# ------------------------------------------------------------------

hdr "Standby address (must NOT exist right now)"

refute "${FAILOVER_IP} is not bound on ${LAN_IF}" standby_bound

# The client-visible half of the same claim, and the one that actually matters:
# if the standby answers while AdGuard is healthy, resolvers that race or
# round-robin will use it and silently bypass AdGuard's filtering.
refute "${FAILOVER_IP} does not answer DNS from this workstation" standby_answers

refute "${FAILOVER_IP} does not answer ICMP" ping -c 2 -W 1 "$FAILOVER_IP"

# ------------------------------------------------------------------
# Daemon health
# ------------------------------------------------------------------

hdr "Daemon"

assert "supervisor PID file exists on the UDM" udm 'test -f /run/adguard-failover.pid'
assert "supervisor process is alive" udm 'kill -0 "$(cat /run/adguard-failover.pid 2>/dev/null)" 2>/dev/null'
assert "dns-failover.sh is running" daemon_running
assert "log file exists" udm "test -f '${LOG_FILE}'"

# The retired implementation was iptables-based. Any surviving DNAT rule is
# leftover state from it: inert, and confusing to whoever finds it next.
refute "no leftover DNAT rule for ${ADGUARD_IP}:53 in nat/PREROUTING" \
    udm "iptables -t nat -S PREROUTING 2>/dev/null | grep -q -- '-d ${ADGUARD_IP}/32 .*dport 53'"

# Stranded Tier 2 induction rules, in BOTH address families.
#
# This is the most consequential check in the file and the reason it belongs in
# the routine test rather than only in the Tier 2 preflight. A leftover rule
# makes the UDM permanently believe AdGuard is down, pinning the standby up —
# at which point clients have a reachable secondary resolver and may begin
# bypassing AdGuard entirely, with no symptom anyone would notice. Surfacing it
# on the next ordinary run is what stops it lurking indefinitely.
assert_no_leftovers

# ------------------------------------------------------------------
# Preflight gates, re-asserted
# ------------------------------------------------------------------
#
# These are not one-time. UniFi regenerates its DNS configuration on settings
# changes, firmware updates and WAN lease renewals, so a gate that passed at
# install time can be false today.

hdr "Standing gates"

assert "dnsmasq still configured bind-dynamic" \
    udm "grep -qE '^[[:space:]]*bind-dynamic[[:space:]]*\$' /run/dnsmasq.dns.conf.d/main.conf"

assert "dnsmasq still listening on ${LAN_IF}" \
    udm "grep -qE '^[[:space:]]*interface=${LAN_IF}[[:space:]]*\$' /run/dnsmasq.dns.conf.d/main.conf"

refute "UDM's own upstream does not list ${ADGUARD_IP}" \
    udm "awk -v ip='${ADGUARD_IP}' '\$1==\"nameserver\" && \$2==ip {f=1} END{exit !f}' '${RESOLV_FILE}'"

# The match MUST be address-anchored. A plain grep for 192.168.1.2 also matches
# 192.168.1.20, .254 and .255 — and the dhcp-range ceiling on a /24 is almost
# always .254, so the unanchored form reports a reservation on every real
# network. See install.sh's gate for the full account. test-hardening.sh has a
# static check that no unanchored form comes back anywhere in the tree.
FAILOVER_IP_RE="${FAILOVER_IP//./\\.}"
DHCP_CLAIM_RE="(^|[^0-9.])${FAILOVER_IP_RE}([^0-9.]|\$)"

# `option:dns-server` lines are excluded: advertising the standby to clients is
# the intended DEPLOYED state, not a claim on the address. A claim is an
# ASSIGNMENT to a host. Excluded by LINE, not by file, so a reservation sitting
# in a config that also advertises the standby is still caught.
refute "no host claims ${FAILOVER_IP}" \
    udm "grep -rEns -- '$DHCP_CLAIM_RE' /run/dnsmasq.dhcp.conf.d/ 2>/dev/null | grep -v 'option:dns-server' | grep -q ."

# STANDBY_IN_DHCP decides whether every Tier 2 run treats binding the standby as
# client-visible — whether it demands a maintenance window, caps engaged time
# and reports it. A stale value silently changes the safety posture of the whole
# suite, so it is checked against the device rather than trusted.
if udm "grep -rhEs -- '$DHCP_CLAIM_RE' /run/dnsmasq.dhcp.conf.d/ 2>/dev/null | grep -q 'option:dns-server'"; then
    if [ "$STANDBY_IN_DHCP" = "yes" ]; then
        _pass "${FAILOVER_IP} is advertised to clients, and STANDBY_IN_DHCP agrees"
    else
        _fail "${FAILOVER_IP} IS advertised to clients but STANDBY_IN_DHCP=\"$STANDBY_IN_DHCP\""
        note "Tier 2 is treating exposure as invisible when it is not. Set STANDBY_IN_DHCP=\"yes\" in scripts/config.env."
    fi
elif [ "$STANDBY_IN_DHCP" = "yes" ]; then
    _fail "STANDBY_IN_DHCP=\"yes\" but ${FAILOVER_IP} is NOT advertised in DHCP"
    note "either the DHCP change was reverted, or the flag is stale"
else
    _pass "${FAILOVER_IP} is not advertised to clients, and STANDBY_IN_DHCP agrees"
fi

assert "corroboration target ${CORROBORATE_SERVER} answers on the UDM" \
    udm "dig @${CORROBORATE_SERVER} example.com A +tries=1 +time=3 2>/dev/null | grep -q -- '->>HEADER<<-'"

# ------------------------------------------------------------------
# Corroboration schedule
# ------------------------------------------------------------------
#
# The corroborating probe must run ONLY in the PENDING state. An implementation
# that probes upstream every iteration would still fail over correctly, so no
# behavioural test would catch it — but it would leak a continuous trickle of
# random-label lookups off the network, and it would mean the state machine is
# not doing what the docs say. This is the check that catches it.
#
# Random labels are hex strings under CORROBORATE_ZONE, so they are trivially
# distinguishable from ordinary traffic.

hdr "Corroboration schedule (must be silent while UP)"

window=$(( INTERVAL * 3 + 5 ))
zone_re="${CORROBORATE_ZONE//./\\.}"

if udm 'command -v tcpdump >/dev/null 2>&1'; then
    info "sampling loopback DNS traffic on the UDM for ${window}s (3+ daemon iterations)"
    captured="$(udm "timeout ${window} tcpdump -l -ni lo -c 200 port 53 2>/dev/null || true")"
    hits="$(printf '%s\n' "$captured" | grep -cE "x[0-9a-f]{16}\.${zone_re}" || true)"
    assert_eq "zero random-label corroboration queries observed while AdGuard is healthy" "0" "$hits"
    if [ "$hits" != "0" ]; then
        note "The daemon is corroborating outside the PENDING state."
        printf '%s\n' "$captured" | grep -E "x[0-9a-f]{16}" | head -3 | sed 's/^/        /'
    fi
else
    _skip "corroboration schedule (tcpdump not available on the UDM)"
fi

# ------------------------------------------------------------------
# Log sanity
# ------------------------------------------------------------------
#
# Edge-triggered logging means a healthy daemon is nearly silent. A steady
# state that produces continuous output is itself a defect: it buries the
# transitions that matter under thousands of identical lines.

hdr "Log volume (edge-triggered logging should be quiet)"

before="$(daemon_log_lines)"
info "watching the log for ${window}s"
sleep "$window"
after="$(daemon_log_lines)"
added=$(( after - before ))

if [ "$added" -eq 0 ]; then
    _pass "log grew by 0 lines over ${window}s while healthy"
else
    _fail "log grew by ${added} lines over ${window}s while healthy — logging is not edge-triggered"
    daemon_log_since "$before" | head -5 | sed 's/^/        /'
fi

# ------------------------------------------------------------------
# Attribution
# ------------------------------------------------------------------

hdr "AdGuard attribution (manual)"
info "Open the AdGuard Home query log. The lookups above for ${PROBE_NAME}"
info "should appear sourced from this workstation's own LAN IP, not the UDM's."
info "If they show the UDM's address, something has put the UDM in the path."

summary
