#!/bin/bash
#
# uninstall.sh — remove the AdGuard failover daemon from the UDM.
#
# Ordering matters: the standby address is removed only AFTER the supervisor
# and daemon are confirmed dead. Removing it first would let a still-running
# daemon re-add it on its next iteration and strand it permanently, silently
# routing clients around AdGuard with nothing left to clean it up.
#
# Leaves udm-boot.service enabled (that's a separate decision — /data/on_boot.d
# is a shared convention and other hooks may depend on it; see ReadMe.md).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$(cd "$SCRIPT_DIR/../scripts" && pwd)/config.env"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: $CONFIG_FILE not found." >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$CONFIG_FILE"

: "${UDM_HOST:?UDM_HOST must be set in config.env}"
: "${UDM_SSH_USER:?UDM_SSH_USER must be set in config.env}"
: "${FAILOVER_IP:?FAILOVER_IP must be set in config.env}"
: "${LAN_IF:?LAN_IF must be set in config.env}"
: "${ADGUARD_IP:=192.168.1.99}"

SSH_TARGET="${UDM_SSH_USER}@${UDM_HOST}"
SSH_OPTS=(-o ConnectTimeout=5)

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }

udm() { ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"; }

# ------------------------------------------------------------------
# Step 1: Stop the supervisor and daemon
# ------------------------------------------------------------------
#
# The daemon's TERM handler removes the standby address itself, so a clean
# stop usually leaves nothing to clean up. Step 3 is the backstop for the
# case where it was killed with SIGKILL or died abnormally.
#
# Every PID is verified against /proc/<pid>/cmdline before it is signalled.
# PID files go stale across reboots and PIDs get recycled, and `pgrep -f`
# matches on a substring of the command line — an operator with an editor or a
# `tail` open on one of these paths is a match. Sending SIGKILL to whatever
# happens to hold a recycled PID, as root, on a router, is not a risk worth
# carrying to save one syscall.
#
# The identity test is positional, not substring: argv[0] must be one of our
# paths, or argv[0] must be a shell and argv[1] one of our paths. A substring
# test over the whole command line matches `vim <path>` and `tail -f <path>`;
# this does not.
#
# Two paths are owned, and both are needed. The supervisor is a backgrounded
# subshell of the boot hook, so a forked subshell inherits the *hook's* argv —
# its cmdline reads `/bin/bash /data/on_boot.d/15-adguard-failover.sh` and
# contains no mention of dns-failover.sh at all. Verified empirically. Checking
# only the daemon path would leave the supervisor running, which would then
# relaunch the daemon after step 1 reported success, and step 3 would remove a
# standby address that gets re-added moments later.
#
# Order matters for the same reason: the supervisor is stopped before the
# daemon, or it restarts what we just stopped.
#
# A previous revision also sent `kill -TERM -"$pid"` to signal the process
# group. That was wrong: a backgrounded subshell in non-interactive bash is not
# a process-group leader, so the negative PID named an unrelated group. It
# appeared to work only because the failed call fell through to the plain
# `kill` after it. Removed rather than repaired — the sweep below covers the
# children, by identity.

say "Stopping supervisor and daemon on ${SSH_TARGET}"
udm '
    DAEMON_PATH=/data/adguard-failover/dns-failover.sh
    HOOK_PATH=/data/on_boot.d/15-adguard-failover.sh
    OWNED_PATHS="$HOOK_PATH $DAEMON_PATH"

    # Does this PID actually belong to us? Positional argv test, see above.
    is_ours() {
        [ -n "$1" ] || return 1
        [ -r "/proc/$1/cmdline" ] || return 1
        _a0=$(tr "\0" "\n" < "/proc/$1/cmdline" 2>/dev/null | sed -n 1p)
        _a1=$(tr "\0" "\n" < "/proc/$1/cmdline" 2>/dev/null | sed -n 2p)
        for _owned in $OWNED_PATHS; do
            [ "$_a0" = "$_owned" ] && return 0
            case "${_a0##*/}" in
                bash|sh|ash|dash)
                    [ "$_a1" = "$_owned" ] && return 0
                    ;;
            esac
        done
        return 1
    }

    stop_pid() {
        is_ours "$1" || return 0
        kill -TERM "$1" 2>/dev/null || true
        _n=0
        while [ "$_n" -lt 8 ] && kill -0 "$1" 2>/dev/null; do
            sleep 1
            _n=$((_n + 1))
        done
        # Re-verify identity before escalating: the PID may have exited and
        # been recycled during the wait above.
        if kill -0 "$1" 2>/dev/null && is_ours "$1"; then
            kill -KILL "$1" 2>/dev/null || true
        fi
    }

    # Supervisor first, by PID file, so it cannot relaunch the daemon.
    if [ -f /run/adguard-failover.pid ]; then
        pid=$(cat /run/adguard-failover.pid 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            if is_ours "$pid"; then
                stop_pid "$pid"
            else
                echo "  ! /run/adguard-failover.pid names PID $pid, which does not look like ours; leaving it alone" >&2
            fi
        fi
        rm -f /run/adguard-failover.pid
    fi

    # Sweep for anything left, however it was started — a supervisor whose PID
    # file was lost, or a daemon started by hand. Every candidate is re-verified
    # by identity rather than trusted from pgrep -f.
    for _path in $OWNED_PATHS; do
        for p in $(pgrep -f "$_path" 2>/dev/null); do
            [ "$p" = "$$" ] && continue
            stop_pid "$p"
        done
    done
'
ok "Supervisor and daemon stopped"

# ------------------------------------------------------------------
# Step 2: Confirm nothing is left running
# ------------------------------------------------------------------

say "Confirming no daemon remains"
# Same positional identity test as step 1 — a `pgrep -f` alone would report a
# stranded daemon when all that is open is an editor on the file, and this check
# aborts the uninstall.
if udm '
    for _path in /data/on_boot.d/15-adguard-failover.sh /data/adguard-failover/dns-failover.sh; do
        for p in $(pgrep -f "$_path" 2>/dev/null); do
            [ "$p" = "$$" ] && continue
            [ -r "/proc/$p/cmdline" ] || continue
            _a0=$(tr "\0" "\n" < "/proc/$p/cmdline" 2>/dev/null | sed -n 1p)
            _a1=$(tr "\0" "\n" < "/proc/$p/cmdline" 2>/dev/null | sed -n 2p)
            if [ "$_a0" = "$_path" ]; then
                echo "$p"; continue
            fi
            case "${_a0##*/}" in
                bash|sh|ash|dash)
                    [ "$_a1" = "$_path" ] && echo "$p"
                    ;;
            esac
        done
    done
