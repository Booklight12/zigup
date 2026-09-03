"""Real curl SOCKS5 transport regression using a loopback-only proxy.

python3 tests/linux_proxy_socks.py --driver zig-out/bin/zigup-proxy-test
No network request is permitted outside the loopback origin fixture.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import select
import shutil
import socket
import socketserver
import subprocess
import tempfile
import threading
import urllib.parse

from proxy_fixture import Fixture, PAYLOAD


def read_exact(connection, count):
    result = bytearray()
    while len(result) < count:
        part = connection.recv(count - len(result))
        if not part:
            raise ConnectionError("SOCKS client disconnected")
        result.extend(part)
    return bytes(result)


class SocksServer(socketserver.ThreadingTCPServer):
    daemon_threads = True

    def __init__(self, origin_port, authenticated):
        self.origin_port = origin_port
        self.authenticated = authenticated
        self.events = []
        server = self

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                client = self.request
                client.settimeout(10)
                try:
                    version, count = read_exact(client, 2)
                    methods = read_exact(client, count)
                    method = 2 if server.authenticated else 0
                    if version != 5 or method not in methods:
                        client.sendall(b"\x05\xff")
                        return
                    client.sendall(bytes((5, method)))
                    auth_valid = not server.authenticated
                    if method == 2:
                        auth_version, user_length = read_exact(client, 2)
                        user = read_exact(client, user_length)
                        password = read_exact(client, read_exact(client, 1)[0])
                        auth_valid = (auth_version == 1 and user == b"test-user" and
                                      password == b"zigup-test-secret@:")
                        client.sendall(bytes((1, 0 if auth_valid else 1)))
                        if not auth_valid:
                            return
                    version, command, reserved, address_type = read_exact(client, 4)
                    if version != 5 or command != 1 or reserved != 0:
                        return
                    if address_type == 1:
                        host = socket.inet_ntop(socket.AF_INET, read_exact(client, 4))
                    elif address_type == 3:
                        host = read_exact(client, read_exact(client, 1)[0]).decode("ascii")
                    elif address_type == 4:
                        host = socket.inet_ntop(socket.AF_INET6, read_exact(client, 16))
                    else:
                        return
                    port = int.from_bytes(read_exact(client, 2), "big")
                    if host not in ("localhost", "127.0.0.1", "::1") or port != server.origin_port:
                        return
                    with socket.create_connection(("127.0.0.1", port), timeout=5) as upstream:
                        server.events.append({"address_type": address_type, "auth_valid": auth_valid})
                        client.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
                        while True:
                            ready, _, _ = select.select([client, upstream], [], [], 10)
                            if not ready:
                                return
                            for source in ready:
                                data = source.recv(65536)
                                if not data:
                                    return
                                (upstream if source is client else client).sendall(data)
                except (OSError, ValueError):
                    return

        super().__init__(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.shutdown()
        self.server_close()
        self.thread.join(timeout=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", required=True)
    args = parser.parse_args()
    curl = shutil.which("curl")
    if curl is None:
        parser.error("curl is required for SOCKS transport tests")
    driver = str(Path(args.driver).resolve())
    cleaned = {"http_proxy", "https_proxy", "all_proxy", "ftp_proxy", "no_proxy", "zigup_proxy"}
    with tempfile.TemporaryDirectory(prefix="zigup-socks-test-") as directory, Fixture() as fixture:
        environ = {key: value for key, value in os.environ.items() if key.lower() not in cleaned}
        environ.update({"HOME": directory, "NO_PROXY": "*"})
        origin = fixture.origin.replace("127.0.0.1", "localhost")
        origin_port = urllib.parse.urlsplit(origin).port
        for authenticated in (False, True):
            proxy = SocksServer(origin_port, authenticated)
            try:
                for scheme in ("socks5", "socks5h"):
                    auth = "test-user:" + urllib.parse.quote("zigup-test-secret@:", safe="") + "@" if authenticated else ""
                    environ["ZIGUP_PROXY"] = f"{scheme}://{auth}127.0.0.1:{proxy.server_address[1]}"
                    output = Path(directory) / f"{scheme}-{authenticated}.download"
                    before = len(proxy.events)
                    result = subprocess.run([driver, "curl", curl, origin + "/payload", str(output)],
                                            env=environ, text=True, capture_output=True, timeout=25)
                    log = result.stdout + result.stderr
                    assert "zigup-test-secret" not in log, "SOCKS credentials leaked"
                    if result.returncode:
                        raise AssertionError(f"{scheme}/auth={authenticated} failed: {log}")
                    assert output.read_bytes() == PAYLOAD
                    events = proxy.events[before:]
                    assert len(events) == 1 and events[0]["auth_valid"], events
                    assert events[0]["address_type"] in ((3,) if scheme == "socks5h" else (1, 4)), events
                    print(f"PASS curl/{scheme}/auth={authenticated}", flush=True)
            finally:
                proxy.close()
        assert not list(Path(directory).glob("*.zigup-proxy-*"))
        print("SOCKS5 transport integration: 4 cases passed", flush=True)


if __name__ == "__main__":
    main()
