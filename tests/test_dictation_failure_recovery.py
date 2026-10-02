"""Fault-inject the production AppDelegate methods with inert I/O boundaries.

This compiles the current method bodies, not copies of the lifecycle logic.
No microphone, global keyboard monitor, model, app window, or clipboard is used.
It complements (and does not replace) the real-app release qualification.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import pytest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "WhisprStream/Sources/WhisprStream/WhisprStreamApp.swift"
METHODS = (
    "startSpeechEngine", "launchSpeechEngine", "armSpeechEngineStartupTimeout",
    "reloadASR", "beginDictation", "endDictation", "handle", "failSpeechEngine",
    "completeSpeechEngineStartup", "presentReview", "cancelCursorContextResolution",
    "scheduleDismiss", "dismissNow", "startCursorContextResolution",
    "deliverPendingTranscriptIfReady", "deliverTranscript", "deliverFinalTranscript",
    "captureDictationCursorSnapshot", "resumeDictationAfterDelivery",
)


def production_method(source, name):
    starts = list(re.finditer(rf"^    private func {name}\(", source, re.MULTILINE))
    assert len(starts) == 1, f"Expected exactly one AppDelegate.{name}"
    start = starts[0].start()
    # AppDelegate methods close at four-space indentation; nested scopes do not.
    end = source.index("\n    }\n", start) + len("\n    }\n")
    return source[start:end].replace("private func", "func", 1)


@pytest.fixture(scope="module")
def recovery_runner(tmp_path_factory):
    if sys.platform != "darwin" or not shutil.which("swiftc"):
        pytest.skip("macOS Swift compiler required")
    work = tmp_path_factory.mktemp("dictation-failure-recovery")
    source = SOURCE.read_text()
    gates = source[source.index("struct DeferredTranscriptDelivery"):source.index("@main")]
    methods = "\n".join(production_method(source, name) for name in METHODS)
    fixture = (ROOT / "tests/fixtures/dictation_failure_recovery.swift").read_text()
    assert fixture.count("// PRODUCTION_METHODS") == 1
    generated = work / "main.swift"
    generated.write_text("import Foundation\n" + gates + fixture.replace("// PRODUCTION_METHODS", methods))
    executable = work / "recovery-checks"
    command = ["swiftc", "-module-cache-path", str(work / "modules")]
    if sdk := os.environ.get("WHISPR_TEST_SWIFT_SDK"):
        command += ["-sdk", sdk]
    command += [str(generated), "-o", str(executable)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    return executable


@pytest.mark.parametrize("scenario", [
    "failures", "late-events", "retry", "launch-failure", "microphone-failure",
    "review-cancel", "review-restore", "review-insert", "review-fallback", "reload", "normal",
    "retry-failure-dismiss", "clipboard-probe-waits", "clipboard-final-waits",
    "deferred-context-snapshot", "deferred-probe-cancelled",
    "background-startup", "record-during-startup", "release-during-startup",
    "record-during-reload",
])
def test_dictation_failure_recovery(recovery_runner, scenario):
    result = subprocess.run([str(recovery_runner), scenario], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stdout + result.stderr
    assert f"PASS {scenario}" in result.stdout
