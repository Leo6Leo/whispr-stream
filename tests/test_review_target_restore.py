"""Exercise the production review focus code with inert AppKit/AX boundaries.

The generated runner uses the current capture/restore methods, so a custom
editor with no Accessibility caret must actually reach the paste target path.
No applications are activated and no clipboard or user documents are touched.
"""

import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def review_target_runner(tmp_path_factory):
    if sys.platform != "darwin" or not shutil.which("swiftc"):
        pytest.skip("macOS Swift compiler required")
    work = tmp_path_factory.mktemp("review-target-restore")
    source = (ROOT / "WhisprStream/Sources/WhisprStream/TextInserter.swift").read_text()
    production = source[source.index("enum TextInserter {"):source.index("    private struct PasteboardSnapshot")]
    fixture = (ROOT / "tests/fixtures/review_target_restore.swift").read_text()
    generated = work / "main.swift"
    generated.write_text(fixture.replace("// PRODUCTION_REVIEW_TARGET", production))
    executable = work / "review-target-checks"
    command = ["swiftc", "-module-cache-path", str(work / "modules")]
    if sdk := os.environ.get("WHISPR_TEST_SWIFT_SDK"):
        command += ["-sdk", sdk]
    result = subprocess.run(command + [str(generated), "-o", str(executable)],
                            capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    return executable


@pytest.mark.parametrize("scenario", [
    "no-accessibility", "no-selection", "range", "text-markers",
    "document-changed", "window-changed", "window-closed", "application-quit",
    "stale-review", "activation-refused", "foreign-element", "unknown-window",
])
def test_review_target_restore(review_target_runner, scenario):
    result = subprocess.run([str(review_target_runner), scenario],
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stdout + result.stderr
    assert f"PASS {scenario}" in result.stdout
