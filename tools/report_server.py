#!/usr/bin/env python3
"""Token-authenticated IP report API for Loon DIRECT egress allowlisting."""

from __future__ import annotations

import ipaddress
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


PORT = int(os.environ.get("PO0_REPORT_PORT", "41741"))
TOKEN_FILE = Path(os.environ.get("PO0_TOKEN_FILE", "/var/lib/po0_whitelist/report.token"))
SET_NAME = os.environ.get("PO0_CLIENT_SET_NAME", "po0_client_ips")
SAVE_FILE = Path(os.environ.get("PO0_CLIENT_SAVE", "/var/lib/po0_whitelist/client.ipset"))
BIND = os.environ.get("PO0_REPORT_BIND", "0.0.0.0")


def load_token() -> str:
    if not TOKEN_FILE.exists():
        raise SystemExit(f"missing token file: {TOKEN_FILE}")
    token = TOKEN_FILE.read_text(encoding="utf-8").strip()
    if not token:
        raise SystemExit("empty report token")
    return token


TOKEN = load_token()


def ensure_set() -> None:
    subprocess.run(
        ["ipset", "create", SET_NAME, "hash:ip", "family", "inet", "-exist"],
        check=True,
        capture_output=True,
    )


def add_ip(ip: str) -> None:
    ensure_set()
    subprocess.run(["ipset", "add", SET_NAME, ip, "-exist"], check=True, capture_output=True)
    SAVE_FILE.parent.mkdir(parents=True, exist_ok=True)
    saved = subprocess.run(["ipset", "save", SET_NAME], check=True, capture_output=True, text=True)
    SAVE_FILE.write_text(saved.stdout, encoding="utf-8")


def restore_set() -> None:
    ensure_set()
    if SAVE_FILE.exists() and SAVE_FILE.stat().st_size > 0:
        subprocess.run(["ipset", "restore", "-exist", "-f", str(SAVE_FILE)], check=False, capture_output=True)


def json_bytes(payload: dict, status: int = 200) -> tuple[int, bytes]:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    return status, body


class Handler(BaseHTTPRequestHandler):
    server_version = "po0-report/1"

    def log_message(self, fmt: str, *args) -> None:
        sys_stderr = __import__("sys").stderr
        sys_stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, status: int, payload: dict) -> None:
        status, body = json_bytes(payload, status)
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        if header.startswith("Bearer "):
            given = header[7:].strip()
        else:
            given = self.headers.get("X-Po0-Token", "").strip()
        return bool(given) and given == TOKEN

    def do_GET(self) -> None:  # noqa: N802
        if self.path.split("?", 1)[0] in {"/", "/health"}:
            self._send(200, {"ok": True})
            return
        self._send(404, {"ok": False, "error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path != "/report":
            self._send(404, {"ok": False, "error": "not found"})
            return
        if not self._authorized():
            self._send(401, {"ok": False, "error": "unauthorized"})
            return
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length > 4096:
            self._send(413, {"ok": False, "error": "body too large"})
            return
        if length:
            self.rfile.read(length)
        raw_ip = self.client_address[0]
        try:
            ip_obj = ipaddress.ip_address(raw_ip)
        except ValueError:
            self._send(400, {"ok": False, "error": "invalid peer ip"})
            return
        if ip_obj.version != 4:
            self._send(400, {"ok": False, "error": "ipv4 only"})
            return
        ip = str(ip_obj)
        try:
            add_ip(ip)
        except subprocess.CalledProcessError as exc:
            self._send(500, {"ok": False, "error": "ipset failed", "detail": exc.returncode})
            return
        self._send(200, {"ok": True, "ip": ip})


def main() -> int:
    restore_set()
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    print(f"po0 report listening on {BIND}:{PORT}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
