"""First-install checks for the model download helper and the speech sidecar.

These run the real `model_download.py` and `asr_server.py` as the app does:
the same interpreter flags and the environment produced by
`PythonProcessEnvironment.sanitized` (parsed from the Swift source), applied
to a deliberately hostile shell environment (poisoned PYTHONPATH with fake
numpy/mlx/huggingface_hub, bogus PYTHONHOME, active venv/conda variables,
Homebrew first in PATH). Every run uses a temporary HOME and HF_HOME; the
real Hugging Face cache is only ever read, through symlinks.

Tiers:

* Default (about 2 s): the sanitizer contract, a fresh model download, and an
  offline first run against a loopback Hub. Needs an interpreter with
  huggingface_hub 1.x: the installed release runtime when
  ``WHISPR_E2E_RUNTIME`` is set, otherwise the repository ``.venv``.
* ``WHISPR_E2E=1``: also Hub outage, insufficient space, cancel with
  partial cleanup, and a dropped connection (the Hub client retries with
  back-off for about five seconds), about 10 s more.
* ``WHISPR_E2E_RUNTIME=<installed Runtime dir>``: the sidecar from that
  runtime, including a real model load and transcription offline when the
  Qwen3-ASR-0.6B cache exists. `WhisprStream/test-first-install-e2e.sh`
  installs the runtime with the app's own installer and sets this, plus
  ``WHISPR_E2E_APP`` so the candidate's bundled scripts are the ones tested.
"""

from __future__ import annotations

import base64
import functools
import importlib.util
import json
import os
import plistlib
import re
import selectors
import shutil
import signal
import socket
import subprocess
import sys
import time
import wave
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))
from hf_loopback import COMMIT, FakeHub, REPO, tiny_qwen_repo  # noqa: E402

ROOT = Path(__file__).parents[1]
APP = Path(os.environ["WHISPR_E2E_APP"]) if os.environ.get("WHISPR_E2E_APP") else None
RESOURCES = APP / "Contents" / "Resources" if APP else ROOT / "WhisprStream" / "Resources"
RUNTIME = Path(os.environ["WHISPR_E2E_RUNTIME"]) if os.environ.get("WHISPR_E2E_RUNTIME") else None
SLOW = os.environ.get("WHISPR_E2E") == "1"
REAL_MODEL = Path.home() / ".cache" / "huggingface" / "hub" / "models--Qwen--Qwen3-ASR-0.6B"
SWIFT_ENVIRONMENT = ROOT / "WhisprStream" / "Sources" / "WhisprStream" / "PythonProcessEnvironment.swift"

needs_runtime = pytest.mark.skipif(RUNTIME is None, reason="set WHISPR_E2E_RUNTIME (test-first-install-e2e.sh)")
slow = pytest.mark.skipif(not SLOW, reason="set WHISPR_E2E=1")


# -- the app's process contract ----------------------------------------------


@functools.cache
def sanitizer() -> tuple[frozenset[str], dict[str, str], list[str]]:
    """Removed keys, forced values, and flags from PythonProcessEnvironment.swift."""
    source = SWIFT_ENVIRONMENT.read_text(encoding="utf-8")
    block = re.search(r"removedKeys: Set<String> = \[(.*?)\]", source, re.S)
    assert block, "PythonProcessEnvironment.removedKeys not found"
    removed = frozenset(re.findall(r'"([A-Z_]+)"', block.group(1)))
    forced = dict(re.findall(r'environment\["([A-Z_]+)"\] = "([^"]*)"', source))
    flags = re.search(r'scriptArguments\(.*?\n\s*\[((?:"-\w", )+)script\.path\]', source, re.S)
    assert flags, "PythonProcessEnvironment.scriptArguments not found"
    return removed, forced, re.findall(r'"(-\w)"', flags.group(1))


def app_environment(base: dict[str, str], additions: dict[str, str]) -> dict[str, str]:
    removed, forced, _ = sanitizer()
    environment = {key: value for key, value in base.items() if key not in removed}
    environment.update(forced)
    environment.update(additions)
    return environment


def app_command(python: Path, script: Path, *arguments: str) -> list[str]:
    return [str(python), *sanitizer()[2], str(script), *arguments]


def test_sanitizer_contract_is_parsed():
    removed, forced, flags = sanitizer()
    assert {"PYTHONPATH", "PYTHONHOME", "VIRTUAL_ENV", "CONDA_PREFIX"} <= removed
    assert forced == {
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONNOUSERSITE": "1",
        "PYTHONUNBUFFERED": "1",
    }
    assert flags == ["-B", "-s", "-u"]


