# zigup

`zigup` keeps two official Zig channels ready on Windows and Linux:

- `zig` is the latest stable Zig release.
- `zig-dev` is the current `master` development release from ziglang.org.

`zigup update` reads the official release index, downloads both archives,
verifies their published SHA-256 hashes, installs them side by side, and updates
the command shims and persistent user `PATH`.

This project requires Zig `0.17.0-dev.1902+896bd9e15` or a compatible newer
development build.

## Build

```powershell
zig-dev build
zig-dev build test
```

The executable is written to `zig-out/bin/zigup.exe` on Windows or
`zig-out/bin/zigup` on Linux. Before `zig-dev` has been provisioned, the same
commands can be run with any compatible Zig development compiler by replacing
`zig-dev` with its command name. After the first successful update, use
`zig-dev` for this project because `zig` intentionally tracks the stable
compiler.

## Quick start on Windows

```powershell
# First-time bootstrap: `zig` must be a compatible development build.
zig build
.\zig-out\bin\zigup.exe update
zig version
zig-dev version
.\zig-out\bin\zigup.exe current
```

The updater adds the directory printed by `zigup env` to your user `PATH`. By
default it is:

```text
%LOCALAPPDATA%\zigup\bin
```

When an older standalone Zig distribution occurs earlier than the user `PATH`,
the Windows updater preserves that directory beside its original location and
replaces it with a junction to the managed stable release. It only does this
after verifying the directory contains a Zig distribution and no unrelated
top-level entries; shared package-manager or tools directories are left
untouched. The backup name starts with the original directory name followed by
`.zigup-backup-<version>`.

If a shared machine-level tools directory contains `zig.exe`, zigup reports
that it skipped the bridge. Move the directory printed by `zigup env` ahead of
that entry manually; zigup will not move or replace a shared directory.

## Commands

- `zigup update` installs the latest official stable and `master` dev releases.
- `zigup add <version> <zig-executable>` registers an existing installation.
- `zigup list` lists registered versions and marks the active one.
- `zigup use <version>` selects a version and regenerates the shim.
- `zigup current` displays the selected version and executable.
- `zigup where <version>` displays a registered executable path.
- `zigup remove <version>` removes registration metadata. It never deletes the
  Zig installation itself, and refuses to remove a version that is currently
  selected for either channel.
- `zigup home` displays the data directory.
- `zigup env` displays the shim directory to add to `PATH`.

Set `ZIGUP_HOME` to override the default data directory. The default is
`%LOCALAPPDATA%\zigup` on Windows, `$XDG_DATA_HOME/zigup` when available on
Unix-like systems, or `$HOME/.local/share/zigup` otherwise.

## Platform-specific updaters

Each operating system runs its own specialized updater implementation:

- **Windows** runs an embedded PowerShell script (`src/windows_update.ps1`).
  Downloads use `curl.exe`, archives are `.zip`, and when an older standalone
  Zig distribution occurs earlier than the user `PATH`, the updater preserves
  that directory beside its original location and replaces it with a junction
  to the managed stable release. Shared directories are never bridged. The
  backup name starts with the original directory name followed by
  `.zigup-backup-<version>`.
- **Linux** runs the native updater (`src/updater_posix.zig`). Downloads use
  `curl` when available and fall back to `wget`; archives are `.tar.xz` and
  are extracted with the system `tar`. Archives are hashed in-process with
  SHA-256 before installation. The updater installs executable `zig` and
  `zig-dev` shell shims, copies the zigup binary next to them, and appends a
  guarded block to `~/.profile` so the shim directory is on the `PATH` for
  future login shells.

Every download URL is restricted to `https://ziglang.org/`, and installation
stops if the archive hash differs from the SHA-256 value in the official
index.

## Storage layout

```text
zigup/
|-- current
|-- current-dev
|-- store.lock
|-- update.lock
|-- bin/
|   |-- zig.cmd        (Windows)
|   |-- zig-dev.cmd    (Windows)
|   |-- zig            (Linux)
|   |-- zig-dev        (Linux)
|   `-- zigup[.exe]
|-- downloads/
|-- toolchains/
`-- versions/
    `-- <version>.path
```
