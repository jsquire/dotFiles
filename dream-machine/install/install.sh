#!/bin/bash
#
# install.sh — deploy the AdGuard failover daemon to the UDM SE.
#
# Run this from your workstation, NOT on the UDM. It:
#   1. Reads config from ../scripts/config.env.
#   2. Verifies SSH reachability of the UDM.
#   3. Runs the Phase 1 preflight gates on the UDM and REFUSES TO INSTALL if
#      any of them fail. Several of these can invalidate the design outright,
#      so they are assertions, not warnings.
#   4. Ensures /data/on_boot.d runs at boot, by installing a vendored copy of
#      unifi-common's udm-boot.service if it is not already enabled.
#   5. Copies dns-failover.sh, boot-hook.sh, and config.env into place.
#   6. Launches the boot hook once to start the daemon without rebooting.
#   7. Tails the log to confirm a healthy start.
#   8. Prints follow-up instructions (UniFi DHCP DNS setting).
#
# With --preflight-only it stops after step 3, having written nothing to the
# UDM. See the argument parser below for why that is a flag here rather than a
# separate script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$REPO_DIR/scripts/config.env"

# ------------------------------------------------------------------
# Load config
# ------------------------------------------------------------------

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: $CONFIG_FILE not found." >&2
    echo "       Copy scripts/config.env.example → scripts/config.env" >&2
    echo "       and edit it for your environment first." >&2
    exit 1
fi

# shellcheck disable=SC1090
. "$CONFIG_FILE"

: "${UDM_HOST:?UDM_HOST must be set in config.env}"
: "${UDM_SSH_USER:?UDM_SSH_USER must be set in config.env}"
: "${ADGUARD_IP:?ADGUARD_IP must be set in config.env}"
: "${FAILOVER_IP:?FAILOVER_IP must be set in config.env}"
: "${LAN_IF:?LAN_IF must be set in config.env}"
: "${CORROBORATE_SERVER:=127.0.0.1}"
: "${RESOLV_FILE:=/run/resolv.conf.d/main}"
: "${LOG_FILE:=/data/adguard-failover/failover.log}"

DNSMASQ_CONF="/run/dnsmasq.dns.conf.d/main.conf"

SSH_TARGET="${UDM_SSH_USER}@${UDM_HOST}"
# StrictHostKeyChecking=ask, not accept-new. This installer copies scripts to a
# root shell on the router and executes them; silently trusting an unknown host
# key is the wrong default for that. In practice a `udm` entry already exists in
# ~/.ssh/config, so the key is long since known and this never prompts — which
# is precisely why accept-new bought nothing.
SSH_OPTS=(-o StrictHostKeyChecking=ask -o ConnectTimeout=5)

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
info() { printf '  \033[0;36mi\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

udm() { ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"; }

# ------------------------------------------------------------------
# Arguments
# ------------------------------------------------------------------
#
# --preflight-only runs SSH verification and the preflight gates, then exits 0
# without writing anything to the UDM.
#
# This is a flag on the installer rather than a separate preflight script, and
# that is deliberate. A standalone script would need its own copy of the gates,
# and the two copies would drift. The failure mode is quiet and bad in both
# directions: preflight passes while install fails on a gate preflight no longer
# has, or preflight enforces a gate the installer has since dropped. One
# implementation, two entry points, no possibility of disagreement.
#
# The gate that motivates this is the hard gate — dnsmasq auto-binding the
# standby address. It can void the whole design, and before this flag existed
# the only way to run it was to run the installer, which then installed. A gate
# you cannot consult without committing to its outcome is not a gate.

PREFLIGHT_ONLY=no

usage() {
    cat <<EOF
Usage: $(basename "$0") [--preflight-only]

  --preflight-only  Run the preflight gates and exit. Writes nothing to the
                    UDM. Exits 0 if every gate passes, non-zero otherwise.
  -h, --help        Show this message.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --preflight-only) PREFLIGHT_ONLY=yes ;;
        -h|--help)        usage; exit 0 ;;
        # Refused rather than ignored. A typo'd flag that is silently dropped
        # would run a full install when the operator asked for a dry run, which
        # is the single worst outcome this flag exists to prevent.
        *)                usage >&2; die "Unrecognised argument: $1" ;;
    esac
    shift
