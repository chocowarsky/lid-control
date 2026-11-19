#!/usr/bin/env bash
# install.sh: Install lid-control CLI, acpid event hooks, logrotate policy, and enable mode

set -euo pipefail
shopt -s nullglob
if [ "$(id -u)" -eq 0 ] || [ -z "${LID_CONTROL_SYSROOT:-}" ]; then
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
STATE_DIR="/var/lib/lid-control"

ENABLE_ON_INSTALL=1
CLEAN_BACKUPS=1

usage() {
    cat << 'EOF'
Usage: sudo ./install.sh [OPTIONS]

Options:
  --no-enable       Install files without activating 'lid-control on'
  --keep-backups    Keep any existing *.bak-* files in /usr/local/bin and /etc/acpi
  -h, --help        Show this help message
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-enable)
            ENABLE_ON_INSTALL=0
            ;;
        --clean-backups)
            CLEAN_BACKUPS=1
            ;;
        --keep-backups)
            CLEAN_BACKUPS=0
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
    echo "[*] Elevating to root privileges for installation..."
    args=()
    if [ "$ENABLE_ON_INSTALL" -eq 0 ]; then
        args+=(--no-enable)
    fi
    if [ "$CLEAN_BACKUPS" -eq 0 ]; then
        args+=(--keep-backups)
    fi
    if [ "${#args[@]}" -gt 0 ]; then
        exec sudo "$(realpath "$0")" "${args[@]}"
    else
        exec sudo "$(realpath "$0")"
    fi
fi

echo "=== Installing Linux Laptop Lid Control (acpid + systemd-logind) ==="

# 1. Install acpid daemon if missing
if ! command -v acpid >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        echo "[*] Installing acpid daemon..."
        apt-get update -qq && apt-get install -y acpid
    else
        echo "[!] Warning: 'acpid' not found; please install acpid for your distribution." >&2
    fi
fi

# 2. Enable acpid service/socket/path triggers
echo "[*] Enabling acpid service..."
systemctl enable acpid.socket acpid.path >/dev/null 2>&1 || true
systemctl enable acpid.service >/dev/null 2>&1 || true

# 3. Create persistent state directory
install -d -m 0755 "$STATE_DIR" /usr/local/bin /etc/acpi /etc/acpi/events /etc/logrotate.d /etc/systemd/logind.conf.d

# 4. Install ACPI event handler, script, and logrotate rule
echo "[*] Installing ACPI lid event handler and logrotate policy..."
install -m 0644 "${DIR}/config/lid-state" /etc/acpi/events/lid-state
install -m 0755 "${DIR}/scripts/lid_backlight.sh" /etc/acpi/lid_backlight.sh
install -m 0644 "${DIR}/config/lid-control.logrotate" /etc/logrotate.d/lid-control

# 5. Install lid-control CLI utility
echo "[*] Installing lid-control CLI to /usr/local/bin/lid-control..."
install -m 0755 "${DIR}/bin/lid-control" /usr/local/bin/lid-control

# 6. Optionally remove stale .bak-* files from earlier manual deployments
if [ "$CLEAN_BACKUPS" -eq 1 ]; then
    backups=(/usr/local/bin/lid-control.bak-* /etc/acpi/lid_backlight.sh.bak-*)
    if [ "${#backups[@]}" -gt 0 ]; then
        echo "[*] Removing ${#backups[@]} stale backup file(s)..."
        rm -f "${backups[@]}"
    fi
fi

# 7. Activate lid-control (logind override, acpid restart, GNOME gsettings) or just reload acpid
if [ "$ENABLE_ON_INSTALL" -eq 1 ]; then
    /usr/local/bin/lid-control on
else
    systemctl restart acpid.service 2>/dev/null || systemctl start acpid.service 2>/dev/null || true
fi

echo ""
echo "=== Installation Complete! ==="
/usr/local/bin/lid-control status
