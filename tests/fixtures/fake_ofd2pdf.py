#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from pypdf import PdfWriter


arguments = sys.argv[1:]
source = Path(arguments[0])
target = Path(arguments[1])
payload = source.read_bytes()

if payload.startswith(b"SLEEP"):
    time.sleep(10)
if payload.startswith(b"FAIL"):
    raise SystemExit(7)
if payload.startswith(b"NO_OUTPUT"):
    raise SystemExit(0)
if payload.startswith(b"EMPTY"):
    target.touch()
    raise SystemExit(0)
if payload.startswith(b"BADPDF"):
    target.write_bytes(b"not a pdf file")
    raise SystemExit(0)
if payload.startswith(b"TRUNCATED"):
    target.write_bytes(b"%PDF-1.4\n1 0 obj\n")
    raise SystemExit(0)

writer = PdfWriter()
writer.add_blank_page(width=595, height=842)
writer.add_metadata(
    {
        "/Producer": "fake-ofd2pdf",
        "/Subject": json.dumps(
            {
                "arguments": arguments,
                "environment": {
                    "home": os.environ.get("HOME"),
                    "cache": os.environ.get("XDG_CACHE_HOME"),
                    "config": os.environ.get("XDG_CONFIG_HOME"),
                    "tmp": os.environ.get("TMPDIR"),
                    "has_api_key": "CONVERTER_API_KEY" in os.environ,
                },
            }
        ),
    }
)
with target.open("wb") as output:
    writer.write(output)
