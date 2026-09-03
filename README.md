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

## Automatic proxy selection

Both the release index and toolchain archives use the same proxy-aware
downloader. No additional flags are needed: `zigup update` automatically
tries the following routes and switches when a network route fails:

1. Environment proxies: for HTTPS downloads, `https_proxy` / `HTTPS_PROXY`,
   followed by `all_proxy` / `ALL_PROXY`. Lowercase takes precedence on Linux.
2. Enabled system proxies. Windows reads current-user Internet settings
   (including PAC/WPAD) and WinHTTP machine settings. Linux reads GNOME manual
   settings with `gsettings`, and can also use the optional libproxy `proxy`
   command for desktop/PAC/WPAD resolution.
3. A direct connection.

The successful route is preferred for later downloads in the same update, but
only when the allowed route plan is unchanged for that URL. PAC rules are
resolved per URL, including transitions from direct to proxied connections.
Disabled Windows proxy settings are ignored even if an old address is retained.
`no_proxy` / `NO_PROXY` and system bypass rules are respected, including domain,
IP, port and CIDR exclusions. Proxy configuration is never written back to the
system or your shell environment.

Use `ZIGUP_PROXY` to override automatic selection:

| Value | Behavior |
| --- | --- |
| unset or `auto` | Environment proxy, system proxy, then direct fallback |
| `direct` | Direct only; ignore all proxy configuration |
| a proxy URL | Use only that proxy, even if `NO_PROXY` matches; never fall back to direct |

For example, in PowerShell:

```powershell
$env:ZIGUP_PROXY = 'http://127.0.0.1:7890'
zigup update
Remove-Item Env:ZIGUP_PROXY  # Restore automatic selection in this shell.
```

Or for one Linux invocation:

```sh
ZIGUP_PROXY=direct zigup update
ZIGUP_PROXY=http://127.0.0.1:7890 zigup update
```

HTTP, HTTPS and SOCKS4/4a/5/5h proxy URLs are supported with curl. Wget supports
ordinary HTTP proxies (including CONNECT to HTTPS destinations); TLS-to-proxy
and SOCKS require curl. In automatic mode unsupported routes are skipped with a
diagnostic; a forced unsupported proxy fails without connecting directly.
Linux PAC/WPAD requires the optional libproxy helper; if it is unavailable,
zigup reports this for GNOME automatic mode and tries the remaining routes.

Proxy discovery, connection attempts and stalled transfers have time limits.
Logs identify the route source without printing proxy credentials. Downloader
configuration files are disabled so they cannot override the selected route.
TLS certificate verification and archive SHA-256 checks remain enabled;
hash/index-content validation failures and local write errors stop the update instead of being
treated as proxy outages. Failed attempts do not replace an existing download.

System integration follows the [Windows WinHTTP proxy APIs](https://learn.microsoft.com/en-us/windows/win32/winhttp/setting-wininet-proxy-configurations-in-winhttp)
and the [libproxy resolution contract](https://libproxy.github.io/libproxy/method.ProxyFactory.get_proxies.html).

## Platform-specific updaters

Each operating system runs its own specialized updater implementation:

- **Windows** runs an embedded PowerShell script (`src/windows_update.ps1`).
  Its proxy helper (`src/windows_proxy.ps1`) is embedded in the same executable;
  no script sidecar is needed. Downloads use `curl.exe`, archives are `.zip`,
  and when an older standalone
  Zig distribution occurs earlier than the user `PATH`, the updater preserves
  that directory beside its original location and replaces it with a junction
  to the managed stable release. Shared directories are never bridged. The
  backup name starts with the original directory name followed by
  `.zigup-backup-<version>`.
- **Linux** runs the native updater (`src/updater_posix.zig`). Downloads use
  the shared native routing module (`src/proxy_posix.zig`) with `curl` when
  available and `wget` otherwise; archives are `.tar.xz` and
  are extracted with the system `tar`. Archives are hashed in-process with
  SHA-256 before installation. The updater installs executable `zig` and
  `zig-dev` shell shims, copies the zigup binary next to them, and appends a
  guarded block to `~/.profile` so the shim directory is on the `PATH` for
  future login shells.

Every download URL is restricted to `https://ziglang.org/`, and installation
stops if the archive hash differs from the SHA-256 value in the official
index.

## Proxy regression tests

```sh
zig-dev build test
zig-dev build test-proxy
```

`test` includes proxy parsing/routing unit tests and, on Windows, the Windows
PowerShell 5.1 test suite. `test-proxy` additionally requires Python 3 (`py -3`
on Windows, `python3` on Linux) and runs real downloaders against temporary
loopback origin/proxy servers. It does not change desktop proxy settings,
registry keys, PATH, profiles, certificate stores, or installed toolchains.

An optional live smoke test fetches the official HTTPS index through a
loopback CONNECT proxy:

```powershell
py -3 tests/proxy_integration.py --windows --live
```

```sh
zig-dev build proxy-test-driver
python3 tests/proxy_integration.py --driver zig-out/bin/zigup-proxy-test --live
```

When GNOME `gsettings` and the libproxy `proxy` helper are available, the
optional native desktop test uses a private keyfile settings backend rather
than modifying your desktop configuration:

```sh
python3 tests/linux_proxy_libproxy.py --driver zig-out/bin/zigup-proxy-test
```

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
