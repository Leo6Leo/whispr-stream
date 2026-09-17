# WhisprStream release checklist

WhisprStream ships a small native app and a separately downloadable Apple-silicon speech engine. Public builds are ZIPs, are not notarized, and use a stable self-signed identity.

## 1. Select and validate the runtime

Use a relocatable standalone CPython 3.12 distribution. Do not use Homebrew Python or a venv.

Public app version `1.0.2` compiles optional models out and intentionally reuses the immutable `WhisprStream-runtime-1.0.0-arm64.zip` asset. Do not rebuild or replace that asset under its existing version or URL. The signed app also pins the complete extracted runtime tree, including the bytecode shipped in that immutable archive; installed runtime verification never deletes or rewrites files.

The current `build-runtime.sh` includes the experimental MLX Whisper adapter and is for a future runtime version only. Before enabling optional models publicly, resolve the deferred model-validation work, assign a new immutable runtime version (for example `1.1.0`), build it, and update every runtime value below.

## 2. Build the app

The app must embed an immutable tag-specific runtime URL, never `latest/download`:

The updater's Ed25519 private key lives only in the macOS login Keychain. Its
public key is checked in at `WhisprStream/update-public-key.txt` and embedded in
every build. Generate the key only once; subsequent invocations print the same
public key:

```bash
swift build -c release --package-path WhisprStream \
  --product WhisprStreamUpdateSigner
codesign --force --options runtime,library --sign "WhisprStream Self-Signed" \
  WhisprStream/.build/release/WhisprStreamUpdateSigner
WhisprStream/.build/release/WhisprStreamUpdateSigner generate
```

Always use the stably signed release tool for `generate`, `export`, and `sign`.
Its code identity is what allows macOS Keychain access to survive later tool
rebuilds; do not create the production key with an ad-hoc debug executable.

Back up the private key to encrypted offline storage, never to this repository:

```bash
WhisprStream/.build/release/WhisprStreamUpdateSigner export \
  /path/outside/the/repository/WhisprStream-update-private-key.txt
```

Losing both the Keychain item and its backup breaks the automatic-update chain
for installed versions. Do not rotate this key as part of a normal release.
The expected code-signing certificate SHA-1 is independently pinned in
`WhisprStream/release-signing-certificate-sha1.txt`. The release builder rejects
an update key, repository, or signing identity that differs from these reviewed
trust roots. Change a pin only as an explicit key-rotation procedure.

App version `1.0.2` intentionally reuses runtime version `1.0.0`; the runtime
version changes only when the standalone Python or dependency payload changes.

```bash
RELEASE=1 VERSION=1.0.2 BUILD_NUMBER=5 ENABLE_OPTIONAL_MODELS=0 \
BUNDLE_IDENTIFIER="com.leoleo.whisprstream" \
SIGNING_IDENTITY="WhisprStream Self-Signed" \
RUNTIME_VERSION=1.0.0 \
RUNTIME_URL="https://github.com/Leo6Leo/whispr-stream/releases/download/v1.0.0/WhisprStream-runtime-1.0.0-arm64.zip" \
RUNTIME_SHA256="b155e21c0bad58d9566430205d0226d7e9066f7b7b7886c7107a53e5a33e221f" \
RUNTIME_CONTENT_SHA256="747eba6e37c2997070ae995c0ca64c116b01071f4f086ccfecf27073a166e0f8" \
RUNTIME_ARCHIVE_BYTES="78119418" \
RUNTIME_INSTALLED_BYTES="248872960" \
WhisprStream/build.sh
```

`RELEASE=1` fails if optional models are enabled, if any runtime value is missing, malformed, zero, non-HTTPS, or if the bundle identifier is not `com.leoleo.whisprstream`. It also fails without a signing identity; it never silently falls back to ad-hoc signing. Release compilation remaps the repository root to `/src`, strips linker-generated `N_OSO` debug records, and both the builder and validator reject executables containing `/Users/` or `/home/` build-machine paths.
The same release identity is also applied to the update-signing utility so it
can reuse the protected Keychain item when the utility is rebuilt.

The main app is signed with `WhisprStream/WhisprStream.entitlements`, including
`com.apple.security.device.audio-input`. Hardened Runtime requires this even
without App Sandbox; `NSMicrophoneUsageDescription` alone is insufficient.
The builder and archive validator inspect the signed app for both requirements.
Updater helpers do not receive microphone access. Run the packaging regression
tests with `pytest tests/test_microphone_packaging.py` on macOS.

Archive the app with macOS metadata preserved:

```bash
ditto -c -k --sequesterRsrc --keepParent \
  WhisprStream.app WhisprStream-macos-arm64.zip
WhisprStream/.build/release/WhisprStreamUpdateSigner sign \
  WhisprStream-macos-arm64.zip WhisprStream-macos-arm64.zip.ed25519
```

Create `SHA256SUMS` for all three artifacts and run the read-only validator.
The validator checks the detached update signature with an independent inline
CryptoKit verifier and the checked-in public-key pin, requires the pinned
signing certificate on the app, helper, and runtime Mach-O files, extracts the
app with macOS metadata preserved, and rejects an unexpected app version or
build number:

```bash
shasum -a 256 WhisprStream-macos-arm64.zip \
  WhisprStream-macos-arm64.zip.ed25519 \
  WhisprStream-runtime-1.0.0-arm64.zip > SHA256SUMS
WhisprStream/validate-release.sh WhisprStream-macos-arm64.zip \
  WhisprStream-runtime-1.0.0-arm64.zip SHA256SUMS \
  WhisprStream-macos-arm64.zip.ed25519 1.0.2 5
```

