#!/bin/bash
# Prove that an installed copy of the previous public release updates itself
# to the current tree through the in-app updater, exactly as an existing user
# would: the copy is launched through LaunchServices, discovers the update in
# a GitHub-shaped feed, downloads and verifies it, hands it to an update
# helper, and comes back as exactly one process of the new version that is
# its own responsible process for macOS privacy permissions, with the user's
# preferences, vocabulary, Application Support data, speech runtime, and
# model cache untouched.
#
# Which helper performs the swap depends on the old version. Releases before
# 1.0.4 run their own helper, which spawns the new app as its child; the new
# app detects that (UpdateRelaunch.swift) and relaunches itself through
# LaunchServices. From 1.0.4 on, the old app runs the helper shipped inside the
# verified replacement, so a 1.0.5 -> 1.0.6 update is installed by the 1.0.6
# helper through LaunchServices and must not relaunch. The script derives the
# expected path from the old tag's source and asserts the matching log lines.
set -euo pipefail

usage() {
    cat <<'EOF'
usage: test-update-from-release.sh [<old-tag>] [--check | --prepare-only] [--manual] [--leave-running]

  <old-tag>        git tag of the installed release to start from (default v1.0.5)
  --check          fast static checks only (tools, tag, release pins, and the log
                   lines and UI labels this test depends on, in the old tag and
                   the current tree); builds and launches nothing
  --prepare-only   build, configure, sign, and serve everything, report whether
                   this Mac is ready for the live run, then stop without
                   launching the app or touching any preferences
  --manual         never click the update prompt from this script; you choose
                   Update & Relaunch (or Settings -> About -> Install and Relaunch)
  --leave-running  after a green run, keep the updated app and its temporary
                   install for a manual dictation check (the script prints the
                   path to remove later)

Environment:
  WHISPR_REPLACEMENT_APP      prebuilt RELEASE=1 WhisprStream.app of the current
                              tree (the release candidate); skips the release build
  WHISPR_EXPECTED_VERSION     version the replacement must have (default: build.sh)
  WHISPR_EXPECTED_BUILD       build number the replacement must have (default: build.sh)
  WHISPR_UPDATE_TEST_TIMEOUT  seconds to wait for the update (default 900)
  PYTHON                      interpreter recorded by the old tag's local build.sh
                              (default: the repository's .venv, else python3)

The live run needs every WhisprStream instance quit (a second instance would
share the trigger key, the microphone, Application Support, and the log), a
Mac where the release app (com.leoleo.whisprstream) has completed onboarding
with the public speech runtime installed, the "WhisprStream Self-Signed"
identity, and Accessibility access for the terminal if the script should click
the prompt. The copies run under the release identifier, so they share the
installed app's preferences: the script exports that domain first, clears
updates.lastPromptedVersion and adds a canary key for the run, and on exit
deletes and re-imports the export, then verifies the domain matches it. It
never touches /Applications, the repository's WhisprStream.app, the
dev.local.whisprstream domain, or TCC, and it removes its worktrees and
temporary files on exit.
EOF
    exit 2
}

OLD_TAG=v1.0.5
OLD_TAG_GIVEN=false
MANUAL=false
LEAVE_RUNNING=false
PREPARE_ONLY=false
CHECK_ONLY=false
for argument in "$@"; do
    case "$argument" in
        --manual) MANUAL=true ;;
        --leave-running) LEAVE_RUNNING=true ;;
        --prepare-only) PREPARE_ONLY=true ;;
        --check) CHECK_ONLY=true ;;
        -h|--help) usage ;;
        -*) usage ;;
        *)
            [ "$OLD_TAG_GIVEN" = false ] || usage
            OLD_TAG="$argument"
            OLD_TAG_GIVEN=true
            ;;
    esac
done
if [ "$CHECK_ONLY" = true ] && [ "$PREPARE_ONLY" = true ]; then
    usage
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASING="$REPOSITORY_ROOT/RELEASING.md"
IDENTITY="WhisprStream Self-Signed"
BUNDLE_IDENTIFIER="com.leoleo.whisprstream"
PROMPTED_VERSION_KEY="updates.lastPromptedVersion"
CANARY_KEY="whisprUpdateTest.canary"
LOG="$HOME/Library/Logs/WhisprStream.log"
SUPPORT_DIR="$HOME/Library/Application Support/WhisprStream"
TIMEOUT="${WHISPR_UPDATE_TEST_TIMEOUT:-900}"
PYTHON="${PYTHON:-$REPOSITORY_ROOT/.venv/bin/python}"
OLD_VERSION="${OLD_TAG#v}"
SOURCES="WhisprStream/Sources/WhisprStream"
HELPER_SOURCE="WhisprStream/Sources/WhisprStreamUpdateInstaller/main.swift"
LS_SELECTOR="openApplicationAtURL:configuration:completionHandler:"
FAILURE_PATTERN='update relaunch failed|update install failed|update check failed|\[whispr updater\] update failed|update launch health signal failed'

fail() {
    echo "error: $*" >&2
    exit 1
}

note() {
    echo "      note: $*"
}

# ---------------------------------------------------------------------------
# Static checks: these run in every mode, and alone with --check.

[ "$(uname)" = Darwin ] || fail "this test drives the macOS updater and only runs on macOS"
for tool in git swift python3 codesign ditto curl osascript defaults pgrep open lsappinfo cmp diff; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done
[ -x /usr/libexec/PlistBuddy ] || fail "missing /usr/libexec/PlistBuddy"
[ -f "$RELEASING" ] || fail "missing $RELEASING (the release runtime pins are read from it)"
[[ "$OLD_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "old tag must look like v1.2.3, got $OLD_TAG"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || fail "WHISPR_UPDATE_TEST_TIMEOUT must be a positive integer"
git -C "$REPOSITORY_ROOT" rev-parse --verify --quiet "refs/tags/$OLD_TAG^{commit}" >/dev/null \
    || fail "unknown tag $OLD_TAG in $REPOSITORY_ROOT"
# The launched copy needs the debug overrides in its environment without
# changing the whole login session (launchctl setenv); open --env does that.
OPEN_HELP="$(open -h 2>&1 || true)"
case "$OPEN_HELP" in
    *--env*) ;;
    *) fail "this macOS 'open' does not support --env" ;;
esac

# The current tree's build.sh defaults are the version this release ships.
build_default() {
    sed -n "s/^$1=\"\${$1:-\([^}]*\)}\"$/\1/p" "$SCRIPT_DIR/build.sh" | sed -n '1p'
}
EXPECTED_VERSION="${WHISPR_EXPECTED_VERSION:-$(build_default VERSION)}"
EXPECTED_BUILD="${WHISPR_EXPECTED_BUILD:-$(build_default BUILD_NUMBER)}"
[[ "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$EXPECTED_BUILD" =~ ^[1-9][0-9]*$ ]] \
    || fail "could not read VERSION and BUILD_NUMBER defaults from build.sh"
python3 -I -c '
import sys
old, new = (tuple(int(part) for part in value.split(".")) for value in sys.argv[1:])
sys.exit(0 if new > old else 1)
' "$OLD_VERSION" "$EXPECTED_VERSION" \
    || fail "$OLD_TAG is not older than the current tree's version $EXPECTED_VERSION"

releasing_value() {
    sed -n "s/^$1=//p" "$2" | sed -n '1p' | tr -d '"\\ '
}
RUNTIME_PIN_NAMES="RUNTIME_VERSION RUNTIME_URL RUNTIME_SHA256 RUNTIME_CONTENT_SHA256 RUNTIME_ARCHIVE_BYTES RUNTIME_INSTALLED_BYTES"
for name in $RUNTIME_PIN_NAMES; do
    [ -n "$(releasing_value "$name" "$RELEASING")" ] || fail "could not read $name from RELEASING.md"
done

