#!/bin/bash
# Build WhisprStream.app.
#
# The ASR runs as a Python sidecar. Local builds use a prepared venv; public
# releases download a separately versioned runtime after first launch.
set -euo pipefail

cd "$(dirname "$0")"
PROJECT_ROOT="$(cd .. && pwd)"
PYTHON="${PYTHON:-$PROJECT_ROOT/.venv/bin/python}"
APP="${APP:-$PROJECT_ROOT/WhisprStream.app}"
VERSION="${VERSION:-1.0.2}"
BUILD_NUMBER="${BUILD_NUMBER:-4}"
RELEASE="${RELEASE:-0}"
ENABLE_OPTIONAL_MODELS="${ENABLE_OPTIONAL_MODELS:-}"
RUNTIME_URL="${RUNTIME_URL:-}"
RUNTIME_SHA256="${RUNTIME_SHA256:-}"
RUNTIME_CONTENT_SHA256="${RUNTIME_CONTENT_SHA256:-}"
RUNTIME_VERSION="${RUNTIME_VERSION:-}"
RUNTIME_ARCHIVE_BYTES="${RUNTIME_ARCHIVE_BYTES:-}"
RUNTIME_INSTALLED_BYTES="${RUNTIME_INSTALLED_BYTES:-}"
UPDATE_REPOSITORY="${UPDATE_REPOSITORY:-Leo6Leo/whispr-stream}"
PINNED_UPDATE_REPOSITORY="Leo6Leo/whispr-stream"
UPDATE_PUBLIC_KEY_FILE="$PROJECT_ROOT/WhisprStream/update-public-key.txt"
SIGNING_CERT_SHA1_FILE="$PROJECT_ROOT/WhisprStream/release-signing-certificate-sha1.txt"
UPDATE_PUBLIC_KEY="${UPDATE_PUBLIC_KEY:-}"
PINNED_UPDATE_PUBLIC_KEY=""
PINNED_SIGNING_CERT_SHA1=""
if [ -f "$UPDATE_PUBLIC_KEY_FILE" ]; then
    PINNED_UPDATE_PUBLIC_KEY="$(tr -d '\r\n' < "$UPDATE_PUBLIC_KEY_FILE")"
fi
if [ -f "$SIGNING_CERT_SHA1_FILE" ]; then
    PINNED_SIGNING_CERT_SHA1="$(tr -d '\r\n' < "$SIGNING_CERT_SHA1_FILE" \
        | tr '[:upper:]' '[:lower:]')"
fi
if [ -z "$UPDATE_PUBLIC_KEY" ]; then
    UPDATE_PUBLIC_KEY="$PINNED_UPDATE_PUBLIC_KEY"
fi
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-dev.local.whisprstream}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"

if [ -z "$ENABLE_OPTIONAL_MODELS" ]; then
    if [ "$RELEASE" = "1" ]; then
        ENABLE_OPTIONAL_MODELS=0
    else
        ENABLE_OPTIONAL_MODELS=1
    fi
fi
if [ "$ENABLE_OPTIONAL_MODELS" != "0" ] && [ "$ENABLE_OPTIONAL_MODELS" != "1" ]; then
    echo "error: ENABLE_OPTIONAL_MODELS must be 0 or 1" >&2
    exit 1
fi
if [ "$RELEASE" = "1" ] && [ "$ENABLE_OPTIONAL_MODELS" != "0" ]; then
    echo "error: optional models must remain disabled in public release builds" >&2
    exit 1
fi

OPTIONAL_MODELS_PLIST_VALUE="<false/>"
OPTIONAL_MODELS_LABEL="disabled"
if [ "$ENABLE_OPTIONAL_MODELS" = "1" ]; then
    OPTIONAL_MODELS_PLIST_VALUE="<true/>"
    OPTIONAL_MODELS_LABEL="enabled"
fi

swift_build() {
    local swift_defines=()
    if [ "$ENABLE_OPTIONAL_MODELS" = "1" ]; then
        swift_defines+=(
            -Xswiftc -D -Xswiftc WHISPR_ENABLE_OPTIONAL_MODELS
        )
    fi
    if [ "$RELEASE" = "1" ]; then
        # This must be compile-time, not inferred solely from mutable runtime
        # metadata, so a release binary can never honor developer overrides.
        swift_defines+=(
            -Xswiftc -D -Xswiftc WHISPR_RELEASE
        )
    fi
    swift build "$@" "${swift_defines[@]}"
}

