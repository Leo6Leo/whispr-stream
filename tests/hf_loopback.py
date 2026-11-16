"""A loopback stand-in for the Hugging Face Hub, used by first-install tests.

It implements only the endpoints `huggingface_hub` 1.x calls from
`model_info(files_metadata=True)` and `snapshot_download` (model info,
revision info, recursive tree listing, and HEAD/GET `resolve` with Range
support), so `WhisprStream/Resources/model_download.py` can run its real
preflight, download, cancel, and cleanup paths without the network.

Failure modes are selected per server instance:

* ``"ok"``: serve every file in full.
* ``"stall"``: send the first half of each weight file, then hold the
  connection open until the server stops (a download the user cancels).
* ``"truncate"``: send the first half of each weight file and close the
  connection (a dropped network mid-transfer).
* ``"metadata_500"``: the model-info API fails (Hub outage).
"""

from __future__ import annotations

import hashlib
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

COMMIT = "0123456789abcdef0123456789abcdef01234567"
REPO = "Qwen/Qwen3-ASR-0.6B"


def tiny_qwen_repo(weight_bytes: int = 256 * 1024) -> dict[str, bytes]:
    """Files shaped like a Qwen3-ASR checkpoint (not loadable weights)."""
    return {
        "config.json": json.dumps({"model_type": "qwen3_asr"}).encode(),
        "vocab.json": b"{}",
        "merges.txt": b"#version: 0.2\n",
        "model.safetensors": (bytes(range(251)) * (weight_bytes // 251 + 1))[:weight_bytes],
        # Present in the repository but excluded by the app's allow-patterns.
        "README.md": b"# not downloaded\n",
    }


class FakeHub:
    def __init__(
        self,
        files: dict[str, bytes],
        mode: str = "ok",
        repo: str = REPO,
        reported_sizes: dict[str, int] | None = None,
        commit: str = COMMIT,
    ):
        self.files = files
        # Sizes the metadata API claims, e.g. to make a model larger than the
        # free space without writing that much data anywhere.
        self.reported_sizes = reported_sizes or {}
        self.commit = commit
        self.mode = mode
        self.repo = repo
        self.requests: list[str] = []
        self._stop = threading.Event()
        hub = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args):  # keep pytest output clean
                pass

            def do_HEAD(self):
                hub._dispatch(self, head=True)

            def do_GET(self):
                hub._dispatch(self, head=False)

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._server.daemon_threads = True
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    @property
    def endpoint(self) -> str:
        host, port = self._server.server_address[:2]
        return f"http://{host}:{port}"

    def __enter__(self) -> "FakeHub":
        self._thread.start()
        return self

    def __exit__(self, *_exc) -> None:
        self._stop.set()
        self._server.shutdown()
        self._server.server_close()

    # -- protocol ---------------------------------------------------------

    def _json(self, handler, payload, status=200):
        body = json.dumps(payload).encode()
        handler.send_response(status)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(body)))
        handler.end_headers()
        handler.wfile.write(body)

    def _info(self) -> dict:
        return {
            "id": self.repo,
            "modelId": self.repo,
            "sha": self.commit,
            "private": False,
            "config": {"model_type": "qwen3_asr"},
            "siblings": [
                {"rfilename": name, "size": self.reported_sizes.get(name, len(data))}
                for name, data in self.files.items()
            ],
        }

    def _tree(self) -> list[dict]:
        entries = []
        for name, data in self.files.items():
            entry = {
                "type": "file",
                "path": name,
                "size": len(data),
                "oid": hashlib.sha1(data).hexdigest(),
            }
            if name.endswith(".safetensors"):
                entry["lfs"] = {
                    "oid": hashlib.sha256(data).hexdigest(),
                    "size": len(data),
                    "pointerSize": 134,
                }
            entries.append(entry)
        return entries

    def _dispatch(self, handler, head: bool) -> None:
        path = unquote(urlparse(handler.path).path)
        self.requests.append(f"{'HEAD' if head else 'GET'} {path}")
        api = f"/api/models/{self.repo}"
        if path in (api, f"{api}/revision/main", f"{api}/revision/{self.commit}"):
            if self.mode == "metadata_500":
                return self._json(handler, {"error": "hub unavailable"}, status=500)
            return self._json(handler, self._info())
        if path.startswith(f"{api}/tree/"):
            return self._json(handler, self._tree())
        match = re.fullmatch(rf"/{re.escape(self.repo)}/resolve/([^/]+)/(.+)", path)
        if match and match.group(2) in self.files:
            return self._serve_file(handler, match.group(2), head)
        self._json(handler, {"error": "not found"}, status=404)

    def _serve_file(self, handler, name: str, head: bool) -> None:
        data = self.files[name]
        etag = hashlib.sha256(data).hexdigest() if name.endswith(".safetensors") else hashlib.sha1(data).hexdigest()
        start = 0
        range_header = handler.headers.get("Range")
        if range_header and not head:
            match = re.fullmatch(r"bytes=(\d+)-", range_header.strip())
            if match:
                start = min(int(match.group(1)), len(data))
        body = data[start:]
        handler.send_response(206 if start else 200)
        handler.send_header("X-Repo-Commit", self.commit)
        handler.send_header("ETag", f'"{etag}"')
        handler.send_header("Content-Length", str(len(body)))
        if start:
            handler.send_header("Content-Range", f"bytes {start}-{len(data) - 1}/{len(data)}")
        handler.end_headers()
        if head:
            return
        weights = name.endswith(".safetensors")
        if weights and self.mode in ("stall", "truncate"):
            half = body[: max(1, len(data) // 2 - start)] if start < len(data) // 2 else b""
            handler.wfile.write(half)
            handler.wfile.flush()
            if self.mode == "stall":
                self._stop.wait()
            handler.close_connection = True
            return
        handler.wfile.write(body)
