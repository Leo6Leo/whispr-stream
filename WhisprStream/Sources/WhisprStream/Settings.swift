import AppKit
import SwiftUI

/// Modifier keys usable for push-to-talk.
///
/// Only modifiers are offered: they arrive as `.flagsChanged` and don't collide
/// with an app's own keyboard shortcuts the way a plain letter key would.
enum TriggerKey: String, CaseIterable, Identifiable, Codable {
    case rightOption, leftOption, rightCommand, rightControl, function

    var id: String { rawValue }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .leftOption: return 58
        case .rightCommand: return 54
        case .rightControl: return 62
        case .function: return 63
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption, .leftOption: return .option
        case .rightCommand: return .command
        case .rightControl: return .control
        case .function: return .function
        }
    }

    var label: String {
        switch self {
        case .rightOption: return "Right Option"
        case .leftOption: return "Left Option"
        case .rightCommand: return "Right Command"
        case .rightControl: return "Right Control"
        case .function: return "Fn"
        }
    }

    var symbol: String {
        switch self {
        case .rightOption, .leftOption: return "⌥"
        case .rightCommand: return "⌘"
        case .rightControl: return "⌃"
        case .function: return "fn"
        }
    }
}

enum ActivationMode: String, CaseIterable, Identifiable {
    case hold, tap

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hold: return "Hold to talk"
        case .tap: return "Tap to toggle"
        }
    }

    var detail: String {
        switch self {
        case .hold: return "Hold the key while speaking, release to insert."
        case .tap: return "Tap once to start, tap again to stop and insert."
        }
    }

    var symbol: String {
        switch self {
        case .hold: return "hand.tap.fill"
        case .tap: return "cursorarrow.click.2"
        }
    }
}

/// Optional language guidance for clips too short to provide reliable language
/// context. Automatic mode preserves multilingual recognition at every length;
/// fixed choices remain available for isolated words that need a tie-breaker.
enum ShortUtteranceLanguage: String, CaseIterable, Identifiable {
    case automaticMultilingual
    case chinese, english, cantonese, arabic, german, french, spanish
    case portuguese, indonesian, italian, korean, russian, thai, vietnamese
    case japanese, turkish, hindi, malay, dutch, swedish, danish, finnish
    case polish, czech, filipino, persian, greek, hungarian, macedonian, romanian

    var id: String { rawValue }

    /// User-facing picker labels. Fixed choices also match Qwen3-ASR's
    /// canonical forced-language names.
    var modelName: String {
        switch self {
        case .automaticMultilingual: return "Automatic multilingual"
        case .chinese: return "Chinese"
        case .english: return "English"
        case .cantonese: return "Cantonese"
        case .arabic: return "Arabic"
        case .german: return "German"
        case .french: return "French"
        case .spanish: return "Spanish"
        case .portuguese: return "Portuguese"
        case .indonesian: return "Indonesian"
        case .italian: return "Italian"
        case .korean: return "Korean"
        case .russian: return "Russian"
        case .thai: return "Thai"
        case .vietnamese: return "Vietnamese"
        case .japanese: return "Japanese"
        case .turkish: return "Turkish"
        case .hindi: return "Hindi"
        case .malay: return "Malay"
        case .dutch: return "Dutch"
        case .swedish: return "Swedish"
        case .danish: return "Danish"
        case .finnish: return "Finnish"
        case .polish: return "Polish"
        case .czech: return "Czech"
        case .filipino: return "Filipino"
        case .persian: return "Persian"
        case .greek: return "Greek"
        case .hungarian: return "Hungarian"
        case .macedonian: return "Macedonian"
        case .romanian: return "Romanian"
        }
    }

    /// A fixed Qwen language name, or nil when the model should infer the
    /// spoken language directly from the audio.
    var fixedModelLanguage: String? {
        self == .automaticMultilingual ? nil : modelName
    }

