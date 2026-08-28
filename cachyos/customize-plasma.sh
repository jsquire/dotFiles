#!/bin/bash

set -euo pipefail

WALLPAPER=""
REFRESH_ICONS=false
CHECK_ONLY=false
ICON_THEME="Slot-Gradient-Dark-Icons"
ICON_PRODUCT_ID="2278954"
ICON_ARCHIVE_NAME="Slot-Gradient-Dark-Icons.tar.xz"
ICON_ARCHIVE_SHA256="819bfda0f1296f4200c95e401a74150bd5c28259a3107add8d1d5deafd33d45c"
ICON_SOURCE_MARKER=".jesse-source-sha256"
ICON_CONTENT_MANIFEST=".jesse-content-sha256"
CURSOR_THEME="capitaine-cursors"
CURSOR_SIZE="24"
DEFAULT_WALLPAPER="/usr/share/wallpapers/cachyos-wallpapers/north.png"
LOCK_WALLPAPER="/usr/share/wallpapers/cachyos-wallpapers/CachyOS_Moon.jpg"
TEMP_DIR=""
ICON_STAGING=""

cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
    if [ -n "$ICON_STAGING" ] && [ -d "$ICON_STAGING" ]; then
        rm -rf "$ICON_STAGING"
    fi
}

trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage: customize-plasma.sh [options]

Apply Jesse's portable Plasma appearance profile. This script is opt-in and
does not copy hardware, display, activity, panel, or security-sensitive state.

Options:
  --wallpaper <path>  Install and use a personal wallpaper instead of the
                      packaged CachyOS North wallpaper.
  --refresh-icons     Replace an installed Slot icon theme with the reviewed
                      archive pinned by this script. The existing theme is
                      backed up first.
  --check             Validate the required CachyOS Plasma session and exit.
  -h, --help          Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --wallpaper)
            [ "$#" -ge 2 ] || {
                echo "ERROR: --wallpaper requires a path." >&2
                exit 2
            }
            WALLPAPER="$2"
            shift
            ;;
        --refresh-icons)
            REFRESH_ICONS=true
            ;;
        --check)
            CHECK_ONLY=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [ -n "$WALLPAPER" ]; then
    [ -f "$WALLPAPER" ] || {
        echo "ERROR: wallpaper not found: $WALLPAPER" >&2
        exit 2
    }
    WALLPAPER="$(realpath "$WALLPAPER")"
fi

if [ "$EUID" -eq 0 ]; then
    echo "ERROR: run this script as the target desktop user, not as root." >&2
    exit 1
fi

case ":${XDG_CURRENT_DESKTOP:-}:" in
    *:KDE:*|*:PLASMA:*) ;;
    *)
        echo "ERROR: an active Plasma session is required." >&2
        exit 1
        ;;
esac

[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || {
    echo "ERROR: the Plasma user session bus is not available." >&2
    exit 1
}

busctl --user status org.kde.KWin &>/dev/null || {
    echo "ERROR: the active user's KWin session is not reachable." >&2
    exit 1
}

pacman -Si cachyos-wallpapers &>/dev/null || {
    echo "ERROR: this profile requires the CachyOS repositories." >&2
    exit 1
}

if [ "$CHECK_ONLY" = true ]; then
    echo "Plasma customization preflight passed."
    exit 0
fi

write_icon_manifest() {
    local directory="$1"
    local output="$2"
    local entries="${TEMP_DIR}/icon-entries"
    local entry path digest target

    if ! (
        cd "$directory"
        find . -mindepth 1 -print0 | LC_ALL=C sort -z
    ) >"$entries"; then
        echo "ERROR: unable to enumerate the installed icon theme." >&2
        return 1
    fi

    : >"$output"
    while IFS= read -r -d '' entry; do
        case "$entry" in
            "./${ICON_SOURCE_MARKER}"|"./${ICON_CONTENT_MANIFEST}")
                continue
                ;;
        esac

        path="${directory}/${entry#./}"
        if [ -L "$path" ]; then
            if ! target="$(readlink -- "$path")"; then
                echo "ERROR: unable to read icon symlink: $entry" >&2
                return 1
            fi
            printf 'L\0%s\0%s\0' "$entry" "$target" >>"$output"
        elif [ -f "$path" ]; then
            if ! digest="$(sha256sum -- "$path")"; then
                echo "ERROR: unable to hash icon file: $entry" >&2
                return 1
            fi
            digest="${digest%% *}"
            printf 'F\0%s\0%s\0' "$entry" "$digest" >>"$output"
        elif [ -d "$path" ]; then
            printf 'D\0%s\0' "$entry" >>"$output"
        else
            echo "ERROR: unsupported icon filesystem entry: $entry" >&2
            return 1
        fi
    done <"$entries"
}

