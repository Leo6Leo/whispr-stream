# WhisprStream — handoff

## Voice Shortcuts

Voice Shortcuts are implemented in the native app. Users can save a spoken
trigger (a single word or phrase) and literal replacement text from the
Shortcuts tab in Settings. Matching finds the trigger anywhere in the final
transcript at token boundaries using shared Unicode
case/punctuation/whitespace normalization; it is exact rather than fuzzy.
Longer phrase matches win over shorter matches at the same position.

Enabled triggers are included in the live ASR context, while replacements stay
in Swift and are never sent to the sidecar. The final HUD text and both output
paths use the expanded replacement. Shortcut data is stored as JSON in the
versioned `voiceShortcuts.v1` UserDefaults key.

New files:

- `WhisprStream/Sources/WhisprStream/VoiceShortcut.swift` — model, normalizer,
  and validation.
- `WhisprStream/Sources/WhisprStream/TranscriptExpander.swift` — deterministic
  final-transcript expansion.
- `WhisprStream/Sources/WhisprStream/VoiceShortcutsView.swift` — settings list
  and add/edit sheet.
- `WhisprStream/Tests/WhisprStreamTests/TranscriptExpanderTests.swift` and
  `VoiceShortcutSettingsTests.swift` — domain and persistence/context tests.

The SwiftPM test target runs with `swift test`; real-voice recognition QA on
both supported models remains a manual follow-up.

## Recording shortcuts

The app stores the recording shortcut as JSON in the versioned
triggerShortcut.v1 UserDefaults key. It preserves the observed physical
key code, the logical Command/Control/Option/Shift modifiers, and a semantic
label for printable, named, and function keys. Existing triggerKey values
for Right/Left Option, Right Command, Right Control, and Fn migrate
automatically; Right Option is the fallback when both settings are invalid.

The Settings and onboarding recorder uses a local first-responder AppKit view.
While it is active, HotKeyMonitor removes both its global and local event
monitors, so recording or saving a new shortcut cannot start dictation. The
monitor listens to .flagsChanged for legacy modifier-only shortcuts and to
.keyDown/.keyUp for chords and F13–F24. Chord matching compares only the
four logical modifiers exactly; hold mode also stops if a required modifier
is released before the primary key.

On-device dictation for macOS that handles **Chinese and English mixed in one
sentence**. Built on an M1 Max / 32 GB, macOS 26.5, Swift 6.2.

Replaces OpenWhispr, whose Whisper backend can't code-switch and only transcribes
after you stop talking.

---

## Current state: working

A native SwiftUI menu-bar app. Hold (or tap) a recording shortcut, speak, and the
transcript appears at the cursor. A floating HUD shows text **while you speak**.

Measured on the user's own voice, 12 s of mixed zh/en audio:

| | value |
|---|---|
| Final transcribe | **~0.30 s** (RTF 0.024, 8-bit) |
| Live pass at 3 s buffer | ~0.064 s |
| Model load (once, at launch) | ~1.9 s |

Sample output — English survives *as English* inside Chinese:

```
你好呀，我就是想测试一下这个presentation，然后看一下这个actually work不。然后我和Ines一起去。
OK, I'm just like actually try, 就试一下这个能不能用。
```

---

## Architecture

**Swift front end + Python ASR sidecar.** Swift owns hotkey, audio capture, HUD,
and text insertion. Python does inference only. They speak newline-delimited JSON
over stdin/stdout:

```
in : {"cmd":"start"} | {"cmd":"audio","pcm":"<base64 int16 16k mono>"} | {"cmd":"stop"}
     {"cmd":"context","text":"Claude Codex"}   # vocabulary, applies live
out: {"type":"ready","ms":1900}
     {"type":"partial","committed":"…","tail":"…"}
     {"type":"final","text":"…","secs":12.0,"ms":299}
```

The sidecar starts at launch and **stays resident**. Reloading the model per
utterance costs ~2.8 s versus ~0.3 s warm — never reload.

Porting Qwen3-ASR to MLX Swift would remove the Python dependency but is weeks of
work for identical output. Not recommended.

### Files

