#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
import time
import zipfile
from pathlib import Path


arguments = sys.argv[1:]
source = Path(arguments[-1])
output_dir = Path(arguments[arguments.index("--outdir") + 1])
target_format = arguments[arguments.index("--convert-to") + 1]
payload = source.read_bytes()

if payload.startswith(b"SLEEP"):
    time.sleep(10)
if payload.startswith(b"FAIL"):
    raise SystemExit(7)
if payload.startswith(b"NO_OUTPUT"):
    raise SystemExit(0)

target = output_dir / f"{source.stem}.{target_format}"
if payload.startswith(b"EMPTY"):
    target.touch()
    raise SystemExit(0)
if payload.startswith(b"BADZIP"):
    target.write_bytes(b"not a zip file")
    raise SystemExit(0)

required = (
    "word/document.xml" if target_format == "docx" else "xl/workbook.xml"
)
if payload.startswith(b"WRONG"):
    required = "wrong/member.xml"

with zipfile.ZipFile(target, "w") as archive:
    archive.writestr("[Content_Types].xml", "<Types/>")
    archive.writestr(required, "<document/>")
    archive.writestr("invocation.json", json.dumps(arguments))
    archive.writestr(
        "environment.json",
        json.dumps(
            {
                "home": os.environ.get("HOME"),
                "cache": os.environ.get("XDG_CACHE_HOME"),
                "config": os.environ.get("XDG_CONFIG_HOME"),
                "tmp": os.environ.get("TMPDIR"),
                "has_api_key": "CONVERTER_API_KEY" in os.environ,
            }
        ),
    )
