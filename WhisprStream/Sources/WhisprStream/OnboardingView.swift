import AVFoundation
import SwiftUI

/// First-run guided setup: welcome, the two required permissions, the
/// optional system-audio permission, preferences, an opt-in for learning
/// from edits, done. The optional steps never block "Continue".
///
/// Permission state is polled rather than pushed — macOS has no callback for
/// Accessibility — so a card flips to "granted" on its own moments after the
/// user flicks the switch in System Settings, without them coming back here.
struct OnboardingView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var runtime: RuntimeManager
    @StateObject private var permissions = Permissions()
    @StateObject private var modelDownloader = ModelDownloader()

    @State private var step: Step = .welcome
    @State private var direction: CGFloat = 1
    @State private var modelReloadToken = 0
    @State private var createVoiceShortcut = false
    @State private var shortcutTrigger = ""
    @State private var shortcutReplacement = ""
    @State private var didNotifyPrerequisitesReady = false

    var onPrerequisitesReady: () -> Void
    var onFinish: () -> Void

    enum Step: Int, CaseIterable {
        case welcome, runtime, model, microphone, accessibility, systemAudio, preferences, oneWordLanguage, output, learning, voiceShortcut, ready
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Group {
                switch step {
                case .welcome: welcome
                case .runtime: runtimeStep
                case .model: modelStep
                case .microphone: microphoneStep
                case .accessibility: accessibilityStep
                case .systemAudio: systemAudioStep
                case .preferences: preferencesStep
                case .oneWordLanguage: oneWordLanguageStep
                case .output: outputStep
                case .learning: learningStep
                case .voiceShortcut: voiceShortcutStep
                case .ready: readyStep
                }
            }
            .transition(slide)
            .frame(maxWidth: 460)

            Spacer(minLength: 0)

            footer
        }
        .frame(width: 580, height: 620)
        .background(.regularMaterial)
        .onAppear {
            permissions.beginPolling()
            notifyWhenPrerequisitesAreReady()
        }
        .onDisappear { permissions.endPolling() }
        .onChange(of: runtime.isReady) { _, _ in notifyWhenPrerequisitesAreReady() }
        .onChange(of: settings.model) { _, _ in notifyWhenPrerequisitesAreReady() }
        .onChange(of: modelReloadToken) { _, _ in notifyWhenPrerequisitesAreReady() }
        .alert(
            "Clear partial model data?",
            isPresented: Binding(
                get: { modelDownloader.cleanupPrompt != nil },
                set: { if !$0 { modelDownloader.dismissCleanupPrompt() } }
            )
        ) {
            Button("Clear and Continue", role: .destructive) {
                modelDownloader.removeIncompleteDownload()
            }
            Button("Keep It", role: .cancel) { modelDownloader.dismissCleanupPrompt() }
        } message: {
            Text("This unfinished data cannot be resumed. Clearing it frees space for a fresh download and does not affect installed models or settings.")
        }
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
            Text("This replaces the engine only. Your models, preferences, vocabulary, and shortcuts will stay on this Mac.")
        }
    }

    private var slide: AnyTransition {
        .asymmetric(
            insertion: .offset(x: 40 * direction).combined(with: .opacity),
            removal: .offset(x: -40 * direction).combined(with: .opacity)
        )
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 22) {
            AnimatedMark()
                .frame(width: 96, height: 96)

            VStack(spacing: 10) {
                Text("WhisprStream")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Requires macOS 14 or later and an Apple-silicon Mac.\nProcessing stays on your Mac.")
                    .font(.system(size: 14.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
        }
    }

    private var microphoneStep: some View {
        StepLayout(
            icon: "mic.fill",
            title: "Microphone access",
            blurb: "WhisprStream needs to hear you. Audio is transcribed on-device and never leaves your Mac."
        ) {
            PermissionCard(
                title: "Microphone",
                granted: permissions.microphone == .authorized,
                denied: permissions.microphone == .denied,
                action: { permissions.requestMicrophone() }
            )
        }
    }

    private var runtimeStep: some View {
        StepLayout(
            icon: "cpu",
            title: "Install the speech engine",
            blurb: "The engine is installed once, keeping app updates small\nand your audio on your Mac."
        ) {
            VStack(spacing: 14) {
                switch runtime.phase {
                case .ready:
                    VStack(spacing: 8) {
                        Label(
                            runtime.isUsingDevelopmentEngine ? "Development engine ready" : "Speech engine ready",
                            systemImage: "checkmark.circle.fill"
                        )
                            .foregroundStyle(.green)
                        if runtime.canManageEngineInstallation && !runtime.isDeveloperTestMode {
                            Button("Repair / Reinstall") { runtime.install() }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                case .checking:
                    ProgressView("Checking speech engine…")
                case .checkingStorage:
                    ProgressView("Checking storage…")
                case let .insufficientStorage(required, available):
                    VStack(spacing: 8) {
                        Text("Not enough storage").font(.headline)
                        Text("Need \(StorageCapacity.formatted(required)); \(StorageCapacity.formatted(available)) available.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Manage Storage…") { StorageCapacity.openStorageSettings() }
                            Button("Try Again") { runtime.install() }
                        }
                    }
                case .downloading:
                    ProgressView("Downloading speech engine…")
                    Button("Cancel") { runtime.cancelInstall() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                case .verifying:
                    ProgressView("Verifying speech engine…")
                case .installing:
                    ProgressView("Installing speech engine…")
                case .missing:
                    if runtime.canManageEngineInstallation {
                        Button("Download speech engine") { runtime.install() }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                    if let summary = runtime.storageSummary {
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = runtime.installMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                case let .failed(message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button("Try Again") { runtime.install() }
                case let .incompatible(message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    if runtime.canManageEngineInstallation {
                        Button("Repair / Reinstall") { runtime.install() }
                    }
                }
            }
        }
    }

    private var modelStep: some View {
        StepLayout(
            icon: "waveform.badge.mic",
            title: "Download a speech model",
            blurb: "The engine runs the app. The model recognizes your voice, so it is downloaded separately and stays on your Mac."
        ) {
            VStack(spacing: 12) {
                ForEach(ASRModel.allCases) { model in
                    onboardingModelRow(model)
                }

                if let preflight = modelDownloader.preflight,
                   modelDownloader.active != nil {
                    Text("Available: \(StorageCapacity.formatted(preflight.availableBytes)) · model files: \(StorageCapacity.formatted(preflight.totalBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(ModelCatalog.hardwareGuidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let failure = modelDownloader.failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .onAppear {
                modelDownloader.onFinish = { model, succeeded in
                    if succeeded { settings.model = model }
                    modelReloadToken &+= 1
                }
            }
        }
    }

    private func onboardingModelRow(_ model: ASRModel) -> some View {
        let state = modelInstallState(model)
        let downloading = modelDownloader.active == model
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(model.label).font(.system(size: 13.5, weight: .medium))
                    if model == .small {
                        Text("RECOMMENDED")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.13), in: Capsule())
                    }
                }
                Text("\(model.approximateSize) · \(model == .small ? "Fastest, recommended" : "Larger and slower")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            if downloading && modelDownloader.phase != .awaitingCleanup {
                VStack(alignment: .trailing, spacing: 4) {
                    if let fraction = modelDownloader.fraction {
                        ProgressView(value: fraction).frame(width: 116)
                        Text("\(StorageCapacity.formatted(modelDownloader.received)) of \(StorageCapacity.formatted(modelDownloader.total))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView("Checking storage…").controlSize(.small)
                    }
                    Button("Cancel") { modelDownloader.cancel() }.controlSize(.small)
                }
            } else if modelDownloader.active == model && modelDownloader.phase == .awaitingCleanup {
                VStack(alignment: .trailing, spacing: 6) {
                    Label(
                        "\(StorageCapacity.formatted(modelDownloader.preflight?.incompleteBytes ?? 0)) partial",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Clear and Continue…") { modelDownloader.requestCleanup() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    HStack(spacing: 10) {
                        Button("Keep and Continue") { modelDownloader.downloadAnyway() }
                            .buttonStyle(.link)
                        Button("Cancel") { modelDownloader.cancel() }
                            .buttonStyle(.link)
                    }
                    .font(.caption)
                }
            } else if state.isInstalled {
                Button(settings.model == model ? "Selected" : "Use") {
                    settings.model = model
                }
                .disabled(settings.model == model)
            } else {
                Button("Download") { modelDownloader.start(model) }
                    .disabled(modelDownloader.isRunning)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func modelInstallState(_ model: ASRModel) -> ModelInstallState {
        _ = modelReloadToken
        return ModelCatalog.state(for: model)
    }

    /// Start the expensive model warm-up as soon as both downloads are done.
    /// The remaining permission and preference steps usually hide the entire
    /// cold-start cost before the user reaches "Start Dictating".
    private func notifyWhenPrerequisitesAreReady() {
        guard !didNotifyPrerequisitesReady,
              runtime.isReady,
              modelInstallState(settings.model).isInstalled else { return }
        didNotifyPrerequisitesReady = true
        onPrerequisitesReady()
    }

    private var accessibilityStep: some View {
        StepLayout(
            icon: "hand.raised.fill",
            title: "Accessibility access",
            blurb: "This lets WhisprStream see your trigger key from any app, and paste the transcript where your cursor is."
        ) {
            VStack(spacing: 14) {
                PermissionCard(
                    title: "Accessibility",
                    granted: permissions.accessibility,
                    denied: false,
                    action: { permissions.requestAccessibility() }
                )

                if !permissions.accessibility {
                    Text("In System Settings, switch on **WhisprStream** under Privacy & Security → Accessibility. This window updates by itself.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .transition(.opacity)
                }
            }
        }
    }

    /// Optional. macOS routes system audio through Screen & System Audio
    /// Recording, so the grant is offered where the feature is introduced,
    /// but never required: Continue works without it, and Settings →
    /// Permissions offers the same grant later.
    private var systemAudioStep: some View {
        StepLayout(
            icon: "play.rectangle",
            title: "Transcribe what your Mac plays",
            blurb: "Optional. Dictate videos, calls, and podcasts. Only audio is captured."
        ) {
            VStack(spacing: 14) {
                PermissionCard(
                    title: "Screen & System Audio Recording",
                    granted: permissions.screenCapture,
                    denied: false,
                    action: { permissions.requestScreenCapture() }
                )

                if permissions.screenCapture {
                    Text("Press **⌥S** while dictating to switch sources.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .transition(.opacity)
                } else {
                    Text("You can skip this. Mic dictation doesn't need it.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .transition(.opacity)
                }
            }
        }
    }

    private var preferencesStep: some View {
        StepLayout(
            icon: "slider.horizontal.3",
            title: "How would you like to talk?",
            blurb: "You can change this any time from the menu bar."
        ) {
            VStack(spacing: 18) {
                ModePicker(settings: settings)
                KeyPicker(settings: settings)
            }
        }
        // Animate the page as one layer so the Picker and selection cards do
        // not mount or fade independently during the onboarding transition.
        .compositingGroup()
    }

    private var oneWordLanguageStep: some View {
        StepLayout(
            icon: "character.bubble",
            title: "One-word dictation language",
            blurb: "Choose how very short, one-word clips are recognized. Normal dictation continues to detect languages automatically."
        ) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "waveform")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Normal dictation")
                            .font(.system(size: 14, weight: .medium))
                        Text("Sentences and longer clips")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("Automatic")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(16)

                Divider().padding(.leading, 54)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        Image(systemName: "text.cursor")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24)

                        Text("One-word dictation")
                            .font(.system(size: 14, weight: .medium))

                        Spacer()

                        Picker("Language", selection: $settings.shortUtteranceLanguage) {
                            ForEach(ShortUtteranceLanguage.allCases) { language in
                                Text(language.modelName).tag(language)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }

                    Text("Automatic multilingual keeps the language you speak, even when it differs from nearby text or your keyboard. Choose a fixed language only when you need strict control for isolated words.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 38)
                }
                .padding(16)
            }
            .onboardingSurface()
            .frame(width: 430)
        }
    }

    private var outputStep: some View {
        StepLayout(
            icon: "text.badge.checkmark",
            title: "Make every dictation useful",
            blurb: "Choose where finished text goes. You can change this any time."
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Text("OUTPUT")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.top, 15)
                    .padding(.bottom, 7)

                OnboardingToggleRow(
                    symbol: "cursorarrow.rays",
                    title: "Insert at cursor",
                    detail: "Place finished text in the app you are using.",
                    isOn: $settings.autoInsert
                )
                Divider().padding(.leading, 54)
                OnboardingToggleRow(
                    symbol: "doc.on.clipboard",
                    title: "Copy to clipboard",
                    detail: "Keep a backup ready to paste anywhere.",
                    isOn: $settings.copyToClipboard
                )
                Divider().padding(.leading, 54)
                OnboardingToggleRow(
                    symbol: "text.quote",
                    title: "Use punctuation",
                    detail: "Keep sentence endings in your dictation.",
                    isOn: $settings.usePunctuation
                )
                Color.clear.frame(height: 12)
            }
            .onboardingSurface()
            .frame(width: 430)
        }
    }

    /// Opt-in, off by default. Learning from edits reads the pasted-into field
    /// through the Accessibility grant already made and keeps the sample on
    /// this Mac, so this step is consent and explanation, not a permission.
    private var learningStep: some View {
        StepLayout(
            icon: "sparkles",
            title: "Help WhisprStream learn",
            blurb: "Optional. Fix a word after dictating, and WhisprStream learns from it."
        ) {
            VStack(spacing: 12) {
                OnboardingToggleRow(
                    symbol: "pencil.line",
                    title: "Learn from my edits",
                    detail: "Stays on this Mac. Review or delete anytime in Settings.",
                    isOn: $settings.captureCorrections
                )
                .padding(.vertical, 4)
                .onboardingSurface()
            }
            .frame(width: 430)
        }
    }

    private var voiceShortcutStep: some View {
        StepLayout(
            icon: "quote.bubble",
            title: "Add a phrase that does more",
            blurb: "Voice Shortcuts turn a phrase you say into text you use often."
        ) {
            Group {
                if createVoiceShortcut {
                    shortcutEditor
                } else {
                    shortcutInvitation
                }
            }
            .frame(width: 420)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: createVoiceShortcut)
        }
    }

    private var shortcutInvitation: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Say it once. Insert it anywhere.")
                    .font(.system(size: 14, weight: .semibold))
                Text("Save phrases for prompts, signatures, links, and more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VoiceShortcutDemo()
            Button("Create a shortcut") { createVoiceShortcut = true }
                .buttonStyle(PrimaryButtonStyle())
            Text("Optional — you can also set this up later in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .onboardingSurface()
    }

    private var shortcutEditor: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(systemName: "quote.bubble.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Your first voice shortcut")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Not now") { createVoiceShortcut = false }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("WHEN I SAY")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                TextField("e.g. shortcut address", text: $shortcutTrigger)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("INSERT THIS")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                TextField("e.g. 123 Main Street", text: $shortcutReplacement)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Use a distinctive phrase so normal dictation does not trigger it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = shortcutValidationError {
                Text(shortcutValidationMessage(error))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(18)
        .onboardingSurface()
    }

    private var readyStep: some View {
        VStack(spacing: 24) {
            SuccessMark()
                .frame(width: 88, height: 88)

            VStack(spacing: 10) {
                Text(permissions.allGranted ? "You're all set" : "Finish setup later")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))

                Text(readyBlurb)
                    .font(.system(size: 14.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
        }
    }

    private var readyBlurb: String {
        guard permissions.allGranted else {
            return "Your engine and model are ready. Grant Microphone and Accessibility in System Settings before dictating."
        }
        switch settings.activationMode {
        case .hold:
            return "Hold \(settings.triggerShortcut.compactDisplay) anywhere, speak,\nand let go. Your words appear at the cursor."
        case .tap:
            return "Tap \(settings.triggerShortcut.compactDisplay) to start, speak,\nand tap again. Your words appear at the cursor."
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 18) {
            ProgressDots(count: Step.allCases.count, index: step.rawValue)

            HStack(spacing: 12) {
                if step != .welcome {
                    Button("Back") { go(back: true) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if canSkip {
                    Button("Skip for now") { go(back: false) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }

                Button(primaryLabel) {
                    if step == .ready { finishOnboarding() } else { go(back: false) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            }
            .font(.system(size: 13.5, weight: .medium))
        }
        .padding(.horizontal, 34)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity)
    }

    private var canSkip: Bool {
        switch step {
        case .microphone: return permissions.microphone != .authorized
        case .accessibility: return !permissions.accessibility
        default: return false
        }
    }

    private var primaryLabel: String {
        switch step {
        case .welcome: return "Get Started"
        case .ready: return permissions.allGranted ? "Start Dictating" : "Finish Setup"
        default: return "Continue"
        }
    }

    private var canContinue: Bool {
        switch step {
        case .runtime: return runtime.isReady
        case .model: return modelInstallState(settings.model).isInstalled
        case .voiceShortcut: return shortcutValidationError == nil
        default: return true
        }
    }

    private var shortcutValidationError: VoiceShortcutValidationError? {
        guard createVoiceShortcut else { return nil }
        let shortcut = VoiceShortcut(
            id: UUID(),
            trigger: shortcutTrigger,
            replacement: shortcutReplacement,
            isEnabled: true
        )
        do {
            try VoiceShortcutValidation.validate(shortcut, against: settings.voiceShortcuts)
            return nil
        } catch let error as VoiceShortcutValidationError {
            return error
        } catch {
            return .emptyTrigger
        }
    }

    private func shortcutValidationMessage(_ error: VoiceShortcutValidationError) -> String {
        switch error {
        case .emptyTrigger: "Add a phrase to say."
        case .emptyReplacement: "Add the text this shortcut should insert."
        case .duplicateTrigger: "That phrase is already used by another shortcut."
        }
    }

    private func finishOnboarding() {
        if createVoiceShortcut {
            let shortcut = VoiceShortcut(
                id: UUID(),
                trigger: shortcutTrigger,
                replacement: shortcutReplacement,
                isEnabled: true
            )
            do {
                try settings.addVoiceShortcut(shortcut)
            } catch {
                Log.write("onboarding voice shortcut save rejected: \(error)")
                return
            }
        }
        onFinish()
    }

    private func go(back: Bool) {
        direction = back ? -1 : 1
        let next = step.rawValue + (back ? -1 : 1)
        guard let target = Step(rawValue: next) else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            step = target
        }
    }
}

// MARK: - Layout

private struct StepLayout<Content: View>: View {
    let icon: String
    let title: String
    let blurb: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(height: 44)

            VStack(spacing: 9) {
                Text(title)
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                Text(blurb)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)

            content
                .padding(.top, 6)
        }
    }
}

private struct OnboardingToggleRow: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 18)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

/// A small, repeating illustration of a phrase becoming saved text. It gives
/// first-time users a concrete reason to create a Voice Shortcut before asking
/// them to fill in any fields.
private struct VoiceShortcutDemo: View {
    private struct Example {
        let trigger: String
        let result: String
        let resultSymbol: String
    }

    private let examples = [
        Example(
            trigger: "magic GitHub",
            result: "https://github.com/your-name",
            resultSymbol: "link"
        ),
        Example(
            trigger: "shortcut intro",
            result: "Hi — great to meet you. Here’s a little about me…",
            resultSymbol: "text.quote"
        ),
        Example(
            trigger: "magic address",
            result: "123 Main Street, Toronto",
            resultSymbol: "mappin.and.ellipse"
        ),
    ]

    @State private var isSpeaking = false
    @State private var showsResult = false
    @State private var exampleIndex = 0

    private var example: Example { examples[exampleIndex] }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .scaleEffect(isSpeaking ? 1.16 : 0.92)
                Text(example.trigger)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.28), value: exampleIndex)
                Spacer()
                WaveBars(isActive: isSpeaking)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))

            Image(systemName: "arrow.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor.opacity(showsResult ? 1 : 0.35))
                .offset(y: showsResult ? 1 : -2)

            HStack(spacing: 7) {
                Image(systemName: example.resultSymbol)
                    .foregroundStyle(.secondary)
                Text(example.result)
                    .lineLimit(1)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.28), value: exampleIndex)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            .opacity(showsResult ? 1 : 0)
            .offset(y: showsResult ? 0 : -3)
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .task {
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.35)) {
                    isSpeaking = true
                    showsResult = false
                }
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                    isSpeaking = false
                    showsResult = true
                }
                try? await Task.sleep(nanoseconds: 2_100_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    showsResult = false
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                // Fade the phrase itself into the next custom example only
                // after its previous inserted text has cleared.
                withAnimation(.easeInOut(duration: 0.28)) {
                    exampleIndex = (exampleIndex + 1) % examples.count
                }
            }
        }
    }
}

