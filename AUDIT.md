# `lid-control` Technical Audit Report

- **Audit Date:** 2026-11-19
- **Repository:** [`chocowarsky/lid-control`](https://github.com/chocowarsky/lid-control) (baseline commits `99ef022` and `3751ccb`)
- **Target System:** ASUS Zenbook S 16 (`UM5606WA_UM5606WA`), Ubuntu with GNOME (`gnome-settings-daemon` `50.0-1ubuntu1`), `systemd-logind`, `acpid`
- **Original Author:** Bagus Wijaya (Warsky) (v1 co-authored with `gus57`)

---

## 1. Discovered System Artifacts & Upstream Alignment

The `lid-control` feature installed on the laptop matched commit `3751ccb` of `chocowarsky/lid-control` (`diff` exit code `0` across all 4 core files), alongside historical timestamped `.bak-*` files from earlier iterations:

| System Path | Repository Path | Timestamp / Size | Purpose |
| :--- | :--- | :--- | :--- |
| `/usr/local/bin/lid-control` | `bin/lid-control` | 2026-11-14 11:25 (5571 B) | User-facing CLI (`status\|on\|off\|log`) |
| `/usr/local/bin/lid-control.bak-20261111-1401` | — | 2026-11-11 14:01 (2979 B) | v1 CLI backup on host |
| `/usr/local/bin/lid-control.bak-20261114-1123` | — | 2026-11-14 11:23 (5049 B) | v2 CLI backup on host |
| `/etc/acpi/lid_backlight.sh` | `scripts/lid_backlight.sh` | 2026-11-14 11:25 (3614 B) | `acpid` lid event handler |
| `/etc/acpi/lid_backlight.sh.bak-20261111-1401` | — | 2026-11-11 14:01 (2367 B) | v1 ACPI handler backup on host |
| `/etc/acpi/lid_backlight.sh.bak-20261114-1123` | — | 2026-11-14 11:23 (2699 B) | v2 ACPI handler backup on host |
| `/etc/acpi/events/lid-state` | `config/lid-state` | 2026-11-11 03:55 (56 B) | Binds `event=button/lid.*` to `lid_backlight.sh %e` |
| `/etc/systemd/logind.conf.d/99-lid-ignore.conf` | `config/99-lid-ignore.conf` | 2026-11-11 03:55 (96 B) | Sets `HandleLidSwitch*=ignore` |
| `/var/lib/lid-control/` | — | 2026-11-14 11:26 | Persistent state (`last_kbd_brightness` / `last_display_brightness`) |
| `/var/log/lid_backlight.log` | — | 120 lines (Nov 11–Nov 19) | Timestamped ACPI lid event log |

---

## 2. Evolution Across Historical Backups & Git History

Comparing the local `.bak-*` files and upstream git commits shows three iterations prior to this audit:

1. **v1 (`2026-11-11`, `*.bak-20261111-1401`, upstream `99ef022`):**
   - Stored brightness state in `/tmp/last_display_brightness` and `/tmp/last_kbd_brightness` (lost on reboot).
   - No `sudo` self-elevation in `lid-control` and no `SUDO_USER` D-Bus targeting for `gsettings`.
   - Set GNOME `lid-close-ac-action` and `lid-close-battery-action` to `'nothing'`.
   - Always wrote `0` to `/sys/class/backlight/*/brightness` on close and restored saved or `MAX / 2` on open, conflicting with GNOME/Mutter brightness state.
   - Forced keyboard backlight to `1` on open if the saved value was `0`.
2. **v2 (`2026-11-14 11:23`, `*.bak-20261114-1123`):**
   - Added automatic `exec sudo "$0" "$@"` elevation for `on` and `off`.
   - Added `SUDO_USER` + `/run/user/$target_uid/bus` D-Bus resolution so `gsettings` acts on the desktop user's session under `sudo`.
   - Still used `/tmp` state files, unconditionally modified sysfs display brightness, and defaulted keyboard backlight to `1`.
3. **v3 (`2026-11-14 11:25`, installed baseline, upstream `3751ccb`):**
   - Moved persistent state to `/var/lib/lid-control`.
   - Changed GNOME `lid-close-*-action` from `'nothing'` to `'blank'`.
   - Guarded sysfs display backlight control with `if ! pgrep -x gnome-shell >/dev/null 2>&1`, delegating display power management to GNOME/Mutter while preserving keyboard backlight level `0` (OFF).

---

## 3. Reverse-Engineered GNOME (`gsd-power`) Interaction

Inspection of `/usr/libexec/gsd-power` (`gnome-settings-daemon` `50.0-1ubuntu1`) and `org.gnome.settings-daemon.plugins.power.gschema.xml` confirms how v3 operates on this system:

- `systemd-logind` reads `/etc/systemd/logind.conf.d/99-lid-ignore.conf` (`HandleLidSwitch=ignore`, `HandleLidSwitchExternalPower=ignore`, `HandleLidSwitchDocked=ignore`) and suppresses kernel suspend on lid close.
- `gsd-power` monitors `UPower` (`LidClosed`), evaluates `lid-close-ac-action` / `lid-close-battery-action` (`'blank'`), invokes `Doing a state transition: blank` via Mutter's `DisplayConfig` (`gsd_display_config_set_power_save_mode`), and manages a `handle-lid-switch` inhibitor and `lid close safety timer`.
- On this hardware (`amdgpu_bl1` backlight, `card1-eDP-1` internal panel, `card1-HDMI-A-1` external monitor), when the lid is closed with an external monitor active, DRM disables the internal connector (`card1-eDP-1/enabled` = `disabled`, `card1-eDP-1/dpms` = `Off`) while `amdgpu_bl1/brightness` retains the user's slider value (`132605 / 400000`).
- Meanwhile, `acpid` catches `button/lid.*` via `/etc/acpi/events/lid-state` and calls `/etc/acpi/lid_backlight.sh` to save and turn off `/sys/class/leds/asus::kbd_backlight/brightness` (`0..3`), restoring the exact level on lid open.

---

## 4. Audit Findings & Remediations

### Finding 1 (High): `lid_backlight.sh` executes even when `lid-control` is `off` (Suspend/Resume Race)
- **Observation:** `lid-control off` removes `/etc/systemd/logind.conf.d/99-lid-ignore.conf` and resets GNOME `gsettings`, leaving `/etc/acpi/events/lid-state` and `/etc/acpi/lid_backlight.sh` active in `acpid`.
- **Impact:** When `lid-control` is `INACTIVE`, closing the lid triggers both `systemd-logind` suspend and `lid_backlight.sh` simultaneously, mutating keyboard backlight (and display sysfs outside GNOME) while the kernel enters or wakes from suspend.
- **Fix Applied:** `scripts/lid_backlight.sh` now checks for `/etc/systemd/logind.conf.d/99-lid-ignore.conf` before modifying any sysfs node and exits cleanly if the mode is inactive.

### Finding 2 (High): Misleading `Display Backlight` output in `lid-control status` under DRM/DPMS blanking
- **Observation:** During live inspection with the lid closed and an external monitor attached (`card1-HDMI-A-1`), `amdgpu_bl1/brightness` and `actual_brightness` remained `132605 / 400000`, while `/sys/class/drm/card1-eDP-1/enabled` was `disabled` and `/sys/class/drm/card1-eDP-1/dpms` was `Off`.
- **Impact:** Running `lid-control status` showed `Display Backlight : 132605 / 400000` with no panel/DPMS indicator, making it look as though the screen backlight had failed to turn off.
- **Fix Applied:** Added `Panel State` reporting in `bin/lid-control` (`get_panel_status`), inspecting `/sys/class/drm/*-eDP-*`, `*-LVDS-*`, and `*-DSI-*` `enabled` and `dpms` attributes alongside backlight brightness.

### Finding 3 (Medium): Multi-line ACPI lid state parsing & unhardened sysfs handling
- **Observation:** `cat /proc/acpi/button/lid/*/state | awk '{print $2}'` can emit multiple lines if more than one ACPI lid device exists. Additionally, `lid_backlight.sh` lacked `set -uo pipefail`, explicit `PATH`, `nullglob` globbing, integer validation, and `max_brightness` bounds clamping.
- **Impact:** Multi-lid systems break string comparisons (`[ "$LID_STATE" = "closed" ]`); corrupted state files or unexpected sysfs responses could cause `test` syntax errors or invalid writes.
- **Fix Applied:** Switched to `awk 'NR==1 {print $2}'` with nullglob-checked `/proc/acpi/button/lid/*/state`, added `set -uo pipefail`, `shopt -s nullglob`, `is_uint` validation, `max_brightness` clamping, and unified `save_and_blank_sysfs` / `restore_sysfs` helpers.

### Finding 4 (Medium): `acpid Service` status double-output bug & socket/path activation visibility
- **Observation:** The original check `$(systemctl is-active acpid.service 2>/dev/null || echo inactive)` outputs `inactive` twice whenever `acpid.service` is stopped, because `systemctl is-active` prints `inactive` to stdout *and* exits with status `3` (or `4`). Furthermore, Ubuntu triggers `acpid.service` via `acpid.socket` and `acpid.path`.
- **Impact:** Stopped `acpid` causes broken multi-line `status` output, and socket/path standby state is indistinguishable from a disabled service.
- **Fix Applied:** Replaced with `get_acpid_status` checking `acpid.service`, `acpid.socket`, and `acpid.path` cleanly without duplicating `"inactive"`.

### Finding 5 (Low): `systemd-logind` reload fallback, `sudo` path resolution, and duplicated `gsettings` logic
- **Observation:**
  1. `systemctl reload systemd-logind` works on modern systemd (`Type=notify-reload`), but fails on older systemd releases where `SIGHUP` is required (and `restart` must be avoided as it terminates active desktop sessions).
  2. `exec sudo "$0" "$@"` relies on `$0` rather than a canonical path.
  3. `SUDO_USER` D-Bus session resolution was duplicated across `bin/lid-control`, `install.sh`, and `uninstall.sh`.
  4. *Operational note:* `pgrep -x gnome-shell` in `lid_backlight.sh` checks process-wide `gnome-shell` (which also matches GDM's greeter if no desktop session is active on the current VT), and direct root shells without `SUDO_USER` cannot access a user's D-Bus `gsettings`.
- **Fix Applied:** Added `reload_logind` (`systemctl reload ... || systemctl kill -s HUP ...`), `exec sudo "$(realpath "$0")" "$@"`, and consolidated `gsettings` calls into `run_gsettings` in `bin/lid-control` (with `install.sh` and `uninstall.sh` delegating to `lid-control on` / `lid-control off`).

### Finding 6 (Low): Unbounded log growth & stale `.bak-*` host artifacts
- **Observation:** `/var/log/lid_backlight.log` had no `logrotate` configuration, and `/usr/local/bin/` and `/etc/acpi/` on the host contained timestamped `.bak-*` files from prior updates.
- **Fix Applied:** Added `config/lid-control.logrotate` (installed to `/etc/logrotate.d/lid-control`), `--clean-backups` / `--no-enable` options in `install.sh`, and `--purge` option in `uninstall.sh`.
