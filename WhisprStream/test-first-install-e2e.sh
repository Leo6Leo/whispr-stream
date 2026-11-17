#!/bin/bash
# First-install end-to-end check for a WhisprStream release candidate.
#
# Exercises the real release artifacts the way a new Mac receives them:
#   1. SHA256SUMS and the existing read-only validate-release.sh.
#   2. A browser-style download: the ZIP gets a quarantine attribute, is
#      extracted with ditto (which propagates it), and the quarantined bundle's
#      signature, pins, and Gatekeeper assessment are checked.
#   3. The app's own runtime installer (FirstInstallE2ETests, release config)
#      installs the real runtime ZIP into an empty temporary Application
#      Support, plus checksum, truncation, content-digest, failed-repair and
#      insufficient-space (a 48 MB disk image) failures, and a health check
#      under a hostile Python environment.
#   4. The candidate's bundled model_download.py and asr_server.py run from
#      that installed runtime (tests/test_first_install_e2e.py): loopback Hub
#      download, cancel, partial cleanup, offline, outage, insufficient space,
#      and a real offline model load and transcription when the
#      Qwen3-ASR-0.6B cache exists (read through symlinks, never written).
#
# It never launches the candidate app, never touches /Applications, TCC, the
# real WhisprStream preferences, Application Support, log, or Hugging Face
# cache, and removes everything it creates. Optional phases:
#
#   WHISPR_E2E_NETWORK=1   HEAD the pinned runtime URL on GitHub and compare
#                          its size (network, read-only).
#   WHISPR_E2E_LAUNCH=dry  Prepare (but do not launch) an ad-hoc re-signed
#                          clone with a unique bundle id, see below.
#   WHISPR_E2E_LAUNCH=1    Also launch that clone against an empty home and
#                          assert its log takes the first-run path. It opens
#                          the setup window and takes keyboard focus, so run
#                          it only when you are not dictating.
#
# Usage: WhisprStream/test-first-install-e2e.sh [artifact-directory]
# Environment: VERSION, BUILD_NUMBER (default: build.sh defaults), PYTEST.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACTS="$(cd "${1:-$PROJECT_ROOT}" && pwd)"
APP_ZIP="$ARTIFACTS/WhisprStream-macos-arm64.zip"
APP_SIGNATURE="$APP_ZIP.ed25519"
SUMS="$ARTIFACTS/SHA256SUMS"
default_from_build() {
    sed -n "s/^$1=\"\${$1:-\([^}]*\)}\"$/\1/p" "$SCRIPT_DIR/build.sh" | head -n 1
}
VERSION="${VERSION:-$(default_from_build VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(default_from_build BUILD_NUMBER)}"
PYTEST="${PYTEST:-pytest}"
PINNED_SIGNING_CERT_SHA1="$(tr -d '\r\n' < "$SCRIPT_DIR/release-signing-certificate-sha1.txt" | tr '[:upper:]' '[:lower:]')"
LAUNCH_MODE="${WHISPR_E2E_LAUNCH:-0}"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/whisprstream-first-install.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
SMALL_VOLUME=""
LAUNCHED_PID=""
CLONE_ID=""
cleanup() {
    if [ -n "$LAUNCHED_PID" ] && kill -0 "$LAUNCHED_PID" 2>/dev/null; then
        kill "$LAUNCHED_PID" 2>/dev/null || true
        sleep 1
        kill -9 "$LAUNCHED_PID" 2>/dev/null || true
    fi
    if [ -n "$CLONE_ID" ]; then
        defaults delete "$CLONE_ID" >/dev/null 2>&1 || true
        rm -f "$HOME/Library/Preferences/$CLONE_ID.plist"
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
            -u "$TEST_ROOT/launch/WhisprStream.app" >/dev/null 2>&1 || true
    fi
    if [ -n "$SMALL_VOLUME" ]; then
        hdiutil detach "$SMALL_VOLUME" -force -quiet >/dev/null 2>&1 || true
    fi
    case "$TEST_ROOT" in
        */whisprstream-first-install.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok  $*"; }
phase() { echo; echo "== $*"; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }

[ -n "$VERSION" ] && [ -n "$BUILD_NUMBER" ] || fail "could not determine VERSION/BUILD_NUMBER"
for file in "$APP_ZIP" "$APP_SIGNATURE" "$SUMS"; do
    [ -f "$file" ] || fail "missing $file"
done
RUNTIME_ZIP="$(ls "$ARTIFACTS"/WhisprStream-runtime-*-arm64.zip 2>/dev/null | head -n 1 || true)"
[ -n "$RUNTIME_ZIP" ] || fail "missing WhisprStream-runtime-*-arm64.zip in $ARTIFACTS"
echo "candidate $VERSION ($BUILD_NUMBER) from $ARTIFACTS"
echo "scratch   $TEST_ROOT"

phase "1. Published checksums and release validation"
(cd "$ARTIFACTS" && shasum -a 256 -c SHA256SUMS) | sed 's/^/  /'
bash "$SCRIPT_DIR/validate-release.sh" "$APP_ZIP" "$RUNTIME_ZIP" "$SUMS" "$APP_SIGNATURE" \
    "$VERSION" "$BUILD_NUMBER" | sed 's/^/  /'

phase "2. Browser download, quarantine, and first-launch prerequisites"
DOWNLOADS="$TEST_ROOT/Downloads"
mkdir -p "$DOWNLOADS"
cp "$APP_ZIP" "$DOWNLOADS/"
DOWNLOADED_ZIP="$DOWNLOADS/$(basename "$APP_ZIP")"
# The attribute Safari writes on a download: flags;hex time;agent;UUID.
xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)" "$DOWNLOADED_ZIP"
ditto -x -k "$DOWNLOADED_ZIP" "$DOWNLOADS"
APP="$DOWNLOADS/WhisprStream.app"
[ -d "$APP" ] || fail "archive did not produce WhisprStream.app"
xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1 \
    || fail "extraction did not propagate quarantine; this run would not model a browser download"
