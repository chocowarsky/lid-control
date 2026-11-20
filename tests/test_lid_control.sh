#!/usr/bin/env bash
# Automated audit and regression test suite for lid-control

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '[PASS] %s\n' "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '[FAIL] %s\n' "$1" >&2
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
    if [[ "$expected" = "$actual" ]]; then
        pass "$msg"
    else
        fail "$msg (expected '$expected', got '$actual')"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="$3"
    if printf '%s\n' "$haystack" | grep -Fq -- "$needle"; then
        pass "$msg"
    else
        fail "$msg (missing '$needle')"
    fi
}

assert_line_count() {
    local haystack="$1"
    local pattern="$2"
    local expected_count="$3"
    local msg="$4"
    local actual_count
    actual_count=$(printf '%s\n' "$haystack" | grep -Fc -- "$pattern" || true)
    assert_eq "$expected_count" "$actual_count" "$msg"
}

# --- Setup mock binaries and isolated sysroot helpers ---
MOCK_BIN="$TMP_ROOT/mock_bin"
mkdir -p "$MOCK_BIN"

cat << 'EOF' > "$MOCK_BIN/sudo"
#!/usr/bin/env bash
if [[ -n "${MOCK_SUDO_LOG:-}" ]]; then
    printf '%s\n' "$*" > "$MOCK_SUDO_LOG"
fi
exit 0
EOF

cat << 'EOF' > "$MOCK_BIN/pgrep"
#!/usr/bin/env bash
exit "${MOCK_PGREP_RC:-0}"
EOF

cat << 'EOF' > "$MOCK_BIN/systemctl"
#!/usr/bin/env bash
if [[ "${1:-}" = "is-active" ]]; then
    state="${MOCK_SYSTEMCTL_STATE:-active}"
    printf '%s\n' "$state"
    if [[ "$state" = "active" ]]; then
        exit 0
    fi
    exit 3
fi
exit 0
EOF

cat << 'EOF' > "$MOCK_BIN/gsettings"
#!/usr/bin/env bash
if [[ "${1:-}" = "get" ]]; then
    printf "'blank'\n"
fi
exit 0
EOF

cat << 'EOF' > "$MOCK_BIN/gdbus"
#!/usr/bin/env bash
if [[ -n "${LID_CONTROL_SYSROOT:-}" ]]; then
    printf '%s\n' "$*" >> "${LID_CONTROL_SYSROOT}/var/log/mock_gdbus.log"
fi
exit "${MOCK_GDBUS_RC:-0}"
EOF

chmod +x "$MOCK_BIN/sudo" "$MOCK_BIN/pgrep" "$MOCK_BIN/systemctl" "$MOCK_BIN/gsettings" "$MOCK_BIN/gdbus"

new_sysroot() {
    local root="$1"
    rm -rf "$root"
    mkdir -p \
        "$root/proc/acpi/button/lid/LID" \
        "$root/sys/class/backlight/amdgpu_bl1" \
        "$root/sys/class/leds/asus::kbd_backlight" \
        "$root/sys/class/drm/card1-eDP-1" \
        "$root/sys/class/drm/card1-HDMI-A-1" \
        "$root/run/user/1000" \
        "$root/etc/acpi/events" \
        "$root/etc/systemd/logind.conf.d" \
        "$root/var/lib/lid-control" \
        "$root/var/log"

    printf 'state:      open\n' > "$root/proc/acpi/button/lid/LID/state"
    printf '132605\n' > "$root/sys/class/backlight/amdgpu_bl1/brightness"
    printf '400000\n' > "$root/sys/class/backlight/amdgpu_bl1/max_brightness"
    printf '2\n' > "$root/sys/class/leds/asus::kbd_backlight/brightness"
    printf '3\n' > "$root/sys/class/leds/asus::kbd_backlight/max_brightness"
    printf 'connected\n' > "$root/sys/class/drm/card1-eDP-1/status"
    printf 'disabled\n' > "$root/sys/class/drm/card1-eDP-1/enabled"
    printf 'Off\n' > "$root/sys/class/drm/card1-eDP-1/dpms"
    printf 'disconnected\n' > "$root/sys/class/drm/card1-HDMI-A-1/status"
    : > "$root/run/user/1000/bus"
    cp "$REPO_DIR/config/lid-state" "$root/etc/acpi/events/lid-state"
    cp "$REPO_DIR/config/99-lid-ignore.conf" "$root/etc/systemd/logind.conf.d/99-lid-ignore.conf"
}

echo "=== 1. Static, Permission, Config & Secret Audits ==="

