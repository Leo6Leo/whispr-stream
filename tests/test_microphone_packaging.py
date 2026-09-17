"""Exercise the release gate against real signed macOS app bundles."""

from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

import pytest


ROOT = Path(__file__).parents[1]
VALIDATOR = ROOT / "WhisprStream/validate-microphone-permission.sh"
pytestmark = pytest.mark.skipif(sys.platform != "darwin", reason="macOS codesign required")


def signed_app(tmp_path, entitlement, description="Test microphone access"):
    app = tmp_path / "Microphone Test.app"
    contents = app / "Contents"
    executable = contents / "MacOS/MicrophoneTest"
    executable.parent.mkdir(parents=True)
    shutil.copyfile("/usr/bin/true", executable)
    executable.chmod(0o755)
    info = {
        "CFBundleIdentifier": "dev.whisprstream.microphone-packaging-test",
        "CFBundleExecutable": "MicrophoneTest",
        "CFBundlePackageType": "APPL",
    }
    if description is not None:
        info["NSMicrophoneUsageDescription"] = description
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    command = ["codesign", "--force", "--sign", "-", "--options", "runtime,library"]
    if entitlement is True:
        command += ["--entitlements", str(ROOT / "WhisprStream/WhisprStream.entitlements")]
    elif entitlement is False:
        denied = tmp_path / "denied.plist"
        denied.write_bytes(plistlib.dumps({"com.apple.security.device.audio-input": False}))
        command += ["--entitlements", str(denied)]
    subprocess.run(command + [str(app)], check=True, capture_output=True)
    subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True, capture_output=True)
    return app


@pytest.mark.parametrize(
    "entitlement,description,error",
    [
        (True, "Test microphone access", None),
        (None, "Test microphone access", "audio-input"),
        (False, "Test microphone access", "audio-input"),
        (True, None, "NSMicrophoneUsageDescription"),
        (True, "   ", "NSMicrophoneUsageDescription"),
    ],
)
def test_signed_microphone_requirements(tmp_path, entitlement, description, error):
    app = signed_app(tmp_path, entitlement, description)
    result = subprocess.run(["bash", str(VALIDATOR), str(app)], capture_output=True, text=True)
    if error is None:
        assert result.returncode == 0, result.stderr
    else:
        assert result.returncode != 0
        assert error in result.stderr
