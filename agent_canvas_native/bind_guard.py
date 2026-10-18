#!/usr/bin/env python3
"""bind_guard.py — publish Agent Canvas on local addresses only.

Agent Canvas binds 127.0.0.1 by default, so the UI is unreachable from any other
machine, and `agent-canvas --host 0.0.0.0` is the wrong fix: it publishes the UI
on *every* interface (VLANs, guest Wi-Fi, tunnels) and drops the session key
from the HTML, so even your own laptop has to paste a key.

This is the middle ground. run.sh runs the launcher on 127.0.0.1 with an
ingress port of its own (INTERNAL = PUBLIC + 1); this guard listens on PUBLIC
across every address that falls inside BIND_ALLOW_CIDRS and proxies to it.
Addresses outside the allowlist are never bound, so nothing answers there.
Because the browser still loads the page through the loopback launcher, the
session key injection is unchanged: opening http://<lan-ip>:<PUBLIC>/ works with
no login, exactly like http://localhost:<PUBLIC>/ does.

The proxy is a plain TCP pump, so HTTP, SSE and WebSockets all pass through
untouched. Before pumping, the first request on each connection is checked
twice: the *client* address must be inside the allowlist, and the *Host* header
must be an allowed address or a name listed in BIND_ALLOW_HOSTS (that is what
keeps a public page from DNS-rebinding at this machine).

Configuration (environment variables, normally set by run.sh from .env):

    BIND_ALLOW_CIDRS=127.0.0.0/8,::1/128,192.168.0.0/16,100.64.0.0/10
    BIND_ALLOW_HOSTS=            # extra Host names, e.g. mac.tailnet.ts.net
    BIND_PUBLIC_PORT=8020        # what browsers and the launcher print
    BIND_INTERNAL_PORT=8021      # the launcher's loopback-only ingress

The guard is only a proxy: it neither starts nor stops the launcher, so the
launcher's own lifecycle (Ctrl+C, shutting down its services) is exactly the
LAN_BIND=off one. The guard exits when its parent process does — run.sh
starts it and then execs the launcher, so that parent *is* the launcher.

The API key is never read or printed here: the launcher owns it.
"""

from __future__ import annotations

import ipaddress
import os
import re
import select
import socket
import subprocess
import sys
import threading
import time
from typing import Sequence

DEFAULT_ALLOW = "127.0.0.0/8,::1/128,192.168.0.0/16,100.64.0.0/10"
COPY_BYTES = 65536
SELECT_POLL = 0.2
HEAD_LIMIT = 8192


def log(msg: str) -> None:
    print(f"[bind_guard] {msg}", flush=True)


def parse_list(raw: str) -> list[str]:
    # run.sh sources .env with bash, so an inline "# ..." on a value line lands
    # in the variable — treat everything from the first # as a comment.
    raw = (raw or "").split("#", 1)[0]
    return [t for t in (s.strip() for s in re.split(r"[,\s]+", raw)) if t]


def parse_cidrs(raw: str) -> list:
    nets = []
    for token in parse_list(raw):
        try:
            nets.append(ipaddress.ip_network(token, strict=False))
        except ValueError as exc:
            raise SystemExit(f"bind_guard: bad BIND_ALLOW_CIDRS entry {token!r}: {exc}")
    if not nets:
        raise SystemExit("bind_guard: BIND_ALLOW_CIDRS parsed to nothing")
    return nets


class Allowlist:
    def __init__(self, cidrs: Sequence, hosts: Sequence[str] = ()):
        self.cidrs = list(cidrs)
        self.hosts = {h.lower() for h in hosts}

    def addr_ok(self, host: str) -> bool:
        if host.lower() in {"localhost", "localhost.localdomain"}:
            return True
        if host.lower() in self.hosts:
            return True
        try:
            addr = ipaddress.ip_address(host)
        except ValueError:
            return False  # some other name: it could resolve anywhere
        return any(addr.version == n.version and addr in n for n in self.cidrs)

    def host_ok(self, value: str) -> bool:
        """Check a Host header value, with any :port stripped."""
        name = value.strip()
        if name.startswith("["):
            name = name[1:].split("]", 1)[0]  # [::1]:8020 -> ::1
        elif name.count(":") == 1:
            name = name.rsplit(":", 1)[0]  # 192.168.1.5:8020 -> 192.168.1.5
        if not name:
            return True
        return self.addr_ok(name)

    def describes(self) -> str:
        return ", ".join(str(n) for n in self.cidrs) + (
            " (+ hosts: " + ", ".join(sorted(self.hosts)) + ")" if self.hosts else ""
        )


