#!/bin/bash
# Inspect the finished bundle, not just the signing inputs. Hardened Runtime
# requires audio-input even when App Sandbox is disabled.
set -euo pipefail

[ "$#" -eq 1 ] || { echo "usage: validate-microphone-permission.sh app-bundle" >&2; exit 2; }
APP="$1"
DESCRIPTION="$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[ -n "${DESCRIPTION//[[:space:]]/}" ] || {
    echo "error: app is missing NSMicrophoneUsageDescription" >&2
    exit 1
}

ENTITLEMENTS_TMP="$(mktemp "${TMPDIR:-/tmp}/whisprstream-entitlements.XXXXXX")"
trap 'rm -f "$ENTITLEMENTS_TMP"' EXIT
codesign --display --entitlements - --xml "$APP" > "$ENTITLEMENTS_TMP"
AUDIO_INPUT="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$ENTITLEMENTS_TMP" 2>/dev/null || true)"
[ "$AUDIO_INPUT" = "true" ] || {
    echo "error: signed app is missing the audio-input entitlement required for microphone access" >&2
    exit 1
}
