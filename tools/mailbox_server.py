#!/usr/bin/env python3
"""Hong Kong CTC mailbox: Loon reports here, po0 pulls over RFC intranet."""

from __future__ import annotations

import ipaddress
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = int(os.environ.get("PO0_MAILBOX_PORT", "18443"))
BIND = os.environ.get("PO0_MAILBOX_BIND", "0.0.0.0")
TOKEN_FILE = Path(os.environ.get("PO0_MAILBOX_TOKEN_FILE", "/var/lib/po0-mailbox/token"))
STORE_FILE = Path(os.environ.get("PO0_MAILBOX_STORE", "/var/lib/po0-mailbox/clients.json"))
PULL_ALLOW = os.environ.get("PO0_MAILBOX_PULL_ALLOW", "10.100.128.90")
TTL_SEC = int(os.environ.get("PO0_MAILBOX_TTL_SEC", str(48 * 3600)))


def load_token() -> str:
    token = TOKEN_FILE.read_text(encoding="utf-8").strip()
    if not token:
        raise SystemExit("empty mailbox token")
    return token


TOKEN = load_token()
ALLOWED_PULL = {item.strip() for item in PULL_ALLOW.split(",") if item.strip()}


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


def write_store(data: dict) -> None:
    STORE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STORE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(STORE_FILE)


class Handler(BaseHTTPRequestHandler):
    server_version = "po0-mailbox/1"

    def log_message(self, fmt: str, *args) -> None:
        import sys

        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _bearer_ok(self) -> bool:
        header = self.headers.get("Authorization", "")
        given = header[7:].strip() if header.startswith("Bearer ") else ""
        return bool(given) and given == TOKEN

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path in {"/", "/health"}:
            self._send(200, {"ok": True})
            return
        if path != "/list":
            self._send(404, {"ok": False, "error": "not found"})
            return
        peer = self.client_address[0]
        if peer not in ALLOWED_PULL or not self._bearer_ok():
            self._send(403, {"ok": False, "error": "forbidden"})
            return
        data = read_store()
        write_store(data)
        self._send(200, {"ok": True, "ips": sorted(data.keys())})

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path != "/report":
            self._send(404, {"ok": False, "error": "not found"})
            return
        if not self._bearer_ok():
            self._send(401, {"ok": False, "error": "unauthorized"})
            return
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length > 4096:
            self._send(413, {"ok": False, "error": "body too large"})
            return
        if length:
            self.rfile.read(length)
        try:
            ip_obj = ipaddress.ip_address(self.client_address[0])
        except ValueError:
            self._send(400, {"ok": False, "error": "invalid peer ip"})
            return
        if ip_obj.version != 4:
            self._send(400, {"ok": False, "error": "ipv4 only"})
            return
        ip = str(ip_obj)
        data = read_store()
        prev = data.get(ip) or {}
        data[ip] = {"ts": time.time(), "hits": int(prev.get("hits", 0)) + 1}
        write_store(data)
        self._send(200, {"ok": True, "ip": ip})


def main() -> int:
    if not TOKEN_FILE.exists():
        raise SystemExit(f"missing {TOKEN_FILE}")
    STORE_FILE.parent.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    print(f"po0 mailbox listening on {BIND}:{PORT}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