done

# ------------------------------------------------------------------
# Step 1: SSH reachability
# ------------------------------------------------------------------

say "Verifying SSH reachability to ${SSH_TARGET}"
if ! udm 'echo ok' >/dev/null 2>&1; then
    die "Cannot SSH to ${SSH_TARGET}. Enable SSH on the UDM (UniFi Network → Settings → Control Plane → Console) and try again."
fi
ok "SSH works"

# ------------------------------------------------------------------
# Step 2: Phase 1 preflight gates
# ------------------------------------------------------------------
#
# These run on every install, not once, because UniFi regenerates its DNS
# configuration on settings changes, firmware updates and WAN lease renewals.
# A gate that passed at first install can be false by the next one.

say "Running preflight gates on the UDM"

# --- Gate: dig is present -----------------------------------------
# RCODE parsing is not portable across drill/nslookup, so there is no
# fallback: absence of dig is an install failure, not a degradation.
if ! udm 'command -v dig >/dev/null 2>&1'; then
    die "GATE FAILED: dig is not installed on the UDM. The daemon classifies probe results by RCODE and has no fallback parser. Install dig (or a package providing it) and re-run."
fi
ok "gate: dig present"

# --- Gate: dnsmasq is bind-dynamic and listening on LAN_IF ---------
# Without bind-dynamic, dnsmasq will not notice the failover address being
# added and will never answer on it.
if ! udm "grep -qE '^[[:space:]]*bind-dynamic[[:space:]]*$' '$DNSMASQ_CONF'"; then
    die "GATE FAILED: ${DNSMASQ_CONF} does not contain 'bind-dynamic'. Without it dnsmasq will not pick up ${FAILOVER_IP} when the daemon binds it, and the design does not work."
fi
if ! udm "grep -qE '^[[:space:]]*interface=${LAN_IF}[[:space:]]*$' '$DNSMASQ_CONF'"; then
    die "GATE FAILED: ${DNSMASQ_CONF} does not list 'interface=${LAN_IF}'. dnsmasq will not serve DNS on an address bound to an interface it is not configured to listen on."
fi
ok "gate: dnsmasq is bind-dynamic and listening on ${LAN_IF}"

# --- Gate: the UDM's own upstream is not AdGuard -------------------
# If it were, the fallback would forward into the same dead resolver and the
# whole scheme is inert. Re-asserted here, re-checked every daemon iteration,
# and listed as a post-upgrade operational check in the docs.
if udm "awk -v ip='$ADGUARD_IP' '\$1==\"nameserver\" && \$2==ip {found=1} END{exit !found}' '$RESOLV_FILE'"; then
    die "GATE FAILED: ${RESOLV_FILE} lists ${ADGUARD_IP} as one of the UDM's own upstream resolvers. Failover would forward into the same dead resolver. Change the UDM's WAN/DNS setting in UniFi to a real upstream and re-run."
fi
ok "gate: UDM upstream does not point at ${ADGUARD_IP}"

# --- Gate: nothing claims FAILOVER_IP ------------------------------
# The DHCP pool floor rules out leases, but static reservations (dhcp-host)
# are not bounded by the pool.
#
# The match MUST be address-anchored, not a substring. A plain
# `grep -- '192.168.1.2'` also matches 192.168.1.20, 192.168.1.254 and
# 192.168.1.255 — and since the dhcp-range ceiling on a /24 is almost always
# .254, the unanchored form fired on every real network and the gate could
# never pass. Measured against this UDM: three matches, none of them the
# address. Dots are escaped so they cannot act as regex wildcards, and the
# address must be bounded on both sides by something that is neither a digit
# nor a dot, which is exactly how dnsmasq delimits addresses (`,` `=` `:`
# whitespace, or end of line).
FAILOVER_IP_RE="${FAILOVER_IP//./\\.}"
DHCP_CLAIM_RE="(^|[^0-9.])${FAILOVER_IP_RE}([^0-9.]|\$)"