# Every log line and label the live run waits for or asserts on must still
# exist, in the old tag (which emits the early ones) and in the current tree
# (the new app and helper). A rename would otherwise surface only as a timeout.
old_source_has() {
    git -C "$REPOSITORY_ROOT" grep -q -F -e "$2" "$OLD_TAG" -- "$1" 2>/dev/null
}
current_source_has() {
    grep -r -q -F -e "$2" "$REPOSITORY_ROOT/$1"
}
require_old() {
    old_source_has "$1" "$2" || fail "$OLD_TAG:$1 no longer contains \"$2\" ($3)"
}
require_current() {
    current_source_has "$1" "$2" || fail "the current $1 no longer contains \"$2\" ($3)"
}
require_old "$SOURCES" 'WHISPR_UPDATE_FEED_URL' "loopback feed override the old debug app needs"
require_old "$SOURCES" 'WHISPR_UPDATE_PUBLIC_KEY' "update key override the old debug app needs"
require_old "$SOURCES" 'update: verified version' "logged by the old app before it hands over"
require_old "$SOURCES" 'Update & Relaunch' "automatic update prompt button"
require_old "$SOURCES" 'Update WhisprStream to' "status-bar menu item that reopens the prompt"
require_old "$SOURCES" "$PROMPTED_VERSION_KEY" "cleared so the automatic prompt appears"
require_old "$SOURCES" 'hasCompletedOnboarding' "the automatic check runs only after onboarding"
require_current "$HELPER_SOURCE" 'installed update at ' "logged by the helper after a healthy launch"
require_current "$HELPER_SOURCE" 'update failed: ' "logged by the helper on failure"
require_current "$HELPER_SOURCE" "\"$BUNDLE_IDENTIFIER\"" "the helper accepts only the release identifier"
require_current "$SOURCES/UpdateRelaunch.swift" 'launch: pid=' "the new app's launch identity line"
require_current "$SOURCES/UpdateRelaunch.swift" 'update relaunch: spawned as a child of helper' "self-relaunch after an old helper"
require_current "$SOURCES/UpdateRelaunch.swift" 'update relaunch: new instance pid=' "self-relaunch completion"
require_current "$SOURCES/UpdateLaunchHealth.swift" '--whispr-update-health-file' "health signal the helper waits for"
require_current "$SOURCES/AppUpdateManager.swift" 'update: verified version' "logged before handing over"
require_current "$SOURCES/AppUpdateManager.swift" '#if DEBUG' "the feed override must be compiled out of release builds"
require_current "WhisprStream/build.sh" '--build-system native' "build.sh must use the native build system on this toolchain"

# Which helper swaps the bundle, and therefore which relaunch path to expect.
OLD_HAS_LAUNCH_LINE=false
if old_source_has "$SOURCES/UpdateRelaunch.swift" 'launch: pid='; then
    OLD_HAS_LAUNCH_LINE=true
fi
if old_source_has "$SOURCES/AppUpdateManager.swift" 'installerHelperSource'; then
    HELPER_FROM=replacement
    current_source_has "$HELPER_SOURCE" 'openApplication' && HELPER_USES_LS=true || HELPER_USES_LS=false
else
    HELPER_FROM=old
    old_source_has "$HELPER_SOURCE" 'openApplication' && HELPER_USES_LS=true || HELPER_USES_LS=false
fi
EXPECT_CHILD_RELAUNCH=true
[ "$HELPER_USES_LS" = false ] || EXPECT_CHILD_RELAUNCH=false
# When the old app runs the new helper, the new helper must still accept the
# exact arguments the old app passes; otherwise every installed copy of the
# old version would fail to update.
if [ "$HELPER_FROM" = replacement ]; then
    HELPER_FLAGS="$(grep -o 'parsed\["--[a-z-]*"\]' "$REPOSITORY_ROOT/$HELPER_SOURCE" \
        | sed 's/parsed\["\(.*\)"\]/\1/' | sort -u)"
    HELPER_ARGC="$(sed -n 's/.*values\.count == \([0-9][0-9]*\).*/\1/p' "$REPOSITORY_ROOT/$HELPER_SOURCE" | sed -n '1p')"
    OLD_FLAGS="$(git -C "$REPOSITORY_ROOT" show "$OLD_TAG:$SOURCES/AppUpdateManager.swift" \
        | grep -o '^ *"--[a-z-]*",' | sed 's/^ *"\(.*\)",/\1/' | sort -u)"
    [ -n "$HELPER_FLAGS" ] && [ -n "$HELPER_ARGC" ] \
        || fail "could not read the helper's argument contract from $HELPER_SOURCE"
    [ "$HELPER_FLAGS" = "$OLD_FLAGS" ] \
        || fail "the current helper expects flags [$(echo $HELPER_FLAGS)] but $OLD_TAG passes [$(echo $OLD_FLAGS)]"
    [ "$HELPER_ARGC" = "$(( $(printf '%s\n' "$OLD_FLAGS" | wc -l) * 2 + 1 ))" ] \
        || fail "the current helper expects $HELPER_ARGC arguments; $OLD_TAG passes $(printf '%s\n' "$OLD_FLAGS" | wc -l | tr -d ' ') flag pairs"
fi
describe_path() {
    if [ "$HELPER_FROM" = replacement ]; then
        printf 'the %s app runs the helper shipped in the replacement' "$OLD_TAG"
    else
        printf 'the %s app runs its own helper' "$OLD_TAG"
    fi
    if [ "$EXPECT_CHILD_RELAUNCH" = true ]; then
        printf ', which spawns the new app as its child; the new app must relaunch itself'
    else
        printf ', which launches the new app through LaunchServices; no self-relaunch'
    fi
}

if [ "$CHECK_ONLY" = true ]; then
    if ! security find-identity -p codesigning 2>/dev/null | grep "\"$IDENTITY\"" >/dev/null; then
        note "signing identity \"$IDENTITY\" is not in the Keychain; builds will fail"
    fi
    echo "Static checks passed for $OLD_TAG -> $EXPECTED_VERSION build $EXPECTED_BUILD:"
    echo "  $(describe_path)."
    exit 0
fi

# ---------------------------------------------------------------------------
# Preconditions for building and running.

security find-identity -p codesigning 2>/dev/null | grep "\"$IDENTITY\"" >/dev/null \
    || fail "signing identity \"$IDENTITY\" is not in the Keychain; see WhisprStream/make-signing-cert.md"
if [ -n "${WHISPR_REPLACEMENT_APP:-}" ]; then
    [ -d "$WHISPR_REPLACEMENT_APP/Contents/MacOS" ] \
        || fail "WHISPR_REPLACEMENT_APP is not an app bundle: $WHISPR_REPLACEMENT_APP"
fi
if [ ! -x "$PYTHON" ]; then
    PYTHON="$(command -v python3)"
fi

other_instances() {
    pgrep -x WhisprStream 2>/dev/null | while IFS= read -r pid; do
        printf '%s %s\n' "$pid" "$(ps -p "$pid" -ww -o comm= 2>/dev/null)"
    done
}
if [ "$PREPARE_ONLY" = false ]; then
    RUNNING_BEFORE="$(other_instances)"
    [ -z "$RUNNING_BEFORE" ] || fail "quit every running WhisprStream instance first; running now:
$RUNNING_BEFORE
(a second instance would share the trigger key, microphone, Application Support, and log)"
    ! pgrep -x WhisprStreamUpdateInstaller >/dev/null 2>&1 \
        || fail "an update helper is still running; wait for it to finish"
fi

# The launched app and its helper create their scratch directories in the
# user's temporary directory; a leftover there after the run is a bug.
APP_TEMP_DIRS="$(printf '%s\n' "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)" "${TMPDIR:-/tmp}" \
    | sed 's:/*$::' | awk 'NF && !seen[$0]++')"

list_app_temp_roots() {
    local directory
    printf '%s\n' "$APP_TEMP_DIRS" | while IFS= read -r directory; do
        [ -d "$directory" ] || continue
        find "$directory" -mindepth 1 -maxdepth 1 \
            \( -name 'WhisprStream-installer-*' -o -name 'WhisprStream-update-*' \) 2>/dev/null
    done | sort
}

