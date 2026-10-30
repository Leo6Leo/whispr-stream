## WhisprStream 1.0.5 (build 9)

This release fixes the thinking-pause sentence break reported against 1.0.4, lets you check up to three uncertain words at once, writes the clipboard once per dictation, and tells you when the speech model is waking up or your Mac is under pressure.

### What's new

- **Check up to three words.** When the engine was unsure about more than one word, **Check a word** now steps through them over the same sentence instead of asking about only the first. Press **1**, **2**, or **3** to pick a candidate, or **Return** to take the highlighted one; each confirmation has its own soft sound. Editing a word by hand still works, and the panel stays within a bounded size on long sentences.
- **The HUD says when the model is waking.** On a Mac deep into swap, the model's weights can be paged out after a few idle minutes, and the first words used to sit behind a silent *Listening…* for several seconds. When a decode has run for a second with nothing to show, the HUD now says **Waking up the speech model…** until the first words arrive.
- **Memory and thermal pressure are explained.** If a final has already waited a second while macOS reports high memory pressure or a serious thermal state, the HUD turns softly orange and says *Memory pressure is high · Transcription may be slower* (or *Mac is running hot*, or *Mac is under heavy load*). A normal wait never warns; the notice clears with the result.
- **Learn from edits works inside documents.** The optional *Learn from edits I make after inserting* watch (off by default) now relocates the inserted sentence by aligning its own line, so edits elsewhere in a note or a re-rendered editor no longer hide a correction, and multi-line edits are learned. The watch finishes as soon as the caret leaves the inserted text. Nothing is uploaded; samples stay under Application Support on this Mac.

### Fixes

- **A thinking pause no longer ends the sentence.** A pause of 1.5 s or more inside your speech is shrunk to half a second before the final decode, so a sentence you continue after a moment's thought no longer gets a stray full stop in the middle. Six out of six pause dictations that produced a stray 。 in 1.0.4 now read correctly, and 208 held-out real transcripts come out unchanged.
- **A pause filled with *um* no longer splits the sentence either.** The engine often breaks just before a hesitation (*ability to. Um, export it* or *ability to, um, export it*). When the word before that break cannot end a sentence (an article, *to*, *and*, *because*, or the equivalent Chinese connectives), the break goes with the hesitation and the sentence is joined again. Words that can end a sentence (*for*, *with*), capitalized names (*option A.*), abbreviations (*e.g.*), and sentence-final particles are left alone. *Hm*, *hmm*, and *hmmm* are now treated as hesitations.
- **Fewer invented words in tap mode.** Long quiet before and after the speech is trimmed before the final decode, which stops the model from inventing text when you tap to start, think for a while, and tap to stop.
- **One clipboard entry per dictation.** 1.0.4 wrote the pasteboard twice, so clipboard-history tools showed every dictation as two entries. The transcript is now written exactly once. The space that separates it from the text before the cursor is decided from that text when it can be read: none at a line start, in an empty field, after an opening bracket, or next to CJK text; one space after a Latin word or sentence punctuation. When the clipboard keeps the transcript, it keeps that leading space too.
- **Words appear sooner after a pause.** The preview decoder now idles through a thinking pause instead of re-decoding room tone every 150 ms, so it is free the moment you resume. On real pause dictations the decoder was still busy at 26 of 64 resumes in 1.0.4 and at none now; the next word after resuming arrives about 50 ms sooner at the median.
- **Each sound plays once on macOS 27.** The system sound API plays every cue twice on macOS 27.0.1; sounds now go through a cached audio player, which follows the output volume rather than the alert volume.
- **The log file is no longer overwritten.** The speech engine's log handle now appends, so its lines stop overwriting what the app itself logged since launch.
- About no longer describes mixed dictation as Chinese and English only.

Thanks to **[@tonykay](https://github.com/tonykay)** for the detailed reports on the pause break, the duplicated clipboard entries, and *Hmm*.

### Known limitations

- A dictation that consists only of a hesitation (*Hmm.*) is dropped as empty, with no explanation in the HUD. Turn filler-word removal off under Settings → General → Output if you dictate those deliberately.
- Short sentences run a fresh final decode a little more often than in 1.0.4, because the idle preview decoder no longer confirms the last word during the trailing silence. Measured on this developer's dictations, the finished text appears about 40 ms later at the median; a fix is queued for the next release.
- Filler-word removal is a beta heuristic. Sentence-initial *Ah* before a name (*Ah Ming*) is removed; turn the setting off if that affects you.
- Manually edited review text still passes through spoken-number, symbol, and shortcut formatting.
- Learned vocabulary hints do not yet receive the same independent verification as explicit vocabulary.

### Install or update

Download **WhisprStream-macos-arm64.zip**, extract it, and move WhisprStream to Applications. Existing users can use **Install and Relaunch** or replace the app manually. Your engine, model cache, settings, vocabulary, and shortcuts are retained.

**Homebrew:** `brew install --cask Leo6Leo/tap/whispr-stream` installs the same signed build from the [Leo6Leo/homebrew-tap](https://github.com/Leo6Leo/homebrew-tap) Cask, which GitHub Actions update automatically whenever a release is published. The Cask removes the quarantine attribute only from the installed WhisprStream.app, so first launch skips the Open Anyway step; it does not disable Gatekeeper. Homebrew installs still update themselves through the app; `brew upgrade --cask --greedy whispr-stream` updates from Homebrew instead.

Requires **macOS 14 or later on Apple silicon**. The app is self-signed and not notarized. If macOS blocks first launch, use **System Settings → Privacy & Security → Open Anyway**.

The speech runtime remains **1.0.0**. The runtime ZIP is provided as a release asset; normal installation downloads the engine through the app. Meeting Notes and experimental custom models are not included in this release.
