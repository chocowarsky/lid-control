#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "[*] Elevating to root privileges for installation..."
    exec sudo "$0" "$@"
fi

echo "=== Installing Linux Laptop Lid Control (acpid + systemd-logind) ==="

# 1. Install acpid daemon if missing
if ! command -v acpid &>/dev/null; then
    echo "[*] Installing acpid daemon..."
    apt-get update -qq && apt-get install -y acpid
fi

# 2. Enable and start acpid
echo "[*] Enabling and starting acpid service..."
systemctl enable acpid.service
systemctl restart acpid.service

# 3. Install ACPI event handler and script
echo "[*] Installing ACPI lid event handler..."
mkdir -p /etc/acpi/events
cp "${DIR}/config/lid-state" /etc/acpi/events/lid-state
chmod 644 /etc/acpi/events/lid-state

cp "${DIR}/scripts/lid_backlight.sh" /etc/acpi/lid_backlight.sh
chmod 755 /etc/acpi/lid_backlight.sh

# 4. Install systemd-logind override
echo "[*] Configuring systemd-logind override (HandleLidSwitch=ignore)..."
mkdir -p /etc/systemd/logind.conf.d
cp "${DIR}/config/99-lid-ignore.conf" /etc/systemd/logind.conf.d/99-lid-ignore.conf
chmod 644 /etc/systemd/logind.conf.d/99-lid-ignore.conf
systemctl reload systemd-logind

# 5. Install lid-control CLI utility
echo "[*] Installing lid-control CLI to /usr/local/bin/lid-control..."
cp "${DIR}/bin/lid-control" /usr/local/bin/lid-control
chmod 755 /usr/local/bin/lid-control

# 6. Apply GNOME power settings for active user session if available
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    USER_UID=$(id -u "$SUDO_USER" 2>/dev/null)
    if [ -n "$USER_UID" ] && [ -e "/run/user/$USER_UID/bus" ]; then
        echo "[*] Configuring GNOME power settings for desktop user '$SUDO_USER'..."
        sudo -u "$SUDO_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
            gsettings set org.gnome.settings-daemon.plugins.power lid-close-ac-action 'nothing' 2>/dev/null || true
        sudo -u "$SUDO_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
            gsettings set org.gnome.settings-daemon.plugins.power lid-close-battery-action 'nothing' 2>/dev/null || true
    fi
fi

systemctl restart acpid

echo ""
echo "=== Installation Complete! ==="
/usr/local/bin/lid-control status