pass "extracted app carries com.apple.quarantine"
[ -z "$(find "$APP" -name '._*' -print -quit)" ] || fail "AppleDouble files leaked into the bundle"
codesign --verify --strict --deep \
    -R="identifier \"com.leoleo.whisprstream\" and certificate leaf = H\"$PINNED_SIGNING_CERT_SHA1\"" "$APP" \
    || fail "quarantined bundle fails strict signature verification"
pass "quarantined bundle passes strict deep signature verification with the pinned certificate"
CODE_FLAGS="$(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p')"
case "$CODE_FLAGS" in *runtime*) pass "hardened runtime ($CODE_FLAGS)";; *) fail "not hardened: $CODE_FLAGS";; esac
SPCTL="$(spctl --assess --type execute -vv "$APP" 2>&1 || true)"
echo "$SPCTL" | sed 's/^/  spctl: /'
case "$SPCTL" in
    *invalid*|*"not signed"*|*damaged*) fail "Gatekeeper reports a broken bundle" ;;
    *accepted*) pass "Gatekeeper accepts the bundle" ;;
    *rejected*) pass "Gatekeeper rejects it as expected for a self-signed, non-notarized build (users need Open Anyway; manual)" ;;
    *) fail "unexpected Gatekeeper assessment" ;;
esac
[ "$(plist "$APP" CFBundleShortVersionString)" = "$VERSION" ] || fail "version mismatch"
[ "$(plist "$APP" CFBundleVersion)" = "$BUILD_NUMBER" ] || fail "build mismatch"
[ "$(plist "$APP" LSUIElement)" = "true" ] || fail "LSUIElement must be true for a menu-bar app"
RUNTIME_URL="$(plist "$APP" WhisprRuntimeURL)"
[ "$(basename "$RUNTIME_URL")" = "$(basename "$RUNTIME_ZIP")" ] \
    || fail "pinned runtime URL names $(basename "$RUNTIME_URL"), not $(basename "$RUNTIME_ZIP")"
