from __future__ import annotations

import os
import shutil
from pathlib import Path

import pytest


@pytest.fixture
def fake_soffice(tmp_path: Path) -> Path:
    executable = tmp_path / "fake-soffice"
    fixture = Path(__file__).parent / "fixtures" / "fake_soffice.py"
    shutil.copyfile(fixture, executable)
    os.chmod(executable, 0o700)
    ofd_executable = tmp_path / "fake-ofd2pdf"
    ofd_fixture = Path(__file__).parent / "fixtures" / "fake_ofd2pdf.py"
    shutil.copyfile(ofd_fixture, ofd_executable)
    os.chmod(ofd_executable, 0o700)
    return executable
