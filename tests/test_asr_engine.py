import importlib.util
import json
import shutil
import sys
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

MODULE_PATH = Path(__file__).parents[1] / "WhisprStream" / "Resources" / "asr_engine.py"
SPEC = importlib.util.spec_from_file_location("whispr_asr_engine", MODULE_PATH)
asr_engine = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = asr_engine
SPEC.loader.exec_module(asr_engine)


def test_whisper_adapter_routes_model_prompt_and_language(monkeypatch):
    calls = []

    def transcribe(audio, **options):
        calls.append((audio, options))
        return {"text": " hello ", "language": "en"}

    monkeypatch.setitem(sys.modules, "mlx_whisper", SimpleNamespace(transcribe=transcribe))
    session = asr_engine.WhisperSession("mlx-community/whisper-small-mlx")
    audio = np.zeros(320, dtype=np.float32)

    result = session.transcribe(audio, context="WhisprStream", language="English")

    assert result.text == " hello "
    assert result.language == "en"
    assert calls == [(audio, {
        "path_or_hf_repo": "mlx-community/whisper-small-mlx",
        "verbose": None,
        "initial_prompt": "WhisprStream",
        "language": "en",
    })]


def test_whisper_adapter_omits_unknown_language_hint(monkeypatch):
    options_seen = []
    fake = SimpleNamespace(
        transcribe=lambda _audio, **options: options_seen.append(options) or {"text": "ok"}
    )
    monkeypatch.setitem(sys.modules, "mlx_whisper", fake)

    session = asr_engine.WhisperSession("/tmp/local-model")
    session.transcribe(np.zeros(1, dtype=np.float32), language="Unknown")

    assert "language" not in options_seen[0]


def test_build_session_rejects_unknown_engine_before_loading_dependencies():
    with pytest.raises(ValueError, match="unsupported speech engine"):
        asr_engine.build_session("anything", engine="other", warm=False)


# -- engine start loads only what is installed ------------------------------


def write_qwen_folder(folder: Path, *, weights: bool = True, sharded: bool = False) -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "config.json").write_text(json.dumps({"model_type": "qwen3_asr"}), encoding="utf-8")
    (folder / "vocab.json").write_text("{}", encoding="utf-8")
    (folder / "merges.txt").write_text("#version: 0.2\n", encoding="utf-8")
    if sharded:
        shards = ["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"]
        (folder / "model.safetensors.index.json").write_text(
            json.dumps({"weight_map": {"a": shards[0], "b": shards[1]}}), encoding="utf-8"
        )
        for shard in shards[: 2 if weights else 1]:
            (folder / shard).write_bytes(b"w")
    elif weights:
        (folder / "model.safetensors").write_bytes(b"w")
    return folder


def hub_repo(hf_home: Path, repo_id: str = "Qwen/Qwen3-ASR-0.6B") -> Path:
    return hf_home / "hub" / ("models--" + repo_id.replace("/", "--"))


def install_snapshot(hf_home: Path, revision: str, *, main: bool = True, repo_id="Qwen/Qwen3-ASR-0.6B", **kwargs):
    repo = hub_repo(hf_home, repo_id)
    snapshot = write_qwen_folder(repo / "snapshots" / revision, **kwargs)
    if main:
        (repo / "refs").mkdir(parents=True, exist_ok=True)
        (repo / "refs" / "main").write_text(revision, encoding="utf-8")
    return snapshot


@pytest.fixture
def hf_home(tmp_path, monkeypatch):
    home = tmp_path / "hf"
    monkeypatch.delenv("HF_HUB_CACHE", raising=False)
    monkeypatch.setenv("HF_HOME", str(home))
    monkeypatch.delenv(asr_engine.ALLOW_MODEL_DOWNLOAD_ENV, raising=False)
    return home


@pytest.fixture
def fake_qwen(monkeypatch):
    """mlx_qwen3_asr and mlx stand-ins that record what they were asked to load."""
    calls = []

    class Session:
        def __init__(self, model, tokenizer_model=None):
            calls.append(("Session", model, tokenizer_model))

    def load_model(path):
        calls.append(("load_model", path))
        return SimpleNamespace(parameters=lambda: {}), {}

    package = SimpleNamespace(Session=Session, load_model=load_model)
    convert = SimpleNamespace(quantize_model=lambda model, bits, group_size: model)
    monkeypatch.setitem(sys.modules, "mlx_qwen3_asr", package)
    monkeypatch.setitem(sys.modules, "mlx_qwen3_asr.convert", convert)
    core = SimpleNamespace(eval=lambda *_: None)
    monkeypatch.setitem(sys.modules, "mlx", SimpleNamespace(core=core))
    monkeypatch.setitem(sys.modules, "mlx.core", core)
    return calls