TEST_ROOT="$(mktemp -d /tmp/whisprstream-update-from-release.XXXXXX)"
# LaunchServices and the kernel report the physical path, so use it everywhere.
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
OLD_SRC="$TEST_ROOT/old-src"
NEW_SRC="$TEST_ROOT/new-src"
INSTALL_ROOT="$TEST_ROOT/install"
TARGET="$INSTALL_ROOT/WhisprStream.app"
TARGET_EXECUTABLE="$TARGET/Contents/MacOS/WhisprStream"
REPLACEMENT="$TEST_ROOT/replacement/WhisprStream.app"
OLD_HELPER_COPY="$TEST_ROOT/old-helper"
FEED_ROOT="$TEST_ROOT/feed"
ARCHIVE="$FEED_ROOT/WhisprStream-macos-arm64.zip"
SIGNATURE="$FEED_ROOT/WhisprStream-macos-arm64.zip.ed25519"
CLICK_SCRIPT="$TEST_ROOT/click-update.applescript"
TEMP_ROOTS_BEFORE="$TEST_ROOT/app-temp-roots-before.txt"
DEFAULTS_BACKUP="$TEST_ROOT/user-defaults-backup.plist"
SERVER_PID=""
OLD_WORKTREE_ADDED=false
NEW_WORKTREE_ADDED=false
RESTORE_DEFAULTS=false
DOMAIN_EXISTED=false
PASSED=false
KEEP_TEST_ROOT=false
list_app_temp_roots >"$TEMP_ROOTS_BEFORE"

# Every process started from this run's temporary tree: the app, its speech
# sidecar (whose arguments name the bundle), and the feed server.
test_processes() {
    pgrep -f "$TEST_ROOT/" 2>/dev/null || true
}

# Running instances of the installed test copy, by executable path.
test_app_pids() {
    ps -axww -o pid=,comm= | awk -v exe="$TARGET_EXECUTABLE" '{
        pid = $1; sub(/^[ \t]*[0-9]+[ \t]+/, ""); if ($0 == exe) print pid
    }'
}

stop_test_processes() {
    local pid
    for pid in $(test_processes); do
        kill -TERM "$pid" 2>/dev/null || true
    done
    for _ in $(seq 1 50); do
        [ -z "$(test_processes)" ] && return 0
        sleep 0.1
    done
    for pid in $(test_processes); do
        kill -KILL "$pid" 2>/dev/null || true
    done
}

# Compare two exported preference plists exactly.
plists_equal() {
    python3 -I -c '
import plistlib, sys
with open(sys.argv[1], "rb") as a, open(sys.argv[2], "rb") as b:
    sys.exit(0 if plistlib.load(a) == plistlib.load(b) else 1)
' "$1" "$2"
}

# Put the release domain back exactly as exported before the run, then prove it.
restore_user_defaults() {
    local check="$TEST_ROOT/user-defaults-restored.plist"
    defaults delete "$BUNDLE_IDENTIFIER" >/dev/null 2>&1 || true
    if [ "$DOMAIN_EXISTED" = true ]; then
        defaults import "$BUNDLE_IDENTIFIER" "$DEFAULTS_BACKUP" || return 1
        defaults export "$BUNDLE_IDENTIFIER" "$check" || return 1
        plists_equal "$DEFAULTS_BACKUP" "$check" || return 1
    else
        defaults export "$BUNDLE_IDENTIFIER" "$check" || return 1
        [ "$(python3 -I -c 'import plistlib,sys; print(len(plistlib.load(open(sys.argv[1],"rb"))))' "$check")" = 0 ] \
            || return 1
    fi
}

remove_new_app_temp_roots() {
    local path
    list_app_temp_roots | comm -13 "$TEMP_ROOTS_BEFORE" - | while IFS= read -r path; do
        case "$path" in
            */WhisprStream-installer-*|*/WhisprStream-update-*) rm -rf -- "$path" ;;
        esac
    done
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    local keep_app=false
    if [ "$LEAVE_RUNNING" = true ] && [ "$PASSED" = true ]; then
        keep_app=true
        KEEP_TEST_ROOT=true
    fi
    if [ "$keep_app" = false ]; then
        stop_test_processes
    fi
    if [ "$RESTORE_DEFAULTS" = true ]; then
        if restore_user_defaults; then
            echo "Restored the $BUNDLE_IDENTIFIER preferences to their exact pre-run export."
        else
            KEEP_TEST_ROOT=true
            echo "error: could not verify the restored $BUNDLE_IDENTIFIER preferences." >&2
            echo "       The pre-run export is kept at $DEFAULTS_BACKUP; restore it with:" >&2
            echo "       defaults delete $BUNDLE_IDENTIFIER; defaults import $BUNDLE_IDENTIFIER '$DEFAULTS_BACKUP'" >&2
            [ "$status" -ne 0 ] || status=1
        fi
    fi
    if [ "$OLD_WORKTREE_ADDED" = true ]; then
        git -C "$REPOSITORY_ROOT" worktree remove --force "$OLD_SRC" >/dev/null 2>&1 || true
    fi
    if [ "$NEW_WORKTREE_ADDED" = true ]; then
        git -C "$REPOSITORY_ROOT" worktree remove --force "$NEW_SRC" >/dev/null 2>&1 || true
    fi
    if [ "$OLD_WORKTREE_ADDED" = true ] || [ "$NEW_WORKTREE_ADDED" = true ]; then
        git -C "$REPOSITORY_ROOT" worktree prune >/dev/null 2>&1 || true
    fi
    if [ -f "$TEMP_ROOTS_BEFORE" ]; then
        remove_new_app_temp_roots
    fi
    if [ "$KEEP_TEST_ROOT" = false ]; then
        case "$TEST_ROOT" in
            /private/tmp/whisprstream-update-from-release.*|/tmp/whisprstream-update-from-release.*)
                rm -rf -- "$TEST_ROOT"
                ;;
        esac
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM

# Run a long step with its output in a log; show the tail only on failure.
run_logged() {
    local name="$1"
    shift
    local log="$TEST_ROOT/$name.log"
    if ! "$@" >"$log" 2>&1; then
        echo "error: $name failed; last lines of its log:" >&2
        tail -n 40 "$log" >&2
        exit 1
    fi
}

bundle_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}

set_bundle_value() {
    local plist="$1/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :$2 $3" "$plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :$2 string $3" "$plist"
}

log_since_launch() {
    tail -n +"$((LOG_LINES_BEFORE + 1))" "$LOG"
}

physical_path() {
    (cd "$1" 2>/dev/null && pwd -P)
}

hub_cache_dir() {
    if [ -n "${HF_HUB_CACHE:-}" ]; then
        printf '%s\n' "${HF_HUB_CACHE/#\~/$HOME}"
    elif [ -n "${HF_HOME:-}" ]; then
        printf '%s/hub\n' "${HF_HOME/#\~/$HOME}"
    else
        printf '%s/.cache/huggingface/hub\n' "$HOME"
    fi
}

# A path -> (kind, size, mtime) manifest of a tree, without following links.
write_manifest() {
    python3 -I -c '
import json, os, stat, sys
root, output = sys.argv[1:]
entries = {}
if os.path.isdir(root):
    for directory, names, files in os.walk(root, followlinks=False):
        for name in names + files:
            path = os.path.join(directory, name)
            info = os.lstat(path)
            kind = "L" if stat.S_ISLNK(info.st_mode) else ("D" if stat.S_ISDIR(info.st_mode) else "F")
            entries[os.path.relpath(path, root)] = [kind, info.st_size if kind == "F" else 0, info.st_mtime_ns]
with open(output, "w", encoding="utf-8") as handle:
    json.dump(entries, handle)
' "$1" "$2"
}

