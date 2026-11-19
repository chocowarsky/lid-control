# Lid Control (`lid-control`)

A lightweight, robust Linux power utility that turns off both the **display panel** and **keyboard backlight** when the laptop lid is closed — **without suspending the system** and **with full brightness preset preservation**.

Designed for always-on laptop setups (running background AI agents, Docker containers, long downloads, compilation, or SSH/VPN tunnels) in clamshell mode.

---

## Why `acpid` + GNOME Blank + `systemd-logind`?

Desktop-level solutions (such as GNOME Shell extensions) suffer from Wayland permission boundaries and inability to switch off hardware keyboard LEDs. On the other hand, naive ACPI scripts that force `0` directly into sysfs backlight break GNOME Mutter's internal backlight range validation (`min: 4000`), desyncing the user's brightness slider.

**`lid-control`** coordinates all layers cleanly:
- **Zero CPU/RAM overhead** (~250 KB resident `acpid` daemon).
- **Exact Preset Preservation**: Display brightness slider is 100% untouched by delegating screen blanking to GNOME's native DPMS (`'blank'`), eliminating Mutter out-of-range clamp bugs.
- **Full Keyboard LED Preset Support**: Directly powers down keyboard LEDs (`/sys/class/leds/*kbd_backlight`) via `acpid` and restores the exact saved level (including level `0` / OFF) across lid cycles and reboots.
- **Persistent State Storage**: Stores state in `/var/lib/lid-control/` instead of volatile RAM (`/tmp`), surviving reboots and system cleanup.
- **Inactive-Mode Safety Guard**: Skips ACPI sysfs changes whenever `lid-control` mode is `off` (`99-lid-ignore.conf` absent), preventing races with `systemd-logind` suspend/resume.
- **Non-Desktop Fallback**: Gracefully falls back to direct sysfs backlight control when running outside a graphical session (TTY / headless).

---

## Architecture

1. **`systemd-logind` Drop-in (`/etc/systemd/logind.conf.d/99-lid-ignore.conf`)**:
   Configures `HandleLidSwitch=ignore`, `HandleLidSwitchExternalPower=ignore`, and `HandleLidSwitchDocked=ignore` to prevent OS suspension when the lid closes.
2. **GNOME Power Policy**:
   Sets `org.gnome.settings-daemon.plugins.power` `lid-close-ac-action` and `lid-close-battery-action` to `'blank'` so Mutter powers off the display panel cleanly via DRM/DPMS while keeping the brightness setting intact.
3. **ACPI Event Rule (`/etc/acpi/events/lid-state`)**:
   Listens for kernel `button/lid.*` hardware events via `acpid`.
4. **Hardware Action Script (`/etc/acpi/lid_backlight.sh` ← `scripts/lid_backlight.sh`)**:
   Verifies `99-lid-ignore.conf` is active, then reads physical lid status from `/proc/acpi/button/lid/*/state`:
   - **`closed`**: Saves current keyboard brightness (0–3) to `/var/lib/lid-control/last_kbd_brightness` and turns off keyboard LEDs. Falls back to sysfs screen power-off only if no desktop compositor is active.
   - **`open`**: Restores keyboard LEDs to their exact previous level (0, 1, 2, or 3) and unblanks fallback devices.
5. **CLI Utility (`/usr/local/bin/lid-control` ← `bin/lid-control`)**:
   Instant terminal management for inspecting status (including DRM panel `enabled`/DPMS state and `acpid` unit/socket/path status), toggling modes, or reading hardware event logs.
6. **Log Rotation (`/etc/logrotate.d/lid-control` ← `config/lid-control.logrotate`)**:
   Rotates `/var/log/lid_backlight.log` weekly (keeps 4 compressed archives).

See [AUDIT.md](AUDIT.md) for the full technical audit and changelog of security/reliability fixes.

---

## Installation

### Prerequisites
- Ubuntu / Debian-based Linux distribution (with `systemd` and `apt`)
- `acpid` package (automatically installed by `install.sh` if absent)

### Quickstart

```bash
git clone https://github.com/chocowarsky/lid-control.git
cd lid-control
chmod +x install.sh uninstall.sh
sudo ./install.sh
```

Optional installer flags:
- `sudo ./install.sh --no-enable`: Installs files and logrotate policy without enabling `lid-control on` immediately.
- `sudo ./install.sh --keep-backups`: Preserves any existing `*.bak-*` backup files in `/usr/local/bin` and `/etc/acpi` (by default, `install.sh` removes stale `*.bak-*` backups).

---

## Usage

Once installed, the `lid-control` CLI is available system-wide:

```bash
# Inspect current mode, acpid status, lid state, DRM panel/DPMS, and backlight levels
lid-control status

# View recent ACPI lid open/close event logs (/var/log/lid_backlight.log)
lid-control log

# Enable Screen-Off mode (display & keyboard off on lid close, no suspend)
sudo lid-control on

# Revert to standard system suspend behavior on lid close
sudo lid-control off
```

### Example Status Output

```text
=== Laptop Lid Control Status (acpid + systemd-logind) ===
Mode Status       : ACTIVE (Screen Blank & Keyboard Off, No Suspend)
acpid Service     : active (socket: active, path: active)
Lid Hardware State: closed
Panel State       : disabled (DPMS: Off) [card1-eDP-1]
Display Backlight : 132605 / 400000
Keyboard Backlight: 0 / 3
Saved Kbd Preset  : Level 0 (persistent in /var/lib/lid-control)
Logind Override   : Active (/etc/systemd/logind.conf.d/99-lid-ignore.conf)
GNOME Lid AC      : 'blank'
GNOME Lid Battery : 'blank'
```

---

## Testing & CI Audit

Run the automated audit and behavioral regression suite locally (uses an isolated non-root `LID_CONTROL_SYSROOT` without modifying system hardware files):

```bash
./tests/test_lid_control.sh
```

Every push and pull request to `main` also runs `ShellCheck` and `./tests/test_lid_control.sh` via [`.github/workflows/audit.yml`](.github/workflows/audit.yml).

---

## Uninstallation

To cleanly remove all system hooks, scripts, logrotate rule, and restore default Ubuntu suspend behavior:

```bash
sudo ./uninstall.sh
```

Pass `--purge` to also delete `/var/log/lid_backlight.log*`:

```bash
sudo ./uninstall.sh --purge
```

---

## License

[MIT License](LICENSE) © 2026 Bagus Wijaya (Warsky)
