#!/usr/bin/env python3
"""Overseas mailbox: Loon reports here, the firewall host pulls the list outbound."""

from __future__ import annotations

import ipaddress
import json
import os
import re
import ssl
import threading
import time
import urllib.error
import urllib.request
from collections import defaultdict, deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = int(os.environ.get("PO0_MAILBOX_PORT", "18443"))
BIND = os.environ.get("PO0_MAILBOX_BIND", "0.0.0.0")
TOKEN_FILE = Path(os.environ.get("PO0_MAILBOX_TOKEN_FILE", "/var/lib/po0-mailbox/token"))
STORE_FILE = Path(os.environ.get("PO0_MAILBOX_STORE", "/var/lib/po0-mailbox/clients.json"))
PULL_ALLOW = os.environ.get("PO0_MAILBOX_PULL_ALLOW", "")
TTL_SEC = int(os.environ.get("PO0_MAILBOX_TTL_SEC", str(48 * 3600)))
TLS_CERT = os.environ.get("PO0_MAILBOX_TLS_CERT", "").strip()
TLS_KEY = os.environ.get("PO0_MAILBOX_TLS_KEY", "").strip()
RATE_WINDOW_SEC = float(os.environ.get("PO0_MAILBOX_RATE_WINDOW_SEC", "60"))
RATE_MAX_HITS = int(os.environ.get("PO0_MAILBOX_RATE_MAX_HITS", "120"))
RATE_MAX_FAILS = int(os.environ.get("PO0_MAILBOX_RATE_MAX_FAILS", "20"))
UPDATE_TTL_SEC = int(os.environ.get("PO0_MAILBOX_UPDATE_TTL_SEC", "300"))
UPDATE_REPO = os.environ.get("PO0_MAILBOX_UPDATE_REPO", "rollingshmily/po0_whitelist")
UPDATE_BRANCH = os.environ.get("PO0_MAILBOX_UPDATE_BRANCH", "main")
UPDATE_LOCK = threading.Lock()


def load_token() -> str:
    token = TOKEN_FILE.read_text(encoding="utf-8").strip()
    if not token:
        raise SystemExit("empty mailbox token")
    return token


def parse_allow_list(raw: str) -> set[str]:
    parts = re.split(r"[,\uff0c\u3001;；\s]+", raw or "")
    allowed: set[str] = set()
    for part in parts:
        item = part.strip().strip("\"'")
        if not item:
            continue
        try:
            allowed.add(str(ipaddress.ip_address(item)))
        except ValueError:
            continue
    return allowed


