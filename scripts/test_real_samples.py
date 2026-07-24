#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import secrets
import subprocess
import tempfile
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote

import httpx

ROOT = Path(__file__).resolve().parents[1]
SAMPLE_DIR = ROOT / "tests" / "docs"


@dataclass(frozen=True, slots=True)
class ExpectedFormat:
    target_suffix: str
    media_type: str
    required_member: str


FORMATS = {
    ".wps": ExpectedFormat(
        target_suffix=".docx",
        media_type=(
            "application/vnd.openxmlformats-officedocument."
            "wordprocessingml.document"
        ),
        required_member="word/document.xml",
    ),
    ".et": ExpectedFormat(
        target_suffix=".xlsx",
        media_type=(
            "application/vnd.openxmlformats-officedocument."
            "spreadsheetml.sheet"
        ),
        required_member="xl/workbook.xml",
    ),
}


def run_docker(*arguments: str, capture: bool = False) -> str:
    result = subprocess.run(
        ["docker", *arguments],
        cwd=ROOT,
        check=True,
        text=True,
        capture_output=capture,
    )
    return result.stdout.strip() if capture else ""


def wait_until_ready(base_url: str) -> None:
    deadline = time.monotonic() + 45
    with httpx.Client(timeout=3) as client:
        while time.monotonic() < deadline:
            try:
                response = client.get(f"{base_url}/health/ready")
                if response.status_code == 200:
                    return
            except httpx.HTTPError:
                pass
            time.sleep(0.5)
    raise RuntimeError("Container did not become ready within 45 seconds")


def validate_conversion(
    client: httpx.Client,
    base_url: str,
    api_key: str,
    sample: Path,
    output_dir: Path,
) -> None:
    expected = FORMATS[sample.suffix.lower()]
    output_name = f"{sample.stem}{expected.target_suffix}"
    output_path = output_dir / output_name
    with sample.open("rb") as source:
        with client.stream(
            "POST",
            f"{base_url}/api/v1/convert",
            headers={"X-API-Key": api_key},
            files={"file": (sample.name, source, "application/octet-stream")},
        ) as response:
            if response.status_code != 200:
                error_body = response.read().decode("utf-8", "replace")
                raise RuntimeError(
                    f"{sample.name}: HTTP {response.status_code}: {error_body}"
                )
            if response.headers.get("content-type") != expected.media_type:
                raise RuntimeError(
                    f"{sample.name}: unexpected Content-Type "
                    f"{response.headers.get('content-type')}"
                )
            disposition = response.headers.get("content-disposition", "")
            encoded_name = quote(output_name, safe="")
            if f"filename*=UTF-8''{encoded_name}" not in disposition:
                raise RuntimeError(
                    f"{sample.name}: incorrect UTF-8 Content-Disposition"
                )
            with output_path.open("wb") as converted:
                for chunk in response.iter_bytes():
                    converted.write(chunk)

    if output_path.stat().st_size == 0:
        raise RuntimeError(f"{sample.name}: conversion output is empty")
    with zipfile.ZipFile(output_path) as archive:
        members = set(archive.namelist())
        if (
            "[Content_Types].xml" not in members
            or expected.required_member not in members
        ):
            raise RuntimeError(f"{sample.name}: invalid OOXML structure")
        corrupt_member = archive.testzip()
        if corrupt_member is not None:
            raise RuntimeError(
                f"{sample.name}: corrupt OOXML member {corrupt_member}"
            )
    print(
        f"PASS {sample.name} -> {output_name} "
        f"({output_path.stat().st_size} bytes)"
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Optionally convert ignored tests/docs WPS/ET samples through "
            "the production Docker image."
        )
    )
    parser.add_argument(
        "--image",
        default="wps-converter:real-sample-test",
        help="Docker image tag to build or reuse",
    )
    parser.add_argument(
        "--skip-build",
        action="store_true",
        help="Reuse --image instead of running docker build",
    )
    arguments = parser.parse_args()

    samples = sorted(
        path
        for path in SAMPLE_DIR.iterdir()
        if path.is_file() and path.suffix.lower() in FORMATS
    ) if SAMPLE_DIR.is_dir() else []
    if not samples:
        print("SKIP no .wps or .et files found under tests/docs")
        return 0

    if not arguments.skip_build:
        run_docker("build", "-t", arguments.image, ".")

    api_key = secrets.token_urlsafe(32)
    container_name = f"wps-converter-real-samples-{os.getpid()}"
    started = False
    try:
        run_docker(
            "run",
            "--rm",
            "-d",
            "--name",
            container_name,
            "--read-only",
            "--tmpfs",
            "/tmp:rw,noexec,nosuid,nodev,size=512m,mode=1777",
            "--cap-drop",
            "ALL",
            "--security-opt",
            "no-new-privileges:true",
            "-p",
            "127.0.0.1::8000",
            "-e",
            f"CONVERTER_API_KEY={api_key}",
            arguments.image,
        )
        started = True
        port_mapping = run_docker(
            "port",
            container_name,
            "8000/tcp",
            capture=True,
        ).splitlines()[0]
        host_port = port_mapping.rsplit(":", 1)[1]
        base_url = f"http://127.0.0.1:{host_port}"
        wait_until_ready(base_url)

        with tempfile.TemporaryDirectory(
            prefix="wps-converter-real-samples-"
        ) as output_directory:
            with httpx.Client(timeout=180) as client:
                for sample in samples:
                    validate_conversion(
                        client,
                        base_url,
                        api_key,
                        sample,
                        Path(output_directory),
                    )
        print(f"PASS {len(samples)} real sample(s)")
        return 0
    finally:
        if started:
            subprocess.run(
                ["docker", "stop", container_name],
                cwd=ROOT,
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )


if __name__ == "__main__":
    raise SystemExit(main())
