#!/bin/bash

set -euo pipefail

############################################
# Nightly Kopia Backup Setup
#
# Installs native Kopia, connects to an
# existing filesystem repository on a
# mounted share, configures snapshot
# policies and exclusions, creates a
# nightly backup script with system
# manifest capture, and schedules it
# via a systemd timer.
#
# Parameters are collected interactively
# on first run.  The script is idempotent
# and safe to re-run.
############################################

############################################
# Configurable defaults
############################################

BACKUP_USER="${SUDO_USER:-$(whoami)}"
BACKUP_HOME="/home/${BACKUP_USER}"
REPO_PATH="/mnt/squire-server/backups/cachyos"
BACKUP_SCRIPT="/usr/local/bin/nightly-backup.sh"
SCHEDULE_TIME="02:00:00"

KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=3

############################################
# Must run as root
############################################

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run with sudo."
    exit 1
fi

# Ensure kopia uses root's config regardless of how sudo handles HOME
export HOME=/root

############################################
# Helper: prompt with default value
############################################

prompt_default() {
    local PROMPT_TEXT="$1"
    local DEFAULT_VAL="$2"
    local INPUT

    read -rp "${PROMPT_TEXT} [${DEFAULT_VAL}]: " INPUT
    echo "${INPUT:-${DEFAULT_VAL}}"
}

############################################
# Interactive parameter prompts
############################################

echo ""
echo "── Nightly Kopia Backup Setup ──"
echo ""
echo "Press Enter to accept the default shown in brackets."
echo ""