# `option:dns-server` lines are excluded, because advertising FAILOVER_IP as a
# DHCP DNS server is the intended DEPLOYED state — that advertisement is the
# entire delivery mechanism for the standby. Counting it as a claim made the
# gate pass only until the design was finished and then block every reinstall
# from that point onward, which is exactly when being unable to reinstall costs
# the most. A claim is an ASSIGNMENT of the address to a host (dhcp-host, or
# the address appearing as a router/gateway/host value); being named as a
# resolver is not.
DHCP_CLAIM_SCAN="grep -rEns -- '$DHCP_CLAIM_RE' /run/dnsmasq.dhcp.conf.d/ 2>/dev/null | grep -v 'option:dns-server'"
if udm "$DHCP_CLAIM_SCAN | grep -q ." ; then
    # Show what actually claimed it, because "appears in the DHCP config" was
    # exactly the diagnostic that sent us chasing a reservation that did not exist.
    say "Matching lines:"
    udm "$DHCP_CLAIM_SCAN" || true
    die "GATE FAILED: ${FAILOVER_IP} is assigned to a host in the UDM's DHCP configuration, most likely as a static reservation. Pick a different FAILOVER_IP or remove the reservation."
fi

if udm "grep -rhEs -- '$DHCP_CLAIM_RE' /run/dnsmasq.dhcp.conf.d/ 2>/dev/null | grep -q 'option:dns-server'"; then
    STANDBY_ADVERTISED=yes
    ok "gate: no host claims ${FAILOVER_IP} (it is advertised to clients as a DNS server — the intended deployed state)"
else
    STANDBY_ADVERTISED=no
    ok "gate: no host claims ${FAILOVER_IP} (not yet advertised to clients via DHCP)"
fi

# --- Gate: FAILOVER_IP is silent right now -------------------------
# If something already answers on it, binding it would create the exact IP
# conflict this design exists to avoid.
if udm "ping -c 2 -W 1 '$FAILOVER_IP' >/dev/null 2>&1"; then
    die "GATE FAILED: ${FAILOVER_IP} answers ICMP, so something on the network already uses it. Binding it would cause an address conflict. Pick a different FAILOVER_IP."
fi
ok "gate: ${FAILOVER_IP} is unused"

# --- Gate: dnsmasq answers on the corroboration target -------------
# The corroborating probe depends entirely on this path being usable.
#
# Retried, because a single shot is too brittle here: UniFi restarts dnsmasq on
# every settings write, and this gate failed on a device where the path was
# perfectly healthy — the install simply landed inside the restart window
# opened by the DHCP change made moments earlier. Failing closed is right; a
# one-shot probe deciding it on the first millisecond is not. Three attempts
# still fail closed for a genuinely dead path, since a dnsmasq that is down
# stays down across all of them.
corroborate_ok=0
for _attempt in 1 2 3; do
    if udm "dig @'$CORROBORATE_SERVER' example.com A +tries=1 +time=3 2>/dev/null | grep -q -- '->>HEADER<<-'"; then
        corroborate_ok=1
        break
    fi
    sleep 3
done
if [ "$corroborate_ok" -eq 0 ]; then
    die "GATE FAILED: no DNS response from ${CORROBORATE_SERVER} on the UDM after 3 attempts. The corroborating probe targets this address and cannot work without it. Set CORROBORATE_SERVER to the LAN bridge address (e.g. the ${LAN_IF} address) and re-run."
fi
ok "gate: dnsmasq answers on ${CORROBORATE_SERVER}"

# --- HARD GATE: dnsmasq auto-binds the failover address ------------
# There is no fallback if this fails. bind-dynamic detects address changes via
# netlink; SIGHUP only clears the cache and reloads hosts/ethers/resolv, and
# neither re-reads the config nor re-enumerates interfaces, so it cannot
# rescue a failed bind. Restarting UniFi's dnsmasq is not an option we control.
#
# This is the only gate that mutates the UDM, so its cleanup is defended three
# ways:
#
#   1. A trap, so the address is removed on any ordinary exit path — including
#      the SSH session being hung up, which is the realistic failure here. The
#      network misbehaving is exactly when the connection drops, and exactly
#      when this gate is being run.
#   2. A watchdog, because a trap does not run under SIGKILL. It is scoped by a
#      token file so it can only ever remove an address this session bound: if
#      the trap already cleaned up, the token is gone and the watchdog is a
#      no-op. Without that scoping it could remove an address bound later by
#      the daemon for real reasons.
#   3. The manual remediation is printed BEFORE the bind, not after a failure,
#      so it is already on screen if the session dies mid-gate.
#
# The trap is deliberately installed *after* a successful add. If the add fails
# because something already holds the address, that address is not ours and
# must not be torn down on our way out.
HARD_GATE_WATCHDOG=15

