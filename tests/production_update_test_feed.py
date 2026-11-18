#!/usr/bin/env python3
"""Loopback HTTPS feed for the production-binary Windows update acceptance test.

The workflow temporarily maps only the official GitHub hostnames to loopback
and installs this test's ephemeral CA in the disposable runner's CurrentUser
Root store. The production binary still executes its normal HTTPS and
GitHub-SHA-256 checks. This feed is never configured into a release build.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import socket
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


REPOSITORY = "REMEDIOSSAMUEL/EYE-BREAK-REMINDER"
VERSION = "v1.4.1"
ASSET_ROOT = f"/{REPOSITORY}/releases/download/{VERSION}/"
API_PATH = f"/repos/{REPOSITORY}/releases/latest"


class TLSHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def get_request(self):
        connection, address = super().get_request()
        try:
            return self.ssl_context.wrap_socket(connection, server_side=True), address
        except Exception:
            connection.close()
            raise


class IPv6ThreadingHTTPServer(TLSHTTPServer):
    address_family = socket.AF_INET6
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        super().server_bind()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def make_handler(setup_path: Path, app_path: Path, request_log: Path):
    setup_path = setup_path.resolve(strict=True)
    app_path = app_path.resolve(strict=True)
    assets = {
        "EyeBreakReminder-Setup-x64.exe": setup_path,
        "EyeBreakReminder.exe": app_path,
    }
    release = {
        "tag_name": VERSION,
        "html_url": f"https://github.com/{REPOSITORY}/releases/tag/{VERSION}",
        "draft": False,
        "prerelease": False,
        "body": "Controlled production-updater transaction served only by an isolated Windows runner.",
        "assets": [
            {
                "name": name,
                "browser_download_url": f"https://github.com{ASSET_ROOT}{name}",
                "size": path.stat().st_size,
                "digest": f"sha256:{sha256(path)}",
            }
            for name, path in assets.items()
        ],
    }
    encoded_release = json.dumps(release, separators=(",", ":")).encode("utf-8")
    log_lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, _format, *_args):
            return

        def do_GET(self):
            host = self.headers.get("Host", "").lower()
            if host.endswith(":443"):
                host = host[:-4]
            record = {
                "utc": datetime.now(timezone.utc).isoformat(),
                "host": host,
                "path": self.path,
                "method": "GET",
            }
            with log_lock:
                with request_log.open("a", encoding="utf-8") as log:
                    log.write(json.dumps(record, separators=(",", ":")) + "\n")

            if host == "api.github.com" and self.path == API_PATH:
                self.send_response(200)
                self.send_header("Content-Type", "application/vnd.github+json")
                self.send_header("Content-Length", str(len(encoded_release)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(encoded_release)
                return

            if host == "github.com" and self.path.startswith(ASSET_ROOT):
                name = self.path[len(ASSET_ROOT):]
                path = assets.get(name)
                if path is not None and "/" not in name:
                    size = path.stat().st_size
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Length", str(size))
                    self.send_header("Connection", "close")
                    self.end_headers()
                    with path.open("rb") as source:
                        for block in iter(lambda: source.read(64 * 1024), b""):
                            self.wfile.write(block)
                    return

            body = b"not found\n"
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

    return Handler


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--certificate", required=True, type=Path)
    parser.add_argument("--private-key", required=True, type=Path)
    parser.add_argument("--setup", required=True, type=Path)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--request-log", required=True, type=Path)
    parser.add_argument("--ready-file", required=True, type=Path)
    args = parser.parse_args()

    handler = make_handler(args.setup, args.app, args.request_log)
    servers = [
        TLSHTTPServer(("127.0.0.1", 443), handler),
        IPv6ThreadingHTTPServer(("::1", 443), handler),
    ]
    import ssl

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(str(args.certificate), str(args.private_key))
    for server in servers:
        server.ssl_context = context
    threads = [
        threading.Thread(target=server.serve_forever, name=f"feed-{index}", daemon=True)
        for index, server in enumerate(servers)
    ]
    for thread in threads:
        thread.start()
    args.ready_file.write_text("ready\n", encoding="ascii")
    try:
        for thread in threads:
            thread.join()
    except KeyboardInterrupt:
        pass
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