```
whispr-stream/
├── asr_engine.py                    # shared model loading + quantization
├── whispr.py                        # CLI: push-to-talk, no live preview
├── whispr_live.py                   # CLI: live preview (reference impl)
├── record_sample.py                 # mic recorder for testing
├── sound-design/
│   ├── index.html                   # the Web Audio design page (source of truth)
│   └── render_sounds.py             # offline port → Resources/Sounds/*.caf
├── stream_from_file.py              # replays a wav through voxmlx (diagnostic)
├── live_stream.py                   # patched voxmlx live (diagnostic)
├── .venv/                           # mlx-qwen3-asr + pynput  ← the app uses this
├── .venv-voxtral/                   # voxmlx — diagnostics only, safe to delete
├── models/voxtral-6bit/             # 3.4 GB, rejected model, safe to delete
└── WhisprStream/
    ├── Package.swift                # SwiftPM, macOS 14+, Swift 5 language mode
    ├── build.sh                     # compiles + assembles + signs the .app
    ├── make-signing-cert.md         # fixes the TCC-on-rebuild problem
    ├── Resources/asr_server.py      # the sidecar
    └── Sources/WhisprStream/
        ├── WhisprStreamApp.swift    # @main, AppDelegate, lifecycle, menu bar
        ├── AppState.swift           # Phase enum + observable HUD state
        ├── ASRService.swift         # sidecar process + JSON protocol
        ├── AudioCapture.swift       # AVAudioEngine → 16 kHz mono Int16
        ├── TriggerShortcut.swift    # versioned shortcut model, validation, display
        ├── TriggerShortcutRecorder.swift # local AppKit recorder and SwiftUI editor
        ├── HotKeyMonitor.swift      # global flags/key events, hold/tap modes
        ├── TextInserter.swift       # pasteboard + synthetic ⌘V
        ├── HUDPanel.swift           # non-activating floating NSPanel
        ├── HUDView.swift            # the capsule, waveform, transitions
        ├── Sound.swift              # SoundPair / SoundTheme model
        ├── Settings.swift           # UserDefaults-backed preferences
        ├── SettingsView.swift       # tabbed Form(.grouped) + AboutView
        ├── OnboardingView.swift     # 5-step guided setup
        ├── Permissions.swift        # polls mic + accessibility state
        ├── SoundPlayer.swift        # AudioServices system sounds
        ├── AppWindows.swift         # onboarding/settings/about windows
        └── Log.swift                # ~/Library/Logs/WhisprStream.log
```

### Build & run

```bash
WhisprStream/build.sh          # → WhisprStream.app at the repo root
open WhisprStream.app
```

Run the macOS system E2E for context-aware capitalization and cross-app paste:

```bash
WhisprStream/e2e-context-aware.sh
```

The test launches a temporary editor process and drives the signed development
app's real keyboard/clipboard fallback, targeting that process directly so it
also works in headless CI sessions. WhisprStream must already be allowed in
System Settings → Privacy & Security → Accessibility.

Run the packaged recording-shortcut E2E:

    WhisprStream/e2e-trigger-shortcut.sh

This builds the 1.0.2 build 4 development artifact, verifies its embedded
bundle version, launches the packaged executable directly, and checks
candidate capture, migration, persistence, hold/tap matching, F13 handling,
modifier-release safety, suspension/rebinding, and coach copy. Physical
programmable-keyboard delivery for F21–F24 remains manual QA.

`build.sh` hardcodes the venv python into `Info.plist` as `WhisprPythonPath`.
Override with `PYTHON=/path/to/python WhisprStream/build.sh`.

---

## The core insight

**Never chunk the audio.** Every streaming ASR path tried destroyed
code-switching, because chunk boundaries land mid-word exactly where the model
has least context — and that's where language switches happen.

Since offline inference runs at RTF 0.024, the fix is to re-transcribe the
**entire growing utterance from scratch** every ~0.2–0.3 s. Each pass sees full
context and reads like the offline result. LocalAgreement-2 marks a prefix stable
once two consecutive passes agree; the dimmed tail is what's still moving. Only
the final full-context pass is inserted.

Cost grows with utterance length, so the buffer caps at 45 s.

### Why not the "real" streaming models

Both were tested on the user's actual voice and rejected:

- **Qwen3-ASR `--streaming`** — drops words, duplicates (`work不 work不`),
  transliterates English names into characters (`Ines` → 艾斯), and silently
  truncates at `--stream-chunk-sec 4.0`.