# Prints a summary; exits non-zero if anything present before is gone, or
# (with "strict") if any existing file changed size.
compare_manifests() {
    python3 -I -c '
import json, sys
before_path, after_path, label, mode = sys.argv[1:]
before = json.load(open(before_path, encoding="utf-8"))
after = json.load(open(after_path, encoding="utf-8"))
missing = sorted(set(before) - set(after))
added = sorted(set(after) - set(before))
resized = sorted(p for p in before if p in after and before[p][0] == "F" and before[p][1] != after[p][1])
touched = sorted(p for p in before if p in after and p not in resized and before[p][2] != after[p][2] and before[p][0] == "F")
for path in missing:
    print(f"      {label}: MISSING after the update: {path}")
for path in resized:
    print(f"      {label}: changed size: {path}")
for path in touched[:10]:
    print(f"      {label}: rewritten (same size): {path}")
for path in added[:10]:
    print(f"      {label}: added: {path}")
print(f"      {label}: {len(before)} entries before, {len(missing)} missing, {len(resized)} resized, "
      f"{len(touched)} rewritten, {len(added)} added")
bad = bool(missing) or (mode == "strict" and bool(resized))
sys.exit(1 if bad else 0)
' "$1" "$2" "$3" "$4"
}

runtime_digest() {
    python3 -I "$SCRIPT_DIR/runtime-content-sha256.py" "$SUPPORT_DIR/Runtime" 2>/dev/null
}

echo "Old release: $OLD_TAG; test root: $TEST_ROOT"
echo "Expected path: $(describe_path)."

echo "[1/7] Building $OLD_TAG: its build.sh bundle plus its debug app and helper"
git -C "$REPOSITORY_ROOT" worktree prune >/dev/null 2>&1 || true
run_logged old-worktree git -C "$REPOSITORY_ROOT" worktree add --detach "$OLD_SRC" "$OLD_TAG"
OLD_WORKTREE_ADDED=true
# The loopback feed override and the update-key override exist only in debug
# executables (#if DEBUG), so the installed copy gets the old tag's debug app
# and debug helper. build.sh uses the native build system because the default
# one links SDK 14 on this toolchain; the debug build does the same.
run_logged old-debug-build swift build --build-system native --package-path "$OLD_SRC/WhisprStream"
OLD_DEBUG="$OLD_SRC/WhisprStream/.build/debug"
[ -x "$OLD_DEBUG/WhisprStream" ] && [ -x "$OLD_DEBUG/WhisprStreamUpdateInstaller" ] \
    || fail "SwiftPM did not produce the $OLD_TAG debug app and helper"
mkdir -p "$INSTALL_ROOT"
run_logged old-bundle-build env -u BUILD_NUMBER -u BUNDLE_IDENTIFIER -u SIGNING_IDENTITY \
    -u RUNTIME_URL -u RUNTIME_SHA256 -u RUNTIME_CONTENT_SHA256 -u RUNTIME_VERSION \
    -u RUNTIME_ARCHIVE_BYTES -u RUNTIME_INSTALLED_BYTES -u UPDATE_PUBLIC_KEY -u UPDATE_REPOSITORY \
    RELEASE=0 VERSION="$OLD_VERSION" APP="$TARGET" PYTHON="$PYTHON" ENABLE_OPTIONAL_MODELS=0 \
    "$OLD_SRC/WhisprStream/build.sh"
cp "$OLD_DEBUG/WhisprStream" "$TARGET_EXECUTABLE"
cp "$OLD_DEBUG/WhisprStreamUpdateInstaller" "$TARGET/Contents/Helpers/WhisprStreamUpdateInstaller"
grep -a -q WHISPR_UPDATE_FEED_URL "$TARGET_EXECUTABLE" \
    || fail "the $OLD_TAG debug app does not contain the loopback feed override"

echo "[2/7] Preparing the replacement from the current tree (RELEASE=1)"
mkdir -p "$(dirname "$REPLACEMENT")"
if [ -n "${WHISPR_REPLACEMENT_APP:-}" ]; then
    ditto "$WHISPR_REPLACEMENT_APP" "$REPLACEMENT"
    echo "      using prebuilt replacement $WHISPR_REPLACEMENT_APP"
else
    if [ -n "$(git -C "$REPOSITORY_ROOT" status --porcelain -- WhisprStream/Sources WhisprStream/build.sh \
        WhisprStream/Package.swift WhisprStream/Resources asr_engine.py 2>/dev/null)" ]; then
        note "uncommitted app changes are not in the replacement; it is built from HEAD"
    fi
    run_logged new-worktree git -C "$REPOSITORY_ROOT" worktree add --detach "$NEW_SRC" HEAD
    NEW_WORKTREE_ADDED=true
    # The exact release command from RELEASING.md section 2, with its runtime
    # pins read from there; VERSION and BUILD_NUMBER come from build.sh.
    RELEASE_ENV=()
    for name in $RUNTIME_PIN_NAMES; do
        RELEASE_ENV+=("$name=$(releasing_value "$name" "$NEW_SRC/RELEASING.md")")
    done
    run_logged new-release-build env -u VERSION -u BUILD_NUMBER -u UPDATE_PUBLIC_KEY -u UPDATE_REPOSITORY \
        RELEASE=1 ENABLE_OPTIONAL_MODELS=0 \
        BUNDLE_IDENTIFIER="$BUNDLE_IDENTIFIER" SIGNING_IDENTITY="$IDENTITY" APP="$REPLACEMENT" \
        "${RELEASE_ENV[@]}" "$NEW_SRC/WhisprStream/build.sh"
fi
# A genuine release executable has the developer seams compiled out and the
# self-relaunch compiled in; a hybrid would fail later with less to go on.
! grep -a -q WHISPR_UPDATE_FEED_URL "$REPLACEMENT/Contents/MacOS/WhisprStream" \
    || fail "the replacement still contains the debug feed override; it is not a RELEASE=1 build"
grep -a -q 'update relaunch: spawned as a child of helper' "$REPLACEMENT/Contents/MacOS/WhisprStream" \
    || fail "the replacement does not contain the update self-relaunch (UpdateRelaunch.swift)"
[ "$(bundle_value "$REPLACEMENT" CFBundleIdentifier)" = "$BUNDLE_IDENTIFIER" ] \
    || fail "the replacement is not a $BUNDLE_IDENTIFIER build"
NEW_VERSION="$(bundle_value "$REPLACEMENT" CFBundleShortVersionString)"
NEW_BUILD="$(bundle_value "$REPLACEMENT" CFBundleVersion)"
[ "$NEW_VERSION" = "$EXPECTED_VERSION" ] && [ "$NEW_BUILD" = "$EXPECTED_BUILD" ] \
    || fail "the replacement is $NEW_VERSION build $NEW_BUILD, expected $EXPECTED_VERSION build $EXPECTED_BUILD"
NEW_RUNTIME_CONTENT_SHA256="$(bundle_value "$REPLACEMENT" WhisprRuntimeContentSHA256)"
# When the old app runs the replacement's helper, confirm that helper really
# launches through LaunchServices (the source was checked above).
if [ "$HELPER_FROM" = replacement ]; then
    if grep -a -q "$LS_SELECTOR" "$REPLACEMENT/Contents/Helpers/WhisprStreamUpdateInstaller"; then
        [ "$EXPECT_CHILD_RELAUNCH" = false ] \
            || fail "the replacement helper uses LaunchServices but its source does not"
    else
        [ "$EXPECT_CHILD_RELAUNCH" = true ] \
            || fail "the replacement helper does not launch through LaunchServices"
    fi
fi
echo "      replacement version $NEW_VERSION build $NEW_BUILD"

echo "[3/7] Configuring both bundles and signing them with \"$IDENTITY\""
KEY_LINES="$(swift -e '
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
')"
PRIVATE_KEY="$(printf '%s\n' "$KEY_LINES" | sed -n '1p')"
PUBLIC_KEY="$(printf '%s\n' "$KEY_LINES" | sed -n '2p')"
[ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] \
    || fail "could not generate an ephemeral update-signing key"