@pytest.mark.parametrize("bits", [0, 8])
def test_installed_model_loads_from_its_snapshot_path(hf_home, fake_qwen, bits):
    snapshot = str(install_snapshot(hf_home, "a" * 40))

    asr_engine.build_session("Qwen/Qwen3-ASR-0.6B", bits, warm=False)

    if bits:
        # The 8-bit path quantizes a loaded model; its tokenizer reads the same folder.
        assert fake_qwen[0] == ("load_model", snapshot)
        assert fake_qwen[1][0] == "Session" and fake_qwen[1][2] == snapshot
    else:
        assert fake_qwen == [("Session", snapshot, None)]


def test_refs_main_snapshot_is_preferred_and_an_incomplete_newer_one_is_skipped(hf_home):
    old = install_snapshot(hf_home, "a" * 40, main=False, sharded=True)
    newest = install_snapshot(hf_home, "c" * 40, main=False)
    main = install_snapshot(hf_home, "b" * 40)
    assert asr_engine.resolve_model_source("Qwen/Qwen3-ASR-0.6B") == str(main)

    # An interrupted download of a newer revision moves refs/main to a
    # snapshot whose last shard never arrived. ModelCatalog still calls the
    # model installed, so the engine must load a complete snapshot.
    shutil.rmtree(main)
    shutil.rmtree(newest)
    install_snapshot(hf_home, "d" * 40, sharded=True, weights=False)
    assert asr_engine.resolve_model_source("Qwen/Qwen3-ASR-0.6B") == str(old)


def test_missing_model_fails_clearly_and_never_reaches_the_library(hf_home, fake_qwen):
    with pytest.raises(asr_engine.ModelNotInstalledError) as raised:
        asr_engine.build_session("Qwen/Qwen3-ASR-1.7B", 8, warm=False)
    message = str(raised.value)
    assert message.startswith("Qwen/Qwen3-ASR-1.7B is not installed")
    assert "never downloads" in message and "WHISPR_ALLOW_MODEL_DOWNLOAD=1" in message
    assert fake_qwen == []


def test_partial_download_is_reported_as_partial(hf_home, fake_qwen):
    install_snapshot(hf_home, "a" * 40, repo_id="Qwen/Qwen3-ASR-1.7B", sharded=True, weights=False)
    blobs = hub_repo(hf_home, "Qwen/Qwen3-ASR-1.7B") / "blobs"
    blobs.mkdir()
    (blobs / "f00d.1d78b43c.incomplete").write_bytes(b"\0" * 1000)

    with pytest.raises(asr_engine.ModelNotInstalledError, match="only partly downloaded"):
        asr_engine.build_session("Qwen/Qwen3-ASR-1.7B", 8, warm=False)
    assert fake_qwen == []


def test_snapshot_without_tokenizer_files_is_not_loadable(hf_home):
    snapshot = install_snapshot(hf_home, "a" * 40)
    (snapshot / "merges.txt").unlink()
    assert asr_engine.missing_model_files(snapshot, "qwen3") == ["merges.txt"]
    with pytest.raises(asr_engine.ModelNotInstalledError):
        asr_engine.resolve_model_source("Qwen/Qwen3-ASR-0.6B")


def test_download_override_only_applies_to_a_model_with_no_complete_snapshot(hf_home, fake_qwen, monkeypatch):
    monkeypatch.setenv(asr_engine.ALLOW_MODEL_DOWNLOAD_ENV, "1")
    asr_engine.build_session("Qwen/Qwen3-ASR-1.7B", 0, warm=False)
    assert fake_qwen == [("Session", "Qwen/Qwen3-ASR-1.7B", None)]  # the library downloads it

    fake_qwen.clear()
    snapshot = str(install_snapshot(hf_home, "a" * 40))
    asr_engine.build_session("Qwen/Qwen3-ASR-0.6B", 0, warm=False)
    assert fake_qwen == [("Session", snapshot, None)]


