"""Optional Linux integration using REAL GNOME gsettings and libproxy.

Requires gsettings, the libproxy `proxy` CLI, and curl or wget on PATH. This
does not modify the desktop: every settings command and child uses a private
GSETTINGS_BACKEND=keyfile and XDG_CONFIG_HOME under TemporaryDirectory.

python3 tests/linux_proxy_libproxy.py --driver zig-out/bin/zigup-proxy-test
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.parse

from proxy_fixture import Fixture, PAYLOAD


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", required=True)
    args = parser.parse_args()
    if not sys.platform.startswith("linux"):
        parser.error("this optional integration test requires Linux")
    for command in ("gsettings", "proxy"):
        if not shutil.which(command):
            parser.error(f"optional dependency {command!r} is not available on PATH")
    tools = [(kind, shutil.which(kind)) for kind in ("curl", "wget") if shutil.which(kind)]
    if not tools:
        parser.error("curl or wget is required")
    driver = str(Path(args.driver).resolve())
    cleaned = {"http_proxy", "https_proxy", "all_proxy", "ftp_proxy", "no_proxy", "zigup_proxy",
               "px_debug", "px_force_config", "g_messages_debug"}
    with tempfile.TemporaryDirectory(prefix="zigup-real-libproxy-") as directory, Fixture() as fixture:
        temporary = Path(directory)
        environ = {key: value for key, value in os.environ.items() if key.lower() not in cleaned}
        environ.update({"HOME": directory, "GSETTINGS_BACKEND": "keyfile",
                        "XDG_CONFIG_HOME": str(temporary / "config"),
                        "XDG_CURRENT_DESKTOP": "GNOME"})
        port = str(urllib.parse.urlsplit(fixture.good).port)

        def setting(schema, key, value):
            subprocess.run(["gsettings", "set", schema, key, value], env=environ,
                           check=True, capture_output=True, timeout=5)

        for schema in ("org.gnome.system.proxy.http", "org.gnome.system.proxy.https"):
            setting(schema, "host", "'127.0.0.1'")
            setting(schema, "port", port)
        setting("org.gnome.system.proxy", "ignore-hosts", "[]")
        setting("org.gnome.system.proxy", "use-same-proxy", "false")
        setting("org.gnome.system.proxy.http", "use-authentication", "false")

        cases = 0
        for kind, executable in tools:
            def download(name, paths):
                command = [driver, kind, executable]
                outputs = []
                for i, path in enumerate(paths):
                    output = temporary / f"{kind}-{name}-{i}.download"
                    outputs.append(output)
                    command += [fixture.origin + path, str(output)]
                start = len(fixture.events)
                result = subprocess.run(command, env=environ, capture_output=True, text=True, timeout=45)
                if result.returncode:
                    raise AssertionError(f"{kind}/{name} failed: {result.stdout}\n{result.stderr}")
                assert all(output.read_bytes() == PAYLOAD for output in outputs), "incorrect payload"
                assert not list(temporary.glob("*.zigup-proxy-*")), "download temporary leaked"
                return fixture.events[start:]

            setting("org.gnome.system.proxy", "mode", "'manual'")
            events = download("native-gnome-manual", ["/payload"])
            assert sum(event["kind"] == "good" for event in events) == 1
            cases += 1
            print(f"PASS {kind}/native-gnome-manual", flush=True)

            setting("org.gnome.system.proxy", "mode", "'auto'")
            setting("org.gnome.system.proxy", "autoconfig-url", repr(fixture.origin + "/pac"))
            events = download("native-pac-per-url", ["/index.json", "/archive"])
            proxied = [event for event in events if event["kind"] == "good"]
            assert len(proxied) == 1 and str(proxied[0]["path"]).endswith("/index.json"), events
            assert any(event["kind"] == "origin" and event["path"] == "/pac" for event in events)
            cases += 1
            print(f"PASS {kind}/native-libproxy-pac-per-url", flush=True)

            for invalid in ("pac-invalid", "pac-fail"):
                setting("org.gnome.system.proxy", "autoconfig-url", repr(fixture.origin + "/" + invalid))
                events = download(invalid, ["/payload"])
                assert not any(event["kind"] == "good" for event in events), events
                cases += 1
                print(f"PASS {kind}/native-libproxy-{invalid}-fallback", flush=True)

            setting("org.gnome.system.proxy", "mode", "'none'")
            events = download("native-disabled", ["/payload"])
            assert not any(event["kind"] == "good" for event in events), events
            cases += 1
            print(f"PASS {kind}/native-gnome-disabled", flush=True)

        assert (temporary / "config" / "glib-2.0" / "settings" / "keyfile").is_file(), "settings were not isolated in the expected private keyfile"
        print(f"Native GNOME/libproxy integration: {cases} cases passed", flush=True)


if __name__ == "__main__":
    main()