@pytest.fixture
def hostile(tmp_path) -> dict[str, str]:
    """A shell environment that breaks any Python that honours it."""
    poison = tmp_path / "poison"
    for module in ("numpy", "mlx", "huggingface_hub", "mlx_qwen3_asr", "httpx"):
        (poison / module).mkdir(parents=True)
        (poison / module / "__init__.py").write_text(
            f"raise ImportError('poisoned {module} from PYTHONPATH')\n", encoding="utf-8"
        )
    (poison / "sitecustomize.py").write_text("raise SystemExit('poisoned sitecustomize')\n", encoding="utf-8")
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    for name in ("python3", "python3.12", "python"):
        (fake_bin / name).write_text("#!/bin/sh\nexit 97\n", encoding="utf-8")
        (fake_bin / name).chmod(0o755)
    home = tmp_path / "home"
    home.mkdir()
    return {
        "HOME": str(home),
        "PATH": f"{fake_bin}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "PYTHONPATH": str(poison),
        "PYTHONHOME": str(tmp_path / "no-such-python-home"),
        "PYTHONSTARTUP": str(poison / "sitecustomize.py"),
        "VIRTUAL_ENV": str(tmp_path / "venv"),
        "CONDA_PREFIX": str(tmp_path / "conda"),
        "CONDA_DEFAULT_ENV": "poisoned",
        "_OLD_VIRTUAL_PATH": "/usr/bin",
        "DYLD_LIBRARY_PATH": str(poison),
        "LANG": "en_US.UTF-8",
        "TMPDIR": str(tmp_path),
    }


# -- interpreters ---------------------------------------------------------------


@functools.cache
def helper_python() -> Path | None:
    if RUNTIME is not None:
        return RUNTIME / "bin" / "python3.12"
    venv = ROOT / ".venv" / "bin" / "python"
    if not venv.exists():
        return None
    probe = subprocess.run(
        [str(venv), "-B", "-s", "-c", "import huggingface_hub as h; print(h.__version__)"],
        capture_output=True, text=True, env={"PATH": "/usr/bin:/bin"},
    )
    if probe.returncode != 0 or not probe.stdout.startswith("1."):
        return None
    return venv


@pytest.fixture
def python() -> Path:
    found = helper_python()
    if found is None:
        pytest.skip("needs the release runtime (WHISPR_E2E_RUNTIME) or a .venv with huggingface_hub 1.x")
    return found


# -- model download helper ------------------------------------------------------


def closed_port_endpoint() -> str:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    return f"http://127.0.0.1:{port}"


def helper_env(hostile: dict[str, str], endpoint: str) -> dict[str, str]:
    home = Path(hostile["HOME"])
    return app_environment(hostile, {"HF_HOME": str(home / "hf"), "HF_ENDPOINT": endpoint})


def run_helper(python: Path, env: dict[str, str], mode: str, timeout: float = 30) -> tuple[int, list[dict]]:
    # ModelDownloader passes [mode, repo, engine] and discards stderr.
    process = subprocess.run(
        app_command(python, RESOURCES / "model_download.py", mode, REPO, "qwen3"),
        env=env, capture_output=True, text=True, timeout=timeout,
    )
    events = [json.loads(line) for line in process.stdout.splitlines() if line.strip()]
    return process.returncode, events


def repo_dir(env: dict[str, str]) -> Path:
    return Path(env["HF_HOME"]) / "hub" / ("models--" + REPO.replace("/", "--"))


def app_considers_installed(env: dict[str, str]) -> bool:
    """ModelCatalog.state: some snapshot has config.json plus Qwen weights."""
    snapshots = repo_dir(env) / "snapshots"
    if not snapshots.is_dir():
        return False
    return any(
        (snapshot / "config.json").is_file()
        and ((snapshot / "model.safetensors").is_file() or (snapshot / "model.safetensors.index.json").is_file())
        for snapshot in snapshots.iterdir()
    )


def incomplete(env: dict[str, str]) -> list[Path]:
    blobs = repo_dir(env) / "blobs"
    return sorted(blobs.glob("*.incomplete")) if blobs.is_dir() else []


def outside_hf_home(env: dict[str, str]) -> list[str]:
    home = Path(env["HOME"])
    hf = Path(env["HF_HOME"])
    return sorted(
        str(path.relative_to(home))
        for path in home.rglob("*")
        if path.is_file() and hf not in path.parents
    )