install_slot_icons() {
    local icons_root="${HOME}/.local/share/icons"
    local destination="${icons_root}/${ICON_THEME}"
    local marker="${destination}/${ICON_SOURCE_MARKER}"
    local manifest="${destination}/${ICON_CONTENT_MANIFEST}"
    local metadata download_url download_name archive archive_listing extracted backup
    local current_manifest staged_manifest

    TEMP_DIR="$(mktemp -d -t plasma-customization.XXXXXXXX)"

    if [ -e "$destination" ] && [ "$REFRESH_ICONS" = false ]; then
        if [ -d "$destination" ] &&
            [ -f "${destination}/index.theme" ] &&
            [ -f "$marker" ] &&
            [ "$(<"$marker")" = "$ICON_ARCHIVE_SHA256" ] &&
            [ -f "$manifest" ]; then
            current_manifest="${TEMP_DIR}/current-icon-manifest"
            if ! write_icon_manifest "$destination" "$current_manifest"; then
                echo "ERROR: the installed ${ICON_THEME} could not be verified." >&2
                echo "Re-run with --refresh-icons to replace it with the reviewed version." >&2
                return 1
            fi
            if cmp -s "$current_manifest" "$manifest"; then
                echo "Keeping verified ${ICON_THEME}."
                return 0
            fi
        fi

        if [ -d "$destination" ] &&
            [ -f "$marker" ] &&
            [ "$(<"$marker")" = "$ICON_ARCHIVE_SHA256" ]; then
            echo "ERROR: the installed ${ICON_THEME} content differs from the pinned artifact." >&2
        else
            echo "ERROR: the installed ${ICON_THEME} does not match the pinned artifact." >&2
        fi
        echo "Re-run with --refresh-icons to back it up and install the reviewed version." >&2
        return 1
    fi

    archive="${TEMP_DIR}/slot-icons.tar.xz"

    metadata="$(curl -fsSL -H 'Accept: application/json' \
        "https://api.opendesktop.org/ocs/v1/content/data/${ICON_PRODUCT_ID}?format=json")"
    download_name="$(jq -er '.data[0].downloadname1' <<<"$metadata")"
    [ "$download_name" = "$ICON_ARCHIVE_NAME" ] || {
        echo "ERROR: unexpected icon archive name: $download_name" >&2
        return 1
    }
    download_url="$(jq -er '.data[0].downloadlink1' <<<"$metadata")"
    curl -fL "$download_url" -o "$archive"
    printf '%s  %s\n' "$ICON_ARCHIVE_SHA256" "$archive" | sha256sum --check -
    archive_listing="$(bsdtar -tf "$archive")"
    grep -E "(^|/)${ICON_THEME}/index\\.theme$" \
        <<<"$archive_listing" >/dev/null || {
            echo "ERROR: the pinned icon archive has an unexpected layout." >&2
            return 1
        }
    bsdtar -xf "$archive" -C "$TEMP_DIR"

    extracted="$(find "$TEMP_DIR" -type d -name "$ICON_THEME" -print -quit)"
    [ -n "$extracted" ] || {
        echo "ERROR: ${ICON_THEME} was not present in the downloaded archive." >&2
        return 1
    }

    mkdir -p "$icons_root"
    ICON_STAGING="$(mktemp -d "${icons_root}/.${ICON_THEME}.staging.XXXXXXXX")"
    cp -a "${extracted}/." "$ICON_STAGING/"
    printf '%s\n' "$ICON_ARCHIVE_SHA256" >"${ICON_STAGING}/${ICON_SOURCE_MARKER}"
    staged_manifest="${TEMP_DIR}/staged-icon-manifest"
    write_icon_manifest "$ICON_STAGING" "$staged_manifest"
    cp "$staged_manifest" "${ICON_STAGING}/${ICON_CONTENT_MANIFEST}"
    [ -f "${ICON_STAGING}/index.theme" ] || {
        echo "ERROR: the staged icon theme is incomplete." >&2
        return 1
    }

    backup=""
    if [ -e "$destination" ]; then
        backup="${destination}.bak-$(date +%Y%m%d%H%M%S%N)"
        mv -T "$destination" "$backup"
    fi

    if ! mv -T "$ICON_STAGING" "$destination"; then
        if [ -n "$backup" ]; then
            mv -T "$backup" "$destination" || {
                echo "ERROR: icon replacement failed and the backup could not be restored: $backup" >&2
                return 1
            }
        fi
        echo "ERROR: icon replacement failed; the previous theme was preserved." >&2
        return 1
    fi
    ICON_STAGING=""

    if [ -n "$backup" ]; then
        echo "Backed up the previous icon theme to ${backup}."
    fi
}

install_wallpaper() {
    local source="$1" extension destination

    [ -f "$source" ] || {
        echo "ERROR: wallpaper not found: $source" >&2
        return 1
    }

    extension="${source##*.}"
    destination="${HOME}/.local/share/wallpapers/Jesse/custom.${extension}"
    install -Dm644 "$source" "$destination"
    printf '%s\n' "$destination"
}

