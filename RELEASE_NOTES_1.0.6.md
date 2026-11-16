## WhisprStream 1.0.6 (build 10)

This release redesigns Settings, adds launch at login, stops the setup guide from reopening on every launch, fixes several number, filler-word, and word-check mistakes found in real dictations, stops the 1.7B model from translating Chinese speech into English, and adds an optional mode that writes the final text with the 1.7B model while live text stays fast.

### What's new

- **Settings looks like System Settings.** The window is now a two-column layout with a sidebar, a title in the toolbar, and a fixed width, and it remembers the section you last had open. Thanks to **[@logonoff](https://github.com/logonoff)** for the redesign.
- **Launch at login.** A new **Startup** toggle under Settings → General registers WhisprStream as a login item. The toggle follows the system: if you change the login item in System Settings, it updates the next time the app becomes active, and a change macOS rejects is reverted with an explanation. Thanks to **[@logonoff](https://github.com/logonoff)**.
- **Use the 1.7B model for the final text (beta, off by default).** With Qwen3-ASR 0.6B selected and 1.7B downloaded, Settings → Speech model offers *Use the 1.7B model for the final text*. Live text keeps coming from the fast model; when you finish speaking, the larger model writes what gets inserted. On 73 real mixed Chinese and English dictations replayed through the engine, the character error rate fell from 0.164 to 0.148 and the text landed about 70 ms later at the median (250 ms to 319 ms; 0.45 s to 0.63 s at the 90th percentile). The gain is modest and uneven: English words inside Chinese sentences improve most, names and product names do not. Both models stay in memory, about 5 GB more, and **Check a word** does not ask questions in this mode. This is a beta: if the larger model writes the sentence in a different language than you spoke, the fast model's text is used instead.
- **A repair alert instead of the setup guide.** If the speech engine fails its health check after you have finished setup, one alert gives the reason and a **Repair** button that opens Engine settings. A finished check or repair starts the engine without relaunching the app.

### Fixes

- **The setup guide no longer reopens on every launch.** The launch decision was made before the engine's health check had finished, so release builds always fell into the guide. It now waits for the check, starts the session when the engine is healthy, and opens the guide only for people who have not completed setup. Thanks to **[@logonoff](https://github.com/logonoff)** for finding and fixing this.
- **The 1.7B model no longer translates Chinese into English.** With the vocabulary list in its prompt, the 1.7B model labelled mixed Chinese and English speech as English and wrote whole Chinese sentences as English translations: five of 73 real dictations, against none without the prompt. The 1.7B model now decodes without the vocabulary prompt, on its own or as the final-text model, and the spelling of single-word vocabulary terms is restored afterwards. The 0.6B model was not affected and is unchanged.
- **Colloquial Chinese quantities read correctly.** *两千五* is 2500 and *一百二* is 120; they used to become 2005 and 102. *两千零五*, *二十五*, and *一百二十* are unchanged.
- **Words are no longer mistaken for numbers.** *万一* stays a word instead of becoming 10001, and two bare digits side by side (*三四个*, *两三天*) stay an estimate instead of becoming 34 or 23. Idioms such as *三三两两* are left alone. Longer digit runs and runs containing a zero still convert.
- **A real *啊！* is kept.** Filler-word removal dropped an interjection the engine had written with an exclamation or question mark (*啊！我给忘了*, *啊？*). Those are speech, not hesitation, and now stay. *啊，* and *啊。* at a pause are still removed.
- **No doubled punctuation after a removed hesitation.** Removing a filler could leave two marks facing each other (*情况，呃：它* became *情况，：它*). A comma now gives way to the stronger mark, and no space is added after a full-width mark.
- **Check a word stops asking pointless questions.** A disputed word that differs only in spacing, capitalization, or punctuation (*Backend* or *back end*, *codebase* or *code base*), or only between the pronouns 他, 她, and 它, is no longer asked about; the other words in the same sentence still are. On one developer's history, that was 17 of 154 questions.
- **Everyday words are never learned as vocabulary.** *Learn from my choices* had learned *the* and *add*. Common English words and Chinese function words are now excluded, both in the app and in the engine.
- **Starting the engine never downloads a model.** The engine used to ask Hugging Face for the newest revision of the model on every start; if the model repository changed, it would have downloaded the whole model again during startup, with no progress or storage check. It now loads exactly the model that is installed and works with the Hub unreachable.
- **A slow model no longer costs you the dictation.** If the engine was still busy when you finished speaking, the text was discarded after five seconds; it now waits for the engine as long as it is making progress.
- **The General pane fits its window.** A long vocabulary list no longer pushes the pane wider than the settings window, and *Reset to Default* is no longer truncated.
- The HUD now animates when *Listening…* becomes *Waking up the speech model…* instead of snapping to the new width.

Thanks to **[@logonoff](https://github.com/logonoff)** for three pull requests in this release: the Settings redesign, launch at login, and the setup-guide fix.

### Known limitations

- The vocabulary spelling pass can still rewrite a correct word into a vocabulary term that looks similar (*Word Cloud* into *Word Claude* when *Claude* is in your vocabulary). Remove the term from the vocabulary if this affects you.
- With the 1.7B model, alone or as the final-text model, the vocabulary no longer steers recognition: multi-word terms, Chinese terms, and Voice Shortcut triggers get no help, and only the spelling of single-word terms is corrected afterwards. Vocabulary works as before with the 0.6B model.
- Selecting the 1.7B model on its own can still occasionally write mixed Chinese and English speech as English; the final-text beta guards against this by checking the result against the fast model.
- Names and product names remain the most common mistake with either model.
- With *Use the 1.7B model for the final text* on, the inserted text can differ from the live preview, since two models wrote them.
- A dictation that consists only of a hesitation (*Hmm.*) is dropped as empty, with no explanation in the HUD. Turn filler-word removal off under Settings → General → Output if you dictate those deliberately.
- Short sentences still run a fresh final decode a little more often than in 1.0.4; the finished text appears about 40 ms later at the median.
- Filler-word removal is a beta heuristic. Sentence-initial *Ah* before a name (*Ah Ming*) is removed; turn the setting off if that affects you.
- Manually edited review text still passes through spoken-number, symbol, and shortcut formatting.
- Learned vocabulary hints do not yet receive the same independent verification as explicit vocabulary.

### Install or update

Download **WhisprStream-macos-arm64.zip**, extract it, and move WhisprStream to Applications. Existing users can use **Install and Relaunch** or replace the app manually. Your engine, model cache, settings, vocabulary, and shortcuts are retained.

**Homebrew:** `brew install --cask Leo6Leo/tap/whispr-stream` installs the same signed build from the [Leo6Leo/homebrew-tap](https://github.com/Leo6Leo/homebrew-tap) Cask, which GitHub Actions update automatically whenever a release is published. The Cask removes the quarantine attribute only from the installed WhisprStream.app, so first launch skips the Open Anyway step; it does not disable Gatekeeper. Homebrew installs still update themselves through the app; `brew upgrade --cask --greedy whispr-stream` updates from Homebrew instead.

Requires **macOS 14 or later on Apple silicon**. The app is self-signed and not notarized. If macOS blocks first launch, use **System Settings → Privacy & Security → Open Anyway**.

The speech runtime remains **1.0.0**. The runtime ZIP is provided as a release asset; normal installation downloads the engine through the app. Meeting Notes and experimental custom models are not included in this release.
