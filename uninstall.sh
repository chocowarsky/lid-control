#!/usr/bin/env bash
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "[*] Elevating to root privileges for uninstallation..."
    exec sudo "$0" "$@"
fi

echo "=== Uninstalling Linux Laptop Lid Control ==="

# 1. Remove systemd-logind override
if [ -f /etc/systemd/logind.conf.d/99-lid-ignore.conf ]; then
    echo "[*] Removing systemd-logind override..."
    rm -f /etc/systemd/logind.conf.d/99-lid-ignore.conf
    systemctl reload systemd-logind
fi

# 2. Remove ACPI event and action script
echo "[*] Removing ACPI configuration..."
rm -f /etc/acpi/events/lid-state
rm -f /etc/acpi/lid_backlight.sh
systemctl restart acpid

# 3. Remove CLI utility
echo "[*] Removing /usr/local/bin/lid-control..."
rm -f /usr/local/bin/lid-control

# 4. Reset GNOME power settings to default
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    USER_UID=$(id -u "$SUDO_USER" 2>/dev/null)
    if [ -n "$USER_UID" ] && [ -e "/run/user/$USER_UID/bus" ]; then
        echo "[*] Resetting GNOME power settings to system defaults for '$SUDO_USER'..."
        sudo -u "$SUDO_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
            gsettings reset org.gnome.settings-daemon.plugins.power lid-close-ac-action 2>/dev/null || true
        sudo -u "$SUDO_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
            gsettings reset org.gnome.settings-daemon.plugins.power lid-close-battery-action 2>/dev/null || true
    fi
fi

echo ""
echo "=== Uninstallation Complete! ==="
echo "Default system suspend behavior on lid close has been restored."