ARCHIVE_BYTES="$(plist "$APP" WhisprRuntimeArchiveBytes)"
[ "$ARCHIVE_BYTES" = "$(stat -f %z "$RUNTIME_ZIP")" ] || fail "WhisprRuntimeArchiveBytes differs from the runtime ZIP size"
pass "Info.plist pins $(basename "$RUNTIME_URL") ($ARCHIVE_BYTES bytes)"
cmp -s "$APP/Contents/Resources/model_download.py" "$SCRIPT_DIR/Resources/model_download.py" \
    && cmp -s "$APP/Contents/Resources/asr_server.py" "$SCRIPT_DIR/Resources/asr_server.py" \
    && cmp -s "$APP/Contents/Resources/asr_engine.py" "$PROJECT_ROOT/asr_engine.py" \
    && pass "bundled Python helpers match this checkout" \
    || echo "  note: bundled Python helpers differ from this checkout; phase 4 tests the bundled copies"

if [ "${WHISPR_E2E_NETWORK:-0}" = "1" ]; then
    phase "2b. Pinned runtime URL is published (network)"
    HEADERS="$(curl -sSIL --max-time 30 "$RUNTIME_URL")" || fail "could not reach $RUNTIME_URL"
    STATUS="$(echo "$HEADERS" | awk '/^HTTP\//{code=$2} END{print code}')"
    LENGTH="$(echo "$HEADERS" | tr -d '\r' | awk 'tolower($1)=="content-length:"{len=$2} END{print len}')"
    [ "$STATUS" = "200" ] || fail "pinned runtime URL returned HTTP $STATUS"
    [ "$LENGTH" = "$ARCHIVE_BYTES" ] || fail "published runtime is $LENGTH bytes, pinned $ARCHIVE_BYTES"
    pass "$RUNTIME_URL is published with the pinned size"
fi

phase "3. App runtime installer on an empty home (Swift, release configuration)"
FRESH_HOME="$TEST_ROOT/home"
SUPPORT="$FRESH_HOME/Library/Application Support"
mkdir -p "$SUPPORT"
hdiutil create -size 48m -fs APFS -volname WhisprE2ESmall -type SPARSE \
    "$TEST_ROOT/small.sparseimage" -quiet
mkdir -p "$TEST_ROOT/small"
hdiutil attach -nobrowse -noautoopen -mountpoint "$TEST_ROOT/small" "$TEST_ROOT/small.sparseimage" -quiet
SMALL_VOLUME="$TEST_ROOT/small"
SWIFT_LOG="$TEST_ROOT/swift-test.log"
set +e
(
    cd "$SCRIPT_DIR"
    WHISPR_E2E_RUNTIME_ZIP="$RUNTIME_ZIP" WHISPR_E2E_APP="$APP" \
    WHISPR_E2E_INSTALL_ROOT="$SUPPORT" WHISPR_E2E_SMALL_VOLUME="$SMALL_VOLUME" \
        swift test --build-system native -c release \
            -Xswiftc -enable-testing -Xswiftc -DWHISPR_RELEASE \
            --filter FirstInstallE2ETests
) > "$SWIFT_LOG" 2>&1
SWIFT_STATUS=$?
set -e
{ grep -E "^Test Case .*(passed|failed|skipped)|: error: " "$SWIFT_LOG" || true
  grep -E "Executed [0-9]+ tests" "$SWIFT_LOG" | tail -n 1 || true
} | sed 's/^/  /' 
[ "$SWIFT_STATUS" -eq 0 ] || fail "FirstInstallE2ETests failed (log: $SWIFT_LOG)"
! grep -q "skipped" "$SWIFT_LOG" || fail "FirstInstallE2ETests skipped a case; every input was provided"
RUNTIME_DIR="$SUPPORT/WhisprStream/Runtime"
[ -x "$RUNTIME_DIR/bin/python3.12" ] || fail "installer left no runtime at $RUNTIME_DIR"
hdiutil detach "$SMALL_VOLUME" -quiet && SMALL_VOLUME=""
pass "runtime installed by RuntimeManager.installArchive at a fresh Application Support"

