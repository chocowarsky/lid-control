#!/usr/bin/env bash
# uninstall.sh: Remove lid-control CLI, acpid hooks, logrotate rule, and restore default suspend

set -euo pipefail
shopt -s nullglob
if [ "$(id -u)" -eq 0 ] || [ -z "${LID_CONTROL_SYSROOT:-}" ]; then
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
fi

PURGE=0

usage() {
    cat << 'EOF'
Usage: sudo ./uninstall.sh [OPTIONS]

Options:
  --purge     Also remove /var/log/lid_backlight.log*
  -h, --help  Show this help message
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --purge)
            PURGE=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

if [ "$(id -u)" -ne 0 ]; then
    echo "[*] Elevating to root privileges for uninstallation..."
    args=()
    if [ "$PURGE" -eq 1 ]; then
        args+=(--purge)
    fi
    if [ "${#args[@]}" -gt 0 ]; then
        exec sudo "$(realpath "$0")" "${args[@]}"
    else
        exec sudo "$(realpath "$0")"
    fi
fi

echo "=== Uninstalling Linux Laptop Lid Control ==="

# 1. Revert systemd-logind override & GNOME power settings via lid-control off (or manually if absent)
if [ -x /usr/local/bin/lid-control ]; then
    /usr/local/bin/lid-control off || true
else
    rm -f /etc/systemd/logind.conf.d/99-lid-ignore.conf
    systemctl reload systemd-logind 2>/dev/null || systemctl kill -s HUP systemd-logind 2>/dev/null || true
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        USER_UID=$(id -u "$SUDO_USER" 2>/dev/null || true)
        if [ -n "$USER_UID" ] && [ -e "/run/user/$USER_UID/bus" ]; then
            sudo -u "$SUDO_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
                gsettings reset org.gnome.settings-daemon.plugins.power lid-close-ac-action 2>/dev/null || true
            sudo -u "$SUDO_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
                gsettings reset org.gnome.settings-daemon.plugins.power lid-close-battery-action 2>/dev/null || true
        fi
    fi
fi

# 2. Remove ACPI configuration, logrotate rule, CLI utility, and stale backups
echo "[*] Removing ACPI configuration, logrotate policy, and CLI..."
rm -f \
    /etc/acpi/events/lid-state \
    /etc/acpi/lid_backlight.sh \
    /etc/logrotate.d/lid-control \
    /usr/local/bin/lid-control \
    /etc/systemd/logind.conf.d/99-lid-ignore.conf
backups=(/usr/local/bin/lid-control.bak-* /etc/acpi/lid_backlight.sh.bak-*)
if [ "${#backups[@]}" -gt 0 ]; then
    echo "[*] Removing ${#backups[@]} stale backup file(s)..."
    rm -f "${backups[@]}"
fi
systemctl restart acpid.service 2>/dev/null || true

# 3. Remove persistent state directory
if [ -d /var/lib/lid-control ]; then
    echo "[*] Cleaning up persistent state directory /var/lib/lid-control..."
    rm -rf /var/lib/lid-control
fi

# 4. Optionally purge logs
if [ "$PURGE" -eq 1 ]; then
    echo "[*] Purging logs..."
    rm -f /var/log/lid_backlight.log*
fi

echo ""
echo "=== Uninstallation Complete! ==="
echo "Default system suspend behavior on lid close has been restored."
