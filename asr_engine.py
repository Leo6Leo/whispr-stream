"""Shared model loading behind a small engine-neutral transcription API.

Qwen3-ASR and Whisper use different MLX implementations and checkpoint
formats. The sidecar deliberately selects an adapter explicitly instead of
guessing from a repository name.

Loading never downloads. Both MLX libraries treat a Hugging Face repository
id as "snapshot_download, then load", which asks the Hub for ``main`` on every
start and fetches a whole new checkpoint whenever ``main`` moves. Downloads
belong to ``model_download.py`` (the app's download UI, storage preflight and
progress), so ``build_session`` resolves a repository id to the complete
snapshot already in the local cache, chosen by the same rules as the app's
``ModelCatalog.state(for:)``, and hands the libraries that folder. A model
that is missing or only partly downloaded fails with ``ModelNotInstalledError``.

Developers running a launcher by hand with a model that is not cached can set
``WHISPR_ALLOW_MODEL_DOWNLOAD=1``: a model with no complete snapshot is then
passed to the library by id, which downloads it. An installed model is still
loaded from its installed snapshot.
"""

from __future__ import annotations

import json
import os
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import MutableMapping

import numpy as np

SAMPLE_RATE = 16000
SUPPORTED_ENGINES = ("qwen3", "whisper")
ALLOW_MODEL_DOWNLOAD_ENV = "WHISPR_ALLOW_MODEL_DOWNLOAD"
_REPO_ID_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
_MODEL_TYPES = {"qwen3": "qwen3_asr", "whisper": "whisper"}


class ModelNotInstalledError(RuntimeError):
    """The requested model has no complete local copy to load."""


def model_downloads_allowed(environ: MutableMapping[str, str] | None = None) -> bool:
    environ = os.environ if environ is None else environ
    return environ.get(ALLOW_MODEL_DOWNLOAD_ENV, "").strip() == "1"


def configure_hub_environment(environ: MutableMapping[str, str] | None = None) -> None:
    """Keep a speech-engine process off the Hub unless downloads are allowed.

    ``huggingface_hub`` reads these when it is first imported, so call this
    before importing anything that pulls it in (mlx_qwen3_asr, mlx_whisper).
    ``build_session`` never asks the libraries to download either way; this
    is the second lock, and it is forced rather than defaulted so an inherited
    ``HF_HUB_OFFLINE=0`` cannot reopen it.
    """
    environ = os.environ if environ is None else environ
    # Parity with model_download.py.
    environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
    environ.setdefault("HF_HUB_DISABLE_XET", "1")
    if not model_downloads_allowed(environ):
        environ["HF_HUB_OFFLINE"] = "1"


def hub_cache_root(environ: MutableMapping[str, str] | None = None) -> Path:
    """The cache ModelCatalog.cacheRoot reads, with the same precedence."""
    environ = os.environ if environ is None else environ
    if environ.get("HF_HUB_CACHE"):
        return Path(environ["HF_HUB_CACHE"]).expanduser()
    if environ.get("HF_HOME"):
        return Path(environ["HF_HOME"]).expanduser() / "hub"
    return Path.home() / ".cache" / "huggingface" / "hub"


def _existing_file(folder: Path, name: str) -> bool:
    # Mirrors ModelCatalog.existingFile: lexically inside the folder, and the
    # target (usually a cache symlink into blobs/) exists.
    candidate = Path(os.path.normpath(folder / name))
    if not str(candidate).startswith(os.path.normpath(folder) + os.sep):
        return False
    return candidate.resolve().is_file()


