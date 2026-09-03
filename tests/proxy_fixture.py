"""Loopback-only origin/proxies for zigup's real downloader regression tests.

No proxy settings, certificate stores, or installed toolchains are changed.
The optional live mode only permits CONNECT to ziglang.org:443.
"""

from __future__ import annotations

import contextlib
import base64
import http.client
import http.server
import json
import select
import socket
import threading
import urllib.parse


PAYLOAD = b"zigup proxy integration payload\n"


class Fixture:
    def __init__(self, *, allow_live: bool = False):
        self.allow_live = allow_live
        self.lock = threading.Lock()
        self.events: list[dict[str, object]] = []
        self.servers: list[http.server.ThreadingHTTPServer] = []
        self.threads: list[threading.Thread] = []
        self.origin = self._start("origin")
        self.synthetic = self.origin.replace("127.0.0.1", "zigup-test.invalid")
        self.good = self._start("good")
        self.bad = self._start("bad")

    def _start(self, kind: str) -> str:
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args):
                pass

            def reply(self, code: int, body: bytes, mime="text/plain"):
                self.send_response(code)
                self.send_header("Content-Type", mime)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                    self.wfile.write(body)
                self.close_connection = True

            def record(self, method: str):
                # Keep only the presence of auth: never retain even test passwords.
                authorization = self.headers.get("Proxy-Authorization", "")
                expected_auth = {
                    "Basic " + base64.b64encode(value).decode("ascii")
                    for value in (b"test-user:zigup-test-secret@:", b"zigup_test_user:p@ss:word%")
                }
                with fixture.lock:
                    fixture.events.append(
                        {
                            "kind": kind,
                            "method": method,
                            "path": self.path,
                            "auth": bool(authorization),
                            "auth_valid": authorization in expected_auth,
                        }
                    )

            def do_GET(self):
                parsed = urllib.parse.urlsplit(self.path)
                if kind == "origin":
                    if parsed.path == "/stats":
                        with fixture.lock:
                            data = json.dumps(fixture.events).encode()
                        self.reply(200, data, "application/json")
                        return
                    self.record("GET")
                    if parsed.path.startswith("/pac"):
                        if parsed.path == "/pac-invalid":
                            body = b"this is not javascript {"
                        elif parsed.path == "/pac-fail":
                            self.reply(404, b"missing PAC")
                            return
                        else:
                            proxy = fixture.good.removeprefix("http://")
                            condition = "!shExpMatch(url, '*/index.json')" if parsed.path == "/pac-reverse" else "shExpMatch(url, '*/index.json')"
                            body = (
                                "function FindProxyForURL(url, host) { "
                                f"if ({condition}) "
                                f"return 'PROXY {proxy}; DIRECT'; "
                                "return 'DIRECT'; }"
                            ).encode()
                        self.reply(200, body, "application/x-ns-proxy-autoconfig")
                    elif parsed.path == "/fail":
                        self.reply(503, b"intentional origin failure")
                    elif parsed.path == "/empty":
                        self.reply(200, b"")
                    else:
                        self.reply(200, PAYLOAD)
                    return

                self.record("GET")
                if kind == "bad":
                    if parsed.path == "/empty":
                        # Truncated success-looking response; the next route's
                        # empty successful body must not retain these bytes.
                        self.send_response(200)
                        self.send_header("Content-Length", "100000")
                        self.send_header("Connection", "close")
                        self.end_headers()
                        self.wfile.write(b"partial bytes from failed proxy")
                        self.close_connection = True
                        return
                    self.reply(502, b"intentional proxy failure")
                    return
                synthetic = (parsed.hostname == "zigup-test.invalid" and
                             parsed.port == urllib.parse.urlsplit(fixture.origin).port)
                if parsed.scheme != "http" or (not synthetic and parsed.hostname not in {
                    "127.0.0.1", "localhost", "::1"
                }):
                    self.reply(403, b"fixture only forwards loopback HTTP")
                    return
                connection = http.client.HTTPConnection(
                    "127.0.0.1" if synthetic else parsed.hostname, parsed.port or 80, timeout=5
                )
                try:
                    path = urllib.parse.urlunsplit(("", "", parsed.path, parsed.query, ""))
                    connection.request("GET", path or "/")
                    response = connection.getresponse()
                    self.reply(response.status, response.read())
                except (OSError, http.client.HTTPException):
                    self.reply(502, b"fixture upstream unavailable")
                finally:
                    connection.close()

            def do_CONNECT(self):
                self.record("CONNECT")
                if kind != "good":
                    self.reply(502, b"intentional proxy failure")
                    return
                try:
                    parsed = urllib.parse.urlsplit("//" + self.path)
                    host, port = parsed.hostname, parsed.port
                except ValueError:
                    self.reply(400, b"invalid CONNECT authority")
                    return
                local = host in {"127.0.0.1", "localhost", "::1"}
                live = fixture.allow_live and host == "ziglang.org" and port == 443
                if not local and not live:
                    self.reply(403, b"CONNECT destination not allowed by fixture")
                    return
                try:
                    upstream = socket.create_connection((host, port), timeout=10)
                except OSError:
                    self.reply(502, b"fixture CONNECT unavailable")
                    return
                with upstream:
                    self.send_response(200, "Connection Established")
                    self.end_headers()
                    self.wfile.flush()
                    self.connection.settimeout(15)
                    upstream.settimeout(15)
                    while True:
                        ready, _, _ = select.select([self.connection, upstream], [], [], 15)
                        if not ready:
                            break
                        try:
                            for source in ready:
                                data = source.recv(65536)
                                if not data:
                                    return
                                other = upstream if source is self.connection else self.connection
                                other.sendall(data)
                        except OSError:
                            break
                self.close_connection = True

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.servers.append(server)
        self.threads.append(thread)
        return f"http://127.0.0.1:{server.server_port}"

    def config(self) -> dict[str, object]:
        return {"origin": self.origin, "synthetic": self.synthetic, "good": self.good, "bad": self.bad,
                "payload": PAYLOAD.decode(), "allow_live": self.allow_live}

    def close(self):
        for server in self.servers:
            server.shutdown()
            server.server_close()
        for thread in self.threads:
            thread.join(timeout=2)

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()
