#!/usr/bin/env bash
# Automatic Screen & Keyboard Backlight Control on Lid Close/Open
# Powered by acpid & kernel ACPI events (sysfs hardware control)

BACKLIGHT_DIR=$(ls -d /sys/class/backlight/* 2>/dev/null | head -n 1)
KBD_DIR=$(ls -d /sys/class/leds/*kbd_backlight 2>/dev/null | head -n 1)
STATE_FILE="/tmp/last_display_brightness"
KBD_STATE_FILE="/tmp/last_kbd_brightness"
LOG_FILE="/var/log/lid_backlight.log"

LID_STATE=$(cat /proc/acpi/button/lid/*/state 2>/dev/null | awk '{print $2}')
echo "$(date '+%Y-%m-%d %H:%M:%S') [acpid] event: $1 | lid_state: $LID_STATE" >> "$LOG_FILE" 2>/dev/null

if [ "$LID_STATE" = "closed" ]; then
    # 1. Turn off screen backlight
    if [ -n "$BACKLIGHT_DIR" ] && [ -f "$BACKLIGHT_DIR/brightness" ]; then
        CURRENT=$(cat "$BACKLIGHT_DIR/brightness" 2>/dev/null || echo 0)
        if [ "$CURRENT" -gt 0 ]; then
            echo "$CURRENT" > "$STATE_FILE" 2>/dev/null
            chmod 644 "$STATE_FILE" 2>/dev/null || true
        fi
        echo 0 > "$BACKLIGHT_DIR/brightness" 2>/dev/null
    fi

    # 2. Turn off keyboard backlight
    if [ -n "$KBD_DIR" ] && [ -f "$KBD_DIR/brightness" ]; then
        KBD_CURRENT=$(cat "$KBD_DIR/brightness" 2>/dev/null || echo 0)
        if [ "$KBD_CURRENT" -gt 0 ]; then
            echo "$KBD_CURRENT" > "$KBD_STATE_FILE" 2>/dev/null
            chmod 644 "$KBD_STATE_FILE" 2>/dev/null || true
        fi
        echo 0 > "$KBD_DIR/brightness" 2>/dev/null
    fi

elif [ "$LID_STATE" = "open" ]; then
    # 1. Restore screen backlight
    if [ -n "$BACKLIGHT_DIR" ] && [ -f "$BACKLIGHT_DIR/brightness" ]; then
        if [ -f "$STATE_FILE" ]; then
            SAVED=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
            if [ "$SAVED" -gt 0 ]; then
                echo "$SAVED" > "$BACKLIGHT_DIR/brightness" 2>/dev/null
            else
                MAX=$(cat "$BACKLIGHT_DIR/max_brightness" 2>/dev/null || echo 400000)
                echo "$((MAX / 2))" > "$BACKLIGHT_DIR/brightness" 2>/dev/null
            fi
        else
            MAX=$(cat "$BACKLIGHT_DIR/max_brightness" 2>/dev/null || echo 400000)
            echo "$((MAX / 2))" > "$BACKLIGHT_DIR/brightness" 2>/dev/null
        fi
    fi

    # 2. Restore keyboard backlight
    if [ -n "$KBD_DIR" ] && [ -f "$KBD_DIR/brightness" ]; then
        if [ -f "$KBD_STATE_FILE" ]; then
            KBD_SAVED=$(cat "$KBD_STATE_FILE" 2>/dev/null || echo 1)
            if [ "$KBD_SAVED" -gt 0 ]; then
                echo "$KBD_SAVED" > "$KBD_DIR/brightness" 2>/dev/null
            else
                echo 1 > "$KBD_DIR/brightness" 2>/dev/null
            fi
        else
            echo 1 > "$KBD_DIR/brightness" 2>/dev/null
        fi
    fi
fi