say "Running HARD GATE: does dnsmasq auto-bind ${FAILOVER_IP}?"
info "Binding ${FAILOVER_IP} briefly. If this session dies mid-gate, remove it with:"
info "    ssh ${SSH_TARGET} \"ip addr del ${FAILOVER_IP}/32 dev ${LAN_IF}\""
gate_result="$(udm "
    set -e
    TOKEN=/run/adguard-failover.hardgate.\$\$
    cleanup() {
        ip addr del '${FAILOVER_IP}/32' dev '${LAN_IF}' 2>/dev/null || true
        rm -f \"\$TOKEN\"
    }
    ip addr add '${FAILOVER_IP}/32' dev '${LAN_IF}' 2>/dev/null || { echo 'ADD_FAILED'; exit 0; }
    trap cleanup EXIT HUP INT TERM
    : > \"\$TOKEN\"
    # stdio is detached so the watchdog cannot hold the SSH session open.
    (
        sleep ${HARD_GATE_WATCHDOG}
        [ -e \"\$TOKEN\" ] || exit 0
        ip addr del '${FAILOVER_IP}/32' dev '${LAN_IF}' 2>/dev/null || true
        rm -f \"\$TOKEN\"
    ) </dev/null >/dev/null 2>&1 &
    sleep 2
    if dig @'${FAILOVER_IP}' example.com A +tries=1 +time=3 2>/dev/null | grep -q -- '->>HEADER<<-'; then
        echo BOUND
    else
        echo NOT_BOUND
    fi
")"

case "$gate_result" in
    BOUND)
        ok "HARD GATE PASSED: dnsmasq answers on ${FAILOVER_IP} when bound"
        ;;
    ADD_FAILED)
        die "HARD GATE FAILED: could not add ${FAILOVER_IP}/32 to ${LAN_IF}."
        ;;
    *)
        die "HARD GATE FAILED: ${FAILOVER_IP} was bound to ${LAN_IF} but dnsmasq did not answer on it. There is no signal-based fallback — SIGHUP does not re-enumerate interfaces. STOP: this portion of the design must be reworked before installing."
        ;;
esac

# --- Advisory: IPv6 DNS --------------------------------------------
# Not a gate — if the UDM advertises itself as a DNS server over RA/DHCPv6,
# clients preferring IPv6 DNS are already bypassing AdGuard today, independent
# of this work. Worth knowing, but it does not block the install.
if udm "grep -rqsE '^[[:space:]]*(dhcp-option=option6:dns-server|enable-ra)' /run/dnsmasq.dhcp.conf.d/ 2>/dev/null"; then
    warn "The UDM appears to advertise IPv6 DNS. Clients preferring IPv6 DNS may bypass AdGuard entirely, independent of this failover scheme. Worth investigating separately."
fi

ok "All preflight gates passed"

# ------------------------------------------------------------------
# Preflight-only exit
# ------------------------------------------------------------------
#
# Everything above this line reads the UDM. The single exception is the hard
# gate, which binds the standby address for about two seconds and removes it
# again, defended by a trap and a watchdog.
#
# Everything below this line writes. So this is the boundary, and it is placed
# here rather than anywhere later on purpose: nothing between the gates and
# this point can deploy, because there is nothing between them.
if [ "$PREFLIGHT_ONLY" = "yes" ]; then
    echo
    ok "Preflight complete. Nothing was installed."
    info "The UDM is unchanged: the gates only read, and the hard gate's"
    info "temporary address has been removed."
    info ""
    info "Re-run without --preflight-only to install."
    exit 0
fi