@pytest.mark.parametrize("value", ["", "0", "true", "yes"])
def test_only_the_exact_override_value_allows_downloads(value):
    assert not asr_engine.model_downloads_allowed({asr_engine.ALLOW_MODEL_DOWNLOAD_ENV: value})
    assert asr_engine.model_downloads_allowed({asr_engine.ALLOW_MODEL_DOWNLOAD_ENV: "1"})


def test_local_model_folder_loads_by_path_and_an_incomplete_one_fails(tmp_path, hf_home, fake_qwen):
    folder = write_qwen_folder(tmp_path / "my model")
    asr_engine.build_session(str(folder), 0, warm=False)
    assert fake_qwen == [("Session", str(folder.resolve()), None)]

    (folder / "model.safetensors").unlink()
    with pytest.raises(asr_engine.ModelNotInstalledError, match="not a complete Qwen3-ASR model folder"):
        asr_engine.build_session(str(folder), 0, warm=False)
    with pytest.raises(asr_engine.ModelNotInstalledError):
        asr_engine.build_session(str(tmp_path / "does-not-exist"), 0, warm=False)


def test_whisper_engine_loads_the_installed_snapshot_path(hf_home, monkeypatch):
    repo_id = "mlx-community/whisper-small-mlx"
    snapshot = hub_repo(hf_home, repo_id) / "snapshots" / ("e" * 40)
    snapshot.mkdir(parents=True)
    (snapshot / "config.json").write_text(json.dumps({"model_type": "whisper"}), encoding="utf-8")
    seen = []
    monkeypatch.setitem(sys.modules, "mlx_whisper", SimpleNamespace(
        transcribe=lambda _audio, **options: seen.append(options["path_or_hf_repo"]) or {"text": ""}
    ))

    with pytest.raises(asr_engine.ModelNotInstalledError, match="partly downloaded"):
        asr_engine.build_session(repo_id, engine="whisper", warm=False)

    (snapshot / "weights.npz").write_bytes(b"w")
    asr_engine.build_session(repo_id, engine="whisper", warm=True)
    assert seen == [str(snapshot)]

    # A Qwen checkpoint is not a Whisper model, whatever its weights.
    with pytest.raises(asr_engine.ModelNotInstalledError):
        asr_engine.resolve_model_source(str(write_qwen_folder(hf_home / "q")), "whisper")


def test_hub_environment_is_forced_offline_unless_downloads_are_allowed():
    inherited = {"HF_HUB_OFFLINE": "0", "HF_HUB_DISABLE_TELEMETRY": "0"}
    asr_engine.configure_hub_environment(inherited)
    assert inherited["HF_HUB_OFFLINE"] == "1"
    assert inherited["HF_HUB_DISABLE_TELEMETRY"] == "0"  # an explicit choice is kept, like model_download.py

    fresh = {}
    asr_engine.configure_hub_environment(fresh)
    assert fresh == {"HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "HF_HUB_DISABLE_XET": "1"}

    developer = {asr_engine.ALLOW_MODEL_DOWNLOAD_ENV: "1"}
    asr_engine.configure_hub_environment(developer)
    assert "HF_HUB_OFFLINE" not in developer
    assert developer["HF_HUB_DISABLE_TELEMETRY"] == "1"


def test_sidecar_falls_back_when_the_final_model_is_not_installed(hf_home, fake_qwen, monkeypatch):
    monkeypatch.syspath_prepend(str(MODULE_PATH.parent))
    import asr_server  # its Server imports the sibling asr_engine module

    snapshot = str(install_snapshot(hf_home, "a" * 40))
    emitted = []
    monkeypatch.setattr(asr_server, "emit", emitted.append)
    warm = []
    monkeypatch.setattr(
        sys.modules["mlx_qwen3_asr"], "Session",
        type("Session", (), {
            "__init__": lambda self, model, tokenizer_model=None: fake_qwen.append(("Session", model)),
            "transcribe": lambda self, audio, **_: warm.append(len(audio)),
        }),
    )

    server = asr_server.Server(
        "Qwen/Qwen3-ASR-0.6B", 0, "", final_model_id="Qwen/Qwen3-ASR-1.7B"
    )

    assert fake_qwen == [("Session", snapshot)]  # the 1.7B never reached the library
    assert server.final_session is None
    assert [event["type"] for event in emitted] == ["ready"]
