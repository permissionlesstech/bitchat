#!/usr/bin/env python3
"""
Minimal threaded SOCKS5 CONNECT proxy used to verify whether Apple's
URLSession actually honors `connectionProxyDictionary` SOCKS settings for
different request types (plain HTTPS vs URLSessionWebSocketTask).

Behavior:
  - Speaks enough SOCKS5 (no-auth) to complete a CONNECT and then relays
    bytes bidirectionally to the real destination.
  - Every accepted CONNECT is appended to a log file as one line:
        <iso8601>\tCONNECT\t<host>:<port>
  - Any raw connection that is NOT valid SOCKS5 is logged as:
        <iso8601>\tNON_SOCKS\t<first-bytes-hex>
    (this catches the feared case where URLSession sends a raw TLS/HTTP
     ClientHello straight at the proxy port instead of a SOCKS greeting).

If a request egresses DIRECTLY (proxy ignored), nothing is logged at all.

Usage: socks5_probe_proxy.py <listen_port> <log_file>
"""
import selectors
import socket
import sys
import threading
from datetime import datetime, timezone

LOG_LOCK = threading.Lock()


def log(logfile, kind, detail):
    line = f"{datetime.now(timezone.utc).isoformat()}\t{kind}\t{detail}\n"
    with LOG_LOCK:
        with open(logfile, "a") as f:
            f.write(line)
    sys.stderr.write("[proxy] " + line)
    sys.stderr.flush()


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def handle(client, logfile):
    client.settimeout(15)
    try:
        # SOCKS5 greeting: VER=0x05, NMETHODS, METHODS...
        head = recv_exact(client, 2)
        if not head:
            return
        if head[0] != 0x05:
            # Not SOCKS5 at all — this is the smoking gun for a direct egress
            # that mistakenly hit the proxy port. Log the first bytes.
            rest = b""
            try:
                client.setblocking(False)
                rest = client.recv(64)
            except Exception:
                pass
            log(logfile, "NON_SOCKS", (head + rest).hex())
            return
        nmethods = head[1]
        if nmethods:
            recv_exact(client, nmethods)
        # Reply: no authentication required
        client.sendall(b"\x05\x00")

        # Request: VER, CMD, RSV, ATYP, ADDR, PORT
        req = recv_exact(client, 4)
        if not req or req[1] != 0x01:  # only CONNECT
            client.sendall(b"\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00")
            return
        atyp = req[3]
        if atyp == 0x01:  # IPv4
            addr = socket.inet_ntoa(recv_exact(client, 4))
        elif atyp == 0x03:  # domain
            ln = recv_exact(client, 1)[0]
            addr = recv_exact(client, ln).decode("ascii", errors="replace")
        elif atyp == 0x04:  # IPv6
            addr = socket.inet_ntop(socket.AF_INET6, recv_exact(client, 16))
        else:
            client.sendall(b"\x05\x08\x00\x01\x00\x00\x00\x00\x00\x00")
            return
        port = int.from_bytes(recv_exact(client, 2), "big")

        log(logfile, "CONNECT", f"{addr}:{port}")

        # Connect to the real destination and reply success.
        try:
            remote = socket.create_connection((addr, port), timeout=15)
        except Exception as e:
            log(logfile, "CONNECT_FAIL", f"{addr}:{port} {e}")
            client.sendall(b"\x05\x01\x00\x01\x00\x00\x00\x00\x00\x00")
            return
        client.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")

        relay(client, remote)
    except Exception:
        pass
    finally:
        try:
            client.close()
        except Exception:
            pass


def relay(a, b):
    a.setblocking(False)
    b.setblocking(False)
    sel = selectors.DefaultSelector()
    sel.register(a, selectors.EVENT_READ, b)
    sel.register(b, selectors.EVENT_READ, a)
    try:
        while True:
            events = sel.select(timeout=30)
            if not events:
                break
            for key, _ in events:
                src = key.fileobj
                dst = key.data
                try:
                    data = src.recv(65536)
                except (BlockingIOError, InterruptedError):
                    continue
                except Exception:
                    return
                if not data:
                    return
                try:
                    dst.sendall(data)
                except Exception:
                    return
    finally:
        sel.close()
        for s in (a, b):
            try:
                s.close()
            except Exception:
                pass


def main():
    if len(sys.argv) != 3:
        print("usage: socks5_probe_proxy.py <port> <logfile>", file=sys.stderr)
        sys.exit(2)
    port = int(sys.argv[1])
    logfile = sys.argv[2]
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(64)
    sys.stderr.write(f"[proxy] listening on 127.0.0.1:{port}, log={logfile}\n")
    sys.stderr.flush()
    print("READY", flush=True)
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client, logfile), daemon=True).start()


if __name__ == "__main__":
    main()
