#!/usr/bin/env python3
"""bind_guard.py — publish Agent Canvas on local addresses only.

Agent Canvas binds 127.0.0.1 by default, so the UI is unreachable from any other
machine, and `agent-canvas --host 0.0.0.0` is the wrong fix: it publishes the UI
on *every* interface (VLANs, guest Wi-Fi, tunnels) and drops the session key
from the HTML, so even your own laptop has to paste a key.

This is the middle ground. It starts the launcher yourself on 127.0.0.1 with an
ingress port of its own (INTERNAL = PUBLIC + 1), then listens itself on PUBLIC
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
    BIND_GUARD_LOG=<state>/logs/bind_guard.log

The API key is never read or printed here: the launcher owns it.
"""

from __future__ import annotations

import ipaddress
import os
import re
import select
import signal
import socket
import subprocess
import sys
import threading
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


def pump(a: socket.socket, b: socket.socket) -> None:
    """Copy both directions until either side closes. No idle timeout: a
    WebSocket session can sit quiet for minutes between agent events."""
    for s in (a, b):
        s.setblocking(False)
    try:
        while True:
            try:
                readable, _, bad = select.select((a, b), (), (a, b), SELECT_POLL)
            except (OSError, ValueError):
                return
            if bad:
                return
            if not readable:
                continue
            for src in readable:
                dst = b if src is a else a
                try:
                    data = src.recv(COPY_BYTES)
                except (BlockingIOError, InterruptedError):
                    continue
                except OSError:
                    return
                if not data:
                    return
                try:
                    dst.sendall(data)
                except OSError:
                    return
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


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
        try:
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
            remote.close()
        except OSError:
            pass
        finally:
            try:
                self.client.close()
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
        while self._alive and keep_going():
            try:
                readable, _, _ = select.select(self.servers, (), (), SELECT_POLL)
            except InterruptedError:
                continue
            except (OSError, ValueError, select.error):
                return
            for srv in readable:
                try:
                    client, peer = srv.accept()
                except OSError:
                    if not self._alive:
                        return
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


class Child:
    """The loopback-only launcher, with its output in a log file."""

    LOG_LIMIT = 8 << 20

    def __init__(self, cmd: Sequence[str], log_path: str | None):
        self.cmd = list(cmd)
        self.log_path = log_path
        self._log = None
        self._stopped = False
        if log_path:
            try:
                # Append, but rotate once it passes LOG_LIMIT so a stack left
                # running for months cannot fill the disk with a copy of the
                # launcher's own output.
                mode = "ab"
                if os.path.exists(log_path) and os.path.getsize(log_path) > self.LOG_LIMIT:
                    mode = "wb"
                self._log = open(log_path, mode, buffering=0)
            except OSError as exc:
                print(f"[bind_guard] warning: cannot write {log_path} ({exc.strerror})"
                      " — launcher output goes to this terminal instead", flush=True)
                self.log_path = None
            else:
                log(f"launcher output -> {log_path}")
        self.proc = subprocess.Popen(
            self.cmd,
            stdout=self._log if self._log else None,
            stderr=subprocess.STDOUT if self._log else None,
        )

    def alive(self) -> bool:
        return self.proc.poll() is None

    def stop(self) -> None:
        # Idempotent: a second Ctrl+C re-enters the signal handler while the
        # first stop() is still waiting on the child.
        if self._stopped:
            return
        self._stopped = True
        if self.alive():
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        if self._log:
            try:
                self._log.close()
            except OSError:
                pass
            self._log = None


def port_from_env(name: str, fallback: int) -> int:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return fallback
    try:
        return int(raw)
    except ValueError:
        raise SystemExit(f"bind_guard: {name}={raw!r} is not a port number")


def main(argv: Sequence[str] | None = None) -> int:
    env = os.environ
    cmd = list(sys.argv[1:] if argv is None else argv)
    if not cmd or cmd[0] in ("-h", "--help"):
        print(__doc__)
        return 0

    public_port = port_from_env("BIND_PUBLIC_PORT", 8020)
    internal_port = port_from_env("BIND_INTERNAL_PORT", public_port + 1)
    allow = Allowlist(parse_cidrs(env.get("BIND_ALLOW_CIDRS", DEFAULT_ALLOW)), parse_list(env.get("BIND_ALLOW_HOSTS", "")))
    log_path = env.get("BIND_GUARD_LOG") or None

    if internal_port == public_port:
        raise SystemExit("bind_guard: BIND_INTERNAL_PORT must differ from BIND_PUBLIC_PORT")

    child = Child(cmd, log_path)
    gateway = Gateway(public_port, ("127.0.0.1", internal_port), allow)
    try:
        gateway.listen()
    except SystemExit:
        child.stop()
        raise

    def on_signal(signum, _frame):
        log(f"signal {signum} — stopping")
        gateway.close()
        child.stop()
        raise SystemExit(128 + signum)

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, on_signal)

    log(f"child launcher pid {child.proc.pid} on http://127.0.0.1:{internal_port} (loopback only)")
    log(f"allowed addresses: {allow.describes()}")

    gateway.serve_forever(keep_going=child.alive)
    rc = child.proc.wait()
    gateway.close()
    if rc:
        log(f"launcher exited with status {rc} — see {log_path or 'its output above'}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