- **Voxtral Realtime 4B 6-bit (`voxmlx` v0.0.2)** — genuinely causal, handles
  code-switching in file replay, but emits **no punctuation** and stalls on
  Chinese live. Chinese costs **0.75 tokens/char vs English's 0.17** (~4.4×), so
  it hits the decode-throughput ceiling first. `voxmlx` also decodes one token at
  a time and prints it, corrupting multi-byte CJK into U+FFFD, and wipes its KV
  cache on every EOS (i.e. every pause).

**Untried:** Voxtral's *4-bit* build with a quantized LM head (~30 ms → ~3 ms per
token) might clear that ceiling. ~2.2 GB download. Only worth it if sub-second
live streaming becomes a hard requirement.

### Vocabulary biasing

The Settings "Vocabulary" field goes verbatim into the Qwen3-ASR **system
prompt** (`<|im_start|>system\n{terms}<|im_end|>`). Soft conditioning, not hotword
boosting — but measured on real voice it works, and costs nothing (~0.20 s either
way):

| context | output |
|---|---|
| `""` | 我在用 **Cloud** 写这个 **CodeX** 的 integration。 |
| `claude codex` | 我在用 Claude 写这个 **CodeX** 的 integration。 |
| `Claude Codex` | 我在用 Claude 写这个 Codex 的 integration。 ✅ |

**Write entries in the casing you want back.** Lowercase `claude` was enough to
beat `Cloud`, but lowercase `codex` did not beat `CodeX`. A longer list and a
full sentence framing did no better than the bare capitalized pair.

Terms apply live via `{"cmd":"context"}` — no model reload. This matters: the
sidecar reads `WHISPR_CONTEXT` from its environment only at spawn, so persisting
to UserDefaults alone leaves the running model on the old vocabulary until the
next launch. `Settings.onContextChange` exists to prevent exactly that.

### Quantization

Measured, same audio:

| | time | transcript |
|---|---|---|
| fp16 | 0.680 s | ✅ |
| **8-bit** | **0.284 s** | ✅ **identical** |
| 4-bit | 0.267 s | ❌ `actually work不` → `Actually Workable` |

**Use 8-bit.** 4-bit is only ~6 % faster and corrupts code-switching. Quantization
happens at load time from the fp16 weights — no separate download.

---

## Sound

`sound-design/index.html` designs ten **start/finish pairs** in Web Audio. There
are no audio files in it — `render_sounds.py` is an offline port of that graph
(same envelope semantics, same RBJ bandpass, band-limited triangle) that renders
20 mono 44.1 kHz `.caf` files into `WhisprStream/Resources/Sounds/`. Edit a
builder there and re-run; `build.sh` copies them into the bundle.

Verified after rendering: every note lands within 0.3 % of its intended pitch
(windowed FFT per note — a whole-file FFT misleads, since the long ringing tail
buries the 0.05 s grace notes), and nothing clips (loudest peak 0.339).

Selecting a **pair** gives a sound at dictation start and its answer on insert.
The original **macOS alert sounds are all still there** and still behave exactly
as before — one sound on insert, nothing on start. `SoundTheme` stores
`pair:<case>` or `system:<name>`; a bare unprefixed value is a pre-pairs setting
and migrates to `.system`.

Note the pairs are not loudness-matched to each other — the clicks peak around
0.07–0.15 and the melodic pairs around 0.28–0.34, as designed.

## Traps that cost real time

**1. Ad-hoc signing breaks Accessibility on every rebuild.** TCC keys the grant to
the code signature; ad-hoc signatures derive from the binary hash, so each rebuild
looks like a new app. The permission still *appears* enabled in System Settings
while doing nothing. Symptom: hotkey and paste both silently stop.

Fix: create a self-signed cert named exactly `WhisprStream Self-Signed`
(see `make-signing-cert.md`); `build.sh` detects it and prints
`▸ signing with stable identity`. Until then, remove **and re-add** the app in
Accessibility after every rebuild — toggling off/on reuses the stale record.

`~/Library/Logs/WhisprStream.log` logs `accessibility=granted|DENIED` at launch.
**Check this first** whenever the hotkey or paste goes quiet.

**2. Synthetic ⌘V needs the right tap.** `.cgAnnotatedSessionEventTap` doesn't
reliably reach other apps. Use `.cghidEventTap` with `.hidSystemState`, send a
real ⌘ press/release around the V (not just `.maskCommand`), and wait ~50 ms after
the pasteboard write or you paste stale content.

**3. Pasteboard, not keystrokes.** Per-character unicode key events are unreliable
for CJK. Pasteboard + ⌘V handles mixed scripts correctly.

