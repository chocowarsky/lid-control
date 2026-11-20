#!/usr/bin/env bash
# Automatic Screen & Keyboard Backlight Control on Lid Close/Open
# Powered by acpid & kernel ACPI events (sysfs hardware control)

set -uo pipefail
shopt -s nullglob

SYSROOT=""
if [[ "$(id -u)" -ne 0 && -n "${LID_CONTROL_SYSROOT:-}" ]]; then
    SYSROOT="$LID_CONTROL_SYSROOT"
else
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
fi

STATE_DIR="${SYSROOT}/var/lib/lid-control"
LOGIND_OVERRIDE="${SYSROOT}/etc/systemd/logind.conf.d/99-lid-ignore.conf"
STATE_FILE="$STATE_DIR/last_display_brightness"
KBD_STATE_FILE="$STATE_DIR/last_kbd_brightness"
LOG_FILE="${SYSROOT}/var/log/lid_backlight.log"

log_event() {
    printf '%s [acpid] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

first_glob() {
    local matches=("$@")
    if [[ "${#matches[@]}" -gt 0 ]]; then
        printf '%s\n' "${matches[0]}"
    fi
}

is_uint() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

get_lid_state() {
    local lid_files=("$SYSROOT"/proc/acpi/button/lid/*/state)
    if [[ "${#lid_files[@]}" -gt 0 ]]; then
        awk 'NR==1 {print $2}' "${lid_files[0]}" 2>/dev/null || true
    fi
}

save_and_blank_sysfs() {
    local sysfs_dir="$1"
    local state_file="$2"
    local min_save="$3"
    local label="$4"

    [[ -n "$sysfs_dir" && -f "$sysfs_dir/brightness" ]] || return 0

    local current
    current=$(cat "$sysfs_dir/brightness" 2>/dev/null || true)
    if is_uint "$current" && [[ "$current" -ge "$min_save" ]]; then
        printf '%s\n' "$current" > "$state_file" 2>/dev/null || true
        chmod 644 "$state_file" 2>/dev/null || true
        log_event "saved $label brightness: $current"
    fi
    printf '0\n' > "$sysfs_dir/brightness" 2>/dev/null || true
}

restore_sysfs() {
    local sysfs_dir="$1"
    local state_file="$2"
    local min_restore="$3"
    local label="$4"

    [[ -n "$sysfs_dir" && -f "$sysfs_dir/brightness" && -f "$state_file" ]] || return 0

    local saved max_val
    saved=$(cat "$state_file" 2>/dev/null || true)
    if ! is_uint "$saved" || [[ "$saved" -lt "$min_restore" ]]; then
        return 0
    fi

    if [[ -f "$sysfs_dir/max_brightness" ]]; then
        max_val=$(cat "$sysfs_dir/max_brightness" 2>/dev/null || true)
        if is_uint "$max_val" && [[ "$saved" -gt "$max_val" ]]; then
            saved="$max_val"
        fi
    fi

    printf '%s\n' "$saved" > "$sysfs_dir/brightness" 2>/dev/null || true
    log_event "restored $label brightness: $saved"
}

has_external_monitor() {
    local status_files=("$SYSROOT"/sys/class/drm/card*-*/status)
    local sf conn_name state
    for sf in "${status_files[@]}"; do
        conn_name=$(basename "$(dirname "$sf")")
        case "$conn_name" in
            *-eDP-*|*-LVDS-*|*-DSI-*|*-Writeback-*)
                continue
                ;;
        esac
        state=$(cat "$sf" 2>/dev/null || true)
        if [[ "$state" = "connected" ]]; then
            return 0
        fi
    done
    return 1
}

