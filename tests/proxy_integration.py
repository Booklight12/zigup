"""Run real curl/wget proxy regressions without changing machine settings.

Windows: py -3 tests/proxy_integration.py --windows
Linux: python3 tests/proxy_integration.py --driver zig-out/bin/zigup-proxy-test
Add --live to also fetch the official HTTPS index through a loopback CONNECT
proxy. All other tests are offline and use only loopback sockets.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import urllib.parse

from proxy_fixture import Fixture, PAYLOAD


SCRIPT_DIR = Path(__file__).resolve().parent
PROXY_NAMES = {"http_proxy", "https_proxy", "all_proxy", "no_proxy", "zigup_proxy"}


def windows_tests(fixture: Fixture, temporary: Path, powershell: str):
    config = temporary / "fixture.json"
    config.write_text(json.dumps(fixture.config()), encoding="utf-8")
    env = {key: value for key, value in os.environ.items() if key.lower() not in PROXY_NAMES}
    subprocess.run(
        [powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
         "-File", str(SCRIPT_DIR / "windows_proxy.Integration.ps1"),
         "-FixtureFile", str(config), "-TestDirectory", str(temporary)],
        check=True, env=env, timeout=300,
    )


def linux_tests(fixture: Fixture, temporary: Path, driver: str, requested_tool: str | None):
    fake_bin = temporary / "fake-bin"
    fake_bin.mkdir()
    # Discovery is exercised through the real subprocess boundary, but the
    # desktop configuration belongs only to these test subprocesses.
    fake_gsettings = fake_bin / "gsettings"
    fake_gsettings.write_text(
        """#!/bin/sh
case "$1:$2:$3" in
  get:org.gnome.system.proxy:mode) printf "'%s'\\n" "${ZIGUP_TEST_PROXY_MODE:-none}" ;;
  get:org.gnome.system.proxy:ignore-hosts) printf '%s\\n' "${ZIGUP_TEST_PROXY_BYPASS:-[]}" ;;
  get:org.gnome.system.proxy:use-same-proxy) printf '%s\\n' "${ZIGUP_TEST_SAME_PROXY:-false}" ;;
  get:org.gnome.system.proxy.https:host) printf "'%s'\\n" "${ZIGUP_TEST_HTTPS_HOST-127.0.0.1}" ;;
  get:org.gnome.system.proxy.http:host) printf "'%s'\\n" "${ZIGUP_TEST_HTTP_HOST-127.0.0.1}" ;;
  get:org.gnome.system.proxy.https:port|get:org.gnome.system.proxy.http:port) printf '%s\\n' "${ZIGUP_TEST_PROXY_PORT:-0}" ;;
  get:org.gnome.system.proxy.socks:host) printf "''\\n" ;;
  get:org.gnome.system.proxy.socks:port) printf '0\\n' ;;
  get:org.gnome.system.proxy.http:use-authentication) printf '%s\\n' "${ZIGUP_TEST_AUTH:-false}" ;;
  get:org.gnome.system.proxy.http:authentication-user) printf "'%s'\\n" "${ZIGUP_TEST_USER:-test-user}" ;;
  get:org.gnome.system.proxy.http:authentication-password) printf "'%s'\\n" "${ZIGUP_TEST_PASSWORD:-test-password}" ;;
  *) exit 1 ;;
esac
""", encoding="utf-8"
    )
    fake_resolver = fake_bin / "proxy"
    fake_resolver.write_text(
        """#!/bin/sh
case "$ZIGUP_TEST_RESOLVER" in
  routes) case "$1" in
    */index.json) printf '%s direct://\\n' "$ZIGUP_TEST_RESOLVER_PROXY" ;;
    *) printf 'direct://\\n' ;;
  esac ;;
  reverse) case "$1" in
    */index.json) printf 'direct://\\n' ;;
    *) printf '%s direct://\\n' "$ZIGUP_TEST_RESOLVER_PROXY" ;;
  esac ;;
  direct) printf 'direct://\\n' ;;
  stall) exec sleep 30 ;;
  *) exit 1 ;;
