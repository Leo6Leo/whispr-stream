#!/bin/bash
# Exercise the real update helper against disposable app bundles.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/.build/debug/WhisprStreamUpdateInstaller"
SYSTEM_TMP="${TMPDIR:-/tmp}"
SYSTEM_TMP="${SYSTEM_TMP%/}"
TEST_ROOT="$(mktemp -d /tmp/whisprstream-updater-e2e.XXXXXX)"
CLEANUP_ROOTS=()
HEALTHY_EXECUTABLE="$TEST_ROOT/HealthyUpdateApp"

cleanup() {
    local path
    for path in "${CLEANUP_ROOTS[@]}"; do
        case "$path" in
            "$TEST_ROOT"|"$TEST_ROOT"/*|"$SYSTEM_TMP"/WhisprStream-installer-*)
                rm -rf -- "$path"
                ;;
        esac
    done
}
trap cleanup EXIT INT TERM
CLEANUP_ROOTS+=("$TEST_ROOT")

fail() {
    echo "error: $*" >&2
    exit 1
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    [ "$actual" = "$expected" ] || fail "$message (expected $expected, got $actual)"
}

bundle_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}

create_app() {
    local app="$1"
    local version="$2"
    local executable_name="${3:-WhisprStream}"
    local launch_behavior="${4:-healthy}"
    local plist="$app/Contents/Info.plist"
    mkdir -p "$app/Contents/MacOS"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleIdentifier -string com.leoleo.whisprstream "$plist"
    plutil -insert CFBundleShortVersionString -string "$version" "$plist"
    plutil -insert CFBundleVersion -string 1 "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleExecutable -string "$executable_name" "$plist"
    plutil -insert LSMinimumSystemVersion -string 14.0 "$plist"
    if [ "$executable_name" = "WhisprStream" ]; then
        if [ "$launch_behavior" = "healthy" ]; then
            cp "$HEALTHY_EXECUTABLE" "$app/Contents/MacOS/WhisprStream"
        else
            cp /usr/bin/true "$app/Contents/MacOS/WhisprStream"
        fi
    fi
}

new_helper_root() {
    NEW_HELPER_ROOT="$(mktemp -d "$SYSTEM_TMP/WhisprStream-installer-XXXXXX")"
    CLEANUP_ROOTS+=("$NEW_HELPER_ROOT")
}

run_helper() {
    local staged="$1"
    local target="$2"
    local helper_root="$3"
    /bin/sleep 0.2 &
    local parent_pid=$!
    "$HELPER" \
        --wait-pid "$parent_pid" \
        --staged-app "$staged" \
        --target-app "$target" \
        --cleanup-root "$helper_root" \
        --ready-file "$helper_root/ready" \
        --health-file "$helper_root/health" \
        --health-token "00000000-0000-0000-0000-000000000001"
}

echo "Building the real update helper..."
swift build --package-path "$SCRIPT_DIR" --product WhisprStreamUpdateInstaller >/dev/null
[ -x "$HELPER" ] || fail "SwiftPM did not produce the update helper"
/usr/bin/clang -O "$SCRIPT_DIR/Tests/Fixtures/HealthyUpdateApp.c" -o "$HEALTHY_EXECUTABLE"
[ -x "$HEALTHY_EXECUTABLE" ] || fail "could not build the healthy launch fixture"

echo "[1/4] Successful replacement and cleanup"
SUCCESS_ROOT="$TEST_ROOT/success"
SUCCESS_TARGET="$SUCCESS_ROOT/WhisprStream.app"
SUCCESS_STAGED="$SUCCESS_ROOT/.WhisprStream.update-success.app"
mkdir -p "$SUCCESS_ROOT"
create_app "$SUCCESS_TARGET" 1.0.1
create_app "$SUCCESS_STAGED" 9.9.9
codesign --force --deep --sign - "$SUCCESS_TARGET" >/dev/null 2>&1
codesign --force --deep --sign - "$SUCCESS_STAGED" >/dev/null 2>&1
new_helper_root
SUCCESS_HELPER_ROOT="$NEW_HELPER_ROOT"
run_helper "$SUCCESS_STAGED" "$SUCCESS_TARGET" "$SUCCESS_HELPER_ROOT"
assert_equal 9.9.9 "$(bundle_value "$SUCCESS_TARGET" CFBundleShortVersionString)" \
    "the replacement version was not installed"
assert_equal 0 "$(find "$SUCCESS_ROOT" -maxdepth 1 -name '.WhisprStream.update-backup-*.app' | wc -l | tr -d ' ')" \
    "the successful update left a backup"
[ ! -e "$SUCCESS_HELPER_ROOT" ] || fail "the successful update left its helper directory"
# The relaunched app must own its TCC grants: it has to be launched through
# LaunchServices (its own responsible process), not as a child of the helper.
[ -f "$SUCCESS_ROOT/launch-identity" ] || fail "the relaunched app did not record its launch identity"
read -r LAUNCHED_PID LAUNCHED_RESPONSIBLE < "$SUCCESS_ROOT/launch-identity"
assert_equal "$LAUNCHED_PID" "$LAUNCHED_RESPONSIBLE" \
    "the relaunched app is not its own responsible process (TCC would charge the old app)"

echo "[2/4] Missing replacement executable restores the previous version"
ROLLBACK_ROOT="$TEST_ROOT/rollback"
ROLLBACK_TARGET="$ROLLBACK_ROOT/WhisprStream.app"
ROLLBACK_STAGED="$ROLLBACK_ROOT/.WhisprStream.update-rollback.app"
mkdir -p "$ROLLBACK_ROOT"
create_app "$ROLLBACK_TARGET" 1.0.1
create_app "$ROLLBACK_STAGED" 9.9.9 MissingExecutable
codesign --force --deep --sign - "$ROLLBACK_TARGET" >/dev/null 2>&1
new_helper_root
ROLLBACK_HELPER_ROOT="$NEW_HELPER_ROOT"
set +e
run_helper "$ROLLBACK_STAGED" "$ROLLBACK_TARGET" "$ROLLBACK_HELPER_ROOT" \
    >"$TEST_ROOT/rollback.stdout" 2>"$TEST_ROOT/rollback.stderr"
ROLLBACK_STATUS=$?
set -e
[ "$ROLLBACK_STATUS" -ne 0 ] || fail "the invalid replacement unexpectedly succeeded"
assert_equal 1.0.1 "$(bundle_value "$ROLLBACK_TARGET" CFBundleShortVersionString)" \
    "rollback did not restore the previous version"
assert_equal WhisprStream "$(bundle_value "$ROLLBACK_TARGET" CFBundleExecutable)" \
    "rollback did not restore the previous executable"
assert_equal 0 "$(find "$ROLLBACK_ROOT" -maxdepth 1 -name '.WhisprStream.update-*.app' | wc -l | tr -d ' ')" \
    "rollback left a staged, backup, or failed app"
[ ! -e "$ROLLBACK_HELPER_ROOT" ] || fail "rollback left its helper directory"
rg -q 'previous version was restored' "$TEST_ROOT/rollback.stderr" \
    || fail "rollback did not report that it restored the previous version"

echo "[3/4] Replacement without a health signal restores the previous version"
HEALTH_ROOT="$TEST_ROOT/health-timeout"
HEALTH_TARGET="$HEALTH_ROOT/WhisprStream.app"
HEALTH_STAGED="$HEALTH_ROOT/.WhisprStream.update-health-timeout.app"
mkdir -p "$HEALTH_ROOT"
create_app "$HEALTH_TARGET" 1.0.1
create_app "$HEALTH_STAGED" 9.9.9 WhisprStream no-health
codesign --force --deep --sign - "$HEALTH_TARGET" >/dev/null 2>&1
codesign --force --deep --sign - "$HEALTH_STAGED" >/dev/null 2>&1
new_helper_root
HEALTH_HELPER_ROOT="$NEW_HELPER_ROOT"
set +e
WHISPR_UPDATE_HEALTH_TIMEOUT=3 run_helper \
    "$HEALTH_STAGED" "$HEALTH_TARGET" "$HEALTH_HELPER_ROOT" \
    >"$TEST_ROOT/health.stdout" 2>"$TEST_ROOT/health.stderr"
HEALTH_STATUS=$?
set -e
[ "$HEALTH_STATUS" -ne 0 ] || fail "the unhealthy replacement unexpectedly succeeded"
assert_equal 1.0.1 "$(bundle_value "$HEALTH_TARGET" CFBundleShortVersionString)" \
    "health-check rollback did not restore the previous version"
rg -q 'did not report a healthy launch' "$TEST_ROOT/health.stderr" \
    || fail "health-check rollback returned the wrong failure"
[ ! -e "$HEALTH_HELPER_ROOT" ] || fail "health-check rollback left its helper directory"

echo "[4/4] Unsafe staged path is rejected before replacement"
SAFETY_ROOT="$TEST_ROOT/safety"
SAFETY_TARGET="$SAFETY_ROOT/WhisprStream.app"
SAFETY_STAGED="$SAFETY_ROOT/WhisprStream.update-unsafe.app"
mkdir -p "$SAFETY_ROOT"
create_app "$SAFETY_TARGET" 1.0.1
create_app "$SAFETY_STAGED" 9.9.9
new_helper_root
SAFETY_HELPER_ROOT="$NEW_HELPER_ROOT"
set +e
run_helper "$SAFETY_STAGED" "$SAFETY_TARGET" "$SAFETY_HELPER_ROOT" \
    >"$TEST_ROOT/safety.stdout" 2>"$TEST_ROOT/safety.stderr"
SAFETY_STATUS=$?
set -e
[ "$SAFETY_STATUS" -ne 0 ] || fail "the helper accepted an unsafe staged path"
assert_equal 1.0.1 "$(bundle_value "$SAFETY_TARGET" CFBundleShortVersionString)" \
    "unsafe-path validation modified the target app"
rg -q 'rejected an unsafe path' "$TEST_ROOT/safety.stderr" \
    || fail "unsafe-path validation returned the wrong failure"

echo "Updater end-to-end checks passed."
echo "The installed WhisprStream app and /Applications were not touched."