# Sign the way build.sh does: the helper explicitly, then the app with its
# entitlements file, plus the hardened-runtime options for the release build.
sign_bundle() {
    local app="$1"
    local entitlements="$2"
    local hardened="$3"
    local helper="$app/Contents/Helpers/WhisprStreamUpdateInstaller"
    if [ "$hardened" = true ]; then
        codesign --force --options runtime,library --sign "$IDENTITY" "$helper" || return 1
        codesign --force --options runtime,library --sign "$IDENTITY" \
            --entitlements "$entitlements" "$app" || return 1
    else
        codesign --force --sign "$IDENTITY" "$helper" || return 1
        codesign --force --sign "$IDENTITY" --entitlements "$entitlements" "$app" || return 1
    fi
    codesign --verify --strict --deep "$app" || return 1
    bash "$SCRIPT_DIR/validate-microphone-permission.sh" "$app" || return 1
    if [ "$hardened" = true ]; then
        local executable details
        for executable in "$app" "$helper"; do
            details="$(codesign -dv --verbose=4 "$executable" 2>&1)"
            printf '%s\n' "$details" | grep 'flags=.*runtime' >/dev/null \
                && printf '%s\n' "$details" | grep 'flags=.*library-validation' >/dev/null || {
                echo "error: lost hardened runtime or library validation: $executable" >&2
                return 1
            }
        done
    fi
}

# The old copy is a local build under the release identifier, so make it look
# like the public release of its tag: that tag's runtime pins (falling back to
# the replacement's), no development Python, and the ephemeral update key.
# It alone fetches the feed, so it alone gets NSAllowsLocalNetworking.
configure_old_app() {
    local app="$TARGET"
    local old_releasing="$TEST_ROOT/old-RELEASING.md"
    git -C "$REPOSITORY_ROOT" show "$OLD_TAG:RELEASING.md" >"$old_releasing" 2>/dev/null || : >"$old_releasing"
    set_bundle_value "$app" CFBundleIdentifier "$BUNDLE_IDENTIFIER"
    set_bundle_value "$app" CFBundleShortVersionString "$OLD_VERSION"
    local key name value
    for key in WhisprRuntimeURL:RUNTIME_URL WhisprRuntimeSHA256:RUNTIME_SHA256 \
        WhisprRuntimeContentSHA256:RUNTIME_CONTENT_SHA256 WhisprRuntimeVersion:RUNTIME_VERSION \
        WhisprRuntimeArchiveBytes:RUNTIME_ARCHIVE_BYTES WhisprRuntimeInstalledBytes:RUNTIME_INSTALLED_BYTES; do
        name="${key##*:}"
        key="${key%%:*}"
        value="$(releasing_value "$name" "$old_releasing")"
        [ -n "$value" ] || value="$(bundle_value "$REPLACEMENT" "$key")"
        set_bundle_value "$app" "$key" "$value"
    done
    /usr/libexec/PlistBuddy -c "Delete :WhisprDevelopmentPythonPath" "$app/Contents/Info.plist" >/dev/null 2>&1 || true
    set_bundle_value "$app" WhisprUpdatePublicKey "$PUBLIC_KEY"
    /usr/libexec/PlistBuddy -c "Delete :NSAppTransportSecurity" "$app/Contents/Info.plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" \
        "$app/Contents/Info.plist"
    local entitlements="$OLD_SRC/WhisprStream/WhisprStream.entitlements"
    [ -f "$entitlements" ] || entitlements="$SCRIPT_DIR/WhisprStream.entitlements"
    # The stable identity keeps the existing microphone and Accessibility
    # grants; ad-hoc signing would make TCC treat this copy as a new app.
    run_logged sign-old sign_bundle "$app" "$entitlements" false
}

# The candidate changes in one value only: the update key the old copy trusts
# (the production key stays in the Keychain). That forces a re-signature with
# the same identity, entitlements, and hardened-runtime options.
configure_replacement() {
    set_bundle_value "$REPLACEMENT" WhisprUpdatePublicKey "$PUBLIC_KEY"
    run_logged sign-new sign_bundle "$REPLACEMENT" "$SCRIPT_DIR/WhisprStream.entitlements" true
}

configure_old_app
configure_replacement
cp "$TARGET/Contents/Helpers/WhisprStreamUpdateInstaller" "$OLD_HELPER_COPY"
[ "$(bundle_value "$TARGET" CFBundleIdentifier)" = "$BUNDLE_IDENTIFIER" ] \
    && [ "$(bundle_value "$TARGET" CFBundleShortVersionString)" = "$OLD_VERSION" ] \
    || fail "the old copy was not configured as $BUNDLE_IDENTIFIER $OLD_VERSION"

echo "[4/7] Serving the signed replacement from a loopback GitHub-shaped feed"
mkdir -p "$FEED_ROOT"
ditto -c -k --sequesterRsrc --keepParent "$REPLACEMENT" "$ARCHIVE"
swift -e '
import CryptoKit
import Foundation
let privateData = Data(base64Encoded: CommandLine.arguments[1])!
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateData)
let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
print(try key.signature(for: archive).base64EncodedString())
' "$PRIVATE_KEY" "$ARCHIVE" >"$SIGNATURE"
swift -e '
import CryptoKit
import Darwin
import Foundation
let publicData = Data(base64Encoded: CommandLine.arguments[1])!
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
let encoded = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
let signature = Data(base64Encoded: encoded)!
exit(key.isValidSignature(signature, for: archive) ? 0 : 1)
' "$PUBLIC_KEY" "$ARCHIVE" "$SIGNATURE" >/dev/null 2>&1 \
    || fail "the generated update signature does not verify"

PORT="$(python3 -I -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
')"
BASE_URL="http://127.0.0.1:$PORT"
python3 -I -c '
import json, sys
output, base_url, tag, archive_bytes, signature_bytes = sys.argv[1:]
payload = {
    "tag_name": tag,
    "html_url": "https://github.com/Leo6Leo/whispr-stream/releases/tag/" + tag,
    "draft": False,
    "prerelease": False,
    "assets": [
        {
            "name": "WhisprStream-macos-arm64.zip",
            "browser_download_url": base_url + "/WhisprStream-macos-arm64.zip",
            "size": int(archive_bytes),
        },
        {
            "name": "WhisprStream-macos-arm64.zip.ed25519",
            "browser_download_url": base_url + "/WhisprStream-macos-arm64.zip.ed25519",
            "size": int(signature_bytes),
        },
    ],
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
' "$FEED_ROOT/latest.json" "$BASE_URL" "v$NEW_VERSION" "$(stat -f %z "$ARCHIVE")" "$(stat -f %z "$SIGNATURE")"
python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$FEED_ROOT" \
    >"$TEST_ROOT/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
    curl -fsS "$BASE_URL/latest.json" >/dev/null 2>&1 && break
    sleep 0.1
done
curl -fsS "$BASE_URL/latest.json" >/dev/null 2>&1 || fail "the loopback feed server did not start"

# Read-only readiness of this Mac for the live run.
DOMAIN_ONBOARDED="$(defaults read "$BUNDLE_IDENTIFIER" hasCompletedOnboarding 2>/dev/null || true)"
RUNTIME_DIGEST_BEFORE="$(runtime_digest || true)"
MODEL_ID="$(defaults read "$BUNDLE_IDENTIFIER" model 2>/dev/null || true)"
MODEL_DIR=""
if [ -n "$MODEL_ID" ]; then
    MODEL_DIR="$(hub_cache_dir)/models--${MODEL_ID//\//--}"
fi
readiness_problems() {
    [ "$DOMAIN_ONBOARDED" = 1 ] \
        || echo "$BUNDLE_IDENTIFIER has not completed onboarding (the automatic update check runs only after it)"
    [ "$RUNTIME_DIGEST_BEFORE" = "$NEW_RUNTIME_CONTENT_SHA256" ] \
        || echo "the public speech runtime in $SUPPORT_DIR/Runtime is missing or does not match $NEW_RUNTIME_CONTENT_SHA256"
    [ -n "$MODEL_DIR" ] && [ -d "$MODEL_DIR" ] \
        || echo "the selected model (${MODEL_ID:-none}) is not in $(hub_cache_dir)"
}

if [ "$PREPARE_ONLY" = true ]; then
    curl -fsS "$BASE_URL/WhisprStream-macos-arm64.zip" -o "$TEST_ROOT/downloaded.zip"
    curl -fsS "$BASE_URL/WhisprStream-macos-arm64.zip.ed25519" -o "$TEST_ROOT/downloaded.zip.ed25519"
    cmp "$ARCHIVE" "$TEST_ROOT/downloaded.zip"
    cmp "$SIGNATURE" "$TEST_ROOT/downloaded.zip.ed25519"
    echo
    echo "Preparation passed: $OLD_TAG and the $NEW_VERSION (build $NEW_BUILD) replacement are built,"
    echo "signed, and served. Nothing was launched; no preferences, /Applications, or the"
    echo "repository app were touched."
    PROBLEMS="$(readiness_problems)"
    RUNNING_NOW="$(other_instances)"
    if [ -n "$RUNNING_NOW" ]; then
        PROBLEMS="${PROBLEMS:+$PROBLEMS
}WhisprStream is running and must be quit first: $(printf '%s' "$RUNNING_NOW" | tr '\n' ';')"
    fi
    if [ -n "$PROBLEMS" ]; then
        echo "Live-run readiness: NOT READY"
        printf '%s\n' "$PROBLEMS" | sed 's/^/  - /'
    else
        echo "Live-run readiness: ready (onboarded, runtime $RUNTIME_DIGEST_BEFORE, model $MODEL_ID)"
    fi
    exit 0