private struct WaveBars: View {
    let isActive: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 2.5, height: isActive ? CGFloat(7 + (index % 2) * 6) : 4)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isActive)
    }
}

private extension View {
    func onboardingSurface() -> some View {
        background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
            .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
    }
}

// MARK: - Permission card

private struct PermissionCard: View {
    let title: String
    let granted: Bool
    let denied: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(granted ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12))
                    .frame(width: 34, height: 34)

                Image(systemName: granted ? "checkmark" : "lock.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(granted ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Text(granted ? "Granted" : (denied ? "Denied — open System Settings" : "Not granted yet"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 12)

            if !granted {
                Button("Grant", action: action)
                    .buttonStyle(PrimaryButtonStyle(compact: true))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            granted ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.07),
                            lineWidth: 1
                        )
                }
        }
        .frame(width: 400)
        .animation(.spring(response: 0.34, dampingFraction: 0.75), value: granted)
    }
}

// MARK: - Pickers

struct ModePicker: View {
    @ObservedObject var settings: Settings

    var body: some View {
        HStack(spacing: 12) {
            ForEach(ActivationMode.allCases) { mode in
                let selected = settings.activationMode == mode
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                        settings.activationMode = mode
                    }
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 20, weight: .medium))
                        Text(mode.label)
                            .font(.system(size: 13, weight: .medium))
                        Text(mode.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: 176, height: 116)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.045))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(
                                        selected ? Color.accentColor : Color.primary.opacity(0.07),
                                        lineWidth: selected ? 1.5 : 1
                                    )
                            }
                    }
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
                .scaleEffect(selected ? 1.0 : 0.97)
            }
        }
    }
}