esac
""", encoding="utf-8"
    )
    fake_gsettings.chmod(0o755)
    fake_resolver.chmod(0o755)
    (temporary / ".curlrc").write_text("zigup-invalid-test-option\n", encoding="utf-8")
    (temporary / ".wgetrc").write_text("zigup_invalid_test_option = 1\n", encoding="utf-8")
    base_env = {key: value for key, value in os.environ.items() if key.lower() not in PROXY_NAMES}
    base_env.update({"HOME": str(temporary), "CURL_HOME": str(temporary),
                     "WGETRC": str(temporary / ".wgetrc"),
                     "XDG_CONFIG_HOME": str(temporary / "xdg-config"),
                     "PATH": str(fake_bin) + os.pathsep + os.environ.get("PATH", ""),
                     "ZIGUP_TEST_RESOLVER": "off", "ZIGUP_TEST_PROXY_MODE": "none"})
    driver_path = str(Path(driver).resolve())
    tools = [requested_tool] if requested_tool else [name for name in ("curl", "wget") if shutil.which(name)]
    if not tools:
        raise RuntimeError("curl or wget is required for Linux integration tests")
    passed = 0

    for tool in tools:
        tool_path = shutil.which(tool)
        if tool_path is None:
            raise RuntimeError(f"{tool} is not installed")
        good_port = str(urllib.parse.urlsplit(fixture.good).port)
        bad_port = str(urllib.parse.urlsplit(fixture.bad).port)

        def run_case(name, settings=None, paths=None, *, succeeds=True, preserve=False):
            nonlocal passed
            env = dict(base_env)
            env.update(settings or {})
            paths = paths or ["/payload"]
            command = [driver_path, tool, tool_path]
            outputs = []
            for number, path in enumerate(paths):
                output = temporary / f"{tool}-{name}-{number}.download"
                if preserve:
                    output.write_bytes(b"previous valid file\n")
                outputs.append(output)
                command += [path if path.startswith("https://") else fixture.origin + path, str(output)]
            start = len(fixture.events)
            result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=75)
            log = result.stdout + result.stderr
            if "zigup-test-secret" in log or "test-user:" in log:
                raise AssertionError(f"{name}: credentials leaked in downloader diagnostics")
            if (result.returncode == 0) != succeeds:
                raise AssertionError(f"{tool}/{name}: unexpected exit {result.returncode}\n{log}")
            for output, path in zip(outputs, paths):
                if succeeds and not path.startswith("https://"):
                    expected = b"" if path == "/empty" else PAYLOAD
                    assert output.read_bytes() == expected, (name, "wrong download contents")
                elif not succeeds and preserve:
                    assert output.read_bytes() == b"previous valid file\n", (name, "existing file lost")
            assert not list(temporary.glob("*.zigup-tmp-*")), (name, "temporary file leaked")
            assert not list(temporary.glob("*.zigup-proxy-*")), (name, "proxy temporary file leaked")
            passed += 1
            print(f"PASS {tool}/{name}", flush=True)
            return fixture.events[start:], log, outputs

        def count(events, kind):
            return sum(event["kind"] == kind for event in events)

        events, _, _ = run_case("direct", {"ZIGUP_PROXY": "direct", "all_proxy": fixture.bad})
        assert count(events, "good") == count(events, "bad") == 0

        events, _, _ = run_case("environment-to-system", {
            "all_proxy": fixture.bad, "ZIGUP_TEST_PROXY_MODE": "manual", "ZIGUP_TEST_PROXY_PORT": good_port,
        }, ["/index.json", "/archive"])
        assert count(events, "bad") >= 1 and count(events, "good") == 2
        assert not any(event["kind"] == "bad" and str(event["path"]).endswith("/archive") for event in events)

        events, _, _ = run_case("system-before-resolver-direct", {
            "ZIGUP_TEST_PROXY_MODE": "manual", "ZIGUP_TEST_PROXY_PORT": good_port,
            "ZIGUP_TEST_RESOLVER": "direct",
        })
        assert count(events, "good") == 1, "libproxy direct must not hide a configured GNOME manual proxy"

        events, _, _ = run_case("system-to-direct", {
            "ZIGUP_TEST_PROXY_MODE": "manual", "ZIGUP_TEST_PROXY_PORT": bad_port,
        })
        assert count(events, "bad") >= 1 and count(events, "origin") == 1

        run_case("partial-proxy-to-empty-direct", {"all_proxy": fixture.bad}, ["/empty"])

        events, _, _ = run_case("disabled-system", {
            "ZIGUP_TEST_PROXY_MODE": "none", "ZIGUP_TEST_PROXY_PORT": bad_port,
        })
        assert count(events, "bad") == 0

        for name, rule in (("no-proxy-all", "*"), ("no-proxy-ip", "127.0.0.1"),
                           ("no-proxy-cidr", "127.0.0.0/8"),
                           ("no-proxy-port", f"127.0.0.1:{urllib.parse.urlsplit(fixture.origin).port}")):
            events, _, _ = run_case(name, {"all_proxy": fixture.bad, "no_proxy": rule,
                                         "ZIGUP_TEST_PROXY_MODE": "manual", "ZIGUP_TEST_PROXY_PORT": bad_port})
            assert count(events, "bad") == 0

        events, _, _ = run_case("forced-proxy-ignores-bypass", {"ZIGUP_PROXY": fixture.good, "no_proxy": "*"})
        assert count(events, "good") == 1
        events, _, _ = run_case("forced-proxy-fails-closed", {"ZIGUP_PROXY": fixture.bad, "no_proxy": "*"},
                                succeeds=False, preserve=True)
        assert count(events, "bad") >= 1 and count(events, "origin") == 0
        events, _, _ = run_case("invalid-proxy-no-network", {"ZIGUP_PROXY": "file:///tmp/proxy"}, succeeds=False)
        assert not events

        auth_proxy = fixture.good.replace("http://", "http://test-user:zigup-test-secret%40%3A@")
        events, _, _ = run_case("proxy-auth-redaction", {"ZIGUP_PROXY": auth_proxy})
        assert any(event["kind"] == "good" and event["auth_valid"] for event in events)

        events, _, _ = run_case("gnome-https-http-fallback", {
            "ZIGUP_TEST_PROXY_MODE": "manual", "ZIGUP_TEST_PROXY_PORT": good_port,
            "ZIGUP_TEST_HTTPS_HOST": "", "ZIGUP_TEST_AUTH": "true",
            "ZIGUP_TEST_USER": "test-user", "ZIGUP_TEST_PASSWORD": "zigup-test-secret@:",
        })
        assert any(event["kind"] == "good" and event["auth_valid"] for event in events)

        events, _, _ = run_case("system-bypass", {"ZIGUP_TEST_PROXY_MODE": "manual",
            "ZIGUP_TEST_PROXY_PORT": bad_port, "ZIGUP_TEST_PROXY_BYPASS": "['127.0.0.1']"})
        assert count(events, "bad") == 0

        events, _, _ = run_case("pac-per-url", {"ZIGUP_TEST_RESOLVER": "routes",
            "ZIGUP_TEST_RESOLVER_PROXY": fixture.good}, ["/index.json", "/archive"])
        assert count(events, "good") == 1
        assert not any(event["kind"] == "good" and str(event["path"]).endswith("/archive") for event in events)

        events, _, _ = run_case("pac-direct-then-proxy", {"ZIGUP_TEST_RESOLVER": "reverse",
            "ZIGUP_TEST_RESOLVER_PROXY": fixture.good}, ["/index.json", "/archive"])
        assert count(events, "good") == 1
        assert any(event["kind"] == "good" and str(event["path"]).endswith("/archive") for event in events)

        started = time.monotonic()
        run_case("bounded-resolver", {"ZIGUP_TEST_RESOLVER": "stall"})
        assert time.monotonic() - started < 15, "proxy discovery exceeded its deadline"

        if tool == "wget":
            events, log, _ = run_case("unsupported-forced-socks", {"ZIGUP_PROXY": "socks5h://127.0.0.1:9"},
                                      succeeds=False, preserve=True)
            assert not events and "curl" in log
            run_case("unsupported-auto-socks-fallback", {"all_proxy": "socks5h://127.0.0.1:9"})

        if fixture.allow_live:
            events, _, outputs = run_case("live-https-connect", {"ZIGUP_PROXY": fixture.good},
                                          ["https://ziglang.org/download/index.json"])
            parsed = json.loads(outputs[0].read_text(encoding="utf-8"))
            assert "master" in parsed
            assert any(event["kind"] == "good" and event["method"] == "CONNECT" for event in events)

    print(f"Linux proxy integration: {passed} cases passed", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--windows", action="store_true")
    parser.add_argument("--powershell", default="powershell.exe")
    parser.add_argument("--driver")
    parser.add_argument("--tool", choices=("curl", "wget"))
    parser.add_argument("--live", action="store_true")
    args = parser.parse_args()
    if args.windows == bool(args.driver):
        parser.error("choose --windows or --driver PATH")
    with tempfile.TemporaryDirectory(prefix="zigup-proxy-test-") as directory, Fixture(allow_live=args.live) as fixture:
        temporary = Path(directory)
        if args.windows:
            windows_tests(fixture, temporary, args.powershell)
        else:
            linux_tests(fixture, temporary, args.driver, args.tool)


if __name__ == "__main__":
    main()
