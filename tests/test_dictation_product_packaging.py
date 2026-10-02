"""Exercise the dictation-only product gate without compiling or signing an app."""

import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).parents[1]
BUILDER = ROOT / "WhisprStream/build.sh"
VALIDATOR = ROOT / "WhisprStream/validate-dictation-product.sh"


class DictationProductPackagingTests(unittest.TestCase):
    def validate(self, info, *, fmt=plistlib.FMT_XML):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Dictation Test.app"
            contents = app / "Contents"
            contents.mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps(info, fmt=fmt))
            return subprocess.run(
                ["bash", str(VALIDATOR), str(app)], capture_output=True, text=True
            )

    def test_dictation_bundle_passes_with_xml_and_binary_plists(self):
        for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
            with self.subTest(fmt=fmt):
                result = self.validate(
                    {"LSUIElement": True, "WhisprMeetingsEnabled": False}, fmt=fmt
                )
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_product_gates_require_explicit_boolean_values(self):
        invalid_values = {
            "LSUIElement": (False, "true", 1, None),
            "WhisprMeetingsEnabled": (True, "false", 0, None),
        }
        for key, values in invalid_values.items():
            for value in values:
                with self.subTest(key=key, value=value):
                    info = {"LSUIElement": True, "WhisprMeetingsEnabled": False}
                    if value is None:
                        del info[key]
                    else:
                        info[key] = value
                    result = self.validate(info)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(key, result.stderr)

    def test_missing_or_malformed_plist_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Broken.app"
            plist = app / "Contents/Info.plist"
            for data in (None, b"not a plist"):
                with self.subTest(data=data):
                    if data is not None:
                        plist.parent.mkdir(parents=True)
                        plist.write_bytes(data)
                    result = subprocess.run(
                        ["bash", str(VALIDATOR), str(app)],
                        capture_output=True,
                        text=True,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("cannot read dictation app Info.plist", result.stderr)

    def test_meetings_build_is_rejected_before_compilation_or_bundle_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Existing.app"
            app.mkdir()
            marker = app / "keep.txt"
            marker.write_text("existing app")
            # A compiler invocation would leave evidence even if it failed.
            tools = Path(directory) / "tools"
            tools.mkdir()
            compiler_marker = Path(directory) / "compiler-invoked"
            compiler = tools / "swift"
            compiler.write_text('#!/bin/sh\ntouch "$COMPILER_MARKER"\nexit 1\n')
            compiler.chmod(0o755)
            for release in ("0", "1"):
                for enabled in ("1", "true", "2"):
                    with self.subTest(release=release, enabled=enabled):
                        env = {
                            **os.environ,
                            "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}",
                            "COMPILER_MARKER": str(compiler_marker),
                            "APP": str(app),
                            "VERSION": "1.0.3",
                            "RELEASE": release,
                            "ENABLE_MEETINGS": enabled,
                        }
                        result = subprocess.run(
                            ["bash", str(BUILDER)], env=env, capture_output=True, text=True
                        )
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("ENABLE_MEETINGS must be 0", result.stderr)
                        self.assertFalse(compiler_marker.exists())
                        self.assertEqual(marker.read_text(), "existing app")

    def test_disabled_meetings_build_reaches_compiler(self):
        with tempfile.TemporaryDirectory() as directory:
            tools = Path(directory)
            marker = tools / "compiler-invoked"
            compiler = tools / "swift"
            compiler.write_text('#!/bin/sh\ntouch "$COMPILER_MARKER"\nexit 1\n')
            compiler.chmod(0o755)
            for enabled in (None, "0"):
                with self.subTest(enabled=enabled):
                    env = {
                        **os.environ,
                        "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}",
                        "COMPILER_MARKER": str(marker),
                        "PYTHON": sys.executable,
                        "RELEASE": "0",
                        "ENABLE_OPTIONAL_MODELS": "0",
                    }
                    env.pop("ENABLE_MEETINGS", None)
                    if enabled is not None:
                        env["ENABLE_MEETINGS"] = enabled
                    result = subprocess.run(
                        ["bash", str(BUILDER)], env=env, capture_output=True, text=True
                    )
                    self.assertTrue(marker.exists(), result.stderr)
                    marker.unlink()


if __name__ == "__main__":
    unittest.main()
