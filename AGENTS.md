# Developer Instructions

## Scope and Architecture

`swaymt` is a Linux-only, native Zig 0.16 application. Keep the implementation
small, fast, and dependency-free. README.md is for installation and everyday
usage; keep protocol details, implementation constraints, and test guidance here.

Maintain these module boundaries:

- `src/main.zig`: CLI parsing, environment lookup, and orchestration.
- `src/sway.zig`: i3/Sway IPC, connector validation, and output commands only.
- `src/dmenu.zig`: Noctalia dmenu Unix socket protocol only.
- `src/brightstay.zig`: optional I²C, EDID, DDC/CI, and cache only.

Do not introduce shell scripts, child processes, `swaymsg`, `noctalia dmenu`
invocations, fallback launchers, or general-purpose IPC/DDC frameworks into the
runtime. PKGBUILD is build-time packaging, not part of the runtime.

The supplied `hyprmt/` tree is a behavioral reference, not a build dependency.
Do not change or package it as part of swaymt.

## Startup and Build Constraints

Use borrowed arguments/environment and bounded stack buffers. The entry point
uses `std.process.Init.Minimal` to avoid allocator and I/O-runtime initialization.
There are no heap allocations in normal startup. JSON uses typed stdlib parsing
with a fixed-buffer allocator; unknown fields are ignored.

- Sway reply payload and JSON scratch space: 64 KiB each.
- Output names: at most 255 bytes.
- Noctalia selected line: at most 64 bytes.
- Unix socket paths must fit the Linux `sockaddr_un` path field.

BrightStay is excluded by default and conditionally imported at compile time.
Normal binaries must not contain hardware scanning or BrightStay cache code.
Release builds strip debug symbols. Preserve the native Zig build system and
avoid third-party dependencies.

## Display Switching

Default mode: `extended`. Both output arguments are required except for standalone
`brightstay` and help. The dmenu CLI mode still requires both names.

Connect to `$SWAYSOCK` directly. Frame requests with `i3-ipc`, native-endian u32
payload length, and native-endian u32 message type. Implement only `GET_OUTPUTS`
and `RUN_COMMAND`. Handle partial I/O, EOF, invalid framing, and failed replies.
Use `MSG_NOSIGNAL` for socket writes.

Query outputs once, including disabled outputs, and validate both configured
names before changing anything. Acknowledge reload before output commands.
Enable and power on the desired output before disabling the other. Extended mode
reloads the configured layout, then enables and powers on both outputs without
inventing positions or modes. Each command is separately acknowledged. Command
acceptance is not proof of physical monitor state; failures stop further commands
but do not roll back previous commands. Reload retains Sway's normal side effects,
including configured `exec_always` commands.

Quote names for Sway, not for a shell. Sway's parsing stages disagree about
backslash escaping, so reject backslashes rather than risk command injection.
Also reject selectors, variable expansion, control characters, empty names, and
identical internal/external names. Preserve tests for quoting and separator
injection before changing these rules.

## Noctalia Protocol

Socket: `$XDG_RUNTIME_DIR/noctalia-dmenu-$WAYLAND_DISPLAY.sock`.
The CLI constructs the socket path and request. Send the prompt line, followed
by newline-separated choices, then shut down the write side to signal EOF.
Read the first selected line, accepting EOF without a final newline. Empty response
or empty line means cancellation. Trim surrounding whitespace when mapping the
selection to a CLI mode. Cancellation must return successfully without Sway IPC.

Choices are `Internal`, `External`, and `Extended`; include `BrightStay` only when
compiled with that feature. Do not invoke the Noctalia executable.

## BrightStay Behavior

This is a hardware-specific, best-effort L22i-40 workaround, not generic monitor
control. Match the original behavior:

- Read 128-byte EDID through Linux I²C.
- Match little-endian product code `26542` and a nonzero manufacturer field.
- Do not add manufacturer identity, serial, EDID header, or checksum requirements.
- Reapply the **color preset**, VCP code `0x14`, value `11`; do not call this a
  brightness VCP operation.
- The DDC/CI Set VCP packet is `51 84 03 14 00 0b a7`; the checksum includes the
  destination address `0x6e`.
- Read EDID at I²C address `0x50`; write DDC/CI at `0x37`, through `I2C_RDWR`.
- Consider bus numbers 0–255, matching the reference's u8 bus representation.