BACKUP_USER=$(prompt_default "Backup user" "${BACKUP_USER}")
BACKUP_HOME=$(prompt_default "Home directory" "/home/${BACKUP_USER}")
REPO_PATH=$(prompt_default "Repository path" "${REPO_PATH}")
while true; do
    SCHEDULE_TIME=$(prompt_default "Backup time (HH:MM:SS)" "${SCHEDULE_TIME}")
    if [[ "${SCHEDULE_TIME}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$ ]]; then
        break
    fi
    echo "  Invalid format. Expected HH:MM:SS (e.g., 02:00:00)"
done

MANIFEST_DIR="${BACKUP_HOME}/.local/share/system-backup/manifests"
SOURCES=( "${BACKUP_HOME}" "/etc" "/boot" )

echo ""
echo "  Retention:  ${KEEP_DAILY} daily / ${KEEP_WEEKLY} weekly / ${KEEP_MONTHLY} monthly"
echo "  Sources:    ${SOURCES[*]}"
echo ""
read -rp "Continue? [Y/n] " CONFIRM
if [[ "${CONFIRM,,}" =~ ^n ]]; then
    echo "Aborted."
    exit 0
fi

############################################
# Derive mount point from repository path
############################################

if [[ ! -d "${REPO_PATH}" ]]; then
    echo "ERROR: Repository path does not exist: ${REPO_PATH}"
    echo "Ensure the share is mounted and the path is correct."
    exit 1
fi

MOUNT_POINT=$(findmnt -n -o TARGET --target "${REPO_PATH}")

if [[ -z "${MOUNT_POINT}" ]]; then
    echo "ERROR: Could not determine mount point for ${REPO_PATH}."
    exit 1
fi

echo "Detected mount point: ${MOUNT_POINT}"

############################################
# Install Kopia (native, not Flatpak)
############################################

if ! command -v kopia &>/dev/null; then
    echo ""
    echo "── Installing kopia-bin and kopia-ui-bin from AUR ──"
    sudo -u "${BACKUP_USER}" yay -S --needed --noconfirm kopia-bin kopia-ui-bin
fi

echo "Kopia version: $(kopia --version)"

############################################
# Connect to repository
############################################

if [[ ! -f /root/.config/kopia/repository.config ]]; then
    echo ""
    echo "── Connecting to Kopia repository ──"
    echo "Repository path: ${REPO_PATH}"
    echo ""

    kopia repository connect filesystem --path="${REPO_PATH}"
    echo "Repository connected."
else
    CONNECTED_PATH=$(kopia repository status --json 2>/dev/null | grep -oP '"path"\s*:\s*"\K[^"]+' || true)
    if [[ -n "${CONNECTED_PATH}" && "${CONNECTED_PATH}" != "${REPO_PATH}" && "${CONNECTED_PATH}" != "${REPO_PATH}/" ]]; then
        echo ""
        echo "WARNING: Kopia is connected to a different repository."
        echo "  Connected: ${CONNECTED_PATH}"
        echo "  Expected:  ${REPO_PATH}"
        echo ""
        read -rp "Reconnect to ${REPO_PATH}? [y/N] " RECONNECT
        if [[ "${RECONNECT,,}" =~ ^y ]]; then
            kopia repository disconnect
            kopia repository connect filesystem --path="${REPO_PATH}"
            echo "Reconnected to ${REPO_PATH}."
        else
            echo "Continuing with existing connection: ${CONNECTED_PATH}"
        fi
    else
        echo "Repository already connected to ${REPO_PATH}."
    fi
fi

############################################
# Secure samba credentials in fstab
############################################

CRED_FILE="${BACKUP_HOME}/.smbcredentials"

if grep -P '\bcifs\b' /etc/fstab | grep -q 'pass=' 2>/dev/null; then
    echo ""
    echo "── Securing samba credentials ──"

    SMB_USER=$(grep -P '\bcifs\b' /etc/fstab | grep -oP 'username=\K[^,]+' | head -1)
    SMB_PASS=$(grep -P '\bcifs\b' /etc/fstab | grep -oP 'pass=\K[^,\s]+' | head -1)

    cat > "${CRED_FILE}" << EOF
username=${SMB_USER}
password=${SMB_PASS}
EOF
    chmod 600 "${CRED_FILE}"
    chown "${BACKUP_USER}:${BACKUP_USER}" "${CRED_FILE}"

    awk -v cred="credentials=${CRED_FILE}" '{
        if ($0 ~ /\<cifs\>/ && $0 ~ /pass=/) {
            gsub(/username=[^,]+,pass=[^,[:space:]]+/, cred)
        }
        print
    }' /etc/fstab > /etc/fstab.tmp && mv /etc/fstab.tmp /etc/fstab

    echo "Credentials moved to ${CRED_FILE} (mode 600)."
    echo "Updated /etc/fstab to use credentials file."
elif [[ -f "${CRED_FILE}" ]]; then
    echo "Samba credentials already secured."
else
    echo "No inline samba credentials found in fstab; skipping."
fi

############################################
# Set Kopia snapshot policies
############################################

echo ""
echo "── Configuring Kopia policies ──"

kopia policy set --global --compression=zstd

for SRC in "${SOURCES[@]}"; do
    kopia policy set "${SRC}" \
        --keep-daily="${KEEP_DAILY}" \
        --keep-weekly="${KEEP_WEEKLY}" \
        --keep-monthly="${KEEP_MONTHLY}"
done

# Set monthly full maintenance (720h = 30 days)
kopia maintenance set --full-interval=720h

# Exclusions for home directory via .kopiaignore (idempotent)
cat > "${BACKUP_HOME}/.kopiaignore" << 'KOPIAIGNORE'
.cache/
.var/app/*/cache/
.vscode/extensions/
.config/Code/Cache/
.config/Code/CachedData/
.config/Code/CachedExtensionVSIXs/
.config/Code/CachedProfilesData/
.config/Code/CachedConfigurations/
.rustup/
.nvm/versions/
.npm/
.cargo/registry/
.cargo/git/
.local/share/Steam/
.local/share/zed/node/
.local/share/goverlay/
Emulation/
.copilot/
.local/share/Trash/
KOPIAIGNORE

chown "${BACKUP_USER}:${BACKUP_USER}" "${BACKUP_HOME}/.kopiaignore"

echo "Policies configured."

############################################
# Create manifest staging directory
############################################

mkdir -p "${MANIFEST_DIR}"
chown "${BACKUP_USER}:${BACKUP_USER}" "${MANIFEST_DIR}"

############################################
# Create nightly backup script
############################################

echo ""
echo "── Creating backup script: ${BACKUP_SCRIPT} ──"

cat > "${BACKUP_SCRIPT}" << 'SCRIPT'
#!/bin/bash
set -euo pipefail

export HOME=/root

BACKUP_HOME="%%BACKUP_HOME%%"
MANIFEST_DIR="%%MANIFEST_DIR%%"
REPO_PATH="%%REPO_PATH%%"

echo "$(date '+%Y-%m-%d %H:%M:%S') ── Nightly backup started ──"

# ── Ensure repository is connected ──
if ! kopia repository status &>/dev/null; then
    echo "Repository not connected. Reconnecting to ${REPO_PATH}..."
    kopia repository connect filesystem --path="${REPO_PATH}"
    echo "Reconnected."
fi

# ── Phase 1: Capture system manifests ──
# Failures here warn but do not block snapshots.
echo "Capturing system manifests..."

mkdir -p "${MANIFEST_DIR}"

pacman -Qe --quiet > "${MANIFEST_DIR}/pkglist-explicit.txt.tmp" \
    && mv "${MANIFEST_DIR}/pkglist-explicit.txt.tmp" "${MANIFEST_DIR}/pkglist-explicit.txt" \
    || echo "WARNING: Failed to capture explicit package list"

pacman -Qm --quiet > "${MANIFEST_DIR}/pkglist-aur.txt.tmp" \
    && mv "${MANIFEST_DIR}/pkglist-aur.txt.tmp" "${MANIFEST_DIR}/pkglist-aur.txt" \
    || echo "WARNING: Failed to capture AUR package list (may be empty)"

flatpak list --app --columns=application > "${MANIFEST_DIR}/flatpak-apps.txt.tmp" \
    && mv "${MANIFEST_DIR}/flatpak-apps.txt.tmp" "${MANIFEST_DIR}/flatpak-apps.txt" \
    || echo "WARNING: Failed to capture Flatpak app list"

systemctl list-unit-files --state=enabled --no-pager > "${MANIFEST_DIR}/enabled-services.txt.tmp" \
    && mv "${MANIFEST_DIR}/enabled-services.txt.tmp" "${MANIFEST_DIR}/enabled-services.txt" \
    || echo "WARNING: Failed to capture enabled services"

cp /etc/fstab "${MANIFEST_DIR}/fstab.txt" \
    || echo "WARNING: Failed to copy fstab"

findmnt --real -n -o TARGET,SOURCE,FSTYPE,OPTIONS > "${MANIFEST_DIR}/active-mounts.txt.tmp" \
    && mv "${MANIFEST_DIR}/active-mounts.txt.tmp" "${MANIFEST_DIR}/active-mounts.txt" \
    || echo "WARNING: Failed to capture active mounts"

echo "Manifests written to ${MANIFEST_DIR}"

# ── Phase 2: Kopia snapshots (all-or-nothing) ──
echo "Creating snapshots..."

kopia snapshot create "${BACKUP_HOME}"
kopia snapshot create /etc
kopia snapshot create /boot

# ── Phase 3: Repository maintenance (quick) ──
echo "Running repository maintenance..."
kopia maintenance run || echo "WARNING: Maintenance failed (snapshots were saved successfully)"

echo "$(date '+%Y-%m-%d %H:%M:%S') ── Nightly backup complete ──"
SCRIPT

# Substitute parameters into the generated script
sed -i "s|%%BACKUP_HOME%%|${BACKUP_HOME}|g"     "${BACKUP_SCRIPT}"
sed -i "s|%%MANIFEST_DIR%%|${MANIFEST_DIR}|g"   "${BACKUP_SCRIPT}"
sed -i "s|%%REPO_PATH%%|${REPO_PATH}|g"         "${BACKUP_SCRIPT}"

chmod 755 "${BACKUP_SCRIPT}"
echo "Backup script created."

############################################
# Create systemd units
############################################

echo ""
echo "── Creating systemd units ──"

# Failure notification service
cat > /etc/systemd/system/nightly-backup-notify.service << EOF
[Unit]
Description=Nightly Backup Failure Notification

[Service]
Type=oneshot
User=${BACKUP_USER}
Environment=DISPLAY=:0
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "${BACKUP_USER}")/bus
ExecStart=/bin/bash -c ' \\
    notify-send --urgency=critical --app-name="Kopia Backup" \\
        "Nightly Backup Failed" \\
        "The nightly backup did not complete successfully. Check /var/log/nightly-backup.log for details." ; \\
    echo "BACKUP FAILED — \$(date)" > ${BACKUP_HOME}/Desktop/BACKUP_FAILED.txt ; \\
    echo "" >> ${BACKUP_HOME}/Desktop/BACKUP_FAILED.txt ; \\
    echo "Check the log for details:" >> ${BACKUP_HOME}/Desktop/BACKUP_FAILED.txt ; \\
    echo "  sudo journalctl -u nightly-backup.service --since today" >> ${BACKUP_HOME}/Desktop/BACKUP_FAILED.txt ; \\
    echo "  cat /var/log/nightly-backup.log" >> ${BACKUP_HOME}/Desktop/BACKUP_FAILED.txt ; \\
    echo "" >> ${BACKUP_HOME}/Desktop/BACKUP_FAILED.txt ; \\
    echo "Once resolved, delete this file." >> ${BACKUP_HOME}/Desktop/BACKUP_FAILED.txt '
EOF

# Main backup service
cat > /etc/systemd/system/nightly-backup.service << EOF
[Unit]
Description=Nightly Kopia Backup
Wants=network-online.target
After=network-online.target
ConditionPathIsMountPoint=${MOUNT_POINT}
OnFailure=nightly-backup-notify.service

[Service]
Type=oneshot
ExecStart=${BACKUP_SCRIPT}
ExecStartPost=/bin/rm -f ${BACKUP_HOME}/Desktop/BACKUP_FAILED.txt
TimeoutStartSec=10800
StandardOutput=append:/var/log/nightly-backup.log
StandardError=append:/var/log/nightly-backup.log
EOF

# Timer
cat > /etc/systemd/system/nightly-backup.timer << EOF
[Unit]
Description=Nightly Kopia Backup Timer

[Timer]
OnCalendar=*-*-* ${SCHEDULE_TIME}
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now nightly-backup.timer
echo "Timer enabled and started: nightly-backup.timer"

############################################
# Log rotation
############################################

echo ""
echo "── Configuring log rotation ──"

cat > /etc/logrotate.d/nightly-backup << 'LOGROTATE'
/var/log/nightly-backup.log {
    size 5M
    rotate 1
    compress
    missingok
    notifempty
    copytruncate
}
LOGROTATE

echo "Logrotate configured."

############################################
# Enable snapper timeline snapshots
############################################

SNAPPER_CONF="/etc/snapper/configs/root"

if [[ -f "${SNAPPER_CONF}" ]] && grep -q 'TIMELINE_CREATE="no"' "${SNAPPER_CONF}"; then
    echo ""
    echo "── Enabling snapper timeline snapshots ──"
    sed -i 's/TIMELINE_CREATE="no"/TIMELINE_CREATE="yes"/' "${SNAPPER_CONF}"
    systemctl enable --now snapper-timeline.timer
    echo "Snapper timeline snapshots enabled."
fi

############################################
# Summary
############################################

echo ""
echo "── Setup complete ──"
echo ""
echo "  Backup script:  ${BACKUP_SCRIPT}"
echo "  Manifests:      ${MANIFEST_DIR}"
echo "  Exclusions:     ${BACKUP_HOME}/.kopiaignore"
echo "  Schedule:       Daily at ${SCHEDULE_TIME} (nightly-backup.timer)"
echo "  Mount check:    ${MOUNT_POINT}"
echo "  Log:            /var/log/nightly-backup.log"
echo "  On failure:     KDE notification + ${BACKUP_HOME}/Desktop/BACKUP_FAILED.txt"
echo ""
echo "  To run a backup now:  sudo ${BACKUP_SCRIPT}"
echo "  To check the timer:   systemctl list-timers | grep nightly"
echo "  To view snapshots:    sudo kopia snapshot list"
echo ""
