#!/usr/bin/env bash
# Automatic Screen & Keyboard Backlight Control on Lid Close/Open
# Powered by acpid & kernel ACPI events (sysfs hardware control)

set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
shopt -s nullglob

STATE_DIR="/var/lib/lid-control"
LOGIND_OVERRIDE="/etc/systemd/logind.conf.d/99-lid-ignore.conf"
STATE_FILE="$STATE_DIR/last_display_brightness"
KBD_STATE_FILE="$STATE_DIR/last_kbd_brightness"
LOG_FILE="/var/log/lid_backlight.log"

log_event() {
    printf '%s [acpid] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

first_glob() {
    local matches=("$@")
    if [ "${#matches[@]}" -gt 0 ]; then
        printf '%s\n' "${matches[0]}"
    fi
}

is_uint() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

get_lid_state() {
    local lid_files=(/proc/acpi/button/lid/*/state)
    if [ "${#lid_files[@]}" -gt 0 ]; then
        awk 'NR==1 {print $2}' "${lid_files[0]}" 2>/dev/null || true
    fi
}

save_and_blank_sysfs() {
    local sysfs_dir="$1"
    local state_file="$2"
    local min_save="$3"
    local label="$4"

    [ -n "$sysfs_dir" ] && [ -f "$sysfs_dir/brightness" ] || return 0

    local current
    current=$(cat "$sysfs_dir/brightness" 2>/dev/null || true)
    if is_uint "$current" && [ "$current" -ge "$min_save" ]; then
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

    [ -n "$sysfs_dir" ] && [ -f "$sysfs_dir/brightness" ] && [ -f "$state_file" ] || return 0

    local saved max_val
    saved=$(cat "$state_file" 2>/dev/null || true)
    if ! is_uint "$saved" || [ "$saved" -lt "$min_restore" ]; then
        return 0
    fi

    if [ -f "$sysfs_dir/max_brightness" ]; then
        max_val=$(cat "$sysfs_dir/max_brightness" 2>/dev/null || true)
        if is_uint "$max_val" && [ "$saved" -gt "$max_val" ]; then
            saved="$max_val"
        fi
    fi

    printf '%s\n' "$saved" > "$sysfs_dir/brightness" 2>/dev/null || true
    log_event "restored $label brightness: $saved"
}

EVENT="${1:-unknown}"
LID_STATE=$(get_lid_state)
log_event "event: $EVENT | lid_state: ${LID_STATE:-unknown}"

# Inactive Mode Guard: do not touch hardware brightness when lid-control is off
# so acpid never races with systemd-logind suspend/resume.
if [ ! -f "$LOGIND_OVERRIDE" ]; then
    log_event "mode inactive ($LOGIND_OVERRIDE absent); skipping hardware control"
    exit 0
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true

BACKLIGHT_DIR=$(first_glob /sys/class/backlight/*)
KBD_DIR=$(first_glob /sys/class/leds/*kbd_backlight)
GNOME_RUNNING=0
if pgrep -x gnome-shell >/dev/null 2>&1; then
    GNOME_RUNNING=1
fi

if [ "$LID_STATE" = "closed" ]; then
    # Always turn off keyboard backlight on lid close, preserving exact level (including 0).
    save_and_blank_sysfs "$KBD_DIR" "$KBD_STATE_FILE" 0 "kbd"

    # Under GNOME, lid-close-*-action='blank' handles display DPMS blanking cleanly via Mutter
    # without altering sysfs brightness. Fallback to sysfs power-off only outside GNOME.
    if [ "$GNOME_RUNNING" -eq 0 ]; then
        save_and_blank_sysfs "$BACKLIGHT_DIR" "$STATE_FILE" 1 "display (non-GNOME fallback)"
    fi

elif [ "$LID_STATE" = "open" ]; then
    # Restore keyboard backlight to exact saved level (including level 0 if user disabled it).
    restore_sysfs "$KBD_DIR" "$KBD_STATE_FILE" 0 "kbd"

    # Restore display backlight only when non-GNOME fallback turned sysfs off.
    if [ "$GNOME_RUNNING" -eq 0 ]; then
        restore_sysfs "$BACKLIGHT_DIR" "$STATE_FILE" 1 "display (non-GNOME fallback)"
    fi
fi
