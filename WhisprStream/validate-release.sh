#!/bin/bash
# Read-only validation for finished WhisprStream release artifacts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PINNED_UPDATE_REPOSITORY="Leo6Leo/whispr-stream"
UPDATE_PUBLIC_KEY_FILE="$SCRIPT_DIR/update-public-key.txt"
SIGNING_CERT_SHA1_FILE="$SCRIPT_DIR/release-signing-certificate-sha1.txt"
[ -f "$UPDATE_PUBLIC_KEY_FILE" ] && [ -f "$SIGNING_CERT_SHA1_FILE" ] || {
    echo "error: checked-in release trust roots are missing" >&2
    exit 1
}
PINNED_UPDATE_PUBLIC_KEY="$(tr -d '\r\n' < "$UPDATE_PUBLIC_KEY_FILE")"
PINNED_SIGNING_CERT_SHA1="$(tr -d '\r\n' < "$SIGNING_CERT_SHA1_FILE" \
    | tr '[:upper:]' '[:lower:]')"
[[ "$PINNED_UPDATE_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
    && [[ "$PINNED_SIGNING_CERT_SHA1" =~ ^[0-9a-f]{40}$ ]] || {
        echo "error: checked-in release trust roots are malformed" >&2
        exit 1
    }

usage() {
    echo "usage: validate-release.sh app.zip runtime.zip SHA256SUMS app-signature app-version build-number" >&2
    exit 2
}

[ "$#" -eq 6 ] || usage
APP="$1"
RUNTIME_ZIP="$2"
SHA256SUMS="$3"
APP_SIGNATURE="$4"
EXPECTED_APP_VERSION="$5"
EXPECTED_BUILD_NUMBER="$6"

[[ "$EXPECTED_APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "error: expected app version must be stable semantic version" >&2
    exit 1
}
[[ "$EXPECTED_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || {
    echo "error: expected build number must be a positive integer" >&2
    exit 1
}

for FILE in "$APP" "$RUNTIME_ZIP" "$SHA256SUMS" "$APP_SIGNATURE"; do
    [ -f "$FILE" ] || { echo "error: missing $FILE" >&2; exit 1; }
done

VALIDATION_TMP="$(mktemp -d "${TMPDIR:-/tmp}/whisprstream-release-check.XXXXXX")"
trap 'rm -rf "$VALIDATION_TMP"' EXIT
ditto -x -k "$APP" "$VALIDATION_TMP/app"
APP_DIR="$VALIDATION_TMP/app/WhisprStream.app"
[ -d "$APP_DIR" ] && [ ! -L "$APP_DIR" ] || {
    echo "error: app archive must contain WhisprStream.app at its top level" >&2
    exit 1
}

bash "$SCRIPT_DIR/validate-dictation-product.sh" "$APP_DIR"

BIN="$APP_DIR/Contents/MacOS/WhisprStream"
UPDATE_INSTALLER="$APP_DIR/Contents/Helpers/WhisprStreamUpdateInstaller"
[ -x "$BIN" ] || { echo "error: app executable is missing" >&2; exit 1; }
[ -x "$UPDATE_INSTALLER" ] || { echo "error: update installer is missing" >&2; exit 1; }
file "$BIN" | grep -q 'arm64' || { echo "error: app is not arm64" >&2; exit 1; }
file "$UPDATE_INSTALLER" | grep -q 'arm64' || { echo "error: update installer is not arm64" >&2; exit 1; }
for EXECUTABLE in "$BIN" "$UPDATE_INSTALLER"; do
    if rg -a -q '(/Users/|/home/)' "$EXECUTABLE"; then
        echo "error: release executable contains a build-machine home path" >&2
        exit 1
    fi
done
codesign --verify --strict --deep \
    -R="identifier \"com.leoleo.whisprstream\" and certificate leaf = H\"$PINNED_SIGNING_CERT_SHA1\"" \
    "$APP_DIR"
codesign --verify --strict \
    -R="identifier \"WhisprStreamUpdateInstaller\" and certificate leaf = H\"$PINNED_SIGNING_CERT_SHA1\"" \
    "$UPDATE_INSTALLER"
assert_hardened_runtime() {
    local executable="$1"
    local details
    details="$(codesign -dv --verbose=4 "$executable" 2>&1)"
    echo "$details" | grep -q 'flags=.*runtime' \
        && echo "$details" | grep -q 'flags=.*library-validation' || {
            echo "error: hardened runtime and library validation are required: $executable" >&2
            exit 1
        }
}
assert_hardened_runtime "$APP_DIR"
assert_hardened_runtime "$UPDATE_INSTALLER"
bash "$SCRIPT_DIR/validate-microphone-permission.sh" "$APP_DIR"

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP_DIR/Contents/Info.plist" 2>/dev/null; }
required_plist() {
    local key="$1"
    local value
    if ! value="$(plist "$key")"; then
        echo "error: release Info.plist is missing $key" >&2
        return 1
    fi
    printf '%s' "$value"
}
BUNDLE_ID="$(required_plist CFBundleIdentifier)"
APP_VERSION="$(required_plist CFBundleShortVersionString)"
BUILD_NUMBER="$(required_plist CFBundleVersion)"
MIN_OS="$(required_plist LSMinimumSystemVersion)"
DEV_PYTHON="$(plist WhisprDevelopmentPythonPath || true)"
RUNTIME_VERSION="$(required_plist WhisprRuntimeVersion)"
RUNTIME_URL="$(required_plist WhisprRuntimeURL)"
RUNTIME_SHA256="$(required_plist WhisprRuntimeSHA256)"
RUNTIME_CONTENT_SHA256="$(required_plist WhisprRuntimeContentSHA256)"
ARCHIVE_BYTES="$(required_plist WhisprRuntimeArchiveBytes)"
INSTALLED_BYTES="$(required_plist WhisprRuntimeInstalledBytes)"
UPDATE_REPOSITORY="$(required_plist WhisprUpdateRepository)"
UPDATE_PUBLIC_KEY="$(required_plist WhisprUpdatePublicKey)"
OPTIONAL_MODELS_ENABLED="$(required_plist WhisprOptionalModelsEnabled)"

[ "$BUNDLE_ID" = "com.leoleo.whisprstream" ] || { echo "error: development bundle identifier" >&2; exit 1; }
[ "$APP_VERSION" = "$EXPECTED_APP_VERSION" ] || { echo "error: app version is $APP_VERSION; expected $EXPECTED_APP_VERSION" >&2; exit 1; }
[ "$BUILD_NUMBER" = "$EXPECTED_BUILD_NUMBER" ] || { echo "error: app build is $BUILD_NUMBER; expected $EXPECTED_BUILD_NUMBER" >&2; exit 1; }
[ "$MIN_OS" = "14.0" ] || { echo "error: minimum macOS must be 14.0" >&2; exit 1; }
[ -z "$DEV_PYTHON" ] || { echo "error: development Python path is embedded" >&2; exit 1; }
[[ "$RUNTIME_URL" =~ ^https:// ]] && [[ "$RUNTIME_URL" != *latest/download* ]] || { echo "error: runtime URL is not immutable HTTPS" >&2; exit 1; }
[[ "$RUNTIME_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "error: invalid runtime SHA-256" >&2; exit 1; }
[[ "$RUNTIME_CONTENT_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "error: invalid runtime content SHA-256" >&2; exit 1; }
[[ "$RUNTIME_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: invalid runtime version" >&2; exit 1; }
[[ "$ARCHIVE_BYTES" =~ ^[1-9][0-9]*$ ]] || { echo "error: invalid runtime archive bytes" >&2; exit 1; }
[[ "$INSTALLED_BYTES" =~ ^[1-9][0-9]*$ ]] || { echo "error: invalid runtime installed bytes" >&2; exit 1; }
[ "$UPDATE_REPOSITORY" = "$PINNED_UPDATE_REPOSITORY" ] || { echo "error: update repository differs from checked-in pin" >&2; exit 1; }
[ "$UPDATE_PUBLIC_KEY" = "$PINNED_UPDATE_PUBLIC_KEY" ] || { echo "error: update public key differs from checked-in pin" >&2; exit 1; }
[ "$OPTIONAL_MODELS_ENABLED" = "false" ] || { echo "error: optional models must be disabled in this public release" >&2; exit 1; }

grep -F "  $(basename "$APP")" "$SHA256SUMS" >/dev/null || { echo "error: app is missing from SHA256SUMS" >&2; exit 1; }
grep -F "  $(basename "$RUNTIME_ZIP")" "$SHA256SUMS" >/dev/null || { echo "error: runtime is missing from SHA256SUMS" >&2; exit 1; }
grep -F "  $(basename "$APP_SIGNATURE")" "$SHA256SUMS" >/dev/null || { echo "error: app signature is missing from SHA256SUMS" >&2; exit 1; }
APP_HASH="$(shasum -a 256 "$APP" | awk '{print $1}')"
RUNTIME_HASH="$(shasum -a 256 "$RUNTIME_ZIP" | awk '{print $1}')"
SIGNATURE_HASH="$(shasum -a 256 "$APP_SIGNATURE" | awk '{print $1}')"
grep -F "$APP_HASH  $(basename "$APP")" "$SHA256SUMS" >/dev/null || { echo "error: app checksum differs from SHA256SUMS" >&2; exit 1; }
grep -F "$RUNTIME_HASH  $(basename "$RUNTIME_ZIP")" "$SHA256SUMS" >/dev/null || { echo "error: runtime checksum differs from SHA256SUMS" >&2; exit 1; }
grep -F "$SIGNATURE_HASH  $(basename "$APP_SIGNATURE")" "$SHA256SUMS" >/dev/null || { echo "error: app signature checksum differs from SHA256SUMS" >&2; exit 1; }
[ "$RUNTIME_HASH" = "$RUNTIME_SHA256" ] || { echo "error: app embedded runtime checksum differs from runtime archive" >&2; exit 1; }

/usr/bin/swift -e '
import CryptoKit
import Darwin
import Foundation

guard CommandLine.arguments.count == 4,
      let publicKeyData = Data(base64Encoded: CommandLine.arguments[1]),
      publicKeyData.count == 32,
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
      let signatureText = try? String(
        contentsOfFile: CommandLine.arguments[3],
        encoding: .utf8
      ),
      let signature = Data(base64Encoded: signatureText.trimmingCharacters(
        in: .whitespacesAndNewlines
      )),
      signature.count == 64,
      let archive = try? Data(
        contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]),
        options: .mappedIfSafe
      ),
      publicKey.isValidSignature(signature, for: archive) else {
    fputs("invalid Ed25519 release signature\n", stderr)
    exit(EXIT_FAILURE)
}
' "$PINNED_UPDATE_PUBLIC_KEY" "$APP" "$APP_SIGNATURE"

STAGING="$VALIDATION_TMP/runtime"
# RuntimeManager installs with ditto. Use the identical extractor here because
# macOS ZIP AppleDouble entries are metadata to ditto but ordinary `._*` files
# to unzip, which would authenticate a different tree than production runs.
ditto -x -k "$RUNTIME_ZIP" "$STAGING"
TOP_LEVEL="$(find "$STAGING" -mindepth 1 -maxdepth 1 -exec basename {} \; 2>/dev/null || true)"
[ "$TOP_LEVEL" = "runtime" ] || { echo "error: runtime zip has the wrong top-level layout" >&2; exit 1; }
MANIFEST="$STAGING/runtime/manifest.json"
PYTHON="$STAGING/runtime/bin/python3.12"
[ -f "$MANIFEST" ] && [ -x "$PYTHON" ] || { echo "error: runtime manifest or Python executable missing" >&2; exit 1; }
MANIFEST_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runtimeVersion"])' "$MANIFEST")"
MANIFEST_MIN_OS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["minimumMacOS"])' "$MANIFEST")"
[ "$MANIFEST_VERSION" = "$RUNTIME_VERSION" ] || { echo "error: runtime manifest version disagrees with app" >&2; exit 1; }
[ "$MANIFEST_MIN_OS" = "$MIN_OS" ] || { echo "error: runtime and app minimum macOS versions disagree" >&2; exit 1; }
ACTUAL_RUNTIME_CONTENT_SHA256="$(
    python3 "$SCRIPT_DIR/runtime-content-sha256.py" "$STAGING/runtime"
)"
EXPECTED_RUNTIME_CONTENT_SHA256="$(printf '%s' "$RUNTIME_CONTENT_SHA256" | tr '[:upper:]' '[:lower:]')"
[ "$ACTUAL_RUNTIME_CONTENT_SHA256" = "$EXPECTED_RUNTIME_CONTENT_SHA256" ] || {
    echo "error: app embedded runtime content digest differs from runtime archive" >&2
    exit 1
}
PYTHONNOUSERSITE=1 PYTHONPATH= PYTHONHOME= VIRTUAL_ENV= "$PYTHON" -s -u -c 'import mlx, numpy, huggingface_hub, mlx_qwen3_asr'

version_at_most() {
    [ "$1" = "$2" ] || [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$2" ]
}

while IFS= read -r FILE; do
    BINARY_MIN_OS="$(vtool -show-build "$FILE" 2>/dev/null | awk '/minos/ {print $2; exit}')"
    [ -n "$BINARY_MIN_OS" ] && version_at_most "$BINARY_MIN_OS" "$MIN_OS" || {
        echo "error: runtime binary requires macOS ${BINARY_MIN_OS:-unknown}: $FILE" >&2
        exit 1
    }
    codesign --verify --strict \
        -R="certificate leaf = H\"$PINNED_SIGNING_CERT_SHA1\"" "$FILE"
done < <(find "$STAGING/runtime" -type f -print0 | xargs -0 file | awk -F: '/Mach-O/ {print $1}')

echo "release artifacts validated"