## Local updater dry runs

No GitHub Release is needed to exercise the updater. Run the non-interactive
helper harness first:

```bash
WhisprStream/test-updater-e2e.sh
```

It builds the real helper and tests successful replacement, missing-executable
and missing-health-signal rollback, cleanup, and unsafe-path rejection using
disposable app bundles under `/tmp`. It never touches the repository app or
`/Applications`.

To exercise the actual Settings → About UI, quit every running WhisprStream
instance and run:

```bash
WhisprStream/run-mock-update.sh success
```

The script builds fresh debug executables, creates current and replacement app
copies under `/tmp`, generates an ephemeral Ed25519 key, serves the signed ZIP
and GitHub-shaped metadata on loopback, and launches only the temporary current
app. Choose **Install and Relaunch**, confirm version 9.9.9 is reported as
installed, and press Control-C in Terminal to remove the test environment.

Repeat the UI flow for the expected failure states:

```bash
WhisprStream/run-mock-update.sh tampered-signature
WhisprStream/run-mock-update.sh wrong-size
WhisprStream/run-mock-update.sh wrong-version
```

Use `--prepare-only` to validate creation and HTTP serving without opening the
app. The `WHISPR_UPDATE_FEED_URL` override exists only in debug builds, accepts
only loopback HTTP URLs, and is compiled out of release builds. Production
builds continue to require HTTPS GitHub release and asset URLs.

## 3. Stable self-signing

Create one certificate using [`make-signing-cert.md`](WhisprStream/make-signing-cert.md), keep its private key outside the repository, and back it up securely. Reuse the same identity for every release; losing the key changes the app's code identity and may require permissions to be granted again.

Self-signing does not provide Apple trust, does not notarize the app, and does not remove the unknown-developer warning. Release notes must point users to **System Settings → Privacy & Security → Open Anyway**. Never tell users to disable Gatekeeper or run broad `xattr` commands.

## 4. Draft release and clean-Mac qualification

For this release, create a draft GitHub Release tagged `v1.0.2`, upload:

- `WhisprStream-macos-arm64.zip`
- `WhisprStream-macos-arm64.zip.ed25519`
- `WhisprStream-runtime-1.0.0-arm64.zip`
- `SHA256SUMS`

Then download both assets back from GitHub and verify their hashes. Before publishing, test the browser-downloaded, quarantined app on:

- a clean macOS 14 Apple-silicon Mac with no Python or Xcode;
- a Mac with Homebrew Python 3.13;
- an active Conda/pyenv environment and poisoned `PYTHONPATH`;
- an 8 GB base M-series Mac and a 16 GB or greater Mac;
- offline, insufficient-space, cancelled-download, checksum-failure, partial-model-cleanup, permission-skip, and update scenarios.

Record failure-state screenshots and logs. Verify that an app replacement preserves the runtime, model cache, and permissions; document any Accessibility re-grant honestly if macOS requires it.

On a fresh macOS user account with no previous microphone grant, explicitly verify:

- In Setup Guide, click **Grant** on the microphone step. The native macOS consent
  dialog must appear and WhisprStream must appear in Privacy & Security → Microphone.
- Allow access and complete an actual dictation after installing the engine/model.
- In a separate fresh account, skip microphone setup and use Settings → Permissions
  → **Grant Access**. This must also show the native prompt.
- Deny access, then retry from the app. It must open the microphone settings pane;
  enabling access and relaunching when macOS requests it must restore dictation.

Moving an app into Applications does not register a microphone request. Local
non-hardened builds and accounts with existing grants do not qualify this check.

## 5. Website and update checks

Confirm the website's download link resolves to the stable app asset and that all source links resolve to [github.com/Leo6Leo/whispr-stream](https://github.com/Leo6Leo/whispr-stream). The website must not advertise a Homebrew command until a real Cask exists.

In Settings → About, confirm that the update checker accepts exact stable semantic versions such as `v1.0.2`, ignores drafts and prereleases, rejects missing, oversized, duplicate, or incorrectly signed assets, and offers **Install and Relaunch** only after discovering both exact update assets. Test a valid signed update end to end from a writable copy in Applications, including relaunch after a quarantined download, plus tampered-signature and read-only-location failures. Quarantine is cleared only from a replacement that has passed the pinned Ed25519 signature and bundle checks. The manual GitHub button must remain available as recovery.

## Local developer test mode

Local builds can use the prepared venv. To exercise the first-run UI without touching real runtime, model, preference, or permission files:

```bash
# Quit any currently running WhisprStream menu-bar process first.
WHISPR_TEST_FIRST_RUN=1 WhisprStream.app/Contents/MacOS/WhisprStream
```

The flag belongs to the process being launched; opening the app from Finder,
or leaving an older menu-bar instance running, does not pass it to that
instance. Local builds also accept the equivalent explicit argument:

```bash
WhisprStream.app/Contents/MacOS/WhisprStream --whispr-test-first-run
```

The launch log records `developerTestMode=true` when the simulator is active.
In a local build, Settings → Engine also has “Enter simulated first run” for
testing without relaunching.

This mode is developer-only and is never included as a public runtime path.

Local builds enable experimental optional models by default. Use
`ENABLE_OPTIONAL_MODELS=0 WhisprStream/build.sh` to reproduce the public 1.0.2
model UI and runtime requirements. `RELEASE=1` always enforces that setting and
cannot be overridden.