' | grep -q .; then
    warn "A supervisor or dns-failover.sh process is STILL running. Removing ${FAILOVER_IP} now would be undone on its next iteration. Kill it manually and re-run this script."
    exit 1
fi
ok "No daemon running"

# ------------------------------------------------------------------
# Step 3: Remove the standby address
# ------------------------------------------------------------------
#
# Safe to do now that nothing can re-add it. Leaving it bound would keep the
# UDM answering DNS on it indefinitely, so clients holding it as their
# secondary could bypass AdGuard with no daemon left to notice.
#
# Removal is verified rather than assumed: `ip addr del` returning success is
# not the same fact as the address being gone, and this is the one piece of
# state whose survival is silently harmful.

# Addresses are matched on the exact field, not by grepping the rendered line.
# `grep 'inet 192.168.1.2/'` treats every dot as "any character" and matches on
# a substring, so it can both false-positive and — with a differently formatted
# line — false-negative. Same idiom as tests/lib.sh.
ip_bound_on_udm() {
    udm "ip -4 -o addr show 2>/dev/null" \
        | awk -v ip="$1" '{ split($4, a, "/"); if (a[1] == ip) found = 1 } END { exit !found }'
}

say "Removing ${FAILOVER_IP} from ${LAN_IF} if present"
if ip_bound_on_udm "$FAILOVER_IP"; then
    udm "ip addr del '${FAILOVER_IP}/32' dev '${LAN_IF}'" >/dev/null 2>&1 || true
fi
if ip_bound_on_udm "$FAILOVER_IP"; then
    warn "${FAILOVER_IP} is STILL bound on the UDM. Remove it manually:"
    warn "    ssh ${SSH_TARGET} \"ip addr del ${FAILOVER_IP}/32 dev ${LAN_IF}\""
    exit 1
fi
ok "${FAILOVER_IP} is not bound on the UDM"

# ------------------------------------------------------------------
# Step 4: Assert the AdGuard host was never impersonated
# ------------------------------------------------------------------
#
# The design forbids the UDM ever holding ${ADGUARD_IP}. If uninstall finds it
# bound, something outside this project put it there, and removing it blindly
# could be worse than leaving it. Report, do not act.

say "Checking that ${ADGUARD_IP} is not bound to any UDM interface"
if ip_bound_on_udm "$ADGUARD_IP"; then
    warn "${ADGUARD_IP} is bound to a UDM interface. This project never binds it."
    warn "Investigate before proceeding — the AdGuard host may be unreachable."
else
    ok "${ADGUARD_IP} is not bound on the UDM"
fi

# ------------------------------------------------------------------
# Step 5: Remove files
# ------------------------------------------------------------------
#
# The provenance record is read BEFORE anything is deleted. It is the only
# thing that can answer "was udm-boot.service here before us?", and once the
# removal starts that question can no longer be asked.
PROVENANCE_FILE="/data/.adguard-failover-provenance"