set_gnome_dpms() {
    local mode="$1"
    local buses=("$SYSROOT"/run/user/*/bus)
    local bus uid user updated=1
    local prefix=()
    for bus in "${buses[@]}"; do
        [[ -e "$bus" ]] || continue
        uid=$(basename "$(dirname "$bus")")
        prefix=()
        if [[ -z "$SYSROOT" ]]; then
            is_uint "$uid" || continue
            user=$(id -un "$uid" 2>/dev/null || true)
            if [[ -z "$user" || "$user" = "root" || "$user" = "gdm" || "$user" = "Debian-gdm" ]]; then
                continue
            fi
            prefix=(sudo -u "$user")
        fi
        if "${prefix[@]}" env DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
            gdbus call --session \
            --dest org.gnome.Mutter.DisplayConfig \
            --object-path /org/gnome/Mutter/DisplayConfig \
            --method org.freedesktop.DBus.Properties.Set \
            "org.gnome.Mutter.DisplayConfig" "PowerSaveMode" "<int32 $mode>" \
            >/dev/null 2>&1; then
            updated=0
        fi
    done
    return "$updated"
}

EVENT="${1:-unknown}"
LID_STATE=$(get_lid_state)
log_event "event: $EVENT | lid_state: ${LID_STATE:-unknown}"

# Inactive Mode Guard: do not touch hardware brightness when lid-control is off
# so acpid never races with systemd-logind suspend/resume.
if [[ ! -f "$LOGIND_OVERRIDE" ]]; then
    log_event "mode inactive ($LOGIND_OVERRIDE absent); skipping hardware control"
    exit 0
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true

BACKLIGHT_DIR=$(first_glob "$SYSROOT"/sys/class/backlight/*)
KBD_DIR=$(first_glob "$SYSROOT"/sys/class/leds/*kbd_backlight)
GNOME_RUNNING=0
if pgrep -x gnome-shell >/dev/null 2>&1; then
    GNOME_RUNNING=1
fi

if [[ "$LID_STATE" = "closed" ]]; then
    # Always turn off keyboard backlight on lid close, preserving exact level (including 0).
    save_and_blank_sysfs "$KBD_DIR" "$KBD_STATE_FILE" 0 "kbd"

    # Display blanking:
    # - Docked with external monitor under GNOME: let Mutter handle clamshell eDP disable.
    # - Undocked under GNOME: switch Mutter PowerSaveMode to 3 (DPMS Off) without touching sysfs slider.
    # - Outside GNOME (or if D-Bus fails): fallback to sysfs backlight power-off.
    if [[ "$GNOME_RUNNING" -eq 1 ]]; then
        if has_external_monitor; then
            log_event "external monitor connected; Mutter handles eDP clamshell state"
        elif set_gnome_dpms 3; then
            log_event "set GNOME Mutter DPMS PowerSaveMode=3 (Off)"
        else
            save_and_blank_sysfs "$BACKLIGHT_DIR" "$STATE_FILE" 1 "display (GNOME DPMS fallback)"
        fi
    else
        save_and_blank_sysfs "$BACKLIGHT_DIR" "$STATE_FILE" 1 "display (non-GNOME fallback)"
    fi

elif [[ "$LID_STATE" = "open" ]]; then
    # Restore keyboard backlight to exact saved level (including level 0 if user disabled it).
    restore_sysfs "$KBD_DIR" "$KBD_STATE_FILE" 0 "kbd"

    # Wake Mutter DPMS on lid open under GNOME; restore sysfs fallback if used.
    if [[ "$GNOME_RUNNING" -eq 1 ]]; then
        if set_gnome_dpms 0; then
            log_event "restored GNOME Mutter DPMS PowerSaveMode=0 (On)"
        fi
        if [[ -f "$STATE_FILE" && -n "$BACKLIGHT_DIR" && -f "$BACKLIGHT_DIR/brightness" ]]; then
            cur_bl=$(cat "$BACKLIGHT_DIR/brightness" 2>/dev/null || echo "1")
            if is_uint "$cur_bl" && [[ "$cur_bl" -eq 0 ]]; then
                restore_sysfs "$BACKLIGHT_DIR" "$STATE_FILE" 1 "display (GNOME DPMS fallback)"
            fi
            rm -f "$STATE_FILE" 2>/dev/null || true
        fi
    else
        restore_sysfs "$BACKLIGHT_DIR" "$STATE_FILE" 1 "display (non-GNOME fallback)"
    fi
fi