def test_fresh_download_installs_only_the_app_patterns(python, hostile):
    files = tiny_qwen_repo()
    with FakeHub(files) as hub:
        env = helper_env(hostile, hub.endpoint)
        status, events = run_helper(python, env, "--preflight")
        assert status == 0, events
        (preflight,) = events
        expected_total = sum(len(data) for name, data in files.items() if name != "README.md")
        assert preflight["totalBytes"] == expected_total
        assert preflight["incompleteBytes"] == 0 and preflight["reusableBytes"] == 0
        assert preflight["availableBytes"] >= preflight["requiredBytes"]
        assert Path(preflight["cacheRoot"]).resolve() == (Path(env["HF_HOME"]) / "hub").resolve()
        assert not app_considers_installed(env)

        status, events = run_helper(python, env, "--download")
        assert status == 0, events
        kinds = [event["type"] for event in events]
        assert kinds[0] == "total" and kinds[-1] == "done"
        progress = [event["bytes"] for event in events if event["type"] == "progress"]
        assert progress == sorted(progress) and progress[-1] == expected_total
        assert app_considers_installed(env)
        snapshot = Path(events[-1]["path"])
        assert snapshot.resolve() == (repo_dir(env) / "snapshots" / COMMIT).resolve()
        assert sorted(path.name for path in snapshot.iterdir()) == [
            "config.json", "merges.txt", "model.safetensors", "vocab.json"
        ]
        assert (snapshot / "model.safetensors").read_bytes() == files["model.safetensors"]
        assert not any("README" in request for request in hub.requests)
        assert incomplete(env) == []
    assert outside_hf_home(env) == []


def test_offline_first_run_reports_a_connection_problem_and_writes_nothing(python, hostile):
    env = helper_env(hostile, closed_port_endpoint())
    for mode in ("--preflight", "--download"):
        status, events = run_helper(python, env, mode)
        assert status == 1
        assert events[-1]["type"] == "error"
        # ModelDownloader maps "metadata" to "Check your connection and try again."
        assert events[-1]["category"] == "metadata", events
    assert not repo_dir(env).exists()
    assert not app_considers_installed(env)


@slow
def test_hub_outage_is_reported_as_metadata_failure(python, hostile):
    with FakeHub(tiny_qwen_repo(), mode="metadata_500") as hub:
        env = helper_env(hostile, hub.endpoint)
        status, events = run_helper(python, env, "--download")
    assert status == 1 and events[-1]["category"] == "metadata"
    assert not repo_dir(env).exists()


@slow
def test_insufficient_space_stops_before_any_weight_is_fetched(python, hostile):
    # Claim a model larger than any disk; the real free space is measured.
    with FakeHub(tiny_qwen_repo(), reported_sizes={"model.safetensors": 1 << 60}) as hub:
        env = helper_env(hostile, hub.endpoint)
        status, events = run_helper(python, env, "--preflight")
        assert status == 0
        assert events[-1]["availableBytes"] < events[-1]["requiredBytes"]

        status, events = run_helper(python, env, "--download")
        assert status == 1
        assert events[-1]["category"] == "storage", events
        assert events[-1]["requiredBytes"] > events[-1]["availableBytes"]
        assert not any("/resolve/" in request for request in hub.requests)
    assert not app_considers_installed(env)


