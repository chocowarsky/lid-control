# Lid Control (`lid-control`)

A lightweight, hardware-level Linux power utility that turns off both the **display panel backlight** and **keyboard backlight** when the laptop lid is closed — **without suspending the system**.

Designed for always-on laptop setups (running background AI agents, Docker containers, long downloads, compilation, or SSH/VPN tunnels) in clamshell mode with zero desktop/Wayland extension overhead.

---

## Why `acpid` + `systemd-logind`?

Desktop-level solutions (such as GNOME Shell extensions or user-space D-Bus daemons) suffer from Wayland permission boundaries, compositor restarts, and inability to directly switch off hardware keyboard LEDs.

**`lid-control`** operates directly at the kernel ACPI and `sysfs` level:
- **Zero CPU/RAM overhead** (~250 KB resident `acpid` daemon).
- **Works across any desktop or headless session** (Wayland, X11, or TTY).
- **Direct hardware power cut**: Writes `0` directly to `/sys/class/backlight/*/brightness` and `/sys/class/leds/*kbd_backlight/brightness`.
- **State preservation**: Automatically saves exact display and keyboard brightness levels before closing and restores them immediately when the lid opens.

---

## Architecture

1. **`systemd-logind` Drop-in (`/etc/systemd/logind.conf.d/99-lid-ignore.conf`)**:
   Configures `HandleLidSwitch=ignore`, `HandleLidSwitchExternalPower=ignore`, and `HandleLidSwitchDocked=ignore` to prevent OS suspension when the lid closes, while reloading cleanly without dropping active user sessions.
2. **GNOME Power Policy**:
   Sets `org.gnome.settings-daemon.plugins.power` `lid-close-ac-action` and `lid-close-battery-action` to `'nothing'` to avoid desktop-layer sleep conflicts.
3. **ACPI Event Rule (`/etc/acpi/events/lid-state`)**:
   Listens for kernel `button/lid.*` hardware events via `acpid`.
4. **Hardware Action Script (`/etc/acpi/lid_backlight.sh`)**:
   Reads physical lid status from `/proc/acpi/button/lid/*/state`:
   - **`closed`**: Saves current display & keyboard brightness to `/tmp/last_display_brightness` and `/tmp/last_kbd_brightness`, then sets both hardware brightness nodes to `0`.
   - **`open`**: Restores both backlights to their previously saved levels (or sane defaults if no state file exists).
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
Mode Status       : ACTIVE (Screen & Keyboard Off, No Suspend)
acpid Service     : active
Lid Hardware State: open
Display Backlight : 200000 / 400000
Keyboard Backlight: 1 / 3
Logind Override   : Active (/etc/systemd/logind.conf.d/99-lid-ignore.conf)
GNOME Lid AC      : 'nothing'
GNOME Lid Battery : 'nothing'
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