if [ "$RELEASE" = "1" ]; then
    if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || ! [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
        echo "error: release app version must be stable semantic version and build number must be positive" >&2
        exit 1
    fi
    if [ -z "$RUNTIME_URL" ] || [ -z "$RUNTIME_SHA256" ] \
        || [ -z "$RUNTIME_CONTENT_SHA256" ] || [ -z "$RUNTIME_VERSION" ] \
        || [ -z "$RUNTIME_ARCHIVE_BYTES" ] || [ -z "$RUNTIME_INSTALLED_BYTES" ]; then
        echo "error: release builds require runtime URL, version, archive/content checksums, and byte metadata" >&2
        exit 1
    fi
    if ! [[ "$RUNTIME_URL" =~ ^https:// ]] || [[ "$RUNTIME_URL" == *"latest/download"* ]] \
        || ! [[ "$RUNTIME_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] \
        || ! [[ "$RUNTIME_CONTENT_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] \
        || ! [[ "$RUNTIME_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || ! [[ "$RUNTIME_ARCHIVE_BYTES" =~ ^[1-9][0-9]*$ ]] \
        || ! [[ "$RUNTIME_INSTALLED_BYTES" =~ ^[1-9][0-9]*$ ]]; then
        echo "error: runtime URL must be immutable HTTPS, checksum must be SHA-256, and sizes must be positive integers" >&2
        exit 1
    fi
    if [ "$BUNDLE_IDENTIFIER" != "com.leoleo.whisprstream" ]; then
        echo "error: release builds require bundle identifier com.leoleo.whisprstream" >&2
        exit 1
    fi
    if ! [[ "$PINNED_UPDATE_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
        || ! [[ "$PINNED_SIGNING_CERT_SHA1" =~ ^[0-9a-f]{40}$ ]]; then
        echo "error: release trust-root files are missing or malformed" >&2
        exit 1
    fi
    if [ "$UPDATE_REPOSITORY" != "$PINNED_UPDATE_REPOSITORY" ] \
        || [ "$UPDATE_PUBLIC_KEY" != "$PINNED_UPDATE_PUBLIC_KEY" ]; then
        echo "error: release update repository and public key must match their checked-in pins" >&2
        exit 1
    fi
    if [ -z "$SIGNING_IDENTITY" ] || [ "$SIGNING_IDENTITY" = "-" ]; then
        echo "error: RELEASE=1 requires SIGNING_IDENTITY; ad-hoc signing is not allowed" >&2
        exit 1
    fi
    DEVELOPMENT_PYTHON=""
    DEVELOPMENT_PYTHON_PLIST=""
else
    if [ ! -x "$PYTHON" ]; then
        echo "error: no python at $PYTHON" >&2
        echo "       set PYTHON=/path/to/python and re-run" >&2
        exit 1
    fi
    # Local builds continue to use the prepared venv. RELEASE=1 deliberately
    # clears this value so no developer-specific path is shipped to users.
    DEVELOPMENT_PYTHON="$PYTHON"
    DEVELOPMENT_PYTHON_PLIST="    <key>WhisprDevelopmentPythonPath</key><string>$DEVELOPMENT_PYTHON</string>"
fi

echo "▸ compiling"
if [ "$RELEASE" = "1" ]; then
    # Swift embeds source and object-file paths in optimized executables. Map
    # the repository root to a stable synthetic path so public artifacts never
    # disclose the builder's user name or local directory layout.
    RELEASE_PATH_FLAGS=(
        -Xswiftc -file-prefix-map \
        -Xswiftc "$PROJECT_ROOT=/src" \
        -Xcc "-fdebug-prefix-map=$PROJECT_ROOT=/src" \
        -Xcc "-ffile-prefix-map=$PROJECT_ROOT=/src"
    )
    # Keep the standalone signer's established binary/Keychain access
    # requirement stable. WHISPR_RELEASE is needed only by the app target's
    # runtime-selection code.
    swift build -c release --product WhisprStreamUpdateSigner \
        "${RELEASE_PATH_FLAGS[@]}"
    swift build -c release --product WhisprStreamUpdateInstaller \
        "${RELEASE_PATH_FLAGS[@]}"
    swift_build -c release --product WhisprStream \
        "${RELEASE_PATH_FLAGS[@]}"
else
    swift_build -c release
fi

BIN=".build/release/WhisprStream"
UPDATE_INSTALLER=".build/release/WhisprStreamUpdateInstaller"
UPDATE_SIGNER=".build/release/WhisprStreamUpdateSigner"
[ -x "$BIN" ] || { echo "error: build produced no binary" >&2; exit 1; }
[ -x "$UPDATE_INSTALLER" ] || { echo "error: build produced no update installer" >&2; exit 1; }
[ -x "$UPDATE_SIGNER" ] || { echo "error: build produced no update signer" >&2; exit 1; }

echo "▸ assembling $(basename "$APP")"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"

cp "$BIN" "$APP/Contents/MacOS/WhisprStream"
cp "$UPDATE_INSTALLER" "$APP/Contents/Helpers/WhisprStreamUpdateInstaller"
cp Resources/asr_server.py "$APP/Contents/Resources/"
cp Resources/model_download.py "$APP/Contents/Resources/"
cp "$PROJECT_ROOT/asr_engine.py" "$APP/Contents/Resources/"

BRAND_LOGO="$PROJECT_ROOT/assets/whisprstream-logo.png"
if [ ! -f "$BRAND_LOGO" ]; then
    echo "error: missing original WhisprStream logo at $BRAND_LOGO" >&2
    exit 1
fi
cp "$BRAND_LOGO" "$APP/Contents/Resources/whisprstream-logo.png"

APP_ICON="$PROJECT_ROOT/assets/WhisprStream.icns"
if [ ! -f "$APP_ICON" ]; then
    echo "error: missing WhisprStream app icon at $APP_ICON" >&2
    exit 1
fi
cp "$APP_ICON" "$APP/Contents/Resources/WhisprStream.icns"

if [ "$RELEASE" = "1" ]; then
    # The linker records absolute object-file paths as N_OSO debug symbols;
    # remove those records after source paths have been remapped above.
    strip -S "$APP/Contents/MacOS/WhisprStream"
    strip -S "$APP/Contents/Helpers/WhisprStreamUpdateInstaller"
    for EXECUTABLE in \
        "$APP/Contents/MacOS/WhisprStream" \
        "$APP/Contents/Helpers/WhisprStreamUpdateInstaller"; do
        if rg -a -q '(/Users/|/home/)' "$EXECUTABLE"; then
            echo "error: release executable contains a build-machine home path" >&2
            exit 1
        fi
    done
fi

# Designed start/finish sounds. Regenerate with sound-design/render_sounds.py.
if [ -d Resources/Sounds ]; then
    mkdir -p "$APP/Contents/Resources/Sounds"
    cp Resources/Sounds/*.caf "$APP/Contents/Resources/Sounds/"
    echo "▸ bundling $(ls Resources/Sounds/*.caf | wc -l | tr -d ' ') sounds"
else
    echo "warning: no Resources/Sounds — run sound-design/render_sounds.py" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>WhisprStream</string>
    <key>CFBundleDisplayName</key><string>WhisprStream</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>WhisprStream</string>
    <key>CFBundleIconFile</key><string>WhisprStream.icns</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>WhisprStream transcribes your speech on-device.</string>
$DEVELOPMENT_PYTHON_PLIST
    <key>WhisprRuntimeURL</key><string>$RUNTIME_URL</string>
    <key>WhisprRuntimeSHA256</key><string>$RUNTIME_SHA256</string>
    <key>WhisprRuntimeContentSHA256</key><string>$RUNTIME_CONTENT_SHA256</string>
    <key>WhisprRuntimeVersion</key><string>$RUNTIME_VERSION</string>
    <key>WhisprRuntimeArchiveBytes</key><string>$RUNTIME_ARCHIVE_BYTES</string>
    <key>WhisprRuntimeInstalledBytes</key><string>$RUNTIME_INSTALLED_BYTES</string>
    <key>WhisprUpdateRepository</key><string>$UPDATE_REPOSITORY</string>
    <key>WhisprUpdatePublicKey</key><string>$UPDATE_PUBLIC_KEY</string>
    <key>WhisprOptionalModelsEnabled</key>$OPTIONAL_MODELS_PLIST_VALUE
</dict>
</plist>
PLIST

# No entitlements: the app is not sandboxed, so com.apple.security.* keys buy
# nothing and attaching them to an ad-hoc signature confuses TCC. Microphone
# access comes from NSMicrophoneUsageDescription; Accessibility is granted by
# the user in System Settings.
#
# An ad-hoc signature is tied to the binary hash, so every rebuild looks like a
# different app to TCC and silently drops the Accessibility grant. A self-signed
# certificate keeps one identity across rebuilds, so the grant sticks.
IDENTITY="$SIGNING_IDENTITY"
CODESIGN_OPTIONS=()
if [ "$RELEASE" = "1" ]; then
    echo "▸ signing release with $IDENTITY"
    CODESIGN_OPTIONS=(--options runtime,library)
else
    if security find-identity -p codesigning 2>/dev/null | grep -q "WhisprStream Self-Signed"; then
        IDENTITY="WhisprStream Self-Signed"
        echo "▸ signing with stable identity"
    else
        IDENTITY="-"
        echo "▸ signing ad-hoc (Accessibility must be re-granted after each rebuild)"
        echo "  to fix permanently, see: make-signing-cert.md"
    fi
fi

# macOS still ships Bash 3.2, where expanding an empty array under `set -u`
# raises "unbound variable". Local signing has no extra options, so route the
# call explicitly instead of expanding that empty array.
codesign_force() {
    if [ "${#CODESIGN_OPTIONS[@]}" -gt 0 ]; then
        codesign --force "${CODESIGN_OPTIONS[@]}" "$@"
    else
        codesign --force "$@"
    fi
}

if [ "$RELEASE" = "1" ]; then
    # A stable code identity lets this release-only tool retain access to the
    # same login-Keychain signing key across rebuilds.
    codesign_force --sign "$IDENTITY" "$UPDATE_SIGNER"
    codesign --verify --strict "$UPDATE_SIGNER"
    codesign --verify --strict \
        -R="identifier \"WhisprStreamUpdateSigner\" and certificate leaf = H\"$PINNED_SIGNING_CERT_SHA1\"" \
        "$UPDATE_SIGNER"
fi
codesign_force --sign "$IDENTITY" \
    "$APP/Contents/Helpers/WhisprStreamUpdateInstaller"
# Nested code is signed explicitly above; signing the outer bundle without
# --deep prevents codesign from making implicit nested-code decisions.
codesign_force --sign "$IDENTITY" "$APP"
if [ "$RELEASE" = "1" ]; then
    codesign --verify --strict --deep "$APP"
    codesign --verify --strict --deep \
        -R="identifier \"com.leoleo.whisprstream\" and certificate leaf = H\"$PINNED_SIGNING_CERT_SHA1\"" \
        "$APP"
    codesign --verify --strict \
        -R="identifier \"WhisprStreamUpdateInstaller\" and certificate leaf = H\"$PINNED_SIGNING_CERT_SHA1\"" \
        "$APP/Contents/Helpers/WhisprStreamUpdateInstaller"
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
    assert_hardened_runtime "$UPDATE_SIGNER"
    assert_hardened_runtime "$APP/Contents/Helpers/WhisprStreamUpdateInstaller"
    assert_hardened_runtime "$APP"
    if /usr/libexec/PlistBuddy -c "Print :WhisprDevelopmentPythonPath" "$APP/Contents/Info.plist" >/dev/null 2>&1; then
        echo "error: release Info.plist contains a development Python path" >&2
        exit 1
    fi
    if [ "$(/usr/libexec/PlistBuddy -c "Print :WhisprOptionalModelsEnabled" "$APP/Contents/Info.plist")" != "false" ]; then
        echo "error: release Info.plist enables optional models" >&2
        exit 1
    fi
fi

echo "✓ built $APP"
echo "  optional models: $OPTIONAL_MODELS_LABEL"
if [ "$RELEASE" = "1" ]; then
    echo "  runtime: $RUNTIME_URL"
else
    echo "  python: $PYTHON"
fi
echo
echo "  open $APP"
