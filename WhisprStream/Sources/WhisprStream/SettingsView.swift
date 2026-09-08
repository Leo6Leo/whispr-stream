import AppKit
import SwiftUI

/// Native macOS settings with a permanently visible labeled sidebar.
///
/// A native TabView collapses its labels into an icon-only strip when macOS
/// decides space is tight. Settings contains six sections, so a fixed sidebar
/// is clearer and does not turn navigation into an overflow control.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var runtime: RuntimeManager
    @ObservedObject var updates: AppUpdateManager
    let onShowUpdate: () -> Void
    @State private var selectedSection: SettingsSection? = .general

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                HStack(spacing: 8) {
                    Label(section.title, systemImage: section.symbol)
                    Spacer(minLength: 4)
                    if section == .about, updates.status.showsUpdateAttention {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel("Update available")
                    }
                }
                .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 160)

            Divider()

            VStack(spacing: 0) {
                if let release = updates.status.availableRelease {
                    SettingsUpdateBanner(release: release, action: onShowUpdate)
                    Divider()
                }

                selectedContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 760, height: 540)
        .onAppear {
            if case .idle = updates.status {
                updates.checkForUpdates()
            }
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedSection ?? .general {
        case .general: GeneralTab(settings: settings)
        case .model: ModelTab(settings: settings)
        case .sound: SoundTab(settings: settings)
        case .shortcuts: VoiceShortcutsView(settings: settings)
        case .permissions: PermissionsTab()
        case .engine: RuntimeTab(runtime: runtime)
        case .about:
            AboutTab(
                settings: settings,
                updates: updates,
                onShowUpdate: onShowUpdate
            )
        }
    }
}

private struct SettingsUpdateBanner: View {
    let release: AppUpdateManager.Release
    let action: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 19))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("WhisprStream \(release.version) is available")
                    .font(.system(size: 13, weight: .semibold))
                Text("Your models and settings will stay in place.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Review Update", action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, model, sound, shortcuts, permissions, engine, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .model: "Model"
        case .sound: "Sound"
        case .shortcuts: "Shortcuts"
        case .permissions: "Permissions"
        case .engine: "Engine"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .model: "waveform.badge.mic"
        case .sound: "speaker.wave.2"
        case .shortcuts: "text.badge.plus"
        case .permissions: "lock.shield"
        case .engine: "cpu"
        case .about: "info.circle"
        }
    }
}

private struct RuntimeTab: View {
    @ObservedObject var runtime: RuntimeManager