def _model_type(folder: Path) -> str | None:
    if not _existing_file(folder, "config.json"):
        return None
    try:
        config = json.loads((folder / "config.json").resolve().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    value = config.get("model_type") if isinstance(config, dict) else None
    return value if isinstance(value, str) else None


def missing_model_files(folder: Path, engine: str) -> list[str]:
    """What keeps ``folder`` from loading; empty when it is complete.

    The same completeness rules as ModelCatalog.isComplete, plus the
    tokenizer files Qwen3-ASR reads from the model folder.
    """
    if not folder.is_dir():
        return ["the folder itself"]
    model_type = _model_type(folder)
    if model_type != _MODEL_TYPES[engine]:
        if model_type is None:
            return ["config.json"]
        return [f"config.json with model_type {_MODEL_TYPES[engine]!r} (found {model_type!r})"]
    if engine == "whisper":
        if any(_existing_file(folder, name) for name in ("model.safetensors", "weights.safetensors", "weights.npz")):
            return []
        return ["weights.safetensors or weights.npz"]

    missing = [name for name in ("vocab.json", "merges.txt") if not _existing_file(folder, name)]
    index = folder / "model.safetensors.index.json"
    if index.exists():
        try:
            weight_map = json.loads(index.resolve().read_text(encoding="utf-8")).get("weight_map")
        except (OSError, ValueError, AttributeError):
            weight_map = None
        if not isinstance(weight_map, dict) or not weight_map:
            missing.append("a readable model.safetensors.index.json")
        else:
            missing += sorted(
                name for name in set(map(str, weight_map.values())) if not _existing_file(folder, name)
            )
    elif not _existing_file(folder, "model.safetensors"):
        missing.append("model.safetensors")
    return missing


def _partial_bytes(repo: Path) -> int:
    total = 0
    blobs = repo / "blobs"
    if blobs.is_dir():
        for blob in blobs.iterdir():
            if blob.name.endswith(".incomplete") and blob.is_file() and not blob.is_symlink():
                try:
                    total += blob.stat().st_size
                except OSError:
                    pass
    return total


def _snapshot_candidates(repo: Path) -> list[Path]:
    """Snapshots in preference order: the one ``refs/main`` names, then newest."""
    snapshots = repo / "snapshots"
    if not snapshots.is_dir():
        return []
    folders = [path for path in snapshots.iterdir() if path.is_dir()]

    def modified(path: Path) -> float:
        try:
            return path.stat().st_mtime
        except OSError:
            return 0.0

    folders.sort(key=modified, reverse=True)
    try:
        main = (repo / "refs" / "main").read_text(encoding="utf-8").strip()
    except OSError:
        main = ""
    folders.sort(key=lambda path: path.name != main)  # stable: main first
    return folders


_NOT_DOWNLOADING = (
    "The speech engine never downloads models; download it from WhisprStream "
    f"Settings, or set {ALLOW_MODEL_DOWNLOAD_ENV}=1 when running the engine by hand."
)


def resolve_model_source(
    model_id: str,
    engine: str = "qwen3",
    *,
    allow_download: bool | None = None,
    environ: MutableMapping[str, str] | None = None,
) -> str:
    """The local folder to load for ``model_id``, never a download.

    A local path must be a complete model folder. A repository id resolves to
    its complete snapshot in the Hugging Face cache, preferring the one
    ``refs/main`` names (so an interrupted download of a newer revision never
    hides a complete older one, as in ModelCatalog). Only when no complete
    snapshot exists and downloads are explicitly allowed is the id returned
    unchanged for the library to fetch.
    """
    if engine not in SUPPORTED_ENGINES:
        raise ValueError(f"unsupported speech engine: {engine}")
    if allow_download is None:
        allow_download = model_downloads_allowed(environ)
    kind = "Qwen3-ASR" if engine == "qwen3" else "MLX Whisper"

    if not _REPO_ID_RE.fullmatch(model_id or ""):
        folder = Path(model_id or "").expanduser()
        missing = missing_model_files(folder, engine)
        if missing:
            raise ModelNotInstalledError(
                f"{model_id or '(empty)'} is not a complete {kind} model folder "
                f"(missing {', '.join(missing)})."
            )
        return str(folder.resolve())

    cache = hub_cache_root(environ)
    repo = cache / ("models--" + model_id.replace("/", "--"))
    for snapshot in _snapshot_candidates(repo):
        if not missing_model_files(snapshot, engine):
            return str(snapshot)
    if allow_download:
        return model_id

    partial = _partial_bytes(repo)
    if partial or (repo / "snapshots").is_dir():
        detail = "is only partly downloaded"
        if partial:
            detail += f" ({partial / 1e9:.2f} GB of interrupted files)"
        detail += f" and has no complete snapshot in {repo}"
    else:
        detail = f"is not installed (nothing at {repo})"
    raise ModelNotInstalledError(f"{model_id} {detail}. {_NOT_DOWNLOADING}")


@dataclass(frozen=True)
class TranscriptionResult:
    text: str
    language: str | None = None


# Whisper's tokenizer uses ISO-like language codes. The Settings UI keeps the
# existing human-readable Qwen names, so translate the shared subset here.
WHISPER_LANGUAGE_CODES = {
    "arabic": "ar",
    "cantonese": "zh",
    "chinese": "zh",
    "czech": "cs",
    "danish": "da",
    "dutch": "nl",
    "english": "en",
    "filipino": "tl",
    "finnish": "fi",
    "french": "fr",
    "german": "de",
    "greek": "el",
    "hindi": "hi",
    "hungarian": "hu",
    "indonesian": "id",
    "italian": "it",
    "japanese": "ja",
    "korean": "ko",
    "macedonian": "mk",
    "malay": "ms",
    "persian": "fa",
    "polish": "pl",
    "portuguese": "pt",
    "romanian": "ro",
    "russian": "ru",
    "spanish": "es",
    "swedish": "sv",
    "thai": "th",
    "turkish": "tr",
    "vietnamese": "vi",
}


class WhisperSession:
    """Expose mlx-whisper through the Session interface used by the sidecar."""

    def __init__(self, model_id: str):
        import mlx_whisper

        self._mlx_whisper = mlx_whisper
        self._model_id = model_id

    def transcribe(
        self,
        audio: np.ndarray,
        *,
        context: str = "",
        language: str | None = None,
    ) -> TranscriptionResult:
        options: dict[str, object] = {
            "path_or_hf_repo": self._model_id,
            # Any library progress text would corrupt the sidecar's JSON stdout.
            "verbose": None,
        }
        if context:
            options["initial_prompt"] = context
        if language:
            code = WHISPER_LANGUAGE_CODES.get(language.strip().casefold())
            if code:
                options["language"] = code
        result = self._mlx_whisper.transcribe(audio, **options)
        language = result.get("language")
        return TranscriptionResult(
            text=str(result.get("text") or ""),
            language=str(language) if language else None,
        )


def _qwen_session(model_id: str, bits: int):
    from mlx_qwen3_asr import Session

    if not bits or bits <= 0:
        return Session(model=model_id)

    import mlx.core as mx
    from mlx_qwen3_asr import load_model
    from mlx_qwen3_asr.convert import quantize_model

    model, _config = load_model(model_id)
    model = quantize_model(model, bits=bits, group_size=64)
    mx.eval(model.parameters())
    return Session(model=model, tokenizer_model=model_id)


def build_session(
    model_id: str = "Qwen/Qwen3-ASR-0.6B",
    bits: int = 8,
    *,
    engine: str = "qwen3",
    warm: bool = True,
    allow_download: bool | None = None,
):
    """Load and optionally warm one installed model. Returns (session, secs).

    Raises ModelNotInstalledError instead of downloading; see the module
    docstring for ``allow_download`` / WHISPR_ALLOW_MODEL_DOWNLOAD.
    """
    if engine not in SUPPORTED_ENGINES:
        raise ValueError(f"unsupported speech engine: {engine}")

    started = time.time()
    source = resolve_model_source(model_id, engine, allow_download=allow_download)
    if engine == "qwen3":
        session = _qwen_session(source, bits)
    else:
        # Whisper MLX repositories carry their own precision/quantization. The
        # Qwen runtime bit preference must not mutate those converted weights.
        session = WhisperSession(source)

    if warm:
        # Force graph compilation now so the first real utterance isn't slow.
        session.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32))

    return session, time.time() - started
