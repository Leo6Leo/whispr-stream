#!/bin/bash
# Validate the built or archive-extracted dictation app's product configuration.
set -euo pipefail

[ "$#" -eq 1 ] || { echo "usage: validate-dictation-product.sh app-bundle" >&2; exit 2; }

python3 - "$1/Contents/Info.plist" <<'PY'
import plistlib
import sys

try:
    with open(sys.argv[1], "rb") as source:
        info = plistlib.load(source)
except (OSError, ValueError) as error:
    sys.exit(f"error: cannot read dictation app Info.plist: {error}")

for key, expected in (("LSUIElement", True), ("WhisprMeetingsEnabled", False)):
    if not isinstance(info, dict) or info.get(key) is not expected:
        sys.exit(f"error: {key} must be a plist boolean {str(expected).lower()}")
PY