# ------------------------------------------------------------------
# Step 3: Ensure the on-boot mechanism exists (idempotent)
# ------------------------------------------------------------------
#
# This previously ran:
#
#     curl -fsL https://raw.githubusercontent.com/.../HEAD/remote_install.sh | /bin/bash
#
# as root on the router, against an unpinned HEAD, with a second unpinned
# fetch inside it for the unit file. That is a supply-chain hole and an
# install-time network dependency, in exchange for one thing: writing
# /etc/systemd/system/udm-boot.service and enabling it.
#
# So we write it ourselves. install/udm-boot.service carries every directive
# from upstream at a recorded commit, unchanged — the only difference is an
# added comment header, and tests/test-hardening.sh asserts that offline by
# digest. The unit name is kept identical so that installing unifi-common later
# overwrites it with an equivalent file rather than creating a second unit that
# would run every hook in /data/on_boot.d twice.
#
# If the unit is already enabled — whether by unifi-common or by a previous run
# of this installer — it is left completely alone. Overwriting a working
# boot-time unit on someone else's router to gain nothing is not a trade worth
# making, and the hooks it runs may not all be ours.

say "Ensuring the on-boot mechanism is present (idempotent)"

# --- Provenance ----------------------------------------------------
#
# Record whether udm-boot.service and /data/on_boot.d existed BEFORE this
# installer ran, so uninstall can tell the operator whether removing them is
# safe. Without this, uninstall leaves both in place and nobody can say whether
# they predated us — and both answers are actionable in opposite directions:
#
#   * If they predated us, disabling udm-boot.service breaks whatever else
#     relies on /data/on_boot.d.
#   * If we created them, leaving them means the system is NOT back to its
#     prior state after an uninstall, which is the claim we want to be able to
#     make honestly.
#
# The marker deliberately lives outside /data/adguard-failover, which uninstall
# removes with `rm -rf`. A record of what to clean up that is destroyed by the
# cleanup is no record at all.
#
# It is written once and never overwritten. On a re-install the unit is already
# enabled — by our own first run — and re-recording it now would downgrade
# "we created this" to "it was already here", silently stranding it forever.
PROVENANCE_FILE="/data/.adguard-failover-provenance"

pre_unit="absent"
if udm 'systemctl is-enabled udm-boot.service >/dev/null 2>&1'; then
    pre_unit="present"
fi
pre_hookdir="absent"
if udm '[ -d /data/on_boot.d ]'; then
    pre_hookdir="present"
fi

if udm "[ -f '$PROVENANCE_FILE' ]"; then
    info "Provenance record already exists; preserving the original."
else
    udm "
        set -e
        mkdir -p /data
        cat > '$PROVENANCE_FILE' <<'PROV'
# Written by install.sh. Records what existed BEFORE the first install, so
# uninstall knows what it may safely remove. Do not edit by hand.
udm_boot_service_before_install=${pre_unit}
on_boot_d_before_install=${pre_hookdir}
PROV
        chmod 0644 '$PROVENANCE_FILE'
    "
    ok "Recorded pre-install state (udm-boot.service: ${pre_unit}, /data/on_boot.d: ${pre_hookdir})"
fi

if [ "$pre_unit" = "present" ]; then
    ok "udm-boot.service already enabled; leaving it untouched"
else
    info "udm-boot.service not present; installing the vendored unit"
    scp "${SSH_OPTS[@]}" \
        "$REPO_DIR/install/udm-boot.service" \
        "$SSH_TARGET":/etc/systemd/system/udm-boot.service
    udm '
        set -e
        mkdir -p /data/on_boot.d
        chmod 0644 /etc/systemd/system/udm-boot.service
        systemctl daemon-reload
        systemctl enable udm-boot.service
        systemctl start udm-boot.service
    '
    if udm 'systemctl is-enabled udm-boot.service >/dev/null 2>&1'; then
        ok "udm-boot.service installed and enabled"
    else
        die "udm-boot.service was written but is not enabled. Without it the daemon will not survive a reboot. Investigate before continuing."
    fi
fi

# ------------------------------------------------------------------
# Step 4: Deploy scripts + config
# ------------------------------------------------------------------

say "Creating /data directories on the UDM"
udm 'mkdir -p /data/adguard-failover /data/on_boot.d'
ok "Directories present"

say "Copying scripts and config to the UDM"
scp "${SSH_OPTS[@]}" \
    "$REPO_DIR/scripts/dns-failover.sh" \
    "$REPO_DIR/scripts/config.env" \
    "$SSH_TARGET":/data/adguard-failover/