fi

PROBLEMS="$(readiness_problems)"
[ -z "$PROBLEMS" ] || fail "this Mac is not ready for the live run:
$PROBLEMS"

echo "[5/7] Recording the user's state before the update"
# Export the release domain so it can be restored exactly, then make the run
# deterministic: the automatic prompt is shown once per version, and a canary
# key proves that arbitrary preferences survive.
if defaults read "$BUNDLE_IDENTIFIER" >/dev/null 2>&1; then
    DOMAIN_EXISTED=true
fi
defaults export "$BUNDLE_IDENTIFIER" "$DEFAULTS_BACKUP"
RESTORE_DEFAULTS=true
CANARY="$(uuidgen)"
defaults delete "$BUNDLE_IDENTIFIER" "$PROMPTED_VERSION_KEY" >/dev/null 2>&1 || true
defaults write "$BUNDLE_IDENTIFIER" "$CANARY_KEY" -string "$CANARY"
defaults export "$BUNDLE_IDENTIFIER" "$TEST_ROOT/defaults-seeded.plist"
write_manifest "$SUPPORT_DIR" "$TEST_ROOT/support-before.json"
write_manifest "$MODEL_DIR" "$TEST_ROOT/model-before.json"
echo "      exported $BUNDLE_IDENTIFIER, cleared $PROMPTED_VERSION_KEY, set $CANARY_KEY"
echo "      runtime digest $RUNTIME_DIGEST_BEFORE; model cache $MODEL_DIR"

echo "[6/7] Launching the installed $OLD_VERSION copy through LaunchServices and updating it"
# Clicks the update button in any window of the launched copy. With a second
# argument of "true" it also opens the status-bar menu and chooses its
# "Update WhisprStream to …" item, which shows the same prompt when the
# automatic one did not appear. Otherwise it reports the window names seen.
cat >"$CLICK_SCRIPT" <<'EOF'
on run argv
    set targetPID to (item 1 of argv) as integer
    set wantMenu to (item 2 of argv) is "true"
    tell application "System Events"
        set matching to (every process whose unix id is targetPID)
        if (count of matching) is 0 then return "no-process"
        set theProcess to item 1 of matching
        set windowNames to {}
        repeat with theWindow in windows of theProcess
            try
                set end of windowNames to (name of theWindow as text)
            on error
                set end of windowNames to "untitled"
            end try
            set elements to entire contents of theWindow
            repeat with element in elements
                try
                    if role of element is "AXButton" then
                        set elementName to name of element
                        if elementName is "Update & Relaunch" or elementName is "Install and Relaunch" then
                            click element
                            return "clicked " & elementName
                        end if
                    end if
                end try
            end repeat
        end repeat
        if wantMenu then
            try
                set statusItem to menu bar item 1 of menu bar 2 of theProcess
                click statusItem
                delay 0.5
                set updateItems to (every menu item of menu 1 of statusItem whose name starts with "Update WhisprStream to")
                if (count of updateItems) > 0 then
                    click item 1 of updateItems
                    return "opened-prompt"
                end if
                key code 53
                return "no-update-item"
            on error errorMessage
                try
                    key code 53
                end try
                return "menu-error " & errorMessage
            end try
        end if
        set AppleScript's text item delimiters to "; "
        return "no-button|" & (windowNames as text)
    end tell
end run
EOF

# Run a command with a wall-clock limit so a hung osascript cannot stall the
# wait loop (perl ships with macOS; without it the command runs unlimited).
with_timeout() {
    local seconds="$1"
    shift
    if command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
    else
        "$@"
    fi
}

# Which helper binary the old app copied into its installer directory.
HELPER_SEEN=""
observe_helper() {
    local root helper
    for root in $(list_app_temp_roots | comm -13 "$TEMP_ROOTS_BEFORE" -); do
        helper="$root/WhisprStreamUpdateInstaller"
        [ -f "$helper" ] || continue
        if cmp -s "$helper" "$REPLACEMENT/Contents/Helpers/WhisprStreamUpdateInstaller"; then
            HELPER_SEEN=replacement
        elif cmp -s "$helper" "$OLD_HELPER_COPY"; then
            HELPER_SEEN=old
        fi
    done
}

[ -f "$LOG" ] || : >"$LOG"
LOG_LINES_BEFORE="$(wc -l <"$LOG" | tr -d ' ')"
# A real user launches the app from Finder, which goes through LaunchServices.
# Only the debug overrides are added, to this one launch's environment.
open --env WHISPR_UPDATE_REPOSITORY=Leo6Leo/whispr-stream \
    --env "WHISPR_UPDATE_PUBLIC_KEY=$PUBLIC_KEY" \
    --env "WHISPR_UPDATE_FEED_URL=$BASE_URL/latest.json" \
    "$TARGET"
OLD_PID=""
for _ in $(seq 1 100); do
    OLD_PID="$(test_app_pids | sed -n '1p')"
    [ -z "$OLD_PID" ] || break
    sleep 0.1
done
[ -n "$OLD_PID" ] || fail "the installed copy did not start (no process runs $TARGET_EXECUTABLE)"
STRAY="$(pgrep -x WhisprStream | grep -v -x "$OLD_PID" || true)"
[ -z "$STRAY" ] || fail "another WhisprStream process appeared: $STRAY"
echo "      installed $OLD_VERSION copy running as pid $OLD_PID"
if [ "$MANUAL" = true ]; then
    echo "      choose Update & Relaunch in the prompt (or Settings -> About -> Install and Relaunch)"
else
    echo "      clicking Update & Relaunch through System Events when the prompt appears;"
    echo "      if that is not permitted here, choose it yourself"
fi
echo "      waiting up to $TIMEOUT s for the update"
if [ "$EXPECT_CHILD_RELAUNCH" = true ]; then
    DONE_PATTERN='update relaunch: new instance pid='
else
    DONE_PATTERN='[whispr updater] installed update at '
fi