def wait_for(predicate, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return predicate()


@slow
def test_cancelled_download_leaves_a_partial_that_setup_offers_to_clean(python, hostile):
    # huggingface_hub writes in 10 MB chunks; stall after half of 24 MB so a
    # real partial blob reaches the disk before the user cancels.
    files = tiny_qwen_repo(weight_bytes=24 * 1024 * 1024)
    with FakeHub(files, mode="stall") as hub:
        env = helper_env(hostile, hub.endpoint)
        process = subprocess.Popen(
            app_command(python, RESOURCES / "model_download.py", "--download", REPO, "qwen3"),
            env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        )
        try:
            assert wait_for(lambda: any(p.stat().st_size > 0 for p in incomplete(env)), 20), \
                "the stalled download never wrote a partial file"
            # While it runs, Settings' cleanup must refuse to touch its files.
            status, events = run_helper(python, env, "--cleanup")
            assert status == 1 and "active" in events[-1]["message"], events
        finally:
            # ModelDownloader.cancel() calls Process.terminate(): SIGTERM.
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=10)
        assert process.returncode != 0
        partial = incomplete(env)
        assert partial, "cancel should leave the interrupted blob for cleanup"
        assert not app_considers_installed(env)

    # The next attempt's preflight reports it, so setup shows the cleanup prompt.
    with FakeHub(files) as hub:
        env["HF_ENDPOINT"] = hub.endpoint
        status, events = run_helper(python, env, "--preflight")
        assert status == 0
        assert events[-1]["incompleteBytes"] == sum(p.stat().st_size for p in partial) > 0
        completed_before = sorted(
            p.name for p in (repo_dir(env) / "blobs").iterdir() if not p.name.endswith(".incomplete")
        )

        status, events = run_helper(python, env, "--cleanup")
        assert status == 0
        assert events[-1]["type"] == "cleanup"
        assert sorted(events[-1]["files"]) == sorted(p.name for p in partial)
        assert incomplete(env) == []
        completed_after = sorted(p.name for p in (repo_dir(env) / "blobs").iterdir())
        assert completed_after == completed_before, "cleanup removed completed blobs"

        status, events = run_helper(python, env, "--download")
        assert status == 0, events
        assert app_considers_installed(env)


@slow
def test_dropped_connection_fails_without_installing_a_model(python, hostile):
    with FakeHub(tiny_qwen_repo(), mode="truncate") as hub:
        env = helper_env(hostile, hub.endpoint)
        status, events = run_helper(python, env, "--download", timeout=60)
    assert status == 1
    assert events[-1]["category"] == "network", events
    assert not app_considers_installed(env)


# -- installed runtime and sidecar -----------------------------------------------


