#!/bin/bash
#
# boot-hook.sh — supervisor that keeps dns-failover.sh alive.
#
# Deployed to /data/on_boot.d/15-adguard-failover.sh on the UDM SE.
# The unifi-common package's udm-boot.service executes every executable in
# /data/on_boot.d/ on boot; the leading "15-" simply orders it relative to
# any other hooks.
#
# We launch dns-failover.sh in the background under a supervisor loop so a
# crash or unexpected exit auto-restarts within a few seconds. The PID of
# the supervisor is written for observability and uninstall.
#
# Restarting matters more here than it looks: the daemon reconciles the
# failover address on startup, so a supervised restart also clears a standby
# address left bound by an abnormal exit.

set -u

INSTALL_DIR="/data/adguard-failover"
DAEMON="$INSTALL_DIR/dns-failover.sh"
CONFIG_FILE="$INSTALL_DIR/config.env"
PIDFILE="/run/adguard-failover.pid"
LOG_FILE="$INSTALL_DIR/failover.log"

# Honour a relocated log path if config.env sets one, so supervisor output
# and daemon output stay in the same file.
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

mkdir -p "$(dirname "$LOG_FILE")"

# Restart backoff. A daemon that fails immediately and repeatedly (missing
# `dig`, unreadable config) would otherwise flood the log at 12 lines/minute
# forever. Backoff escalates on quick failures and resets once the daemon has
# stayed up long enough to be considered healthy.
RESTART_DELAY_MIN=5
RESTART_DELAY_MAX=60
HEALTHY_RUNTIME=60

if [ ! -x "$DAEMON" ]; then
    printf '%s  boot-hook: %s missing or not executable; not starting\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$DAEMON" >>"$LOG_FILE"
    exit 1
fi

# If a previous supervisor is still running, don't start another.
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    printf '%s  boot-hook: supervisor already running (pid %s), skipping\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$(cat "$PIDFILE")" >>"$LOG_FILE"
    exit 0
fi

# Supervisor: relaunch the daemon whenever it exits.
# stdin/stdout/stderr are explicitly detached from any inherited fds
# (particularly important when boot-hook.sh is invoked over SSH, so the
# SSH session can close promptly instead of hanging on the backgrounded
# subshell's dangling stdio).
(
    daemon_pid=""

    # Killing this supervisor MUST take the daemon with it.
    #
    # The daemon used to run in the foreground of this subshell. A non-interactive
    # bash will not deliver a trap until the foreground child returns, and it does
    # not forward the signal, so `kill <supervisor>` killed the supervisor and
    # left the daemon reparented to init. install.sh does exactly that before
    # starting a fresh copy, so every re-install added another daemon: observed on
    # the UDM as two processes probing on their own schedules, duplicating every
    # log line and racing each other for the standby address.
    #
    # Backgrounding the daemon and waiting on it makes this trap reachable. The
    # daemon's own TERM handler unbinds the standby, so a clean supervisor stop
    # also leaves no address behind.
    terminate() {
        if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
            printf '%s  boot-hook: signal received; stopping dns-failover.sh (pid %s)\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$daemon_pid" >>"$LOG_FILE"
            kill "$daemon_pid" 2>/dev/null || true
            wait "$daemon_pid" 2>/dev/null || true
        fi
        exit 0
    }
    trap terminate TERM INT

    delay=$RESTART_DELAY_MIN
    while true; do
        printf '%s  boot-hook: launching dns-failover.sh\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" >>"$LOG_FILE"

        started=$(date '+%s')
        "$DAEMON" >>"$LOG_FILE" 2>&1 &
        daemon_pid=$!
        wait "$daemon_pid"
        rc=$?
        daemon_pid=""
        ran=$(( $(date '+%s') - started ))

        if [ "$ran" -ge "$HEALTHY_RUNTIME" ]; then
            delay=$RESTART_DELAY_MIN
        fi

        printf '%s  boot-hook: dns-failover.sh exited (rc=%s) after %ss; restarting in %ss\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$rc" "$ran" "$delay" >>"$LOG_FILE"

        # Backgrounded sleep + wait so `terminate` is reachable during the
        # restart backoff too; a plain sleep would defer the trap for up to
        # RESTART_DELAY_MAX seconds.
        sleep "$delay" &
        wait $!

        if [ "$ran" -lt "$HEALTHY_RUNTIME" ] && [ "$delay" -lt "$RESTART_DELAY_MAX" ]; then
            delay=$(( delay * 2 ))
            [ "$delay" -gt "$RESTART_DELAY_MAX" ] && delay=$RESTART_DELAY_MAX
        fi
    done
) </dev/null >>"$LOG_FILE" 2>&1 &

pid=$!
echo "$pid" >"$PIDFILE"
disown "$pid" 2>/dev/null || true

printf '%s  boot-hook: supervisor started (pid %s)\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$pid" >>"$LOG_FILE"
