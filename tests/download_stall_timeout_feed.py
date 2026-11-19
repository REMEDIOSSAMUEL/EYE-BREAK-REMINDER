#!/usr/bin/env python3
"""Loopback TLS server that sends valid HTTP headers and then stalls the body."""

import ipaddress
import json
import os
import socket
import socketserver
import ssl
import sys
import threading
import time


def write_state(path, **values):
    temporary = path + ".tmp"
    with open(temporary, "w", encoding="utf-8", newline="\n") as stream:
        json.dump(values, stream, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


class StallServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    address_family = socket.AF_INET6
    allow_reuse_address = True
    daemon_threads = True

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()

    def get_request(self):
        request, address = super().get_request()
        return self.context.wrap_socket(request, server_side=True), address


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        server = self.server
        peer = self.client_address[0].split("%", 1)[0]
        address = ipaddress.ip_address(peer)
        is_loopback = address.is_loopback or (address.ipv4_mapped and address.ipv4_mapped.is_loopback)
        if not is_loopback:
            write_state(server.state_path, ready=True, rejected_non_loopback=True)
            return

        self.request.settimeout(5)
        data = bytearray()
        try:
            while b"\r\n\r\n" not in data and len(data) < 16384:
                chunk = self.request.recv(2048)
                if not chunk:
                    return
                data.extend(chunk)
        except (OSError, TimeoutError):
            return

        request_line = bytes(data).split(b"\r\n", 1)[0].decode("ascii", "replace")
        if request_line != "GET /stall.bin HTTP/1.1":
            try:
                self.request.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            except OSError:
                pass
            write_state(server.state_path, ready=True, unexpected_request=request_line)
            return

        headers = (
            b"HTTP/1.1 200 OK\r\n"
            b"Content-Type: application/octet-stream\r\n"
            b"Content-Length: 3\r\n"
            b"Connection: keep-alive\r\n"
            b"\r\n"
        )
        try:
            self.request.sendall(headers)
        except OSError as error:
            write_state(server.state_path, ready=True, request_received=True,
                        headers_sent=False, error=str(error))
            return

        write_state(server.state_path, ready=True, request_received=True,
                    headers_sent=True, body_bytes_sent=0, request_line=request_line,
                    stall_seconds=server.stall_seconds)
        # Keep TLS/TCP open without sending any body bytes. A body that never
        # arrives is what exercises WinHTTP's receive timeout, rather than a
        # timeout setting assertion or an early connection-close test.
        time.sleep(server.stall_seconds)


def main():
    if len(sys.argv) != 6:
        raise SystemExit("usage: download_stall_timeout_feed.py <port> <cert> <key> <state-json> <stall-seconds>")
    port, cert_path, key_path, state_path, stall_seconds = sys.argv[1:]
    port = int(port)
    stall_seconds = int(stall_seconds)
    if not (1024 <= port <= 65535) or not (10 <= stall_seconds <= 60):
        raise SystemExit("port or stall duration is outside the test bounds")

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(certfile=cert_path, keyfile=key_path)

    server = StallServer(("::", port), Handler)
    server.state_path = state_path
    server.stall_seconds = stall_seconds
    server.context = context
    write_state(state_path, ready=True, request_received=False, headers_sent=False)
    print("ready", flush=True)
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