def load_digest_tool():
    spec = importlib.util.spec_from_file_location(
        "runtime_content_sha256", ROOT / "WhisprStream" / "runtime-content-sha256.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@needs_runtime
def test_installed_runtime_matches_the_candidate_pin():
    if APP is None:
        pytest.skip("set WHISPR_E2E_APP to compare with the candidate's Info.plist")
    with (APP / "Contents" / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    manifest = json.loads((RUNTIME / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["runtimeVersion"] == info["WhisprRuntimeVersion"]
    assert manifest["payloadBytes"] == int(info["WhisprRuntimeInstalledBytes"])
    assert load_digest_tool().content_digest(RUNTIME) == info["WhisprRuntimeContentSHA256"].lower()


def mirror_model_cache(hf_home: Path) -> None:
    """A private HF cache whose snapshot files are symlinks into the real one."""
    if not (REAL_MODEL / "refs" / "main").is_file():
        pytest.skip(f"no cached Qwen3-ASR-0.6B at {REAL_MODEL}")
    revision = (REAL_MODEL / "refs" / "main").read_text(encoding="utf-8").strip()
    source = REAL_MODEL / "snapshots" / revision
    repo = hf_home / "hub" / REAL_MODEL.name
    (repo / "refs").mkdir(parents=True)
    (repo / "refs" / "main").write_text(revision, encoding="utf-8")
    target = repo / "snapshots" / revision
    target.mkdir(parents=True)
    for entry in source.iterdir():
        (target / entry.name).symlink_to(entry.resolve())


@pytest.fixture(scope="session")
def speech_pcm(tmp_path_factory) -> bytes:
    if not shutil.which("say") or not shutil.which("afconvert"):
        pytest.skip("needs macOS say and afconvert")
    folder = tmp_path_factory.mktemp("speech")
    aiff, wav = folder / "speech.aiff", folder / "speech.wav"
    subprocess.run(["say", "-o", str(aiff), "Hello world, this is a first install test."], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)], check=True)
    with wave.open(str(wav)) as clip:
        assert clip.getframerate() == 16000 and clip.getnchannels() == 1 and clip.getsampwidth() == 2
        return clip.readframes(clip.getnframes())


class Sidecar:
    """Drives asr_server.py over stdin/stdout like ASRService."""

    def __init__(self, env: dict[str, str]):
        self.process = subprocess.Popen(
            app_command(RUNTIME / "bin" / "python3.12", RESOURCES / "asr_server.py"),
            env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)

    def event(self, timeout: float) -> dict | None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.selector.select(timeout=max(0.0, deadline - time.monotonic())):
                line = self.process.stdout.readline()
                if not line:
                    return None
                if line.strip():
                    return json.loads(line)
        return None

    def send(self, command: dict) -> None:
        self.process.stdin.write(json.dumps(command) + "\n")
        self.process.stdin.flush()

    def dictate(self, pcm: bytes) -> dict | None:
        self.send({"cmd": "start"})
        for offset in range(0, len(pcm), 3200):  # 100 ms chunks, as AudioCapture sends
            self.send({"cmd": "audio", "pcm": base64.b64encode(pcm[offset:offset + 3200]).decode()})
        self.send({"cmd": "stop"})
        while True:
            event = self.event(60)
            if event is None or event["type"] in ("final", "error"):
                return event

    def close(self) -> str:
        if self.process.poll() is None:
            self.process.terminate()  # ASRService.shutdown()
        try:
            _, stderr = self.process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            _, stderr = self.process.communicate()
        self.selector.close()
        return stderr


def sidecar_env(hostile: dict[str, str], endpoint: str) -> dict[str, str]:
    # The additions ASRService.init passes for the default 0.6B configuration.
    return app_environment(hostile, {
        "HF_HOME": str(Path(hostile["HOME"]) / "hf"),
        "HF_ENDPOINT": endpoint,
        "WHISPR_MODEL": REPO,
        "WHISPR_ENGINE": "qwen3",
        "WHISPR_BITS": "8",
        "WHISPR_CONTEXT": "",
        "WHISPR_LEARNED_CONTEXT": "",
        "WHISPR_FINAL_MODEL": "",
        "WHISPR_SHORT_UTTERANCE_LANGUAGE": "",
    })


@needs_runtime
def test_hostile_environment_breaks_an_unsanitized_runtime(hostile):
    # Control for the next tests: without the app's sanitizer this Python fails.
    process = subprocess.run(
        [str(RUNTIME / "bin" / "python3.12"), "-B", "-c", "import numpy"],
        env=hostile, capture_output=True, text=True, timeout=30,
    )
    assert process.returncode != 0


@needs_runtime
def test_sidecar_loads_and_transcribes_offline_under_hostile_environment(hostile, speech_pcm):
    digest_tool = load_digest_tool()
    before = digest_tool.content_digest(RUNTIME)
    env = sidecar_env(hostile, closed_port_endpoint())  # offline after setup
    mirror_model_cache(Path(env["HF_HOME"]))

    started = time.monotonic()
    sidecar = Sidecar(env)
    try:
        ready = sidecar.event(60)
        assert ready is not None and ready["type"] == "ready", (ready, sidecar.close())
        load_seconds = time.monotonic() - started
        # ASRService.smallModelStartupBudget is 20 s.
        assert load_seconds < 20, f"0.6B took {load_seconds:.1f}s to report ready"
        final = sidecar.dictate(speech_pcm)
    finally:
        stderr = sidecar.close()
    assert final is not None and final["type"] == "final", (final, stderr[-2000:])
    text = final["text"].lower()
    assert "hello" in text and "install" in text, final
    assert digest_tool.content_digest(RUNTIME) == before, "running the sidecar modified the runtime"


@needs_runtime
def test_sidecar_without_a_model_fails_fast_offline(hostile):
    env = sidecar_env(hostile, closed_port_endpoint())
    sidecar = Sidecar(env)
    try:
        event = sidecar.event(60)
    finally:
        stderr = sidecar.close()
    assert event is not None and event["type"] == "error", (event, stderr[-2000:])
    assert event["message"].startswith("load:")
    assert "is not installed" in event["message"], event


@needs_runtime
def test_installed_model_is_not_replaced_when_the_hub_moves_main(hostile):
    with FakeHub(tiny_qwen_repo()) as hub:  # a different commit with junk weights
        env = sidecar_env(hostile, hub.endpoint)
        mirror_model_cache(Path(env["HF_HOME"]))
        sidecar = Sidecar(env)
        try:
            event = sidecar.event(60)
        finally:
            stderr = sidecar.close()
        fetched = [request for request in hub.requests if "/resolve/" in request]
    assert fetched == [], f"engine start fetched {len(fetched)} files from the Hub"
    assert event is not None and event["type"] == "ready", (event, stderr[-2000:])


# Engine start loads exactly what is installed and never talks to the Hub. A
# live loopback Hub (rather than a closed port) makes any request observable.


@needs_runtime
def test_missing_model_fails_without_any_hub_request(hostile):
    with FakeHub(tiny_qwen_repo()) as hub:
        # An inherited HF_HUB_OFFLINE=0 must not reopen the Hub.
        env = {**sidecar_env(hostile, hub.endpoint), "HF_HUB_OFFLINE": "0"}
        started = time.monotonic()
        sidecar = Sidecar(env)
        try:
            event = sidecar.event(60)
        finally:
            stderr = sidecar.close()
        elapsed = time.monotonic() - started
    assert hub.requests == [], hub.requests
    assert event is not None and event["type"] == "error", (event, stderr[-2000:])
    message = event["message"]
    assert message.startswith(f"load: {REPO} is not installed"), message
    assert "never downloads" in message and "WHISPR_ALLOW_MODEL_DOWNLOAD=1" in message, message
    assert elapsed < 20, f"a missing model took {elapsed:.1f}s to fail"
    assert not repo_dir(env).exists()


@needs_runtime
def test_partly_downloaded_model_fails_clearly_without_resuming(hostile):
    files = tiny_qwen_repo()
    with FakeHub(files) as hub:
        env = sidecar_env(hostile, hub.endpoint)
        # What an interrupted model_download.py leaves: refs/main and a
        # snapshot whose weights never arrived, plus a partial blob.
        repo = repo_dir(env)
        snapshot = repo / "snapshots" / COMMIT
        snapshot.mkdir(parents=True)
        (repo / "refs").mkdir()
        (repo / "refs" / "main").write_text(COMMIT, encoding="utf-8")
        for name in ("config.json", "vocab.json", "merges.txt"):
            (snapshot / name).write_bytes(files[name])
        (repo / "blobs").mkdir()
        (repo / "blobs" / "abc.incomplete").write_bytes(b"\0" * 4096)
        assert not app_considers_installed(env)

        sidecar = Sidecar(env)
        try:
            event = sidecar.event(60)
        finally:
            stderr = sidecar.close()
    assert hub.requests == [], hub.requests
    assert event is not None and event["type"] == "error", (event, stderr[-2000:])
    assert f"{REPO} is only partly downloaded" in event["message"], event
    assert sorted(path.name for path in snapshot.iterdir()) == ["config.json", "merges.txt", "vocab.json"]
    assert [path.name for path in incomplete(env)] == ["abc.incomplete"]


@needs_runtime
def test_missing_final_model_falls_back_to_the_installed_preview_model(hostile, speech_pcm):
    final_repo = "Qwen/Qwen3-ASR-1.7B"
    with FakeHub(tiny_qwen_repo(), repo=final_repo) as hub:
        env = {**sidecar_env(hostile, hub.endpoint), "WHISPR_FINAL_MODEL": final_repo}
        mirror_model_cache(Path(env["HF_HOME"]))
        sidecar = Sidecar(env)
        try:
            ready = sidecar.event(60)
            assert ready is not None and ready["type"] == "ready", (ready, sidecar.close())
            final = sidecar.dictate(speech_pcm)
        finally:
            stderr = sidecar.close()
    assert hub.requests == [], hub.requests
    assert f"final model unavailable, finals use the preview model: {final_repo} is not installed" in stderr
    assert final is not None and final["type"] == "final", (final, stderr[-2000:])
    assert "hello" in final["text"].lower(), final


@needs_runtime
def test_download_override_still_loads_the_installed_snapshot(hostile):
    with FakeHub(tiny_qwen_repo()) as hub:  # main moved to junk weights
        env = {**sidecar_env(hostile, hub.endpoint), "WHISPR_ALLOW_MODEL_DOWNLOAD": "1"}
        mirror_model_cache(Path(env["HF_HOME"]))
        sidecar = Sidecar(env)
        try:
            event = sidecar.event(60)
        finally:
            stderr = sidecar.close()
    assert hub.requests == [], hub.requests
    assert event is not None and event["type"] == "ready", (event, stderr[-2000:])


@needs_runtime
def test_download_override_lets_a_hand_run_engine_fetch_an_uncached_model(hostile):
    with FakeHub(tiny_qwen_repo()) as hub:
        env = {**sidecar_env(hostile, hub.endpoint), "WHISPR_ALLOW_MODEL_DOWNLOAD": "1"}
        sidecar = Sidecar(env)
        try:
            event = sidecar.event(60)
        finally:
            stderr = sidecar.close()
        fetched = [request for request in hub.requests if "/resolve/" in request]
    # The documented developer escape hatch reaches the Hub; the loopback
    # repository holds junk weights, so the load itself then fails.
    assert fetched, hub.requests
    assert app_considers_installed(env)
    assert event is not None and event["type"] == "error", (event, stderr[-2000:])
    assert "not installed" not in event["message"], event