Cache: `/var/cache/brightstay/monitor.cache`, text `BUS:26542\n`.
Validate a cached bus through EDID and the preset operation before returning.
Missing, malformed, stale, or failed cached entries fall back to scanning
`/sys/class/i2c-dev`; open devices under `/dev/i2c-*`. A usable cached bus avoids
scanning and rewriting the cache.

After finding a working bus, write an exclusive temporary file in the cache
directory, set mode `0664`, fsync it, atomically rename it, then fsync the directory.
Clean up temporary files on failure. Never truncate the live cache in place.
A directory-sync failure after rename does not roll back the valid replacement.
Cache failures warn without undoing successful hardware work. No usable monitor
is a successful no-op. Physical application of the preset is not read back.

## Arch Packaging and System Assets

`archlinux/PKGBUILD` is a local split-package recipe, with `pkgbase=swaymt`:

- `swaymt`: default binary, no BrightStay system assets.
- `l22i-swaymt`: BrightStay-enabled binary; provides `swaymt` at the package version
  and conflicts with the default package because both install `/usr/bin/swaymt`.

Build a local snapshot as documented in README.md. Its checksum is intentionally
`SKIP` because the snapshot is mutable local input; this is not suitable as release
artifact verification. Before publishing a release recipe, use an immutable source
and a real checksum. Use baseline CPU features, separate output prefixes, and test
both feature configurations. Sway is required; Noctalia is optional for the picker.

Only the L22i variant installs these assets:

| Source                                     | Installed path                                      |
| ------------------------------------------ | --------------------------------------------------- |
| `assets/modules-load.d/swaymt.conf`        | `/usr/lib/modules-load.d/swaymt.conf`               |
| `assets/sysusers.d/swaymt.sysusers`        | `/usr/lib/sysusers.d/swaymt.conf`                   |
| `assets/tmpfiles.d/swaymt.conf`            | `/usr/lib/tmpfiles.d/swaymt.conf`                   |
| `assets/udev/rules.d/45-swaymt.rules`      | `/usr/lib/udev/rules.d/45-swaymt.rules`             |
| `assets/systemd/brightstay.service`        | `/usr/lib/systemd/user/brightstay.service`          |
| `assets/systemd/brightstay-resume.service` | `/usr/lib/systemd/system/brightstay-resume.service` |

The sysusers file must be installed with a `.conf` suffix. Create group `i2c`;
give matching `i2c-dev` devices mode `0660`, group `i2c`; load `i2c-dev` on boot.
Create `/var/cache/brightstay` as `root:i2c`, mode `2775`, so cache replacements
inherit group `i2c`. Arch's systemd package hooks process sysusers and tmpfiles.
Do not add users to groups or enable services automatically. Users opt in; group
access covers all matching I²C devices, not only the target monitor.

The user service delays three seconds at graphical login. The system service
arms before sleep and runs the workaround seven seconds after resume, using
`ExecStop` when `sleep.target` is no longer needed. It runs as root, unlike the
interactive command and user service. Keep CLI spelling lowercase `brightstay`.

## Verification

Every test must be isolated. Never access a real Sway/Noctalia session, real
`/dev/i2c-*`, host `/sys/class/i2c-dev`, `/var/cache/brightstay`, monitors, network,
or root privileges. Use socket pairs, fake byte streams, temporary directories,
and narrow injected hardware behavior. Do not make production design generic
solely for tests.

```sh
zig fmt --check build.zig build.zig.zon src
zig build
zig build test
zig build -Dbrightstay=true
zig build test -Dbrightstay=true
zig build -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseFast -Dbrightstay=true
zig build test -Doptimize=ReleaseFast -Dbrightstay=true
```

Protect framing, malformed replies, connector lookup, quoting, command ordering,
Noctalia request/EOF/cancellation, EDID matching, malformed/stale cache fallback,
cache fast path, atomic replacement, and failure cleanup. Check that default
binaries exclude BrightStay-specific paths/code and have no accidental runtime
process spawning or heap allocation.

For packaging changes, run `bash -n archlinux/PKGBUILD`,
`makepkg --printsrcinfo` from `archlinux/`, and build both package archives without
installing them. Inspect file lists, permissions, dependency metadata, and service
commands. Verify system assets only against temporary roots or offline parsers;
never reload host udev, change host groups, or enable services as part of tests.

Review the diff for unintended files, dead code, duplicate logic, and stale
compositor terminology. Do not commit or push unless explicitly requested.