    var body: some View {
        Form {
            Section("Speech engine") {
                LabeledContent("Status") {
                    switch runtime.phase {
                    case .ready:
                        VStack(alignment: .trailing, spacing: 5) {
                            Label(
                                runtime.isUsingDevelopmentEngine ? "Development engine ready" : "Ready",
                                systemImage: "checkmark.circle.fill"
                            )
                                .foregroundStyle(.green)
                            if runtime.canManageEngineInstallation && !runtime.isDeveloperTestMode {
                                Button("Repair / Reinstall") { runtime.install() }
                                    .buttonStyle(.link)
                                    .font(.caption)
                            }
                        }
                    case .missing: Text("Not installed")
                    case .checking: ProgressView("Checking…")
                    case .checkingStorage: ProgressView("Checking storage…")
                    case let .insufficientStorage(required, available):
                        VStack(alignment: .trailing, spacing: 5) {
                            Text("Need \(StorageCapacity.formatted(required)); \(StorageCapacity.formatted(available)) available")
                                .foregroundStyle(.red)
                            HStack {
                                Button("Manage Storage…") { StorageCapacity.openStorageSettings() }
                                Button("Try Again") { runtime.install() }
                            }
                        }
                    case .downloading: ProgressView()
                    case .verifying: ProgressView("Verifying…")
                    case .installing: ProgressView("Installing…")
                    case let .failed(message): Text(message).foregroundStyle(.red)
                    case let .incompatible(message):
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(message).foregroundStyle(.red).multilineTextAlignment(.trailing)
                            if runtime.canManageEngineInstallation {
                                Button("Repair / Reinstall") { runtime.install() }
                            }
                        }
                    }
                }
                if runtime.isReady {
                    Text(runtime.isUsingDevelopmentEngine
                         ? "This local build uses the prepared development engine. Downloadable repair is available in configured release builds."
                         : "The engine is stored in Application Support, separately from the app bundle. Models are downloaded only when you choose one.")
                        .foregroundStyle(.secondary)
                    if runtime.isDeveloperTestMode {
                        Button("Reset simulated first run") { runtime.resetDeveloperTestInstall() }
                        Text("This changes no real files. Quit and relaunch with the test flag to run onboarding again.")
                            .foregroundStyle(.secondary)
                    } else if runtime.isDeveloperTestModeAvailable {
                        Button("Enter simulated first run") { runtime.activateDeveloperTestMode() }
                        Text("Development-only: simulates engine and model downloads without touching real install files.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if runtime.canManageEngineInstallation {
                        Button("Install speech engine") { runtime.install() }
                    }
                    if runtime.isDeveloperTestModeAvailable {
                        Button("Enter simulated first run") { runtime.activateDeveloperTestMode() }
                        Text("Development-only: simulates engine and model downloads without touching real install files.")
                            .foregroundStyle(.secondary)
                    }
                    if let summary = runtime.storageSummary {
                        Text(summary).foregroundStyle(.secondary)
                    }
                    if let message = runtime.installMessage {
                        Text(message).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { runtime.refresh() }
        .alert(
            "Replace speech engine?",
            isPresented: Binding(
                get: { runtime.requiresRepairConfirmation },
                set: { if !$0 { runtime.cancelRepairConfirmation() } }
            )
        ) {
            Button("Repair / Reinstall", role: .destructive) { runtime.confirmRepairInstall() }
            Button("Cancel", role: .cancel) { runtime.cancelRepairConfirmation() }
        } message: {
            Text("This replaces the engine only. Models, preferences, vocabulary, and shortcuts stay on this Mac.")
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            Section {
                Picker("Activation", selection: $settings.activationMode) {
                    ForEach(ActivationMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                TriggerShortcutEditor(settings: settings)
            } header: {
                Text("Dictation")
            } footer: {
                Text(settings.activationMode.detail)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Section("Output") {
                Toggle(isOn: $settings.autoInsert) {
                    Text("Insert at cursor")
                    Text("Paste the finished transcript into the active app.")
                }

                Toggle(isOn: $settings.copyToClipboard) {
                    Text("Copy to clipboard")
                    Text("Keep the finished transcript on the clipboard.")
                }

                Toggle(isOn: $settings.usePunctuation) {
                    Text("Use punctuation")
                    Text(settings.usePunctuation
                         ? "Keep sentence-ending punctuation from dictation."
                         : "Remove sentence-ending punctuation from dictation.")
                }

                Toggle(isOn: $settings.contextAwareCapitalization) {
                    HStack(spacing: 6) {
                        Text("Context-aware capitalization")
                        Text("Beta")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.14), in: Capsule())
                    }
                    Text(settings.contextAwareCapitalization
                         ? "Match nearby text. This may add a brief delay in some apps."
                         : "Keep the speech model's capitalization without checking the cursor.")
                }
            }

            Section {
                LabeledContent("Language") {
                    Text("Automatic")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Normal dictation")
            } footer: {
                Text("Sentences and clips longer than two seconds detect their language automatically, including mixed-language speech.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Section {
                Picker("Language", selection: $settings.shortUtteranceLanguage) {
                    ForEach(ShortUtteranceLanguage.allCases) { language in
                        Text(language.modelName).tag(language)
                    }
                }
            } header: {
                Text("One-word dictation")
            } footer: {
                Text("Automatic multilingual preserves the language you speak, including short Chinese/English switches. Choose a fixed language only when isolated words are repeatedly misdetected; fixed choices apply to clips up to two seconds.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            VocabularySection(settings: settings)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Model

private struct ModelTab: View {
    @ObservedObject var settings: Settings
    @StateObject private var downloader = ModelDownloader()
    @State private var isAddingCustomModel = false

    /// Bumped to force a re-read of the cache. Not a cache of the result:
    /// `TabView` builds more than one `ModelTab`, and `@State` filled by
    /// `onAppear` on one instance is not the state the displayed instance
    /// renders with — which showed every model as "not installed".
    @State private var reloadToken = 0

    var body: some View {
        Form {
            Section {
                ForEach(settings.availableModels) { model in
                    ModelRow(
                        model: model,
                        state: installState(model),
                        isSelected: settings.model == model,
                        downloader: downloader,
                        select: { settings.model = model },
                        forget: model.isBuiltIn
                            ? nil
                            : { settings.forgetCustomModel(model) }
                    )
                }
                if FeatureFlags.optionalModelsEnabled {
                    Button {
                        isAddingCustomModel = true
                    } label: {
                        Label("Add Custom Model…", systemImage: "plus.circle")
                    }
                }
            } header: {
                Text("Speech model")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if settings.isReloadingModel {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading weights…")
                        }
                    } else if let failure = downloader.failure {
                        Text(failure).foregroundStyle(.red)
                    } else if FeatureFlags.optionalModelsEnabled {
                        Text("Switching models restarts the speech engine and reloads its weights. Add a compatible Qwen3-ASR or MLX Whisper repository, or use a converted model folder already on this Mac.")
                    } else {
                        Text("Switching models restarts the speech engine and reloads its weights.")
                    }
                    Text(ModelCatalog.hardwareGuidance)
                }
                .foregroundStyle(.secondary)
                .font(.callout)
                .animation(.spring(response: 0.3, dampingFraction: 0.85),
                           value: settings.isReloadingModel)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in reloadToken &+= 1 }
        .task {
            downloader.onFinish = { _, _ in reloadToken &+= 1 }
        }
        .sheet(isPresented: $isAddingCustomModel) {
            if FeatureFlags.optionalModelsEnabled {
                AddCustomModelView(settings: settings)
            }
        }
        .alert(
            "Clear partial model data?",
            isPresented: Binding(
                get: { downloader.cleanupPrompt != nil },
                set: { if !$0 { downloader.dismissCleanupPrompt() } }
            )
        ) {
            Button(
                downloader.cleanupWillContinueDownload ? "Clear and Continue" : "Clear Partial Data",
                role: .destructive
            ) {
                downloader.removeIncompleteDownload()
            }
            Button("Keep It", role: .cancel) { downloader.dismissCleanupPrompt() }
        } message: {
            Text("This unfinished data cannot be resumed. Only partial files for this model will be cleared; installed models and settings are unchanged.")
        }
    }

    /// Reads the cache on every render. Cheap — a few `stat` calls — and it
    /// cannot show a stale answer after a download or an external change.
    private func installState(_ model: ASRModel) -> ModelInstallState {
        _ = reloadToken
        return ModelCatalog.state(for: model)
    }
}

private struct ModelRow: View {
    let model: ASRModel
    let state: ModelInstallState
    let isSelected: Bool
    @ObservedObject var downloader: ModelDownloader
    let select: () -> Void
    let forget: (() -> Void)?

    private var isDownloading: Bool { downloader.active == model }

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                trailing
                if let forget {
                    Menu {
                        Button("Forget Model", role: .destructive, action: forget)
                            .disabled(isDownloading)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Custom model options")
                }
            }
        } label: {
            Text(model.label)
            Text(model.detail)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isDownloading)
    }

    @ViewBuilder
    private var trailing: some View {
        if isDownloading && downloader.phase != .awaitingCleanup {
            VStack(alignment: .trailing, spacing: 4) {
                if let fraction = downloader.fraction {
                    ProgressView(value: fraction).frame(width: 116)
                    Text(progressLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Starting…").font(.caption).foregroundStyle(.secondary)
                }
                Button("Cancel") { downloader.cancel() }
                    .controlSize(.small)
            }
        } else if isDownloading && downloader.phase == .awaitingCleanup {
            VStack(alignment: .trailing, spacing: 6) {
                Label(
                    "\(StorageCapacity.formatted(downloader.preflight?.incompleteBytes ?? 0)) partial",
                    systemImage: "exclamationmark.triangle.fill"
                )
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Clear and Continue…") { downloader.requestCleanup() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                HStack(spacing: 10) {
                    Button("Keep and Continue") { downloader.downloadAnyway() }
                    Button("Cancel") { downloader.cancel() }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        } else if state.isInstalled {
            if isSelected {
                Label("In use", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
            } else {
                Button("Use", action: select)
            }
        } else if model.isDownloadable {
            VStack(alignment: .trailing, spacing: 3) {
                Button("Download") { downloader.start(model) }
                    .disabled(downloader.isRunning)
                Text(sizeLabel).font(.caption).foregroundStyle(.secondary)
                let incomplete = ModelCatalog.incompleteBytes(for: model)
                if incomplete > 0 {
                    Button("Clear \(ModelCatalog.formatted(bytes: incomplete)) Partial Data…") {
                        downloader.requestCleanup(for: model)
                    }
                    .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
        } else {
            Label("Folder unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var progressLabel: String {
        let got = ModelCatalog.formatted(bytes: downloader.received)
        guard downloader.total > 0 else { return got }
        return "\(got) of \(ModelCatalog.formatted(bytes: downloader.total))"
    }

    /// Never says "Resume", and never counts a partial as progress.
    ///
    /// Measured: huggingface_hub writes each attempt to a *process-unique*
    /// `<etag>.<uuid>.incomplete` (file_download.py:1920) and starts from zero, so
    /// an interrupted download is dead weight rather than a head start — even
    /// with Xet disabled. Showing "3.6 GB of 4 GB done" would promise a resume
    /// that will not happen.
    private var sizeLabel: String {
        if case let .partial(bytes) = state, bytes > 0 {
            return "\(model.approximateSize) · \(ModelCatalog.formatted(bytes: bytes)) unused on disk"
        }
        return model.approximateSize
    }
}

private struct AddCustomModelView: View {
    @ObservedObject var settings: Settings
    @Environment(\.dismiss) private var dismiss
    @State private var engine: ASREngine = .whisper
    @State private var source: ASRModelSource = .huggingFace
    @State private var location = ""
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Model format") {
                    Picker("Engine", selection: $engine) {
                        ForEach(ASREngine.allCases) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    Text(engine.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("Model source") {
                    Picker("Source", selection: $source) {
                        ForEach(ASRModelSource.allCases) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)

                    if source == .huggingFace {
                        TextField("Model id (owner/model)", text: $location)
                            .textFieldStyle(.roundedBorder)
                        Text(engine == .whisper
                             ? "Example: mlx-community/whisper-small-mlx"
                             : "Use a complete Qwen3-ASR checkpoint or compatible fine-tune.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            TextField("Model folder", text: $location)
                                .textFieldStyle(.roundedBorder)
                            Button("Choose…", action: chooseFolder)
                        }
                    }

                    if let failure {
                        Text(failure)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("Custom models run locally and are never uploaded by WhisprStream.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Model", action: addModel)
                    .keyboardShortcut(.defaultAction)
                    .disabled(location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: 390)
        .onChange(of: engine) { failure = nil }
        .onChange(of: source) {
            location = ""
            failure = nil
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose Model"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        location = url.path
        failure = nil
    }

    private func addModel() {
        do {
            let added = try settings.addCustomModel(
                engine: engine,
                source: source,
                location: location
            )
            if ModelCatalog.state(for: added).isInstalled {
                settings.model = added
            }
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - Sound

private struct SoundTab: View {
    @ObservedObject var settings: Settings

    private var isPair: Bool {
        if case .pair = settings.soundTheme { return true }
        return false
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.playSound) {
                    Text("Play a sound")
                    Text(isPair
                         ? "One sound when dictation starts, its answer when the text lands."
                         : "A single sound when the text lands.")
                }

                Picker("Sound", selection: $settings.soundTheme) {
                    ForEach(SoundPair.groups, id: \.0) { name, pairs in
                        Section(name) {
                            ForEach(pairs) { pair in
                                Text(pair.label).tag(SoundTheme.pair(pair))
                            }
                        }
                    }
                    Section("macOS alert sounds") {
                        ForEach(Settings.availableSounds, id: \.self) { name in
                            Text(name).tag(SoundTheme.system(name))
                        }
                    }
                }
                .disabled(!settings.playSound)

                LabeledContent("Preview") {
                    Button {
                        settings.previewSound()
                    } label: {
                        Label(isPair ? "Play both" : "Play", systemImage: "play.fill")
                    }
                    .disabled(!settings.playSound)
                }
            } header: {
                Text("Sound")
            } footer: {
                Group {
                    if case let .pair(pair) = settings.soundTheme {
                        Text(pair.detail)
                    } else {
                        Text("These are macOS's own alert sounds, from /System/Library/Sounds. Drop an .aiff or .wav into ~/Library/Sounds and it appears here too. They play on insert only — pick a pair above to also get a sound when dictation starts.")
                    }
                }
                .foregroundStyle(.secondary)
                .font(.callout)
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: settings.soundTheme)
            }
        }
        .formStyle(.grouped)
        // Auditioning while picking is the whole point of a sound list.
        .onChange(of: settings.soundTheme) { _, _ in
            if settings.playSound { settings.previewSound() }
        }
    }
}

// MARK: - Permissions

private struct PermissionsTab: View {
    @StateObject private var permissions = Permissions()

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    title: "Microphone",
                    detail: "Required to hear you. Audio is transcribed on-device.",
                    granted: permissions.microphone == .authorized,
                    open: { permissions.openSettings(.microphone) }
                )
                PermissionRow(
                    title: "Accessibility",
                    detail: "Required to see your trigger key and paste at the cursor.",
                    granted: permissions.accessibility,
                    open: { permissions.openSettings(.accessibility) }
                )
            } header: {
                Text("Required access")
            } footer: {
                Text(permissions.allGranted
                     ? "Everything is granted. WhisprStream is ready."
                     : "This list updates by itself — leave it open while you change System Settings.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.beginPolling() }
        .onDisappear { permissions.endPolling() }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let open: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
            } else {
                Button("Open Settings", action: open)
            }
        } label: {
            Text(title)
            Text(detail)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: granted)
    }
}

// MARK: - About

private struct AboutTab: View {
    @ObservedObject var settings: Settings
    @ObservedObject var updates: AppUpdateManager
    let onShowUpdate: () -> Void

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 18) {
            WhisprStreamBrandLogo()
                .frame(width: 235, height: 34)
                .padding(.top, 34)

            VStack(spacing: 5) {
                Text("Version \(version)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Text("On-device dictation for macOS.\nHandles Chinese and English mixed in one sentence.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 30)

            VStack(spacing: 6) {
                detail("Speech model", "\(settings.model.label) · 8-bit")
                detail("Runtime", "MLX on Apple Silicon")
                detail("Audio", "Never uploaded")
            }
            .padding(.top, 4)

            AppUpdateControls(updates: updates, onShowUpdate: onShowUpdate)

            Spacer()
        }
        .onAppear {
            if case .idle = updates.status {
                updates.checkForUpdates()
            }
        }
    }

    private func detail(_ key: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 210, alignment: .leading)
        }
    }

}

private struct AppUpdateControls: View {
    @ObservedObject var updates: AppUpdateManager
    let onShowUpdate: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            switch updates.status {
            case .idle:
                Button("Check for Updates", action: updates.checkForUpdates)
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking for updates…")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            case .upToDate:
                Label("WhisprStream is up to date", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                Button("Check Again", action: updates.checkForUpdates)
                    .buttonStyle(.link)
                    .font(.caption)
            case let .available(release):
                VStack(spacing: 6) {
                    Text("Version \(release.version) is available")
                        .font(.callout.weight(.medium))
                    Button("Install and Relaunch", action: updates.installAvailableUpdate)
                    Button("View on GitHub…", action: updates.openAvailableRelease)
                        .buttonStyle(.link)
                        .font(.caption)
                    Button("Check Again", action: updates.checkForUpdates)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            case let .downloading(release):
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Downloading version \(release.version)…")
                    }
                    Button("Cancel", action: updates.cancelUpdate)
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            case let .installing(release):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Installing version \(release.version)…")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            case let .failed(message):
                VStack(spacing: 5) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Check for Updates", action: updates.checkForUpdates)
                    if updates.canOpenReleasePage {
                        Button("Open GitHub Releases…", action: updates.openAvailableRelease)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }

            if DeveloperTestMode.isAvailable {
                Divider()
                    .frame(width: 160)
                    .padding(.top, 5)
                Button("Test Available Update") {
                    updates.presentSimulatedUpdate()
                    onShowUpdate()
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("Development only — no update is downloaded or installed")
            }
        }
        .multilineTextAlignment(.center)
        .padding(.top, 4)
    }
}

struct AboutView: View {
    @ObservedObject var updates: AppUpdateManager
    let onShowUpdate: () -> Void

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 18) {
            WhisprStreamBrandLogo()
                .frame(width: 235, height: 34)
                .padding(.top, 34)

            VStack(spacing: 5) {
                Text("Version \(version)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Text("On-device dictation for macOS.\nHandles Chinese and English mixed in one sentence.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 30)

            VStack(spacing: 6) {
                // Reads the live setting: hardcoding this would quietly lie the
                // moment someone switched models in the Model tab.
                detail("Speech model", "\(Settings.shared.model.label) · 8-bit")
                detail("Runtime", "MLX on Apple Silicon")
                detail("Network", "None — audio never leaves this Mac")
            }
            .padding(.top, 4)

            AppUpdateControls(updates: updates, onShowUpdate: onShowUpdate)

            Spacer()
        }
        .frame(width: 420, height: 430)
        .background(.regularMaterial)
        .onAppear {
            if case .idle = updates.status {
                updates.checkForUpdates()
            }
        }
    }

    private func detail(_ key: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 210, alignment: .leading)
        }
    }
}