phase "4. Model download helper and speech sidecar from the installed runtime"
if ! (
    cd "$PROJECT_ROOT"
    WHISPR_E2E=1 WHISPR_E2E_RUNTIME="$RUNTIME_DIR" WHISPR_E2E_APP="$APP" \
        "$PYTEST" -q -rsxX -p no:cacheprovider tests/test_first_install_e2e.py
) 2>&1 | sed 's/^/  /'; then
    fail "tests/test_first_install_e2e.py failed"
fi

if [ "$LAUNCH_MODE" != "0" ]; then
    phase "5. Re-signed clone against an empty home ($LAUNCH_MODE)"
    # The candidate itself shares com.leoleo.whisprstream with an installed
    # copy, and cfprefsd ignores CFFIXED_USER_HOME, so launching it would read
    # and merge the real preferences. A clone with a unique bundle id gets an
    # empty preferences domain; CFFIXED_USER_HOME redirects Application
    # Support, the log, and NSHomeDirectory (the model cache root).
    CLONE_ID="test.whisprstream.firstinstall.$$"
    CLONE="$TEST_ROOT/launch/WhisprStream.app"
    mkdir -p "$TEST_ROOT/launch" "$TEST_ROOT/launch-home"
    ditto "$APP" "$CLONE"
    xattr -dr com.apple.quarantine "$CLONE"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $CLONE_ID" "$CLONE/Contents/Info.plist"
    codesign -d --entitlements - --xml "$APP" > "$TEST_ROOT/launch/entitlements.plist" 2>/dev/null
    codesign --force --deep --options runtime --entitlements "$TEST_ROOT/launch/entitlements.plist" \
        --sign - "$CLONE" 2>/dev/null
    codesign --verify --strict --deep "$CLONE" || fail "re-signed clone does not verify"
    pass "clone $CLONE_ID re-signed ad hoc with the candidate's entitlements"
    LAUNCH_HOME="$TEST_ROOT/launch-home"
    if [ "$LAUNCH_MODE" = "dry" ]; then
        echo "  dry run: would start CFFIXED_USER_HOME=$LAUNCH_HOME HF_HOME=$LAUNCH_HOME/hf $CLONE/Contents/MacOS/WhisprStream"
    else
        LAUNCH_LOG="$LAUNCH_HOME/Library/Logs/WhisprStream.log"
        CFFIXED_USER_HOME="$LAUNCH_HOME" HF_HOME="$LAUNCH_HOME/hf" \
            "$CLONE/Contents/MacOS/WhisprStream" > "$TEST_ROOT/launch/stdout.log" 2>&1 &
        LAUNCHED_PID=$!
        for _ in $(seq 1 100); do
            grep -q "launch:" "$LAUNCH_LOG" 2>/dev/null && break
            sleep 0.2
        done
        LAUNCH_LINE="$(grep "launch:" "$LAUNCH_LOG" 2>/dev/null | tail -n 1 || true)"
        echo "  $LAUNCH_LINE"
        [ -n "$LAUNCH_LINE" ] || fail "clone wrote no launch line to its redirected log"
        case "$LAUNCH_LINE" in
            *"onboarded=false"*"developerTestMode=false"*) pass "first-run path: not onboarded, no developer simulator" ;;
            *) fail "clone did not take the first-run path" ;;
        esac
        [ ! -e "$LAUNCH_HOME/Library/Application Support/WhisprStream/Runtime" ] \
            || fail "a fresh launch must not find or create a runtime before setup"
        kill -0 "$LAUNCHED_PID" 2>/dev/null || fail "clone exited during first launch"
        pass "clone is running the setup guide; stopping it"
    fi
fi

phase "Done"
echo "first-install end-to-end checks passed for $VERSION ($BUILD_NUMBER)"
echo "still manual: see RELEASING.md section 4 (Gatekeeper Open Anyway, native microphone and"
echo "Accessibility prompts on an account with no grant, real dictation, 8 GB hardware, macOS 14)"