def interface_addresses() -> list[str]:
    """Every address currently on a real interface, via ifconfig or ip(8).

    Reading the interface table is the point: a new LAN IP (DHCP renewal, a
    second NIC) or a Tailscale address that appears later is picked up on the
    next start, and an interface that goes away simply fails to bind.
    """
    addrs: list[str] = []
    for argv in (["ifconfig", "-a"], ["ip", "-o", "addr", "show"]):
        try:
            out = subprocess.run(argv, capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        addrs += re.findall(r"\binet6?\s+(?:addr:\s*)?([0-9a-fA-F:.]+)", out)
    ordered: list[str] = []
    for a in (a.split("%")[0] for a in addrs):
        if a not in ordered:
            ordered.append(a)
    return ordered


def bind_targets(allow: Allowlist) -> list[str]:
    # Loopback first: its bind failure is fatal (see Gateway.listen), and it is
    # what keeps http://localhost:<port>/ working when LAN_BIND is on.
    targets = ["127.0.0.1", "::1"]
    for addr in interface_addresses():
        if addr not in targets and allow.addr_ok(addr):
            targets.append(addr)
    return targets


def reject(sock: socket.socket, why: str) -> None:
    body = f"bind_guard: {why}\n".encode()
    head = (
        b"HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nConnection: close\r\n"
        b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n"
    )
    try:
        sock.sendall(head + body)
    except OSError:
        pass


def _copy(src: socket.socket, dst: socket.socket) -> None:
    """One direction of pump(): blocking recv -> sendall until EOF, then pass
    the EOF on as a half-close so the other direction can still finish.

    Blocking on purpose. The old select() loop used non-blocking sockets, and
    sendall() on a non-blocking socket raises as soon as the peer's buffer is
    full — any response bigger than the socket buffers, read by a client
    slower than the launcher (a LAN laptop, a large conversation history), was
    cut off mid-body."""
    try:
        while True:
            data = src.recv(COPY_BYTES)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        # A reset on either side: tear down both directions, not just this one.
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        return
    try:
        dst.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def pump(a: socket.socket, b: socket.socket) -> None:
    """Copy both directions until both sides are done. No idle timeout: a
    WebSocket session can sit quiet for minutes between agent events (dead
    peers are found by TCP keepalive instead, see Connection)."""
    for s in (a, b):
        s.settimeout(None)
    back = threading.Thread(target=_copy, args=(b, a), daemon=True)
    back.start()
    _copy(a, b)
    back.join()


class Connection(threading.Thread):
    """Read the request head, apply the two checks, then hand off to pump()."""

    def __init__(self, client, peer, allow: Allowlist, upstream: tuple[str, int]):
        super().__init__(daemon=True)
        self.client = client
        self.peer = peer
        self.allow = allow
        self.upstream = upstream

    def run(self) -> None:
        head = b""
        remote = None
        try:
            # With no idle timeout, a laptop that sleeps or leaves the network
            # would otherwise pin this thread and two fds forever.
            self.client.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            self.client.settimeout(15)
            while b"\r\n\r\n" not in head and len(head) < HEAD_LIMIT:
                chunk = self.client.recv(4096)
                if not chunk:
                    break
                head += chunk

            client_ip = self.peer[0] if isinstance(self.peer, tuple) else str(self.peer)
            if not self.allow.addr_ok(client_ip):
                log(f"403: client {client_ip} is outside BIND_ALLOW_CIDRS")
                reject(self.client, f"client address {client_ip} is not allowed")
                return

            match = re.search(rb"\r\nhost:\s*([^\r\n]+)", head[:HEAD_LIMIT], re.I)
            host = match.group(1).decode("latin-1").strip() if match else ""
            if not self.allow.host_ok(host):
                log(f"403: Host {host!r} from {client_ip} is not allowed")
                reject(self.client, f"Host header {host!r} is not allowed")
                return

            remote = socket.create_connection(self.upstream, timeout=15)
            if head:
                remote.sendall(head)
            pump(self.client, remote)
        except OSError:
            pass
        finally:
            for s in (remote, self.client):
                if s is None:
                    continue
                try:
                    s.close()
                except OSError:
                    pass


class Gateway:
    def __init__(self, port: int, upstream: tuple[str, int], allow: Allowlist):
        self.port = port
        self.upstream = upstream
        self.allow = allow
        self.servers: list[socket.socket] = []
        self._alive = True

    def listen(self) -> None:
        for addr in bind_targets(self.allow):
            required = addr == "127.0.0.1"
            family = socket.AF_INET6 if ":" in addr else socket.AF_INET
            try:
                srv = socket.socket(family, socket.SOCK_STREAM)
                srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                srv.bind((addr, self.port))
                srv.listen(128)
            except OSError as exc:
                if required:
                    raise SystemExit(
                        f"bind_guard: cannot bind {addr}:{self.port} ({exc.strerror}). "
                        "Something already listens there — pick another AGENT_CANVAS_PORT."
                    )
                # An interface that went away or lost the race should not take
                # the gateway down: localhost still works, the others may return
                # on the next start.
                log(f"note: could not bind {addr}:{self.port} ({exc.strerror}) — skipped")
                continue
            self.servers.append(srv)
            log(f"listening on http://{addr}:{self.port}")
        if not self.servers:
            raise SystemExit(f"bind_guard: bound nothing on port {self.port} — is it in use?")

    def serve_forever(self, keep_going=lambda: True) -> None:
        # Never return early on an error while still alive: main() treats a
        # return as "shut everything down", and the old early return left the
        # port bound with nobody accepting on it.
        while self._alive and keep_going():
            try:
                readable, _, _ = select.select(self.servers, (), (), SELECT_POLL)
            except (OSError, ValueError) as exc:
                if not self._alive:
                    return
                log(f"select failed ({exc}) — retrying")
                time.sleep(1)
                continue
            for srv in readable:
                try:
                    client, peer = srv.accept()
                except OSError as exc:
                    if not self._alive:
                        return
                    # EMFILE and friends leave the socket readable: back off
                    # instead of spinning at 100% CPU.
                    log(f"accept failed ({exc.strerror or exc}) — backing off")
                    time.sleep(0.5)
                    continue
                Connection(client, peer, self.allow, self.upstream).start()

    def close(self) -> None:
        self._alive = False
        servers, self.servers = self.servers, []
        for srv in servers:
            try:
                srv.close()
            except OSError:
                pass


def port_from_env(name: str, fallback: int) -> int:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return fallback
    try:
        return int(raw)
    except ValueError:
        raise SystemExit(f"bind_guard: {name}={raw!r} is not a port number")


def main() -> int:
    if any(a in ("-h", "--help") for a in sys.argv[1:]):
        print(__doc__)
        return 0
    env = os.environ
    public_port = port_from_env("BIND_PUBLIC_PORT", 8020)
    internal_port = port_from_env("BIND_INTERNAL_PORT", public_port + 1)
    allow = Allowlist(parse_cidrs(env.get("BIND_ALLOW_CIDRS", DEFAULT_ALLOW)), parse_list(env.get("BIND_ALLOW_HOSTS", "")))
    if internal_port == public_port:
        raise SystemExit("bind_guard: BIND_INTERNAL_PORT must differ from BIND_PUBLIC_PORT")

    # run.sh starts this in the background and then execs the launcher, so our
    # parent pid *is* the launcher. Once it is gone we are reparented, and we
    # exit too, rather than keep holding the public port for the next run.
    parent = os.getppid()
    gateway = Gateway(public_port, ("127.0.0.1", internal_port), allow)
    gateway.listen()
    log(f"proxying to http://127.0.0.1:{internal_port} while pid {parent} runs")
    log(f"allowed addresses: {allow.describes()}")
    try:
        gateway.serve_forever(keep_going=lambda: os.getppid() == parent)
    finally:
        gateway.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