LAUNCHED_AT="$(date +%s)"
DEADLINE=$(( LAUNCHED_AT + TIMEOUT ))
CLICKED=false
INSTALL_REPORTED=false
LAST_WINDOWS=""
MENU_NOTE_SHOWN=false
FEED_REPORTED=false
OUTCOME=timeout
DEFAULTS_BASELINE="$TEST_ROOT/defaults-seeded.plist"
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    observe_helper
    if log_since_launch | grep -F -- "$DONE_PATTERN" >/dev/null; then
        OUTCOME=done
        break
    fi
    if log_since_launch | grep -E "$FAILURE_PATTERN" >/dev/null; then
        OUTCOME=failed
        break
    fi
    if [ "$FEED_REPORTED" = false ] && grep 'GET /latest.json' "$TEST_ROOT/server.log" >/dev/null 2>&1; then
        echo "      $(date +%T) the $OLD_TAG copy fetched the loopback feed"
        FEED_REPORTED=true
        # The old app has finished launching (including its cross-build
        # vocabulary merge); this is what the update must preserve.
        if defaults export "$BUNDLE_IDENTIFIER" "$TEST_ROOT/defaults-old-running.plist" 2>/dev/null; then
            DEFAULTS_BASELINE="$TEST_ROOT/defaults-old-running.plist"
        fi
    fi
    if [ "$INSTALL_REPORTED" = false ] \
        && [ "$(bundle_value "$TARGET" CFBundleShortVersionString 2>/dev/null || true)" = "$NEW_VERSION" ]; then
        echo "      $(date +%T) the helper swapped in version $NEW_VERSION"
        INSTALL_REPORTED=true
    fi
    if [ "$MANUAL" = false ] && [ "$CLICKED" = false ]; then
        # The automatic prompt appears a few seconds after launch. If it has
        # not, open the status-bar menu every few seconds and choose its
        # "Update WhisprStream to …" item, which shows the same prompt.
        ELAPSED=$(( $(date +%s) - LAUNCHED_AT ))
        USE_MENU=false
        if [ "$ELAPSED" -ge 10 ] && [ $(( ELAPSED % 5 )) -eq 0 ]; then
            USE_MENU=true
        fi
        CLICK_RESULT="$(with_timeout 30 osascript "$CLICK_SCRIPT" "$OLD_PID" "$USE_MENU" 2>&1 || true)"
        case "$CLICK_RESULT" in
            clicked*)
                echo "      $(date +%T) ${CLICK_RESULT#clicked }: clicked"
                CLICKED=true
                ;;
            opened-prompt)
                echo "      $(date +%T) opened the update prompt from the status-bar menu"
                ;;
            ""|no-process|no-update-item) ;;
            no-button*)
                WINDOWS="${CLICK_RESULT#no-button|}"
                if [ "$WINDOWS" != "$LAST_WINDOWS" ]; then
                    echo "      $(date +%T) windows: ${WINDOWS:-none}"
                    LAST_WINDOWS="$WINDOWS"
                fi
                ;;
            menu-error*)
                if [ "$MENU_NOTE_SHOWN" = false ]; then
                    note "the status-bar menu could not be used (${CLICK_RESULT#menu-error }); still watching the windows"
                    MENU_NOTE_SHOWN=true
                fi
                ;;
            *)
                note "System Events cannot click for this terminal ($CLICK_RESULT);"
                echo "      choose Update & Relaunch yourself"
                MANUAL=true
                ;;
        esac
    fi
    sleep 0.5
done
if [ "$OUTCOME" != done ]; then
    echo "=== loopback feed requests ===" >&2
    grep -E 'GET ' "$TEST_ROOT/server.log" >&2 || echo "(the app never requested the feed)" >&2
    echo "=== WhisprStream.log since launch ===" >&2
    log_since_launch | grep -E 'launch:|update' >&2 || true
    case "$OUTCOME" in
        failed) fail "the update or the self-relaunch reported a failure" ;;
        *) fail "the update did not finish within $TIMEOUT s" ;;
    esac
fi

echo "[7/7] Checking the log, the processes, the bundle, and the user's data"
# Give the old process (and any self-relaunched child) time to exit, the old
# speech sidecar time to stop, and the helper time to clean up.
for _ in $(seq 1 150); do
    if [ "$(test_app_pids | wc -l | tr -d ' ')" = 1 ] \
        && ! pgrep -x WhisprStreamUpdateInstaller >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
# A moment more so the surviving instance has logged its launch and settled.
sleep 3

assert_logged() {
    log_since_launch | grep -F -- "$1" >/dev/null || {
        echo "=== WhisprStream.log since launch ===" >&2
        log_since_launch | grep -E 'launch:|update' >&2 || true
        fail "missing log line: $1"
    }
}

# The old copy was launched like a user launch: its own responsible process.
if [ "$OLD_HAS_LAUNCH_LINE" = true ]; then
    assert_logged "launch: pid=$OLD_PID parent=1 responsible=$OLD_PID"
fi
assert_logged "update: verified version $NEW_VERSION; terminating for replacement"
INSTALLED_PATH="$(log_since_launch | sed -n 's/^\[whispr updater\] installed update at \(.*\)$/\1/p' | sed -n '1p')"
[ -n "$INSTALLED_PATH" ] || assert_logged "[whispr updater] installed update at "
[ "$(physical_path "$INSTALLED_PATH")" = "$TARGET" ] \
    || fail "the helper installed the update somewhere else: $INSTALLED_PATH"
! log_since_launch | grep -E "$FAILURE_PATTERN" >/dev/null \
    || fail "the log reports an update failure"

RUNNING="$(test_app_pids | tr '\n' ' ' | sed 's/ $//')"
case "$RUNNING" in
    ""|*" "*) fail "expected exactly one process running $TARGET_EXECUTABLE; found: ${RUNNING:-none}" ;;
esac
NEW_PID="$RUNNING"
[ "$NEW_PID" != "$OLD_PID" ] || fail "the old process $OLD_PID is still the running instance"

if [ "$EXPECT_CHILD_RELAUNCH" = true ]; then
    HELPER_PID="$(log_since_launch \
        | sed -n 's/.*update relaunch: spawned as a child of helper \([0-9][0-9]*\);.*/\1/p' | sed -n '1p')"
    [ -n "$HELPER_PID" ] || assert_logged "update relaunch: spawned as a child of helper"
    RELAUNCH_PIDS="$(log_since_launch \
        | sed -n 's/.*update relaunch: new instance pid=\([0-9][0-9]*\); terminating pid=\([0-9][0-9]*\).*/\1 \2/p' \
        | sed -n '1p')"
    LOGGED_NEW_PID="${RELAUNCH_PIDS%% *}"
    CHILD_PID="${RELAUNCH_PIDS##* }"
    [ -n "$LOGGED_NEW_PID" ] && [ -n "$CHILD_PID" ] && [ "$LOGGED_NEW_PID" != "$CHILD_PID" ] \
        || fail "could not read the relaunch pids from the log"
    [ "$LOGGED_NEW_PID" = "$NEW_PID" ] \
        || fail "the log names pid $LOGGED_NEW_PID as the relaunched instance, but pid $NEW_PID is running"
    assert_logged "launch: pid=$CHILD_PID parent=$HELPER_PID responsible="
    PATH_SUMMARY="helper $HELPER_PID spawned pid $CHILD_PID, which relaunched itself as pid $NEW_PID"
else
    # LaunchServices launched the new app directly: no self-relaunch at all.
    ! log_since_launch | grep -F 'update relaunch:' >/dev/null || {
        log_since_launch | grep -F 'update relaunch:' >&2
        fail "the new app relaunched itself although the helper launched it through LaunchServices"
    }
    PATH_SUMMARY="the helper launched pid $NEW_PID through LaunchServices; no self-relaunch"
fi
# The surviving instance is its own responsible process (TCC charges it, not
# the exited old version), both by its own log line and by the process table.
assert_logged "launch: pid=$NEW_PID parent=1 responsible=$NEW_PID"
[ "$(ps -p "$NEW_PID" -o ppid= | tr -d ' ')" = 1 ] || fail "pid $NEW_PID is not a child of launchd"
echo "      $PATH_SUMMARY (parent 1, responsible for itself)"

if [ -n "$HELPER_SEEN" ]; then
    [ "$HELPER_SEEN" = "$HELPER_FROM" ] \
        || fail "the $HELPER_SEEN helper ran, but the $OLD_TAG app should have run the $HELPER_FROM one"
    echo "      observed the $HELPER_SEEN helper in the installer directory, as expected"
else
    note "the installer directory's helper was not observed (it lives a few seconds); not checked"
fi

