# Install WhisprStream

WhisprStream is a free, open-source menu-bar dictation app for Apple-silicon Macs. It requires macOS 14 or later and approximately 4 GB free for the app, private speech engine, and recommended Qwen3-ASR 0.6B model.

## Download and open

1. Open [GitHub Releases](https://github.com/Leo6Leo/whispr-stream/releases) and download `WhisprStream-macos-arm64.zip` from the latest published release.
2. Extract the ZIP and move **WhisprStream** to your Applications folder.
3. Open WhisprStream normally.
4. If macOS blocks it, open **System Settings → Privacy & Security**. Find the WhisprStream message under Security, click **Open Anyway**, authenticate, and confirm **Open**.

The release is signed with WhisprStream's stable self-signed identity but is not notarized by Apple. The Open Anyway step is expected. Do not disable Gatekeeper globally.

## First launch

The app keeps the speech engine and speech model as separate downloads:

- The exact engine download and installed sizes are shown in Setup Guide before installation. It is stored in `~/Library/Application Support/WhisprStream/Runtime` and is reused across app updates.
- Qwen3-ASR 0.6B is approximately 1.9 GB installed and is recommended for most Macs. Plan for at least 4 GB free for a complete installation.
- Qwen3-ASR 1.7B is approximately 4.3 GB installed. It is larger and slower, may improve difficult audio, and is best with 16 GB or more unified memory. Plan for about 6 GB free.

The app checks available storage before either download and checks again before installing or extracting files. Model metadata is fetched from Hugging Face so the exact byte total can be shown.

## Experimental optional models

Custom-model support is not available in the public 1.0.2 app. It remains behind a compile-time gate while its validation and runtime packaging are completed. The two built-in Qwen3-ASR choices remain available normally.

Local source builds enable the experiment by default. In those builds, open **Settings → Model → Add Custom Model…**. Custom entries can use a Hugging Face model id or an existing local folder:

- Choose **Qwen3-ASR** for a complete Qwen3-ASR checkpoint or compatible fine-tune. The folder/repository must include a `config.json` declaring `model_type: qwen3_asr` and complete `model.safetensors` weights (single-file or indexed shards).
- Choose **Whisper (MLX)** for a converted Whisper model supported by `mlx-whisper`. It must include a `config.json` declaring `model_type: whisper` plus `model.safetensors`, `weights.safetensors`, or `weights.npz`.

Hugging Face repositories are checked for the selected engine's required files before download. Local folders are validated immediately, remain in their original location, and must stay available while selected. **Forget Model** removes only the saved entry; it never deletes the local folder or cached weights.

To test the public configuration from source, build with `ENABLE_OPTIONAL_MODELS=0 WhisprStream/build.sh`.

## Permissions and menu-bar behavior

Onboarding asks for Microphone access and Accessibility access. Microphone is needed to capture speech; Accessibility is needed to see the recording shortcut globally and insert text at the cursor. If you choose **Skip for now**, the final screen will say **Finish setup later** and you can grant access from **Settings → Permissions**.

Click **Grant** in the Setup Guide's microphone step, or **Grant Access** under
**Settings → Permissions**, to show the macOS consent dialog. Moving the app into
Applications alone does not add it to the system's Microphone list. If access was
previously denied, the app opens System Settings so you can enable it there.

WhisprStream runs in the menu bar rather than the Dock. Choose **Setup Guide…** from the menu-bar icon to reopen onboarding. Choose **Settings…** for model, engine, permissions, vocabulary, shortcuts, and preferences.

## Recovery and storage cleanup

- If the engine is missing, incompatible, or fails its health check, open **Settings → Engine** and choose **Install** or **Repair / Reinstall**. Repair replaces only the engine; it does not delete models, preferences, vocabulary, or shortcuts.
- If a model download is interrupted, the app reports the scoped partial storage. Choose **Clear Partial Data** in **Settings → Model**. During a new download, **Clear and Continue** removes the unusable partial data before retrying; **Keep and Continue** leaves it in place. Cleanup affects only `.incomplete` files for the selected model.
- Download activity uses a crash-safe lock. Cancelling the operation or quitting unexpectedly releases the lock automatically, so stale state cannot permanently block cleanup.
- If a model is missing, open **Settings → Model** or **Setup Guide…**, select a model, and download it again.
- If permissions were revoked, open **Settings → Permissions** and use **Open Settings**.

## Updates

WhisprStream checks for stable updates shortly after launch and every six hours while it remains open. Each new release gets one automatic prompt; choosing **Not Now** dismisses that prompt while leaving an accent-colored dot beside the menu bar icon and an update banner in Settings. **Update & Relaunch** downloads the app ZIP, verifies its Ed25519 release signature, replaces the installed app, and reopens it. You can also check manually in **Settings → About**. If WhisprStream is running from a read-only location, move it to Applications and try again or use **Open GitHub Releases…** for a manual replacement. The runtime, models, settings, vocabulary, and shortcuts remain in your user Library.

## Uninstall

Remove these items separately according to what you want to keep:

- `/Applications/WhisprStream.app` — the native app.
- `~/Library/Application Support/WhisprStream/Runtime` — the private speech engine.
- `~/.cache/huggingface/hub/models--Qwen--Qwen3-ASR-0.6B`, `models--Qwen--Qwen3-ASR-1.7B`, and any custom Hugging Face model repositories — optional model caches at the default Hugging Face cache location. A custom `HF_HUB_CACHE` or `HF_HOME` location may be elsewhere.
- WhisprStream preferences in `~/Library/Preferences` — settings, vocabulary, and shortcuts.
- `~/Library/Logs/WhisprStream.log` — diagnostic logs.

Removing the app does not automatically remove the runtime, model caches, preferences, or logs.
