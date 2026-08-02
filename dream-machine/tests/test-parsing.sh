#!/bin/bash
#
# test-parsing.sh — NON-DISRUPTIVE, offline. Asserts the dig parsing contract
# and the RCODE classification table.
#
# Why this test exists: when failover fires is decided entirely by how one line
# of dig output is parsed. That makes it the highest-leverage line in the
# project and the easiest to "tidy up" into something subtly different. A
# future refactor that changes classification should fail here loudly rather
# than silently change the conditions under which the network fails over.
#
# The retired daemon used `[ $? -eq 0 ] && [ -n "$out" ]`, which conflates
# SERVFAIL with success and an empty answer section with failure. Both
# confusions are asserted against below.
#
# Fixtures, not live queries: some RCODEs (REFUSED especially) cannot be
# produced on demand from a working network, and a test that depends on what
# the internet returns today is not a test.

VERIFY_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$VERIFY_DIR/lib.sh"

hdr "test-parsing.sh — dig parsing contract"

# ------------------------------------------------------------------
# The contract, restated
# ------------------------------------------------------------------
#
#   1. Select the line containing '->>HEADER<<-'.
#   2. Extract the token following 'status: ', up to the next comma. That
#      value is the RCODE and the SOLE input to classification.
#   3. If no such line exists, the result is TIMEOUT.
#
# NOT part of the contract: dig's exit status, +short output, emptiness of the
# answer section.

fixture_header() {
    cat <<EOF
; <<>> DiG 9.20.24 <<>> @$2 $3 A +tries=1 +time=2
; (1 server found)
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: $1, id: 21836
;; flags: qr rd ra; QUERY: 1, ANSWER: $4, AUTHORITY: 1, ADDITIONAL: 1

;; QUESTION SECTION:
;$3.			IN	A

;; Query time: 12 msec
EOF
}

fixture_timeout() {
    cat <<'EOF'
; <<>> DiG 9.20.24 <<>> @192.0.2.1 example.com A +tries=1 +time=2
; (1 server found)
;; global options: +cmd
;; connection timed out; no servers could be reached
EOF
}

# ------------------------------------------------------------------
# Extraction
# ------------------------------------------------------------------

hdr "RCODE extraction"

for code in NOERROR NXDOMAIN SERVFAIL REFUSED NOTIMP FORMERR; do
    assert_eq "extracts ${code} from the header line" \
        "$code" "$(parse_rcode "$(fixture_header "$code" 9.9.9.9 example.com 1)")"
done

assert_eq "no header line classifies as TIMEOUT" \
    "TIMEOUT" "$(parse_rcode "$(fixture_timeout)")"

assert_eq "completely empty output classifies as TIMEOUT" \
    "TIMEOUT" "$(parse_rcode "")"

# ------------------------------------------------------------------
# Classification
# ------------------------------------------------------------------

hdr "Classification table"

# NOERROR and NXDOMAIN are success. Both prove the resolver processed the
# query and the resolution chain worked end to end.
assert "NOERROR classifies as success" rcode_is_ok NOERROR
assert "NXDOMAIN classifies as success" rcode_is_ok NXDOMAIN

# SERVFAIL and REFUSED are failures. RFC 1035 makes them valid responses, but
# from the user's perspective DNS is broken, and that is the perspective that
# decides whether failover should help. Treating SERVFAIL as "up" would leave
# clients dead while the daemon reported everything fine.
refute "SERVFAIL classifies as FAILURE" rcode_is_ok SERVFAIL
refute "REFUSED classifies as FAILURE" rcode_is_ok REFUSED
refute "TIMEOUT classifies as FAILURE" rcode_is_ok TIMEOUT

# Anything unrecognised must fail closed rather than read as healthy.
refute "unknown RCODE classifies as FAILURE" rcode_is_ok NOTIMP
refute "empty string classifies as FAILURE" rcode_is_ok ""

# ------------------------------------------------------------------
# The specific confusions being designed out
# ------------------------------------------------------------------

hdr "Anti-patterns the contract exists to prevent"

# A SERVFAIL response has ANSWER: 0 but IS a response. Exit-status-based
# checks and answer-section-emptiness checks both get this wrong in the
# direction that matters: they can report AdGuard as up while it serves
# nothing.
servfail_out="$(fixture_header SERVFAIL 192.168.1.99 dns.quad9.net 0)"
assert_eq "SERVFAIL with an empty answer section is still parsed as SERVFAIL" \
    "SERVFAIL" "$(parse_rcode "$servfail_out")"
refute "...and is therefore classified as failure" rcode_is_ok "$(parse_rcode "$servfail_out")"

# NOERROR with ANSWER: 0 (NODATA, or a referral) is a working resolver. An
# emptiness check would call this a failure and fail over for no reason.
# Measured note: <random>.example.com returns exactly this — NOERROR with
# ANSWER: 0 — not NXDOMAIN, which is why both are accepted as success.
nodata_out="$(fixture_header NOERROR 127.0.0.1 x0123456789abcdef.example.com 0)"
assert_eq "NOERROR with an empty answer section is still parsed as NOERROR" \
    "NOERROR" "$(parse_rcode "$nodata_out")"
assert "...and is therefore classified as success" rcode_is_ok "$(parse_rcode "$nodata_out")"

# ------------------------------------------------------------------
# Live sanity check
# ------------------------------------------------------------------
#
# Fixtures prove the parser. This proves the fixtures still resemble reality —
# that a dig upgrade has not changed the header format out from under us.

hdr "Live format check (requires internet)"

live="$(dig @9.9.9.9 dns.quad9.net A +tries=1 +time=3 2>/dev/null)"
if printf '%s\n' "$live" | grep -q -- '->>HEADER<<-'; then
    _pass "real dig output still contains a '->>HEADER<<-' line"
    assert_eq "real dig output parses to NOERROR" "NOERROR" "$(parse_rcode "$live")"
else
    _skip "live format check (no response from 9.9.9.9)"
fi

# The corroborating probe's expected result, verified against reality rather
# than assumed. Either NOERROR or NXDOMAIN is fine; both require the full
# recursion chain to have worked, which is the entire point of the probe.
corr_live="$(dig @9.9.9.9 "$(random_label).${CORROBORATE_ZONE}" A +tries=1 +time=3 2>/dev/null)"
corr_rcode="$(parse_rcode "$corr_live")"
case "$corr_rcode" in
    NOERROR|NXDOMAIN)
        _pass "random label under ${CORROBORATE_ZONE} yields ${corr_rcode} (a success code)"
        ;;
    TIMEOUT)
        _skip "corroboration zone check (no internet)"
        ;;
    *)
        _fail "random label under ${CORROBORATE_ZONE} yields ${corr_rcode}, which the daemon classifies as FAILURE"
        note "Corroboration would never succeed, so failover would be permanently suppressed."
        note "Pick a different CORROBORATE_ZONE."
        ;;
esac

summary