sudo pacman -S --needed --noconfirm \
    breeze \
    breeze-gtk \
    cachyos-wallpapers \
    capitaine-cursors \
    curl \
    coreutils \
    findutils \
    grep \
    jq \
    kconfig \
    libarchive \
    plasma-workspace \
    qt6-tools

for wallpaper_file in "$DEFAULT_WALLPAPER" "$LOCK_WALLPAPER"; do
    [ -f "$wallpaper_file" ] || {
        echo "ERROR: required CachyOS wallpaper not found: $wallpaper_file" >&2
        exit 1
    }
done

for command_name in \
    bsdtar \
    busctl \
    cmp \
    curl \
    find \
    jq \
    kbuildsycoca6 \
    kwriteconfig6 \
    lookandfeeltool \
    plasma-apply-colorscheme \
    plasma-apply-cursortheme \
    plasma-apply-wallpaperimage \
    qdbus6 \
    readlink \
    sha256sum \
    sort
do
    command -v "$command_name" &>/dev/null || {
        echo "ERROR: required command not found: $command_name" >&2
        exit 1
    }
done

install_slot_icons

lookandfeeltool --apply org.kde.breezedark.desktop --keep-auto
plasma-apply-colorscheme BreezeDark
plasma-apply-cursortheme --size "$CURSOR_SIZE" "$CURSOR_THEME"

kwriteconfig6 --file kdeglobals --group Icons --key Theme "$ICON_THEME" --notify
kwriteconfig6 --file kdeglobals --group KDE --key AnimationDurationFactor "0.25" --notify
kwriteconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage \
    "org.kde.breezedark.desktop" --notify
kwriteconfig6 --file kdeglobals --group KDE --key widgetStyle "Breeze" --notify
kwriteconfig6 --file plasmarc --group Theme --key name "default" --notify
kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key library \
    "org.kde.breeze" --notify
kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key theme \
    "Breeze" --notify

kwriteconfig6 --file kdeglobals --group "KFileDialog Settings" \
    --key "Allow Expansion" "false"
kwriteconfig6 --file kdeglobals --group "KFileDialog Settings" \
    --key "Automatically select filename extension" "true"
kwriteconfig6 --file kdeglobals --group "KFileDialog Settings" \
    --key "Breadcrumb Navigation" "true"
kwriteconfig6 --file kdeglobals --group "KFileDialog Settings" \
    --key "Decoration position" "2"
kwriteconfig6 --file kdeglobals --group "KFileDialog Settings" \
    --key "Show Full Path" "false"
kwriteconfig6 --file kdeglobals --group "KFileDialog Settings" \
    --key "Show Inline Previews" "true"
kwriteconfig6 --file kdeglobals --group "KFileDialog Settings" \
    --key "Show Preview" "false"
kwriteconfig6 --file kdeglobals --group "KFileDialog Settings" \
    --key "Show hidden files" "false"
kwriteconfig6 --file kdeglobals --group "KFileDialog Settings" \
    --key "Sort by" "Name"
kwriteconfig6 --file kdeglobals --group "KFileDialog Settings" \
    --key "Sort directories first" "true"
kwriteconfig6 --file kdeglobals --group "KFileDialog Settings" \
    --key "View Style" "DetailTree" --notify

for gtk_version in 3.0 4.0; do
    kwriteconfig6 --file "gtk-${gtk_version}/settings.ini" --group Settings \
        --key gtk-application-prefer-dark-theme --type bool true
    kwriteconfig6 --file "gtk-${gtk_version}/settings.ini" --group Settings \
        --key gtk-cursor-theme-name "$CURSOR_THEME"
    kwriteconfig6 --file "gtk-${gtk_version}/settings.ini" --group Settings \
        --key gtk-cursor-theme-size "$CURSOR_SIZE"
    kwriteconfig6 --file "gtk-${gtk_version}/settings.ini" --group Settings \
        --key gtk-icon-theme-name "$ICON_THEME"
done
kwriteconfig6 --file "gtk-3.0/settings.ini" --group Settings \
    --key gtk-theme-name "Breeze"

if [ -n "$WALLPAPER" ]; then
    wallpaper_path="$(install_wallpaper "$WALLPAPER")"
else
    wallpaper_path="$DEFAULT_WALLPAPER"
fi

plasma-apply-wallpaperimage --fill-mode preserveAspectCrop "$wallpaper_path"

kwriteconfig6 --file kscreenlockerrc \
    --group Greeter --group Wallpaper --group org.kde.image --group General \
    --key Image "file://${LOCK_WALLPAPER}" --notify
kwriteconfig6 --file kscreenlockerrc \
    --group Greeter --group Wallpaper --group org.kde.image --group General \
    --key PreviewImage "file://${LOCK_WALLPAPER}" --notify

kbuildsycoca6 --noincremental
qdbus6 org.kde.KWin /KWin reconfigure

echo
echo "Plasma customization applied."
echo "Log out and back in once to refresh all Qt and GTK applications."
