#!/usr/bin/env python3
"""Serve deterministic loopback-only HTTPS responses for the chroot audit."""

from __future__ import annotations

import pathlib
import socket
import ssl
import sys
import traceback


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit("usage: https-test-server.py CERT KEY READY_FILE")

    cert, key, ready_path = sys.argv[1:]
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    # The locked 2022 factory rootfs ships uhttpd's small legacy key.  Lower
    # only this offline loopback server's OpenSSL security level so the test
    # can exercise the exact certificate/key material available on-device.
    context.set_ciphers("DEFAULT:@SECLEVEL=0")
    context.load_cert_chain(certfile=cert, keyfile=key)
    response_body = b"busybox-wget-https-semantic\n"
    response = (
        b"HTTP/1.0 200 OK\r\n"
        + f"Content-Length: {len(response_body)}\r\n".encode("ascii")
        + b"Content-Type: text/plain\r\nConnection: close\r\n\r\n"
        + response_body
    )

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 18443))
        listener.listen(8)
        listener.settimeout(15)
        pathlib.Path(ready_path).write_text("ready\n", encoding="ascii")
        print("READY 127.0.0.1:18443", flush=True)

        # One direct stock-OpenSSL probe plus up to five BusyBox wget attempts.
        for _ in range(6):
            try:
                connection, peer = listener.accept()
            except TimeoutError:
                break
            try:
                with connection:
                    connection.settimeout(3)
                    print(f"ACCEPTED {peer[0]}:{peer[1]}", flush=True)
                    prefix = connection.recv(5, socket.MSG_PEEK)
                    print(f"CLIENT_PREFIX {prefix.hex()}", flush=True)
                    with context.wrap_socket(connection, server_side=True) as tls:
                        request = bytearray()
                        while b"\r\n\r\n" not in request and len(request) < 65536:
                            chunk = tls.recv(4096)
                            if not chunk:
                                break
                            request.extend(chunk)
                        if not request.startswith((b"GET ", b"HEAD ")):
                            raise ValueError(f"unexpected request from {peer}: {request[:80]!r}")
                        tls.sendall(response)
                print(f"SERVED {peer[0]}:{peer[1]}", flush=True)
            except Exception:
                traceback.print_exc()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
