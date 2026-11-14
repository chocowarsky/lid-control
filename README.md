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
- **Non-Desktop Fallback**: Gracefully falls back to direct sysfs backlight control when running outside a graphical session (TTY / headless).

---

## Architecture

1. **`systemd-logind` Drop-in (`/etc/systemd/logind.conf.d/99-lid-ignore.conf`)**:
   Configures `HandleLidSwitch=ignore`, `HandleLidSwitchExternalPower=ignore`, and `HandleLidSwitchDocked=ignore` to prevent OS suspension when the lid closes.
2. **GNOME Power Policy**:
   Sets `org.gnome.settings-daemon.plugins.power` `lid-close-ac-action` and `lid-close-battery-action` to `'blank'` so Mutter powers off the display panel cleanly via DPMS while keeping the brightness setting intact.
3. **ACPI Event Rule (`/etc/acpi/events/lid-state`)**:
   Listens for kernel `button/lid.*` hardware events via `acpid`.
4. **Hardware Action Script (`/etc/acpi/lid_backlight.sh`)**:
   Reads physical lid status from `/proc/acpi/button/lid/*/state`:
   - **`closed`**: Saves current keyboard brightness (0–3) to `/var/lib/lid-control/last_kbd_brightness` and turns off keyboard LEDs. Falls back to sysfs screen power-off only if no desktop compositor is active.
   - **`open`**: Restores keyboard LEDs to their exact previous level (0, 1, 2, or 3) and unblanks fallback devices.
5. **CLI Utility (`/usr/local/bin/lid-control`)**:
   Instant terminal management for inspecting status, toggling modes, or reading hardware event logs.

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

---

## Usage

Once installed, the `lid-control` CLI is available system-wide:

```bash
# Inspect current mode, acpid status, lid state, and backlight levels
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
acpid Service     : active
Lid Hardware State: open
Display Backlight : 185166 / 400000
Keyboard Backlight: 1 / 3
Saved Kbd Preset  : Level 1 (persistent in /var/lib/lid-control)
Logind Override   : Active (/etc/systemd/logind.conf.d/99-lid-ignore.conf)
GNOME Lid AC      : 'blank'
GNOME Lid Battery : 'blank'
```

---

## Uninstallation

To cleanly remove all system hooks, scripts, and restore default Ubuntu suspend behavior:

```bash
sudo ./uninstall.sh
```

---

## License

[MIT License](LICENSE) © 2026 Bagus Wijaya (Warsky)