    /// Decode both the current stored value and names used by earlier builds.
    /// The old smart mode guessed from cursor/keyboard context; migrate it to
    /// automatic audio detection so writing context cannot force-translate a
    /// language switch.
    static func persistedValue(_ rawValue: String?) -> Self {
        switch rawValue {
        case "smartEnglishChinese", "automatic":
            return .automaticMultilingual
        case let rawValue?:
            return Self(rawValue: rawValue) ?? .automaticMultilingual
        case nil:
            return .automaticMultilingual
        }
    }
}

/// User preferences, persisted to UserDefaults.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var triggerShortcut: TriggerShortcut {
        didSet {
            guard triggerShortcut != oldValue else { return }
            persistTriggerShortcut()
            onHotKeyConfigurationChange?()
        }
    }

    @Published var activationMode: ActivationMode {
        didSet {
            guard activationMode != oldValue else { return }
            defaults.set(activationMode.rawValue, forKey: Keys.activationMode)
            onHotKeyConfigurationChange?()
        }
    }

    /// Insert the transcript at the active app's cursor.
    @Published var autoInsert: Bool {
        didSet { defaults.set(autoInsert, forKey: Keys.autoInsert) }
    }

    /// Keep the finished transcript on the clipboard after dictation.
    @Published var copyToClipboard: Bool {
        didSet { defaults.set(copyToClipboard, forKey: Keys.copyToClipboard) }
    }

    @Published var reviewUncertainWords: Bool {
        didSet { defaults.set(reviewUncertainWords, forKey: Keys.reviewUncertainWords) }
    }

    @Published var learnFromCorrections: Bool {
        didSet {
            defaults.set(learnFromCorrections, forKey: Keys.learnFromCorrections)
            onLearningChange?()
        }
    }

    var onLearningChange: (() -> Void)?

    /// Keep sentence-ending punctuation from the speech model. When disabled,
    /// finished dictations end with a space instead so the next dictation does
    /// not run into the previous one.
    @Published var usePunctuation: Bool {
        didSet { defaults.set(usePunctuation, forKey: Keys.usePunctuation) }
    }

    /// Match the transcript's opening capitalization to text at the active
    /// cursor. Apps without readable cursor context use a guarded keyboard
    /// probe that must finish before the transcript is inserted.
    @Published var contextAwareCapitalization: Bool {
        didSet {
            defaults.set(
                contextAwareCapitalization,
                forKey: Keys.contextAwareCapitalization
            )
        }
    }

    /// A user-selected tie-breaker for context-poor, very short recordings.
    /// Changing it restarts the sidecar because preview reuse must never cross
    /// between forced- and automatically-detected language modes.
    @Published var shortUtteranceLanguage: ShortUtteranceLanguage {
        didSet {
            guard shortUtteranceLanguage != oldValue else { return }
            defaults.set(shortUtteranceLanguage.rawValue, forKey: Keys.shortUtteranceLanguage)
            onShortUtteranceLanguageChange?(shortUtteranceLanguage)
        }
    }

    @Published var playSound: Bool {
        didSet { defaults.set(playSound, forKey: Keys.playSound) }
    }

    /// Which sound plays around a dictation — a designed pair, or one of
    /// macOS's own alert sounds as before.
    @Published var soundTheme: SoundTheme {
        didSet {
            defaults.set(soundTheme.storageValue, forKey: Keys.soundTheme)
            warm(soundTheme)
        }
    }

    /// Every playable macOS alert sound, system then user.
    static var availableSounds: [String] { SoundPlayer.available }

    /// Registers the files up front so the first play isn't slower than the rest.
    private func warm(_ theme: SoundTheme) {
        switch theme {
        case let .pair(pair):
            SoundPlayer.shared.prepareBundled(pair.startFile)
            SoundPlayer.shared.prepareBundled(pair.finishFile)
        case let .system(name):
            SoundPlayer.shared.prepare(name)
        }
    }

    /// Called when dictation begins.
    ///
    /// Only pairs have a start half. A macOS alert sound stays finish-only, which
    /// is exactly how the app behaved before pairs existed.
    func playStart() {
        guard playSound, case let .pair(pair) = soundTheme else { return }
        SoundPlayer.shared.playBundled(pair.startFile)
    }

    /// Called when a transcript is inserted.
    func playFeedback() {
        guard playSound else { return }
        playFinishSound()
    }

    private func playFinishSound() {
        switch soundTheme {
        case let .pair(pair): SoundPlayer.shared.playBundled(pair.finishFile)
        case let .system(name): SoundPlayer.shared.play(name)
        }
    }

    /// Auditions the whole cycle: start, then finish once the start has rung.
    ///
    /// Ignores the enable toggle — the user pressed the button, so they want to
    /// hear it.
    func previewSound() {
        guard case let .pair(pair) = soundTheme else {
            playFinishSound()
            return
        }
        SoundPlayer.shared.playBundled(pair.startFile)
        let gap = pair.startDuration + 0.28
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) { [weak self] in
            self?.playFinishSound()
        }
    }

    /// Vocabulary entries used to bias decoding. Each entry may be a word or a
    /// phrase; the array is the source of truth so spaces do not become data
    /// delimiters.
    ///
    /// The running sidecar receives a newline-separated prompt whenever this
    /// array changes. Persisting alone is not enough: the sidecar reads its
    /// startup value from the environment, so edits must also be pushed live.
    @Published private(set) var vocabularyEntries: [String] {
        didSet {
            defaults.set(vocabularyEntries, forKey: Keys.vocabularyEntries)
            onContextChange?(asrContext)
        }
    }

    /// Vocabulary plus enabled Voice Shortcut triggers, sent to the resident
    /// ASR sidecar as newline-separated soft recognition context.
    var asrContext: String {
        var lines: [String] = []
        var seen = Set<String>()
        for line in vocabularyEntries + voiceShortcuts.filter(\.isEnabled).map(\.trigger) {
            guard seen.insert(line).inserted else { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    @Published private(set) var voiceShortcuts: [VoiceShortcut] {
        didSet {
            guard voiceShortcuts != oldValue else { return }
            persistVoiceShortcuts()
            onContextChange?(asrContext)
        }
    }

    func addVoiceShortcut(_ shortcut: VoiceShortcut) throws {
        try VoiceShortcutValidation.validate(shortcut, against: voiceShortcuts)
        voiceShortcuts.append(shortcut)
    }

    func updateVoiceShortcut(_ shortcut: VoiceShortcut) throws {
        try VoiceShortcutValidation.validate(
            shortcut,
            against: voiceShortcuts,
            excluding: shortcut.id
        )
        guard let index = voiceShortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        voiceShortcuts[index] = shortcut
    }

    func removeVoiceShortcut(id: UUID) {
        voiceShortcuts.removeAll { $0.id == id }
    }

    func setVoiceShortcutEnabled(id: UUID, enabled: Bool) {
        guard let index = voiceShortcuts.firstIndex(where: { $0.id == id }),
              voiceShortcuts[index].isEnabled != enabled else { return }
        voiceShortcuts[index].isEnabled = enabled
    }

    /// Replaces the complete shortcut list after validating the same invariants
    /// as the editor. Used by import so invalid or duplicate triggers can never
    /// bypass normal shortcut validation.
    func setVoiceShortcuts(_ shortcuts: [VoiceShortcut]) throws {
        var validated: [VoiceShortcut] = []
        for shortcut in shortcuts {
            try VoiceShortcutValidation.validate(shortcut, against: validated)
            validated.append(shortcut)
        }
        voiceShortcuts = validated
    }

    private func persistVoiceShortcuts() {
        guard let data = try? JSONEncoder().encode(voiceShortcuts) else {
            Log.write("voice shortcuts save failed")
            return
        }
        defaults.set(data, forKey: Keys.voiceShortcuts)
    }

    /// Replaces the complete vocabulary after applying the same normalization
    /// and case-sensitive de-duplication used by manual entry and imports.
    func setVocabulary(_ entries: [String]) {
        vocabularyEntries = VocabularyEntry.normalizedUnique(entries)
    }

    /// User-added model definitions. The weights themselves remain in the
    /// selected local folder or Hugging Face cache.
    @Published private(set) var customModels: [ASRModel] {
        didSet {
            guard FeatureFlags.optionalModelsEnabled else { return }
            persistCustomModels()
        }
    }

    var availableModels: [ASRModel] {
        FeatureFlags.optionalModelsEnabled
            ? ASRModel.allCases + customModels
            : ASRModel.allCases
    }

    /// Which speech model the sidecar loads.
    ///
    /// Unlike the vocabulary this cannot be applied live — the weights are loaded
    /// once at sidecar start — so changing it restarts the sidecar and pays the
    /// model load again.
    @Published var model: ASRModel {
        didSet {
            guard FeatureFlags.optionalModelsEnabled || model.isBuiltIn else {
                // A public build may inherit an experimental preference from a
                // developer build. Keep that preference stored for developers,
                // but never select or launch it in the public product.
                model = oldValue.isBuiltIn ? oldValue : .small
                return
            }
            guard model != oldValue else { return }
            if let data = try? JSONEncoder().encode(model) {
                defaults.set(data, forKey: Keys.selectedModel)
            }
            // Keep the original key current for backwards compatibility with
            // older builds and the existing preferences migration.
            defaults.set(model.rawValue, forKey: Keys.model)
            onModelChange?(model)
        }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarded) }
    }

    /// Remains true until the first-dictation invitation is either displayed
    /// or made unnecessary by the user starting a dictation themselves.
    /// Keeping this separate from onboarding lets a user grant permissions
    /// after setup (or after relaunching) without losing the invitation.
    @Published var needsFirstDictationCoach: Bool {
        didSet { defaults.set(needsFirstDictationCoach, forKey: Keys.firstDictationCoachPending) }
    }

    /// True while the sidecar is reloading after a model switch. Drives the
    /// Settings UI only; dictation can capture audio during the reload.
    @Published var isReloadingModel = false

    /// Fired when a change requires the hotkey monitor to be rebound.
    var onHotKeyConfigurationChange: (() -> Void)?

    /// True while the local shortcut recorder owns keyboard input.
    /// This state is intentionally transient and is not persisted.
    @Published private(set) var isCapturingTriggerShortcut = false
    private var triggerShortcutCaptureCount = 0

    /// Fired when the recorder starts or ends so the global hotkey monitor can
    /// get out of the way of the Settings/onboarding window.
    var onTriggerShortcutCaptureChange: ((Bool) -> Void)?

    /// Fired when vocabulary or Voice Shortcuts change, to push the combined
    /// context to the live sidecar.
    var onContextChange: ((String) -> Void)?

    /// Fired when the model changes, to restart the sidecar on the new weights.
    var onModelChange: ((ASRModel) -> Void)?

    /// Fired when short-utterance language guidance changes. Like the model,
    /// this is a sidecar startup option and therefore requires a restart.
    var onShortUtteranceLanguageChange: ((ShortUtteranceLanguage) -> Void)?

    private let defaults: UserDefaults

    private enum Keys {
        static let triggerKey = "triggerKey"
        static let triggerShortcut = "triggerShortcut.v1"
        static let activationMode = "activationMode"
        static let autoInsert = "autoInsert"
        static let copyToClipboard = "copyToClipboard"
        static let reviewUncertainWords = "reviewUncertainWords.v1"
        static let learnFromCorrections = "learnFromCorrections.v1"
        static let usePunctuation = "usePunctuation"
        static let contextAwareCapitalization = "contextAwareCapitalization"
        static let shortUtteranceLanguage = "shortUtteranceLanguage"
        static let playSound = "playSound"
        static let insertSound = "insertSound"   // pre-pairs; read once to migrate
        static let soundTheme = "soundTheme"
        static let contextTerms = "contextTerms"
        static let vocabularyEntries = "vocabularyEntries"
        static let voiceShortcuts = "voiceShortcuts.v1"
        static let model = "model"
        static let selectedModel = "selectedModel.v2"
        static let customModels = "customModels.v1"
        static let onboarded = "hasCompletedOnboarding"
        static let firstDictationCoachPending = "needsFirstDictationCoach"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedShortcut: TriggerShortcut? = {
            guard let data = defaults.data(forKey: Keys.triggerShortcut) else { return nil }
            do {
                let shortcut = try JSONDecoder().decode(TriggerShortcut.self, from: data)
                guard let validated = TriggerShortcut.validated(shortcut) else {
                    Log.write("trigger shortcut is invalid; trying legacy setting")
                    return nil
                }
                return validated
            } catch {
                Log.write("trigger shortcut load failed; trying legacy setting")
                return nil
            }
        }()
        let legacyShortcut = TriggerKey(
            rawValue: defaults.string(forKey: Keys.triggerKey) ?? ""
        ).map(TriggerShortcut.modifierOnly)
        triggerShortcut = storedShortcut ?? legacyShortcut ?? .defaultValue
        activationMode = ActivationMode(rawValue: defaults.string(forKey: Keys.activationMode) ?? "")
            ?? .hold
        autoInsert = defaults.object(forKey: Keys.autoInsert) as? Bool ?? true
        copyToClipboard = defaults.object(forKey: Keys.copyToClipboard) as? Bool ?? true
        reviewUncertainWords = defaults.bool(forKey: Keys.reviewUncertainWords)
        learnFromCorrections = defaults.bool(forKey: Keys.learnFromCorrections)
        usePunctuation = defaults.object(forKey: Keys.usePunctuation) as? Bool ?? true
        contextAwareCapitalization = defaults.object(
            forKey: Keys.contextAwareCapitalization
        ) as? Bool ?? false
        shortUtteranceLanguage = ShortUtteranceLanguage.persistedValue(
            defaults.string(forKey: Keys.shortUtteranceLanguage)
        )
        playSound = defaults.object(forKey: Keys.playSound) as? Bool ?? true
        // Migration: before pairs, the choice lived in `insertSound` as a bare
        // alert-sound name. Carry it over so an existing setting is preserved
        // rather than silently reset to a new default.
        soundTheme = SoundTheme(storageValue: defaults.string(forKey: Keys.soundTheme) ?? "")
            ?? SoundTheme(storageValue: defaults.string(forKey: Keys.insertSound) ?? "")
            ?? .pair(.openResolve)

        if let value = defaults.object(forKey: Keys.vocabularyEntries) {
            if let stored = value as? [String] {
                vocabularyEntries = VocabularyEntry.normalizedUnique(stored)
            } else {
                // Do not silently replace an unexpected current value. Keeping
                // the object intact makes recovery possible and lets the
                // one-time legacy migration remain retryable after repair.
                Log.write("vocabulary load failed; preserving malformed stored value")
                vocabularyEntries = []
            }
        } else {
            // Legacy versions stored a whitespace-delimited string. That format
            // cannot recover phrases, but migrating it preserves every existing
            // single-word entry and gives future edits a lossless representation.
            if let value = defaults.object(forKey: Keys.contextTerms),
               !(value is String) {
                Log.write("legacy vocabulary load failed; preserving malformed stored value")
                vocabularyEntries = []
            } else {
                let legacy = defaults.string(forKey: Keys.contextTerms) ?? ""
                let entries = legacy.split(whereSeparator: \.isWhitespace).map(String.init)
                let migrated = VocabularyEntry.normalizedUnique(entries)
                defaults.set(migrated, forKey: Keys.vocabularyEntries)
                vocabularyEntries = migrated
            }
        }
        if let data = defaults.data(forKey: Keys.voiceShortcuts) {
            do {
                voiceShortcuts = try JSONDecoder().decode([VoiceShortcut].self, from: data)
            } catch {
                Log.write("voice shortcuts load failed; starting empty")
                voiceShortcuts = []
            }
        } else {
            voiceShortcuts = []
        }
        let decodedCustomModels: [ASRModel] = {
            guard let data = defaults.data(forKey: Keys.customModels),
                  let values = try? JSONDecoder().decode([ASRModel].self, from: data)
            else { return [] }
            return values.filter { !$0.isBuiltIn }
        }()
        let decodedSelection: ASRModel = {
            if let data = defaults.data(forKey: Keys.selectedModel),
               let value = try? JSONDecoder().decode(ASRModel.self, from: data) {
                return value
            }
            return ASRModel(rawValue: defaults.string(forKey: Keys.model) ?? "") ?? .small
        }()
        var uniqueCustomModels: [ASRModel] = []
        for value in decodedCustomModels where !uniqueCustomModels.contains(value) {
            uniqueCustomModels.append(value)
        }
        if FeatureFlags.optionalModelsEnabled,
           !decodedSelection.isBuiltIn,
           !uniqueCustomModels.contains(decodedSelection) {
            uniqueCustomModels.append(decodedSelection)
        }
        // Keep the stored data untouched while the gate is off, but do not
        // surface it through the running public app.
        customModels = FeatureFlags.optionalModelsEnabled ? uniqueCustomModels : []
        model = FeatureFlags.optionalModelsEnabled || decodedSelection.isBuiltIn
            ? decodedSelection
            : .small
        let completedOnboarding = defaults.bool(forKey: Keys.onboarded)
        hasCompletedOnboarding = completedOnboarding
        if let pending = defaults.object(forKey: Keys.firstDictationCoachPending) as? Bool {
            needsFirstDictationCoach = pending
        } else {
            // A genuinely new or unfinished installation should receive the
            // invitation. Existing users upgrading from a version without this
            // key have already completed setup, so do not replay first-run UI.
            needsFirstDictationCoach = !completedOnboarding
            defaults.set(needsFirstDictationCoach, forKey: Keys.firstDictationCoachPending)
        }

        warm(soundTheme)
        persistTriggerShortcut()
        if FeatureFlags.optionalModelsEnabled {
            persistCustomModels()
        }
    }

    @discardableResult
    func addCustomModel(
        engine: ASREngine,
        source: ASRModelSource,
        location: String
    ) throws -> ASRModel {
        guard FeatureFlags.optionalModelsEnabled else {
            throw ASRModelValidationError.optionalModelsUnavailable
        }
        let candidate = try ModelCatalog.validatedCustomModel(
            engine: engine,
            source: source,
            location: location
        )
        guard !candidate.isBuiltIn else { return candidate }
        if !customModels.contains(candidate) {
            customModels.append(candidate)
        }
        return candidate
    }

    /// Removes only the saved definition. Downloaded weights and local folders
    /// are deliberately left untouched.
    func forgetCustomModel(_ forgotten: ASRModel) {
        guard FeatureFlags.optionalModelsEnabled else { return }
        guard !forgotten.isBuiltIn else { return }
        if model == forgotten {
            model = ASRModel.allCases.first(where: {
                ModelCatalog.state(for: $0).isInstalled
            }) ?? .small
        }
        customModels.removeAll { $0 == forgotten }
    }

    func resetTriggerShortcut() {
        triggerShortcut = .defaultValue
    }

    func beginTriggerShortcutCapture() {
        triggerShortcutCaptureCount += 1
        guard triggerShortcutCaptureCount == 1 else { return }
        isCapturingTriggerShortcut = true
        onTriggerShortcutCaptureChange?(true)
    }

    func endTriggerShortcutCapture() {
        guard triggerShortcutCaptureCount > 0 else { return }
        triggerShortcutCaptureCount -= 1
        guard triggerShortcutCaptureCount == 0 else { return }
        isCapturingTriggerShortcut = false
        onTriggerShortcutCaptureChange?(false)
    }

    private func persistTriggerShortcut() {
        guard let data = try? JSONEncoder().encode(triggerShortcut) else {
            Log.write("trigger shortcut save failed")
            return
        }
        defaults.set(data, forKey: Keys.triggerShortcut)
    }

    private func persistCustomModels() {
        guard let data = try? JSONEncoder().encode(customModels) else {
            Log.write("custom models save failed")
            return
        }
        defaults.set(data, forKey: Keys.customModels)
    }
}
