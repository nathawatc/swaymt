# Sway Monitor Toggle

Switch between internal, external, and extended displays in Sway, or choose a
mode from a Noctalia picker.

## Requirements

- Linux and Sway.
- Noctalia for the optional display picker.
- Zig 0.16.x to build from source.

## Build from Source

```sh
zig build -Doptimize=ReleaseFast
```

The executable is `zig-out/bin/swaymt`. For a debug build, use `zig build`.
BrightStay support is not included by default.

## Usage

Replace these connector names with your own:

```sh
swaymt -i eDP-1 -e HDMI-A-1
swaymt -i eDP-1 -e HDMI-A-1 internal
swaymt -i eDP-1 -e HDMI-A-1 external
swaymt -i eDP-1 -e HDMI-A-1 extended
swaymt -i eDP-1 -e HDMI-A-1 dmenu
```

- **Internal:** use only the internal display.
- **External:** use only the external display.
- **Extended:** enable both displays using the layout in your Sway configuration.
  This is the default when no mode is supplied.
- **Dmenu:** choose Internal, External, or Extended through Noctalia. Cancelling
  leaves your displays unchanged.

Both connectors must be connected, even if one is currently disabled. Display
switching reloads your Sway configuration, including its `exec_always` commands.
The picker connects directly to Noctalia; no launcher fallback is used.

Long options are also supported:

```sh
swaymt --internal eDP-1 --external HDMI-A-1 dmenu
swaymt --help
```

For a Sway key binding:

```text
bindsym $mod+p exec swaymt -i eDP-1 -e HDMI-A-1 dmenu
```

### L22i-40 Setup

BrightStay reapplies the monitor's user color preset after waking to work around
firmware that resets color settings and brightness. It is hardware-specific,
not a general brightness controller.

Run `swaymt brightstay` to apply the workaround manually. It is best-effort:
no usable monitor or a failed hardware operation exits successfully (code `0`).
Cache failures may warn but do not turn the command into a failure.

The `l22i-swaymt` package provides:

- The `i2c` group and group read/write permissions for I²C devices.
- Automatic loading of `i2c-dev` on boot.
- A group-writable cache directory at `/var/cache/brightstay/`.
- Optional services for login and resume; neither is enabled automatically.

To apply the workaround automatically:

```sh
systemctl --user enable brightstay.service
sudo systemctl enable brightstay-resume.service
```