class RateLimiter:
    def __init__(self, window_sec: float, max_hits: int, max_fails: int) -> None:
        self.window_sec = window_sec
        self.max_hits = max_hits
        self.max_fails = max_fails
        self._hits: dict[str, deque[float]] = defaultdict(deque)
        self._fails: dict[str, deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()

    def _prune(self, dq: deque[float], now: float) -> None:
        cutoff = now - self.window_sec
        while dq and dq[0] <= cutoff:
            dq.popleft()

    def allow(self, ip: str) -> bool:
        now = time.monotonic()
        with self._lock:
            hits = self._hits[ip]
            fails = self._fails[ip]
            self._prune(hits, now)
            self._prune(fails, now)
            if len(hits) >= self.max_hits or len(fails) >= self.max_fails:
                return False
            hits.append(now)
            return True

    def fail(self, ip: str) -> None:
        now = time.monotonic()
        with self._lock:
            fails = self._fails[ip]
            self._prune(fails, now)
            fails.append(now)


TOKEN = ""
ALLOWED_PULL: set[str] = set()
LIMITER = RateLimiter(RATE_WINDOW_SEC, RATE_MAX_HITS, RATE_MAX_FAILS)


def read_store() -> dict:
    if not STORE_FILE.exists():
        return {}
    try:
        data = json.loads(STORE_FILE.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}
    now = time.time()
    return {
        ip: meta
        for ip, meta in data.items()
        if isinstance(meta, dict) and now - float(meta.get("ts", 0)) <= TTL_SEC
    }


def update_cache_path() -> Path:
    return STORE_FILE.parent / "update.tar.gz"


def refresh_update_archive() -> Path:
    cache = update_cache_path()
    cache.parent.mkdir(parents=True, exist_ok=True)
    url = f"https://github.com/{UPDATE_REPO}/archive/refs/heads/{UPDATE_BRANCH}.tar.gz"
    with UPDATE_LOCK:
        if cache.exists() and time.time() - cache.stat().st_mtime < UPDATE_TTL_SEC:
            return cache
        tmp = cache.with_suffix(".tmp")
        req = urllib.request.Request(url, headers={"User-Agent": "po0-mailbox-update"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            blob = resp.read()
        if len(blob) < 100 or blob[:2] != b"\x1f\x8b":
            raise RuntimeError("invalid github archive")
        tmp.write_bytes(blob)
        tmp.replace(cache)
        return cache


def write_store(data: dict) -> None:
    STORE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STORE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(STORE_FILE)


class Handler(BaseHTTPRequestHandler):
    server_version = "mailbox"
    sys_version = ""

    def log_message(self, fmt: str, *args) -> None:
        import sys

        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _peer(self) -> str:
        return self.client_address[0]

    def _gated(self) -> bool:
        return LIMITER.allow(self._peer())

    def _deny(self, status: int, error: str, *, failed: bool) -> None:
        if failed:
            LIMITER.fail(self._peer())
        self._send(status, {"ok": False, "error": error})

    def _send(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, path: Path) -> None:
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Content-Disposition", "attachment; filename=po0_whitelist.tar.gz")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _pull_auth_ok(self) -> bool:
        return self._bearer_ok() and self._peer() in ALLOWED_PULL

    def _bearer_ok(self) -> bool:
        header = self.headers.get("Authorization", "")
        given = header[7:].strip() if header.startswith("Bearer ") else ""
        return bool(TOKEN) and bool(given) and given == TOKEN

    def do_GET(self) -> None:  # noqa: N802
        if not self._gated():
            self._send(429, {"ok": False, "error": "too many requests"})
            return
        path = self.path.split("?", 1)[0]
        if path not in {"/list", "/update"}:
            self._send(404, {"ok": False, "error": "not found"})
            return
        if not self._pull_auth_ok():
            self._deny(403, "forbidden", failed=True)
            return
        if path == "/update":
            try:
                archive = refresh_update_archive()
            except (OSError, RuntimeError, urllib.error.URLError, TimeoutError) as exc:
                self.log_error("update fetch failed: %s", exc)
                self._send(502, {"ok": False, "error": "update fetch failed"})
                return
            self._send_file(archive)
            return
        data = read_store()
        write_store(data)
        self._send(200, {"ok": True, "ips": sorted(data.keys())})

    def do_POST(self) -> None:  # noqa: N802
        if not self._gated():
            self._send(429, {"ok": False, "error": "too many requests"})
            return
        path = self.path.split("?", 1)[0]
        if path != "/report":
            self._send(404, {"ok": False, "error": "not found"})
            return
        if not self._bearer_ok():
            self._deny(401, "unauthorized", failed=True)
            return
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length > 4096:
            self._deny(413, "body too large", failed=True)
            return
        if length:
            self.rfile.read(length)
        try:
            ip_obj = ipaddress.ip_address(self._peer())
        except ValueError:
            self._deny(400, "invalid peer ip", failed=True)
            return
        if ip_obj.version != 4:
            self._deny(400, "ipv4 only", failed=True)
            return
        ip = str(ip_obj)
        data = read_store()
        prev = data.get(ip) or {}
        data[ip] = {"ts": time.time(), "hits": int(prev.get("hits", 0)) + 1}
        write_store(data)
        self._send(200, {"ok": True, "ip": ip})


def configure() -> None:
    global TOKEN, ALLOWED_PULL, LIMITER
    if not TOKEN_FILE.exists():
        raise SystemExit(f"missing {TOKEN_FILE}")
    TOKEN = load_token()
    ALLOWED_PULL = parse_allow_list(os.environ.get("PO0_MAILBOX_PULL_ALLOW", PULL_ALLOW))
    LIMITER = RateLimiter(RATE_WINDOW_SEC, RATE_MAX_HITS, RATE_MAX_FAILS)


def wrap_tls(server: ThreadingHTTPServer) -> str:
    if not TLS_CERT or not TLS_KEY:
        return "http"
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(TLS_CERT, TLS_KEY)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    return "https"


def main() -> int:
    configure()
    STORE_FILE.parent.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    scheme = wrap_tls(server)
    print(f"po0 mailbox listening on {scheme}://{BIND}:{PORT}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
