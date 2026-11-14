#!/usr/bin/env bash
# Automatic Screen & Keyboard Backlight Control on Lid Close/Open
# Powered by acpid & kernel ACPI events (sysfs hardware control)

STATE_DIR="/var/lib/lid-control"
mkdir -p "$STATE_DIR" 2>/dev/null || true

BACKLIGHT_DIR=$(ls -d /sys/class/backlight/* 2>/dev/null | head -n 1)
KBD_DIR=$(ls -d /sys/class/leds/*kbd_backlight 2>/dev/null | head -n 1)
STATE_FILE="$STATE_DIR/last_display_brightness"
KBD_STATE_FILE="$STATE_DIR/last_kbd_brightness"
LOG_FILE="/var/log/lid_backlight.log"

LID_STATE=$(cat /proc/acpi/button/lid/*/state 2>/dev/null | awk '{print $2}')
echo "$(date '+%Y-%m-%d %H:%M:%S') [acpid] event: $1 | lid_state: $LID_STATE" >> "$LOG_FILE" 2>/dev/null

if [ "$LID_STATE" = "closed" ]; then
    # 1. Handle Keyboard Backlight (always turn off on lid close, saving exact level 0-3)
    if [ -n "$KBD_DIR" ] && [ -f "$KBD_DIR/brightness" ]; then
        KBD_CURRENT=$(cat "$KBD_DIR/brightness" 2>/dev/null)
        if [ -n "$KBD_CURRENT" ] && [ "$KBD_CURRENT" -ge 0 ] 2>/dev/null; then
            echo "$KBD_CURRENT" > "$KBD_STATE_FILE" 2>/dev/null
            chmod 644 "$KBD_STATE_FILE" 2>/dev/null || true
            echo "$(date '+%Y-%m-%d %H:%M:%S') [acpid] saved kbd brightness: $KBD_CURRENT" >> "$LOG_FILE" 2>/dev/null
        fi
        echo 0 > "$KBD_DIR/brightness" 2>/dev/null
    fi

    # 2. Handle Screen Backlight
    # When GNOME is running, GNOME's native lid-close-*-action='blank' handles display DPMS blanking cleanly
    # without touching sysfs brightness (avoiding Mutter out-of-range clamp bugs and preserving exact user slider).
    # If GNOME is not running (e.g. pure console/TTY, boot, or non-desktop environment), fallback to sysfs power-off.
    if ! pgrep -x gnome-shell >/dev/null 2>&1; then
        if [ -n "$BACKLIGHT_DIR" ] && [ -f "$BACKLIGHT_DIR/brightness" ]; then
            CURRENT=$(cat "$BACKLIGHT_DIR/brightness" 2>/dev/null)
            if [ -n "$CURRENT" ] && [ "$CURRENT" -gt 0 ] 2>/dev/null; then
                echo "$CURRENT" > "$STATE_FILE" 2>/dev/null
                chmod 644 "$STATE_FILE" 2>/dev/null || true
                echo "$(date '+%Y-%m-%d %H:%M:%S') [acpid] saved display brightness: $CURRENT (non-GNOME fallback)" >> "$LOG_FILE" 2>/dev/null
            fi
            echo 0 > "$BACKLIGHT_DIR/brightness" 2>/dev/null
        fi
    fi

elif [ "$LID_STATE" = "open" ]; then
    # 1. Restore Keyboard Backlight to exact saved level (including level 0 if user turned it off)
    if [ -n "$KBD_DIR" ] && [ -f "$KBD_DIR/brightness" ]; then
        if [ -f "$KBD_STATE_FILE" ]; then
            KBD_SAVED=$(cat "$KBD_STATE_FILE" 2>/dev/null)
            if [ -n "$KBD_SAVED" ] && [ "$KBD_SAVED" -ge 0 ] 2>/dev/null; then
                echo "$KBD_SAVED" > "$KBD_DIR/brightness" 2>/dev/null
                echo "$(date '+%Y-%m-%d %H:%M:%S') [acpid] restored kbd brightness: $KBD_SAVED" >> "$LOG_FILE" 2>/dev/null
            fi
        fi
    fi

    # 2. Restore Screen Backlight (for non-GNOME environments where sysfs was set to 0)
    if ! pgrep -x gnome-shell >/dev/null 2>&1; then
        if [ -n "$BACKLIGHT_DIR" ] && [ -f "$BACKLIGHT_DIR/brightness" ]; then
            if [ -f "$STATE_FILE" ]; then
                SAVED=$(cat "$STATE_FILE" 2>/dev/null)
                if [ -n "$SAVED" ] && [ "$SAVED" -gt 0 ] 2>/dev/null; then
                    echo "$SAVED" > "$BACKLIGHT_DIR/brightness" 2>/dev/null
                    echo "$(date '+%Y-%m-%d %H:%M:%S') [acpid] restored display brightness: $SAVED (non-GNOME fallback)" >> "$LOG_FILE" 2>/dev/null
                fi
            fi
        fi
    fi
fi