SCRIPTS=(
    "$REPO_DIR/bin/lid-control"
    "$REPO_DIR/scripts/lid_backlight.sh"
    "$REPO_DIR/install.sh"
    "$REPO_DIR/uninstall.sh"
    "$REPO_DIR/tests/test_lid_control.sh"
)

for s in "${SCRIPTS[@]}"; do
    if bash -n "$s"; then
        pass "bash -n syntax check: $(basename "$s")"
    else
        fail "bash -n syntax check: $(basename "$s")"
    fi
    if [[ -x "$s" ]]; then
        pass "executable bit set: $(basename "$s")"
    else
        fail "executable bit set: $(basename "$s")"
    fi
done

for s in "$REPO_DIR/bin/lid-control" "$REPO_DIR/scripts/lid_backlight.sh" "$REPO_DIR/install.sh" "$REPO_DIR/uninstall.sh"; do
    if grep -Eq '^set -(e|eu|euo|uo) pipefail$' "$s"; then
        pass "strict mode header present: $(basename "$s")"
    else
        fail "strict mode header missing: $(basename "$s")"
    fi
done

if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "${SCRIPTS[@]}"; then
        pass "shellcheck clean across all scripts"
    else
        fail "shellcheck reported warnings/errors"
    fi
else
    printf '[INFO] shellcheck not installed locally; skipping local shellcheck (covered in CI)\n'
fi

if grep -RInE '(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)' \
    "$REPO_DIR/bin" "$REPO_DIR/scripts" "$REPO_DIR/config" "$REPO_DIR/install.sh" "$REPO_DIR/uninstall.sh" "$REPO_DIR/README.md" "$REPO_DIR/AUDIT.md" >/dev/null 2>&1; then
    fail "secret scan found potential credentials"
else
    pass "secret scan clean across repository files"
fi

assert_contains "$(cat "$REPO_DIR/config/lid-state")" "action=/etc/acpi/lid_backlight.sh %e" "config/lid-state binds lid_backlight.sh"
assert_contains "$(cat "$REPO_DIR/config/99-lid-ignore.conf")" "HandleLidSwitch=ignore" "config/99-lid-ignore.conf ignores lid switch"
assert_contains "$(cat "$REPO_DIR/config/lid-control.logrotate")" "copytruncate" "config/lid-control.logrotate uses copytruncate"

echo "=== 2. Non-Root Self-Elevation Regression Tests ==="

if [[ "$(id -u)" -ne 0 ]]; then
    SUDO_LOG="$TMP_ROOT/sudo_args.log"
    TEST_SYSROOT="$TMP_ROOT/elevate_sysroot"
    mkdir -p "$TEST_SYSROOT"

    rm -f "$SUDO_LOG"
    if LID_CONTROL_SYSROOT="$TEST_SYSROOT" MOCK_SUDO_LOG="$SUDO_LOG" PATH="$MOCK_BIN:$PATH" "$REPO_DIR/install.sh" </dev/null >/dev/null; then
        assert_eq "$(realpath "$REPO_DIR/install.sh")" "$(cat "$SUDO_LOG")" "install.sh default flags elevate via exec sudo without set -e abort"
    else
        fail "install.sh default flags failed non-root self-elevation"
    fi

    rm -f "$SUDO_LOG"
    if LID_CONTROL_SYSROOT="$TEST_SYSROOT" MOCK_SUDO_LOG="$SUDO_LOG" PATH="$MOCK_BIN:$PATH" "$REPO_DIR/install.sh" --no-enable --keep-backups </dev/null >/dev/null; then
        assert_eq "$(realpath "$REPO_DIR/install.sh") --no-enable --keep-backups" "$(cat "$SUDO_LOG")" "install.sh forwards --no-enable --keep-backups to sudo"
    else
        fail "install.sh --no-enable --keep-backups failed non-root self-elevation"
    fi

    rm -f "$SUDO_LOG"
    if LID_CONTROL_SYSROOT="$TEST_SYSROOT" MOCK_SUDO_LOG="$SUDO_LOG" PATH="$MOCK_BIN:$PATH" "$REPO_DIR/uninstall.sh" </dev/null >/dev/null; then
        assert_eq "$(realpath "$REPO_DIR/uninstall.sh")" "$(cat "$SUDO_LOG")" "uninstall.sh default flags elevate via exec sudo without set -e abort"
    else
        fail "uninstall.sh default flags failed non-root self-elevation"
    fi

    rm -f "$SUDO_LOG"
    if LID_CONTROL_SYSROOT="$TEST_SYSROOT" MOCK_SUDO_LOG="$SUDO_LOG" PATH="$MOCK_BIN:$PATH" "$REPO_DIR/uninstall.sh" --purge </dev/null >/dev/null; then
        assert_eq "$(realpath "$REPO_DIR/uninstall.sh") --purge" "$(cat "$SUDO_LOG")" "uninstall.sh forwards --purge to sudo"
    else
        fail "uninstall.sh --purge failed non-root self-elevation"
    fi