scp "${SSH_OPTS[@]}" \
    "$REPO_DIR/scripts/boot-hook.sh" \
    "$SSH_TARGET":/data/on_boot.d/15-adguard-failover.sh
ok "Files deployed"

say "Setting executable bits"
udm '
    chmod +x /data/adguard-failover/dns-failover.sh
    chmod +x /data/on_boot.d/15-adguard-failover.sh
'
ok "Permissions set"

# ------------------------------------------------------------------
# Step 5: First launch (no reboot required)
# ------------------------------------------------------------------

# The PID in /run/adguard-failover.pid is verified against /proc/<pid>/cmdline
# before it is signalled. The file survives reboots but PIDs do not, so a stale
# file can name an unrelated process — and this runs as root on a router.
#
# The identity test is positional (argv[0] is our path, or argv[0] is a shell
# and argv[1] is our path), not a substring match over the command line, which
# would also match an editor or a `tail` open on the same file.
#
# The path checked is the *boot hook*, not the daemon: the supervisor is a
# backgrounded subshell of the hook and inherits the hook's argv, so its
# cmdline never mentions dns-failover.sh. Checking the daemon path here would
# silently match nothing and leave the old supervisor running alongside the new
# one. Kept identical in uninstall.sh — if you change one, change both.
say "Stopping any previous supervisor and starting fresh"
udm "
    HOOK_PATH=/data/on_boot.d/15-adguard-failover.sh
    is_ours() {
        [ -n \"\$1\" ] || return 1
        [ -r \"/proc/\$1/cmdline\" ] || return 1
        _a0=\$(tr '\\0' '\\n' < \"/proc/\$1/cmdline\" 2>/dev/null | sed -n 1p)
        _a1=\$(tr '\\0' '\\n' < \"/proc/\$1/cmdline\" 2>/dev/null | sed -n 2p)
        [ \"\$_a0\" = \"\$HOOK_PATH\" ] && return 0
        case \"\${_a0##*/}\" in
            bash|sh|ash|dash) [ \"\$_a1\" = \"\$HOOK_PATH\" ] && return 0 ;;
        esac
        return 1
    }
    if [ -f /run/adguard-failover.pid ]; then
        pid=\$(cat /run/adguard-failover.pid 2>/dev/null || true)
        if [ -n \"\$pid\" ] && kill -0 \"\$pid\" 2>/dev/null; then
            if is_ours \"\$pid\"; then
                kill \"\$pid\" || true
                sleep 1
            else
                echo \"  ! /run/adguard-failover.pid names PID \$pid, which does not look like ours; leaving it alone\" >&2
            fi
        fi
        rm -f /run/adguard-failover.pid
    fi
    # Orphan sweep. Two reasons this cannot rely on the supervisor's trap:
    # installs predating that trap left daemons reparented to init (one was
    # found on the UDM), and a supervisor killed with -9 never runs a trap at
    # all. Identity-verified against the daemon's own path, so it can only ever
    # match this project's process.
    DAEMON_PATH=/data/adguard-failover/dns-failover.sh
    is_our_daemon() {
        [ -n \"\$1\" ] || return 1
        [ -r \"/proc/\$1/cmdline\" ] || return 1
        _b0=\$(tr '\\0' '\\n' < \"/proc/\$1/cmdline\" 2>/dev/null | sed -n 1p)
        _b1=\$(tr '\\0' '\\n' < \"/proc/\$1/cmdline\" 2>/dev/null | sed -n 2p)
        [ \"\$_b0\" = \"\$DAEMON_PATH\" ] && return 0
        case \"\${_b0##*/}\" in
            bash|sh|ash|dash) [ \"\$_b1\" = \"\$DAEMON_PATH\" ] && return 0 ;;
        esac
        return 1
    }
    for _p in /proc/[0-9]*; do
        _pid=\${_p#/proc/}
        if is_our_daemon \"\$_pid\"; then
            echo \"  i stopping daemon pid \$_pid\" >&2
            kill \"\$_pid\" 2>/dev/null || true
        fi
    done
    sleep 1
    for _p in /proc/[0-9]*; do
        _pid=\${_p#/proc/}
        if is_our_daemon \"\$_pid\"; then
            echo \"  ! daemon pid \$_pid survived TERM; not escalating. Investigate before relying on failover.\" >&2
        fi
    done
    # The daemon reconciles on startup, but clear any stranded standby address
    # here too so a fresh install never begins in a failed-over state.
    ip addr del '${FAILOVER_IP}/32' dev '${LAN_IF}' 2>/dev/null || true
    # Explicit stdio redirection is belt-and-suspenders on top of the
    # detachment inside boot-hook.sh, so the SSH session cannot hang on
    # any inherited fd from the backgrounded supervisor.
    nohup /data/on_boot.d/15-adguard-failover.sh </dev/null >/dev/null 2>&1
    sleep 3
"
ok "Daemon launched"

# ------------------------------------------------------------------
# Step 6: Tail the log
# ------------------------------------------------------------------

say "Recent log output from ${LOG_FILE}:"
udm "tail -n 25 '$LOG_FILE' || true"
echo

# ------------------------------------------------------------------
# Follow-up instructions
# ------------------------------------------------------------------

cat <<EOF

$(ok "Install complete.")

Next steps (manual, GUI only):

  1. Open the UniFi Network app.
  2. Settings → Networks → your LAN network.
  3. Under DHCP Service Management → DNS Server, choose Manual and set
     BOTH entries, in this order:

         DNS 1:  ${ADGUARD_IP}    (AdGuard Home)
         DNS 2:  ${FAILOVER_IP}    (failover — normally does not exist)

     Both are required. DNS 1 alone gives you no failover; DNS 2 alone
     bypasses AdGuard entirely. Do NOT add a public resolver such as Quad9
     to this list: a secondary that is always reachable gets used
     opportunistically and would silently bypass AdGuard during normal
     operation. ${FAILOVER_IP} is safe precisely because it does not exist
     until it is needed.

  4. Save. Clients pick up the new list on their next lease renewal
     (~12h at the default 24h lease), or immediately on release/renew.

To verify behaviour, run the scripts in ../tests/.

Tier 1 — offline. No UDM, no network. Run any time:

  ./tests/test-parsing.sh        the dig contract and the RCODE table
  ./tests/test-state-machine.sh  the full state machine, against stubs
  ./tests/test-lib.sh            the Tier 2 plumbing, against a fake UDM
  ./tests/test-hardening.sh      kill-target identity, SSH policy, supply chain
  ./tests/test-install.sh        install/uninstall control flow + preflight

Tier 2 — live, but every change is confined to the UDM and reversed on exit.
AdGuard is never touched and clients keep resolving through it normally:

  ./tests/test-normal.sh         steady state, standing gates, stranded rules
  ./tests/test-failover.sh       AdGuard's DNS service down, host still up
  ./tests/test-host-down.sh      AdGuard's address gone from the UDM entirely
  ./tests/test-suppression.sh    AdGuard down during a WAN outage
  ./tests/test-drift.sh          upstream drift detection

RUN THE FULL TIER 2 SUITE BEFORE ADDING THE STANDBY TO DHCP (step 4 above).

Until the standby is advertised, binding it during a test is invisible to
every client. Afterwards it is not: clients may use it, and resolve unfiltered
and unattributed for as long as it is bound. Set STANDBY_IN_DHCP="yes" in
config.env when you complete step 4; the tests will then require a maintenance
window, cap engaged time and report it.

Tier 3 — manual drills, for the one question no automated test can answer:
whether real clients fail over, and how long they stall. See
../docs/failure-drills.md.

If anything goes wrong, ../docs/rollback.md is three commands and no prose.

EOF

if [ "${STANDBY_ADVERTISED:-no}" = "yes" ]; then
    cat <<EOF
!! ${FAILOVER_IP} IS ALREADY ADVERTISED TO CLIENTS VIA DHCP — step 4 is done.

   Tier 2 is therefore NO LONGER invisible to clients: any test that binds the
   standby creates a real path clients may take, resolving unfiltered and
   unattributed for as long as it stays bound.

   Set STANDBY_IN_DHCP="yes" in scripts/config.env before running Tier 2. That
   file is read by the test harness on your workstation, not by this device, so
   nothing needs redeploying. With it set, the tests require a maintenance
   window, cap engaged time, and report it.

EOF
fi
