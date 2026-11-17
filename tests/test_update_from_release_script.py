"""Keep WhisprStream/test-update-from-release.sh from rotting silently.

The live update test launches the app and drives its UI, so it is never run
here. Its --check mode is: it verifies the tools, the old tag, the release
pins, and every log line and label the live run waits for, in both the old tag
and the current tree, in well under a second. The --prepare-only pass builds
two app bundles and takes minutes; it runs only when
WHISPR_RUN_UPDATE_FROM_RELEASE_PREPARE=1 is set.
"""

import os
from pathlib import Path
import subprocess
import sys

import pytest


ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "WhisprStream/test-update-from-release.sh"
DEFAULT_OLD_TAG = "v1.0.5"
pytestmark = pytest.mark.skipif(sys.platform != "darwin", reason="macOS updater test")


def has_tag(tag):
    return subprocess.run(
        ["git", "-C", str(ROOT), "rev-parse", "--verify", "--quiet", f"refs/tags/{tag}^{{commit}}"],
        capture_output=True,
    ).returncode == 0


def run_script(*arguments, timeout=60, env=None):
    return subprocess.run(
        [str(SCRIPT), *arguments],
        capture_output=True,
        text=True,
        timeout=timeout,
        env=env,
    )


def test_script_is_valid_bash():
    result = subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


def test_unknown_option_prints_usage():
    result = run_script("--no-such-option")
    assert result.returncode == 2
    assert "usage: test-update-from-release.sh" in result.stdout


@pytest.mark.skipif(not has_tag(DEFAULT_OLD_TAG), reason=f"tag {DEFAULT_OLD_TAG} is not fetched")
def test_static_check_for_default_tag():
    result = run_script("--check")
    assert result.returncode == 0, result.stdout + result.stderr
    assert f"Static checks passed for {DEFAULT_OLD_TAG} ->" in result.stdout
    # 1.0.4 and later run the replacement's helper, which uses LaunchServices.
    assert "no self-relaunch" in result.stdout


@pytest.mark.skipif(not has_tag("v1.0.3"), reason="tag v1.0.3 is not fetched")
def test_static_check_expects_self_relaunch_from_a_pre_104_helper():
    result = run_script("v1.0.3", "--check")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "the new app must relaunch itself" in result.stdout


def test_static_check_rejects_unknown_tag():
    result = run_script("v0.0.0-not-a-tag", "--check")
    assert result.returncode != 0


@pytest.mark.skipif(
    os.environ.get("WHISPR_RUN_UPDATE_FROM_RELEASE_PREPARE") != "1",
    reason="set WHISPR_RUN_UPDATE_FROM_RELEASE_PREPARE=1 to build and serve both bundles (minutes)",
)
def test_prepare_only_builds_signs_and_serves():
    result = run_script("--prepare-only", timeout=3600, env=dict(os.environ))
    assert result.returncode == 0, result.stdout[-4000:] + result.stderr[-4000:]
    assert "Preparation passed" in result.stdout