struct KeyPicker: View {
    @ObservedObject var settings: Settings

    var body: some View {
        HStack(spacing: 10) {
            Text("Recording shortcut")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TriggerShortcutEditor(settings: settings, compact: true)
        }
    }
}

// MARK: - Decorations

private struct ProgressDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Color.accentColor : Color.secondary.opacity(0.28))
                    .frame(width: i == index ? 20 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: index)
    }
}

/// Waveform bars that idle in a gentle loop — the welcome screen's mark.
private struct AnimatedMark: View {
    @State private var animating = false
    private let heights: [CGFloat] = [0.35, 0.62, 1.0, 0.72, 0.45]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(heights.indices, id: \.self) { i in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: 8, height: 64 * heights[i] * (animating ? 1.0 : 0.42))
                    .animation(
                        .easeInOut(duration: 0.72)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.09),
                        value: animating
                    )
            }
        }
        .frame(height: 76)
        .onAppear { animating = true }
    }
}

/// Checkmark that draws itself in, then settles.
private struct SuccessMark: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.15))
                .scaleEffect(appeared ? 1 : 0.5)
                .opacity(appeared ? 1 : 0)

            Image(systemName: "checkmark")
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .scaleEffect(appeared ? 1 : 0.3)
                .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { appeared = true }
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12.5 : 13.5, weight: .semibold))
            .foregroundStyle(isEnabled ? .white : .secondary)
            .padding(.horizontal, compact ? 14 : 20)
            .padding(.vertical, compact ? 6 : 9)
            .background {
                Capsule().fill(isEnabled ? Color.accentColor : Color.secondary.opacity(0.16))
            }
            .opacity(configuration.isPressed && isEnabled ? 0.78 : 1)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.7), value: configuration.isPressed && isEnabled)
    }
}
