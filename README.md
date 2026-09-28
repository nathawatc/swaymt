# swaymt

A small native Zig monitor switcher for Sway, inspired by Windows + P.
It talks directly to Sway and Noctalia over Unix sockets: no shell scripts,
child processes, `swaymsg`, or `noctalia dmenu` invocation.

## Requirements and build

- Linux and Zig 0.16.0.
- Sway, with `SWAYSOCK` exported in the calling environment.
- Noctalia with its dmenu socket available, for the optional picker.

```sh
zig build
zig build -Doptimize=ReleaseFast
zig build test
```

The executable is `zig-out/bin/swaymt`. There are no third-party dependencies.
BrightStay is excluded by default. Debug is the default optimization mode;
`ReleaseSmall` is also available when binary size matters most.

## Usage

```sh
swaymt -i eDP-1 -e HDMI-A-1
swaymt -i eDP-1 -e HDMI-A-1 internal
swaymt -i eDP-1 -e HDMI-A-1 external
swaymt -i eDP-1 -e HDMI-A-1 extended
swaymt --internal eDP-1 --external HDMI-A-1 dmenu
```

Both output names are required for display modes. The default mode is `extended`.
Use `swaymt --help` for options.

- `internal`: reload configuration, enable and power on internal, disable external.
- `external`: reload configuration, enable and power on external, disable internal.
- `extended`: reload configuration, enable and power on both. Positions, modes,
  scaling, and other layout settings come from your Sway configuration.

Both configured connectors must appear in a single `GET_OUTPUTS` reply, including
currently disabled outputs. Validation happens before changing anything. Each
command is acknowledged before proceeding; failures stop subsequent commands.
Commands already applied are not rolled back. Reload has Sway's normal config
side effects, including `exec_always` commands configured by you.

### Noctalia picker

`dmenu` connects directly to
`$XDG_RUNTIME_DIR/noctalia-dmenu-$WAYLAND_DISPLAY.sock`. Both environment variables
must be set. It sends the `Display:` prompt and the choices `Internal`, `External`,
and `Extended`, then closes its write side and waits for a selection. Cancellation
exits successfully without contacting Sway. There are no fallback launchers.

### Optional BrightStay

```sh
zig build -Dbrightstay=true -Doptimize=ReleaseFast
zig build test -Dbrightstay=true
swaymt brightstay
```

This hardware-specific workaround is for the Lenovo L22i-40 firmware issue that
resets user color settings after waking. It reapplies **color preset VCP `0x14`,
value `11`**; it does not write a brightness VCP. A BrightStay-enabled build also
adds `BrightStay` to the picker. The standalone command needs neither monitor
arguments nor a Sway/Wayland session.

BrightStay reads EDID through Linux I²C and matches product code `26542` with a
nonzero manufacturer field. It intentionally does not require a specific
manufacturer, serial number, EDID header, or checksum. As in the original
workaround, only bus numbers 0–255 are considered. Access to the matching
`/dev/i2c-*` device and an available `i2c-dev` driver are required. Grant device
access narrowly; do not run the whole desktop utility as root.

The cache is `/var/cache/brightstay/monitor.cache`. Provision
`/var/cache/brightstay/` with write access for the invoking user if caching is
wanted. The cached bus is revalidated by reading EDID and applying the preset;
missing, malformed, stale, or failed cached entries fall back to scanning
`/sys/class/i2c-dev`. Cache updates use exclusive temporary files in the same
directory, file sync, atomic rename, and directory sync. Failed writes clean up
the temporary file. Cache permissions are `0664`.

The workaround remains best-effort: no usable monitor is a successful no-op.
Cache failures warn without undoing a successful preset operation. BrightStay is
optional and intended for this particular setup, not general monitor control.

## Implementation and tests

- `src/main.zig`: CLI, environment, and orchestration.
- `src/sway.zig`: native i3/Sway IPC and monitor commands.
- `src/dmenu.zig`: Noctalia socket protocol.
- `src/brightstay.zig`: optional I²C, EDID, DDC/CI, and cache.

Startup uses borrowed arguments/environment and bounded stack buffers, not heap
allocation. Sway replies and JSON scratch space are each limited to 64 KiB;
connector names to 255 bytes. Names are quoted for Sway, not a shell. Selectors,
variables, control characters, and backslashes are rejected rather than risk
ambiguous command parsing. Noctalia selections are limited to 64 bytes.

Tests use socket pairs, byte fixtures, injected hardware behavior, and temporary
directories only. They never contact a desktop session, real I²C devices, system
I²C directories, or the real BrightStay cache. Run tests with both feature settings
as shown above. Physical monitor behavior requires separate manual verification.