# Exactly one WhisprStream process system-wide, and nothing left of the old one.
ALL_RUNNING="$(pgrep -x WhisprStream | tr '\n' ' ' | sed 's/ $//' || true)"
[ "$ALL_RUNNING" = "$NEW_PID" ] \
    || fail "expected exactly one WhisprStream process, pid $NEW_PID; found: ${ALL_RUNNING:-none}"
! pgrep -x WhisprStreamUpdateInstaller >/dev/null 2>&1 || fail "an update helper is still running"
ORPHANS=""
for _ in $(seq 1 100); do
    ORPHANS=""
    for pid in $(pgrep -f "$INSTALL_ROOT/" 2>/dev/null || true); do
        [ "$pid" != "$NEW_PID" ] || continue
        [ "$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')" = "$NEW_PID" ] && continue
        ps -p "$pid" >/dev/null 2>&1 || continue
        ORPHANS="$ORPHANS $pid"
    done
    [ -z "$ORPHANS" ] && break
    sleep 0.1
done
[ -z "$ORPHANS" ] \
    || fail "processes from the old instance outlived it: $(ps -p "$(printf '%s' "${ORPHANS# }" | tr ' ' ',')" -ww -o pid=,args= 2>/dev/null | tr '\n' ';')"

# The new version is what LaunchServices and the bundle report.
APP_INFO="$(lsappinfo info -app "$NEW_PID" 2>/dev/null || true)"
LS_BUNDLE_PATH="$(printf '%s\n' "$APP_INFO" | sed -n 's/.*bundle path="\(.*\)"$/\1/p' | sed -n '1p')"
LS_BUNDLE_ID="$(printf '%s\n' "$APP_INFO" | sed -n 's/.*bundleID="\([^"]*\)".*/\1/p' | sed -n '1p')"
LS_BUILD="$(printf '%s\n' "$APP_INFO" | sed -n 's/.* Version="\([^"]*\)".*/\1/p' | sed -n '1p')"
[ "$(physical_path "$LS_BUNDLE_PATH")" = "$TARGET" ] && [ "$LS_BUNDLE_ID" = "$BUNDLE_IDENTIFIER" ] \
    && [ "$LS_BUILD" = "$NEW_BUILD" ] \
    || fail "LaunchServices reports pid $NEW_PID as ${LS_BUNDLE_ID:-?} build ${LS_BUILD:-?} at ${LS_BUNDLE_PATH:-?}"
[ "$(bundle_value "$TARGET" CFBundleShortVersionString)" = "$NEW_VERSION" ] \
    && [ "$(bundle_value "$TARGET" CFBundleVersion)" = "$NEW_BUILD" ] \
    || fail "the installed app is not version $NEW_VERSION build $NEW_BUILD"
diff -rq "$REPLACEMENT" "$TARGET" >"$TEST_ROOT/bundle-diff.txt" 2>&1 \
    || fail "the installed bundle differs from the served replacement: $(head -n 5 "$TEST_ROOT/bundle-diff.txt")"
codesign --verify --strict --deep "$TARGET" || fail "the installed bundle's signature does not verify"
echo "      pid $NEW_PID is $BUNDLE_IDENTIFIER $NEW_VERSION build $NEW_BUILD, byte-identical to the served build"

# No staged, backup, or failed bundle beside the install; no scratch left.
LEFTOVER_BUNDLES="$(find "$INSTALL_ROOT" -mindepth 1 -maxdepth 1 -name '.WhisprStream.update-*')"
[ -z "$LEFTOVER_BUNDLES" ] || fail "leftover update bundles in the install directory: $LEFTOVER_BUNDLES"
LEFTOVER_ROOTS="$(list_app_temp_roots | comm -13 "$TEMP_ROOTS_BEFORE" - || true)"
[ -z "$LEFTOVER_ROOTS" ] || fail "leftover helper or download directories from this run: $LEFTOVER_ROOTS"

# The user's preferences: everything the old version had is still there and
# unchanged, apart from keys the system or the prompt itself writes.
defaults export "$BUNDLE_IDENTIFIER" "$TEST_ROOT/defaults-after.plist"
python3 -I -c '
import json, plistlib, sys
baseline_path, after_path, canary_key, canary, prompted_key = sys.argv[1:]
before = plistlib.load(open(baseline_path, "rb"))
after = plistlib.load(open(after_path, "rb"))
volatile_prefixes = ("NSStatusItem ", "NSWindow Frame ", "NSSplitView Subview Frames ", "NSToolbar Configuration ")
merged_lists = {"vocabularyEntries", "contextTerms"}
merged_json = {"voiceShortcuts.v1"}
problems = []
for key, value in sorted(before.items()):
    if key == prompted_key or key.startswith(volatile_prefixes):
        continue
    if key not in after:
        problems.append(f"{key} was removed")
    elif key in merged_lists and isinstance(value, list) and isinstance(after[key], list):
        lost = [entry for entry in value if entry not in after[key]]
        if lost:
            problems.append(f"{key} lost {lost!r}")
    elif key in merged_json and isinstance(value, bytes) and value != after[key]:
        try:
            old_items, new_items = json.loads(value), json.loads(after[key])
            lost = [item for item in old_items if item not in new_items]
        except (ValueError, TypeError):
            lost = ["(undecodable)"]
        if lost:
            problems.append(f"{key} lost {len(lost)} entries")
    elif after[key] != value:
        problems.append(f"{key} changed")
if after.get(canary_key) != canary:
    problems.append(f"the canary {canary_key} did not survive")
for problem in problems:
    print(f"      preferences: {problem}")
vocabulary = after.get("vocabularyEntries", after.get("contextTerms", []))
print(f"      preferences: {len(before)} keys compared, {len(problems)} problems, "
      f"{len(vocabulary)} vocabulary entries")
sys.exit(1 if problems else 0)
' "$DEFAULTS_BASELINE" "$TEST_ROOT/defaults-after.plist" "$CANARY_KEY" "$CANARY" "$PROMPTED_VERSION_KEY" \
    || fail "the update did not preserve the user's preferences"

# Application Support: nothing removed, and the speech runtime is byte-for-byte
# what it was, which is also exactly what the new version pins.
write_manifest "$SUPPORT_DIR" "$TEST_ROOT/support-after.json"
compare_manifests "$TEST_ROOT/support-before.json" "$TEST_ROOT/support-after.json" "Application Support" lenient \
    || fail "the update removed data from $SUPPORT_DIR"
RUNTIME_DIGEST_AFTER="$(runtime_digest || true)"
[ "$RUNTIME_DIGEST_AFTER" = "$RUNTIME_DIGEST_BEFORE" ] \
    || fail "the speech runtime changed during the update ($RUNTIME_DIGEST_BEFORE -> ${RUNTIME_DIGEST_AFTER:-unreadable})"
[ "$RUNTIME_DIGEST_AFTER" = "$NEW_RUNTIME_CONTENT_SHA256" ] \
    || fail "the installed runtime does not match the runtime $NEW_VERSION pins"
echo "      speech runtime unchanged ($RUNTIME_DIGEST_AFTER, the digest $NEW_VERSION pins)"
write_manifest "$MODEL_DIR" "$TEST_ROOT/model-after.json"
compare_manifests "$TEST_ROOT/model-before.json" "$TEST_ROOT/model-after.json" "model cache" strict \
    || fail "the update changed the model cache $MODEL_DIR"

PASSED=true
echo
echo "Update from $OLD_TAG to $NEW_VERSION build $NEW_BUILD passed: $(describe_path)."
echo "The surviving instance (pid $NEW_PID) is the only WhisprStream process and its own"
echo "responsible process; preferences, vocabulary, Application Support, the speech runtime,"
echo "and the model cache were preserved. /Applications and the repository app were not touched."
if [ "$LEAVE_RUNNING" = true ]; then
    echo
    echo "The updated app (pid $NEW_PID) is still running from $TARGET."
    echo "Dictate once to confirm the microphone works, then quit it and remove $TEST_ROOT."
fi