**4. Hugging Face downloads never resume — disabling Xet does not fix it.**
The Xet backend fails on this connection (`CAS Client Error: Format error`), so
`HF_HUB_DISABLE_XET=1` is still needed. But it does **not** buy resumption:
`huggingface_hub` writes every attempt to a process-unique
`<etag>.<uuid>.incomplete` (`file_download.py:1920`, so a broken `flock` can't
corrupt a shared file) and starts from byte zero each time. Verified by
interrupting and restarting a download: a *fourth* `.incomplete` blob appeared
rather than the third continuing.

Consequences: an interrupted multi-GB download costs its bytes twice and leaves
the partial behind forever, so the Model tab never offers "Resume" and never
counts a partial as progress. For a large weight file over a flaky connection,
`curl -L -C -` is still the only thing that genuinely resumes.

**5. Synthetic `say` audio is misleading.** It made Qwen3-ASR streaming look
usable when real speech broke it immediately — TTS has clean pauses that
conveniently land on chunk boundaries. **Always validate on the user's real
voice** (`record_sample.py`).

**6. iOS `SystemSoundID` numbers are no-ops on macOS.** `AudioServicesPlaySystemSound(1016)`
silently does nothing. macOS IDs start at 4096; register a file first with
`AudioServicesCreateSystemSoundID(url as CFURL, &id)`.

**7a. `TabView` builds more than one instance of a tab.** `@State` filled by
`onAppear` on one instance is not the state the *displayed* instance renders
with. The Model tab showed both models as "not installed" while the check itself
was returning `installed` — the rows had rendered from an empty dictionary
belonging to a different instance. Don't cache derived state in `@State` behind
`onAppear` in a tab; compute it in `body`, or hold it in a `@StateObject`.

**7. SourceKit reports phantom errors** for this package — `Cannot find type
'AppState' in scope`, `Settings requires arguments in <...>`. Ignore them and
trust `swift build`. (`Settings` does collide with SwiftUI's `Settings` scene
type, but module-local wins and it compiles fine.)

---

## UI details worth preserving

- **HUD panel is fixed-size (900×190) with the capsule centred.** Resizing an
  NSWindow can't animate in step with SwiftUI's layout spring — growing the window
  per partial made the capsule visibly snap. Fixed window, SwiftUI owns motion.
- **`.nonactivatingPanel` + `canBecomeKey = false`** — if the HUD took focus the
  paste would land in the HUD, not the user's app.
- **Reset state only in `dismiss`'s completion handler.** `.idle` renders as the
  "Listening…" placeholder, so resetting before the fade finishes makes the HUD
  visibly revert mid-fade.
- **`.compositingGroup()` before `.shadow()`** — a shadow on a `.ultraThinMaterial`
  fill renders behind the blur and muddies the panel.
- **Derive frame widths from content constants.** A hard-coded `.frame(width: 78)`
  on a 127.5 pt waveform spilled 50 pt into the text. The leading slot is now
  sized per phase (81 pt waveform / 35 pt dots / 24 pt checkmark).
- Motion vocabulary: text `spring(0.30, 0.85)`, phase `spring(0.26, 0.72)`,
  waveform bars `spring(0.28, 0.62)`, fade in 0.14 s / out 0.16 s,
  checkmark held 0.42 s.

---

## Ideas not yet built

- **Floating HUD is terminal-independent already**, but there's no way to see the
  transcript history. A recent-transcripts list could be useful.
- **Buffer trimming** — use `return_timestamps=True` to find where committed text
  ends, drop those samples, keep the text as a prefix. Turns the live loop's O(n²)
  into ~O(n), making long dictation flat-cost. Only matters past ~30 s utterances.
- **Local LLM cleanup pass** (`mlx-lm`) for 的/得 homophone slips and spacing at
  script boundaries.
- App icon (currently an SF Symbol), `SoundPlayer.playUserAlert()`
  is written but unwired.
- 1.7B model was never benchmarked — its download stalled on the Xet bug. 0.6B is
  good enough that this is low priority.

---

## User preferences observed

- Wants things verified, not asserted — measurements over claims.
- Cares about UI polish and animation quality; will notice a clipped shadow or a
  28 pt gap.
- Tests on their own real speech and reports honestly when something is bad.
- Prefers Apple-native idioms over hand-rolled equivalents.