else
    printf '[INFO] running as root; skipping non-root sudo elevation tests\n'
fi

echo "=== 3. Behavioral Tests (scripts/lid_backlight.sh & bin/lid-control) ==="

if [[ "$(id -u)" -eq 0 ]]; then
    printf '[INFO] running as root; skipping non-root LID_CONTROL_SYSROOT isolation tests\n'
else
    SYSROOT="$TMP_ROOT/sysroot"

    # Test 3a: Inactive mode guard
    new_sysroot "$SYSROOT"
    rm -f "$SYSROOT/etc/systemd/logind.conf.d/99-lid-ignore.conf"
    printf 'state:      closed\n' > "$SYSROOT/proc/acpi/button/lid/LID/state"
    LID_CONTROL_SYSROOT="$SYSROOT" MOCK_PGREP_RC=1 PATH="$MOCK_BIN:$PATH" \
        "$REPO_DIR/scripts/lid_backlight.sh" "button/lid"
    assert_eq "2" "$(cat "$SYSROOT/sys/class/leds/asus::kbd_backlight/brightness")" "inactive guard leaves kbd brightness untouched"
    assert_eq "132605" "$(cat "$SYSROOT/sys/class/backlight/amdgpu_bl1/brightness")" "inactive guard leaves display brightness untouched"
    assert_contains "$(cat "$SYSROOT/var/log/lid_backlight.log")" "skipping hardware control" "inactive guard logs skip event"

    # Test 3b: Active undocked mode under GNOME (Mutter DPMS PowerSaveMode + kbd save/blank/restore)
    new_sysroot "$SYSROOT"
    printf 'state:      closed\n' > "$SYSROOT/proc/acpi/button/lid/LID/state"
    LID_CONTROL_SYSROOT="$SYSROOT" MOCK_PGREP_RC=0 PATH="$MOCK_BIN:$PATH" \
        "$REPO_DIR/scripts/lid_backlight.sh" "button/lid"
    assert_eq "0" "$(cat "$SYSROOT/sys/class/leds/asus::kbd_backlight/brightness")" "GNOME close turns off kbd backlight"
    assert_eq "2" "$(cat "$SYSROOT/var/lib/lid-control/last_kbd_brightness")" "GNOME close saves exact kbd level 2"
    assert_eq "132605" "$(cat "$SYSROOT/sys/class/backlight/amdgpu_bl1/brightness")" "GNOME close preserves sysfs display backlight"
    assert_contains "$(cat "$SYSROOT/var/log/mock_gdbus.log")" "<int32 3>" "GNOME undocked close sets Mutter PowerSaveMode=3 (Off)"

    printf 'state:      open\n' > "$SYSROOT/proc/acpi/button/lid/LID/state"
    LID_CONTROL_SYSROOT="$SYSROOT" MOCK_PGREP_RC=0 PATH="$MOCK_BIN:$PATH" \
        "$REPO_DIR/scripts/lid_backlight.sh" "button/lid"
    assert_eq "2" "$(cat "$SYSROOT/sys/class/leds/asus::kbd_backlight/brightness")" "GNOME open restores kbd level 2"
    assert_contains "$(cat "$SYSROOT/var/log/mock_gdbus.log")" "<int32 0>" "GNOME open restores Mutter PowerSaveMode=0 (On)"

    # Test 3b-ext: Active docked mode under GNOME (external monitor connected -> skips PowerSaveMode=3)
    new_sysroot "$SYSROOT"
    printf 'connected\n' > "$SYSROOT/sys/class/drm/card1-HDMI-A-1/status"
    printf 'state:      closed\n' > "$SYSROOT/proc/acpi/button/lid/LID/state"
    LID_CONTROL_SYSROOT="$SYSROOT" MOCK_PGREP_RC=0 PATH="$MOCK_BIN:$PATH" \
        "$REPO_DIR/scripts/lid_backlight.sh" "button/lid"
    if [[ ! -f "$SYSROOT/var/log/mock_gdbus.log" ]]; then
        pass "GNOME docked close skips PowerSaveMode=3 so external monitor stays on"
    else
        fail "GNOME docked close should not set PowerSaveMode=3"
    fi
    assert_contains "$(cat "$SYSROOT/var/log/lid_backlight.log")" "external monitor connected" "GNOME docked close logs external monitor mode"

    # Test 3b-fallback: Active undocked mode under GNOME when gdbus fails -> sysfs fallback & restore
    new_sysroot "$SYSROOT"
    printf 'state:      closed\n' > "$SYSROOT/proc/acpi/button/lid/LID/state"
    LID_CONTROL_SYSROOT="$SYSROOT" MOCK_PGREP_RC=0 MOCK_GDBUS_RC=1 PATH="$MOCK_BIN:$PATH" \
        "$REPO_DIR/scripts/lid_backlight.sh" "button/lid"
    assert_eq "0" "$(cat "$SYSROOT/sys/class/backlight/amdgpu_bl1/brightness")" "GNOME DPMS failure falls back to sysfs display blanking"
    printf 'state:      open\n' > "$SYSROOT/proc/acpi/button/lid/LID/state"
    LID_CONTROL_SYSROOT="$SYSROOT" MOCK_PGREP_RC=0 MOCK_GDBUS_RC=1 PATH="$MOCK_BIN:$PATH" \
        "$REPO_DIR/scripts/lid_backlight.sh" "button/lid"
    assert_eq "132605" "$(cat "$SYSROOT/sys/class/backlight/amdgpu_bl1/brightness")" "GNOME open restores sysfs fallback display brightness"

    # Test 3c: Kbd backlight level 0 preservation
    new_sysroot "$SYSROOT"
    printf '0\n' > "$SYSROOT/sys/class/leds/asus::kbd_backlight/brightness"
    printf 'state:      closed\n' > "$SYSROOT/proc/acpi/button/lid/LID/state"
    LID_CONTROL_SYSROOT="$SYSROOT" MOCK_PGREP_RC=0 PATH="$MOCK_BIN:$PATH" \
        "$REPO_DIR/scripts/lid_backlight.sh" "button/lid"
    assert_eq "0" "$(cat "$SYSROOT/var/lib/lid-control/last_kbd_brightness")" "kbd level 0 saved on close"

    printf '1\n' > "$SYSROOT/sys/class/leds/asus::kbd_backlight/brightness"
    printf 'state:      open\n' > "$SYSROOT/proc/acpi/button/lid/LID/state"
    LID_CONTROL_SYSROOT="$SYSROOT" MOCK_PGREP_RC=0 PATH="$MOCK_BIN:$PATH" \
        "$REPO_DIR/scripts/lid_backlight.sh" "button/lid"
    assert_eq "0" "$(cat "$SYSROOT/sys/class/leds/asus::kbd_backlight/brightness")" "kbd level 0 preserved on open"

    # Test 3d: Non-GNOME fallback display backlight save/blank/restore
    new_sysroot "$SYSROOT"
    printf '150000\n' > "$SYSROOT/sys/class/backlight/amdgpu_bl1/brightness"
    printf 'state:      closed\n' > "$SYSROOT/proc/acpi/button/lid/LID/state"
    LID_CONTROL_SYSROOT="$SYSROOT" MOCK_PGREP_RC=1 PATH="$MOCK_BIN:$PATH" \
        "$REPO_DIR/scripts/lid_backlight.sh" "button/lid"
    assert_eq "0" "$(cat "$SYSROOT/sys/class/backlight/amdgpu_bl1/brightness")" "non-GNOME close blanks sysfs display backlight"
    assert_eq "150000" "$(cat "$SYSROOT/var/lib/lid-control/last_display_brightness")" "non-GNOME close saves display brightness"

    printf 'state:      open\n' > "$SYSROOT/proc/acpi/button/lid/LID/state"
    LID_CONTROL_SYSROOT="$SYSROOT" MOCK_PGREP_RC=1 PATH="$MOCK_BIN:$PATH" \
        "$REPO_DIR/scripts/lid_backlight.sh" "button/lid"
    assert_eq "150000" "$(cat "$SYSROOT/sys/class/backlight/amdgpu_bl1/brightness")" "non-GNOME open restores display brightness"

    # Test 3e: Out-of-bounds clamping and corrupted state resilience
    new_sysroot "$SYSROOT"
    printf '0\n' > "$SYSROOT/sys/class/leds/asus::kbd_backlight/brightness"
    printf '999\n' > "$SYSROOT/var/lib/lid-control/last_kbd_brightness"
    printf 'state:      open\n' > "$SYSROOT/proc/acpi/button/lid/LID/state"
    LID_CONTROL_SYSROOT="$SYSROOT" MOCK_PGREP_RC=0 PATH="$MOCK_BIN:$PATH" \
        "$REPO_DIR/scripts/lid_backlight.sh" "button/lid"
    assert_eq "3" "$(cat "$SYSROOT/sys/class/leds/asus::kbd_backlight/brightness")" "saved brightness above max_brightness clamps to 3"

    printf '0\n' > "$SYSROOT/sys/class/leds/asus::kbd_backlight/brightness"
    printf 'bad_val\n' > "$SYSROOT/var/lib/lid-control/last_kbd_brightness"
    LID_CONTROL_SYSROOT="$SYSROOT" MOCK_PGREP_RC=0 PATH="$MOCK_BIN:$PATH" \
        "$REPO_DIR/scripts/lid_backlight.sh" "button/lid"
    assert_eq "0" "$(cat "$SYSROOT/sys/class/leds/asus::kbd_backlight/brightness")" "corrupted non-numeric state file safely ignored"

    # Test 3f: Multi-lid ACPI node parsing
    new_sysroot "$SYSROOT"
    rm -rf "$SYSROOT/proc/acpi/button/lid/LID"
    mkdir -p "$SYSROOT/proc/acpi/button/lid/LID0" "$SYSROOT/proc/acpi/button/lid/LID1"
    printf 'state:      closed\n' > "$SYSROOT/proc/acpi/button/lid/LID0/state"
    printf 'state:      open\n' > "$SYSROOT/proc/acpi/button/lid/LID1/state"
    LID_CONTROL_SYSROOT="$SYSROOT" MOCK_PGREP_RC=0 PATH="$MOCK_BIN:$PATH" \
        "$REPO_DIR/scripts/lid_backlight.sh" "button/lid"
    assert_eq "0" "$(cat "$SYSROOT/sys/class/leds/asus::kbd_backlight/brightness")" "multi-lid ACPI nodes parse first lid cleanly"

    # Test 3g: bin/lid-control status (ACTIVE & INACTIVE), log, help, invalid cmd
    new_sysroot "$SYSROOT"
    printf 'state:      closed\n' > "$SYSROOT/proc/acpi/button/lid/LID/state"
    STATUS_ACTIVE=$(LID_CONTROL_SYSROOT="$SYSROOT" MOCK_SYSTEMCTL_STATE="active" PATH="$MOCK_BIN:$PATH" \
        "$REPO_DIR/bin/lid-control" status)
    assert_contains "$STATUS_ACTIVE" "Mode Status       : ACTIVE" "status reports ACTIVE mode"
    assert_contains "$STATUS_ACTIVE" "Panel State       : disabled (DPMS: Off) [card1-eDP-1]" "status reports DRM panel DPMS state"
    assert_contains "$STATUS_ACTIVE" "Display Backlight : 132605 / 400000" "status reports display backlight"
    assert_contains "$STATUS_ACTIVE" "Keyboard Backlight: 2 / 3" "status reports keyboard backlight"
    assert_contains "$STATUS_ACTIVE" "acpid Service     : active (socket: active, path: active)" "status reports acpid socket/path state"

    rm -f "$SYSROOT/etc/systemd/logind.conf.d/99-lid-ignore.conf"
    STATUS_INACTIVE=$(LID_CONTROL_SYSROOT="$SYSROOT" MOCK_SYSTEMCTL_STATE="inactive" PATH="$MOCK_BIN:$PATH" \
        "$REPO_DIR/bin/lid-control" status)
    assert_contains "$STATUS_INACTIVE" "Mode Status       : INACTIVE" "status reports INACTIVE mode"
    assert_line_count "$STATUS_INACTIVE" "acpid Service     : inactive (service: inactive, socket: inactive, path: inactive)" 1 \
        "status prints single clean inactive line when systemctl exits non-zero"

    printf '2026-11-20 00:00:00 [acpid] test log entry\n' > "$SYSROOT/var/log/lid_backlight.log"
    LOG_OUT=$(LID_CONTROL_SYSROOT="$SYSROOT" PATH="$MOCK_BIN:$PATH" "$REPO_DIR/bin/lid-control" log)
    assert_contains "$LOG_OUT" "test log entry" "log subcommand reads SYSROOT log file"

    if "$REPO_DIR/bin/lid-control" --help >/dev/null; then
        pass "--help exits 0"
    else
        fail "--help exited non-zero"
    fi

    if "$REPO_DIR/bin/lid-control" bogus >/dev/null 2>&1; then
        fail "invalid subcommand should exit non-zero"
    else
        pass "invalid subcommand exits non-zero"
    fi
fi

echo "=== Summary: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[[ "$FAIL_COUNT" -eq 0 ]]
