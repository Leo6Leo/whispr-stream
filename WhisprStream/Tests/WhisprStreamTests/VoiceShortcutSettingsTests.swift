import XCTest
@testable import WhisprStream

@MainActor
final class VoiceShortcutSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "WhisprStreamTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func testPersistenceAndCombinedContext() throws {
        let defaults = makeDefaults()
        let settings = Settings(defaults: defaults)
        settings.usePunctuation = false
        settings.contextAwareCapitalization = false
        settings.shortUtteranceLanguage = .english
        settings.setVocabulary(["Claude", "GitHub"])

        let enabled = VoiceShortcut(
            id: UUID(), trigger: "haha github", replacement: "https://example.com", isEnabled: true
        )
        let disabled = VoiceShortcut(
            id: UUID(), trigger: "secret phrase", replacement: "hidden", isEnabled: false
        )
        try settings.addVoiceShortcut(enabled)
        try settings.addVoiceShortcut(disabled)

        XCTAssertEqual(settings.asrContext, "Claude\nGitHub\nhaha github")

        let reloaded = Settings(defaults: defaults)
        XCTAssertFalse(reloaded.usePunctuation)
        XCTAssertFalse(reloaded.contextAwareCapitalization)
        XCTAssertEqual(reloaded.shortUtteranceLanguage, .english)
        XCTAssertEqual(reloaded.voiceShortcuts, [enabled, disabled])
        XCTAssertEqual(reloaded.asrContext, "Claude\nGitHub\nhaha github")
    }

    func testRemoveFillerWordsDefaultsOnAndPersists() {
        let defaults = makeDefaults()
        let settings = Settings(defaults: defaults)
        XCTAssertTrue(settings.removeFillerWords)
        settings.removeFillerWords = false
        XCTAssertFalse(Settings(defaults: defaults).removeFillerWords)
    }

    func testContextAwareCapitalizationDefaultsOff() {
        XCTAssertFalse(Settings(defaults: makeDefaults()).contextAwareCapitalization)
    }

    func testPlaySoundDefaultsOn() {
        XCTAssertTrue(Settings(defaults: makeDefaults()).playSound)
    }

    func testOneWordDictationOffersAutomaticAndEveryQwenLanguage() {
        let fixedLanguages = ShortUtteranceLanguage.allCases.compactMap(\.fixedModelLanguage)

        XCTAssertEqual(ShortUtteranceLanguage.allCases.count, 31)
        XCTAssertEqual(Set(fixedLanguages).count, 30)
        XCTAssertEqual(
            ShortUtteranceLanguage.automaticMultilingual.modelName,
            "Automatic multilingual"
        )
    }

    func testOneWordDictationDefaultsToAutomaticMultilingual() {
        XCTAssertEqual(
            Settings(defaults: makeDefaults()).shortUtteranceLanguage,
            .automaticMultilingual
        )
    }

    func testAutomaticShortDictationNeverForcesALanguage() {
        XCTAssertNil(ShortUtteranceLanguageResolver.modelLanguage(
            for: .automaticMultilingual
        ))
    }

    func testFixedShortDictationLanguageRemainsDeterministic() {
        XCTAssertEqual(
            ShortUtteranceLanguageResolver.modelLanguage(
                for: .french
            ),
            "French"
        )
    }

    func testOneWordLanguageOnboardingFollowsSpeakingPreferences() throws {
        let steps = OnboardingView.Step.allCases
        let preferencesIndex = try XCTUnwrap(steps.firstIndex(of: .preferences))

        XCTAssertEqual(steps[preferencesIndex + 1], .oneWordLanguage)
    }

    func testOptionalOnboardingStepsFollowTheirSubjects() throws {
        let steps = OnboardingView.Step.allCases
        let accessibilityIndex = try XCTUnwrap(steps.firstIndex(of: .accessibility))
        let outputIndex = try XCTUnwrap(steps.firstIndex(of: .output))
        let readyIndex = try XCTUnwrap(steps.firstIndex(of: .ready))

        // The optional system-audio grant sits with the other permissions.
        XCTAssertEqual(steps[accessibilityIndex + 1], .systemAudio)
        // Learning from edits is introduced right after output choices.
        XCTAssertEqual(steps[outputIndex + 1], .learning)
        XCTAssertEqual(steps.last, .ready)
        XCTAssertLessThan(try XCTUnwrap(steps.firstIndex(of: .learning)), readyIndex)
    }

    func testFirstDictationCoachUsesSelectedKeyAndActivationMode() {
        XCTAssertEqual(
            FirstDictationCoachView.instruction(key: .rightOption, mode: .hold),
            "Click in any text field, then hold ⌥ Right Option, speak, and release."
        )
        XCTAssertEqual(
            FirstDictationCoachView.instruction(key: .function, mode: .tap),
            "Click in any text field, tap Fn, speak, then tap it again."
        )
    }

    func testDeveloperFirstRunSimulationOffersFirstDictationCoach() {
        XCTAssertTrue(FirstDictationCoachPolicy.shouldOffer(
            needsFirstDictationCoach: false,
            isDeveloperFirstRunSimulation: true
        ))
        XCTAssertTrue(FirstDictationCoachPolicy.shouldOffer(
            needsFirstDictationCoach: true,
            isDeveloperFirstRunSimulation: false
        ))
        XCTAssertFalse(FirstDictationCoachPolicy.shouldOffer(
            needsFirstDictationCoach: false,
            isDeveloperFirstRunSimulation: false
        ))
    }

    func testFirstDictationCoachWaitsForEveryRuntimePrerequisite() {
        XCTAssertTrue(FirstDictationCoachPolicy.shouldPresent(
            isQueued: true,
            isSpeechEngineReady: true,
            hasMicrophonePermission: true,
            hasAccessibilityPermission: true
        ))

        for missing in 0..<4 {
            var prerequisites = [true, true, true, true]
            prerequisites[missing] = false
            XCTAssertFalse(FirstDictationCoachPolicy.shouldPresent(
                isQueued: prerequisites[0],
                isSpeechEngineReady: prerequisites[1],
                hasMicrophonePermission: prerequisites[2],
                hasAccessibilityPermission: prerequisites[3]
            ))
        }
    }

    func testNewInstallPersistsPendingFirstDictationCoachUntilHandled() {
        let defaults = makeDefaults()
        var settings = Settings(defaults: defaults)

        XCTAssertFalse(settings.hasCompletedOnboarding)
        XCTAssertTrue(settings.needsFirstDictationCoach)

        settings.hasCompletedOnboarding = true
        settings = Settings(defaults: defaults)
        XCTAssertTrue(settings.needsFirstDictationCoach)

        settings.needsFirstDictationCoach = false
        XCTAssertFalse(Settings(defaults: defaults).needsFirstDictationCoach)
    }

    func testExistingOnboardedUserDoesNotReceiveMigratedFirstRunCoach() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "hasCompletedOnboarding")

        let settings = Settings(defaults: defaults)

        XCTAssertFalse(settings.needsFirstDictationCoach)
        XCTAssertEqual(defaults.object(forKey: "needsFirstDictationCoach") as? Bool, false)
    }

    func testLegacyAutomaticShortLanguageMigratesToAutomaticMultilingual() {
        let defaults = makeDefaults()
        defaults.set("automatic", forKey: "shortUtteranceLanguage")

        XCTAssertEqual(
            Settings(defaults: defaults).shortUtteranceLanguage,
            .automaticMultilingual
        )
    }

    func testLegacySmartBilingualMigratesToAutomaticMultilingual() {
        let defaults = makeDefaults()
        defaults.set("smartEnglishChinese", forKey: "shortUtteranceLanguage")

        XCTAssertEqual(
            Settings(defaults: defaults).shortUtteranceLanguage,
            .automaticMultilingual
        )
    }

    func testContextDeduplicatesIdenticalLiteralLinesAndNeverIncludesReplacement() throws {
        let settings = Settings(defaults: makeDefaults())
        settings.setVocabulary(["hello", "world"])
        let shortcut = VoiceShortcut(
            id: UUID(), trigger: "hello", replacement: "world\nprivate replacement", isEnabled: true
        )
        try settings.addVoiceShortcut(shortcut)

        XCTAssertEqual(settings.asrContext, "hello\nworld")
        XCTAssertFalse(settings.asrContext.contains("private replacement"))
    }

    func testDisabledToggleAndAllShortcutMutationsPushContext() throws {
        let settings = Settings(defaults: makeDefaults())
        var updates: [String] = []
        settings.onContextChange = { updates.append($0) }

        let shortcut = VoiceShortcut(
            id: UUID(), trigger: "pineapple", replacement: "fruit", isEnabled: true
        )
        try settings.addVoiceShortcut(shortcut)
        settings.setVoiceShortcutEnabled(id: shortcut.id, enabled: false)
        settings.setVoiceShortcutEnabled(id: shortcut.id, enabled: true)
        try settings.updateVoiceShortcut(
            VoiceShortcut(id: shortcut.id, trigger: "mango", replacement: "fruit", isEnabled: true)
        )
        settings.removeVoiceShortcut(id: shortcut.id)

        XCTAssertEqual(updates, ["pineapple", "", "pineapple", "mango", ""])
    }

    func testDuplicateDisabledShortcutIsRejected() throws {
        let settings = Settings(defaults: makeDefaults())
        let existing = VoiceShortcut(
            id: UUID(), trigger: "haha github", replacement: "one", isEnabled: false
        )
        try settings.addVoiceShortcut(existing)

        XCTAssertThrowsError(
            try settings.addVoiceShortcut(
                VoiceShortcut(id: UUID(), trigger: "HAHA, GITHUB!", replacement: "two", isEnabled: true)
            )
        ) { error in
            XCTAssertEqual(error as? VoiceShortcutValidationError, .duplicateTrigger)
        }
    }

    func testDecodeFailureStartsEmpty() {
        let defaults = makeDefaults()
        defaults.set(Data([0x01, 0x02, 0x03]), forKey: "voiceShortcuts.v1")
        let settings = Settings(defaults: defaults)
        XCTAssertTrue(settings.voiceShortcuts.isEmpty)
    }

    func testMalformedVocabularyStorageIsNotOverwrittenDuringInitialization() {
        let defaults = makeDefaults()
        let malformed = ["unexpected": true]
        defaults.set(malformed, forKey: "vocabularyEntries")
        defaults.set("Legacy term", forKey: "contextTerms")

        let settings = Settings(defaults: defaults)

        XCTAssertTrue(settings.vocabularyEntries.isEmpty)
        XCTAssertEqual(
            defaults.dictionary(forKey: "vocabularyEntries") as? [String: Bool],
            malformed
        )
    }
}
