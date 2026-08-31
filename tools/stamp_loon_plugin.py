#!/usr/bin/env python3
"""Stamp loon/po0-ip-report.plugin #!date with Asia/Shanghai time and bump vX.Y."""

from __future__ import annotations

import re
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

PLUGIN = Path(__file__).resolve().parents[1] / "loon" / "po0-ip-report.plugin"
DATE_RE = re.compile(r"^#!date=.*$", re.M)
VERSION_RE = re.compile(r"v(\d+)\.(\d+)\s*$")


def main() -> int:
    text = PLUGIN.read_text(encoding="utf-8")
    match = DATE_RE.search(text)
    if not match:
        raise SystemExit("missing #!date= in plugin")
    current = match.group(0)
    version = VERSION_RE.search(current)
    if version:
        major, minor = int(version.group(1)), int(version.group(2)) + 1
    else:
        major, minor = 1, 6
    now = datetime.now(ZoneInfo("Asia/Shanghai")).strftime("%Y-%m-%d %H:%M")
    stamped = f"#!date={now} v{major}.{minor}"
    PLUGIN.write_text(DATE_RE.sub(stamped, text, count=1), encoding="utf-8")
    print(stamped)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