PRE_UNIT="unknown"
PRE_HOOKDIR="unknown"
if udm "[ -f '$PROVENANCE_FILE' ]"; then
    PRE_UNIT=$(udm "sed -n 's/^udm_boot_service_before_install=//p' '$PROVENANCE_FILE'" | tr -d '\r')
    PRE_HOOKDIR=$(udm "sed -n 's/^on_boot_d_before_install=//p' '$PROVENANCE_FILE'" | tr -d '\r')
    : "${PRE_UNIT:=unknown}"
    : "${PRE_HOOKDIR:=unknown}"
    ok "Read provenance record (udm-boot.service before install: ${PRE_UNIT})"
else
    warn "No provenance record found at ${PROVENANCE_FILE}."
    warn "This install predates provenance recording, or the file was removed."
    warn "udm-boot.service will be reported as 'unknown' below — do not assume."
fi

say "Removing boot hook, daemon, config and logs"
udm "
    rm -f /data/on_boot.d/15-adguard-failover.sh
    rm -rf /data/adguard-failover
    rm -f /run/adguard-failover.pid
    rm -f '$PROVENANCE_FILE'
"
ok "Files removed"

say "Verifying nothing was left behind"
LEFTOVERS=$(udm "
    for f in /data/adguard-failover \
             /data/on_boot.d/15-adguard-failover.sh /run/adguard-failover.pid \
             '$PROVENANCE_FILE'; do
        [ -e \"\$f\" ] && echo \"\$f\"
    done
    true
")
if [ -n "$LEFTOVERS" ]; then
    warn "These paths still exist on the UDM:"
    printf '    %s\n' $LEFTOVERS
    exit 1
fi
ok "Nothing left behind"

# ------------------------------------------------------------------
# Step 6: Remove the boot mechanism, but only if we created it
# ------------------------------------------------------------------
#
# This is reported, never done automatically. /data/on_boot.d is a shared
# convention and other hooks may live there; disabling the unit that runs them
# is not a decision an uninstaller should take on the operator's behalf.
#
# But it is now an *informed* decision, which it was not before: the provenance
# record says whether the unit predated this project.

say "Checking the on-boot mechanism"
if udm 'systemctl is-enabled udm-boot.service >/dev/null 2>&1'; then
    OTHER_HOOKS=$(udm 'ls -A /data/on_boot.d 2>/dev/null | wc -l' | tr -d ' \r')
    case "$PRE_UNIT" in
        absent)
            warn "udm-boot.service did NOT exist before this project installed it."
            warn "Leaving it enabled means the UDM is not back to its prior state."
            if [ "${OTHER_HOOKS:-0}" -gt 0 ]; then
                warn "However, /data/on_boot.d now holds ${OTHER_HOOKS} other hook(s),"
                warn "which would stop running if you remove it. Check them first:"
                warn "    ssh ${SSH_TARGET} 'ls -la /data/on_boot.d'"
            else
                warn "/data/on_boot.d is empty, so removing it is safe:"
                warn "    ssh ${SSH_TARGET} 'systemctl disable --now udm-boot.service && rm -f /etc/systemd/system/udm-boot.service'"
                if [ "$PRE_HOOKDIR" = "absent" ]; then
                    warn "    ssh ${SSH_TARGET} 'rmdir /data/on_boot.d'"
                fi
            fi
            ;;
        present)
            ok "udm-boot.service predates this project — leaving it alone is correct."
            ;;
        *)
            warn "Cannot tell whether udm-boot.service predates this project."
            warn "Do NOT disable it without checking what else uses /data/on_boot.d:"
            warn "    ssh ${SSH_TARGET} 'ls -la /data/on_boot.d'"
            ;;
    esac
else
    ok "udm-boot.service is not enabled; nothing to consider"
fi

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------

cat <<EOF

$(ok "Uninstall complete.")

Everything this project wrote to the UDM is gone: the daemon, the boot hook,
the config, the log, the PID file, the provenance record, and the standby
address ${FAILOVER_IP} — the last of which was verified removed, not assumed.

Two things are deliberately NOT undone, because both are decisions rather
than artefacts of this project:

1. DHCP still advertises ${FAILOVER_IP} as a secondary DNS server.
   Remove it in UniFi Network → Settings → Networks → Default → DHCP →
   DNS Server, leaving only ${ADGUARD_IP}. Until you do, clients hold a
   secondary that no longer exists — which is the same state this design
   maintains during normal operation, so it is harmless, but it also
   provides no failover any more.

2. udm-boot.service, if it is still enabled. See the guidance printed just
   above, which is based on whether the record showed it existed before
   this project was installed. That is the one piece of state where the
   right answer depends on your router rather than on this project, so it
   is reported rather than decided.

EOF
