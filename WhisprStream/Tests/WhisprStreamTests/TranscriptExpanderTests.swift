import XCTest
@testable import WhisprStream

final class TranscriptExpanderTests: XCTestCase {
    func testPunctuationCanBeReplacedWithSpace() {
        XCTAssertEqual(
            TranscriptFormatter.format("Hello, world!", usePunctuation: false),
            "Hello, world"
        )
        XCTAssertEqual(
            TranscriptFormatter.format("你好。", usePunctuation: false),
            "你好"
        )
    }

    func testPunctuationPreferencePreservesTextWhenEnabled() {
        XCTAssertEqual(
            TranscriptFormatter.format("Hello, world!", usePunctuation: true),
            "Hello, world!"
        )
    }

    func testPunctuationFormatterPreservesInternalPunctuation() {
        XCTAssertEqual(
            TranscriptFormatter.format("Use example.com now.", usePunctuation: false),
            "Use example.com now"
        )
    }

    func testPunctuationFormatterHandlesClosingQuotesAndBrackets() {
        XCTAssertEqual(
            TranscriptFormatter.format("He said \"hello.\"", usePunctuation: false),
            "He said \"hello\""
        )
        XCTAssertEqual(
            TranscriptFormatter.format("她说「你好。」", usePunctuation: false),
            "她说「你好」"
        )
        XCTAssertEqual(
            TranscriptFormatter.format("Done.)", usePunctuation: false),
            "Done)"
        )
    }

    func testInsertionTextAddsOneSeparatorWithoutPollutingFormattedText() {
        XCTAssertEqual(TranscriptFormatter.textForInsertion("Hello."), "Hello. ")
        XCTAssertEqual(TranscriptFormatter.textForInsertion("你好"), "你好 ")
        XCTAssertEqual(TranscriptFormatter.textForInsertion("already spaced "), "already spaced ")
        XCTAssertEqual(TranscriptFormatter.textForInsertion("line break\n"), "line break\n")
    }

    func testCursorContinuationLowercasesSentenceStyleOpening() {
        XCTAssertEqual(
            TranscriptFormatter.adjustedForCursor(
                "Is the deal for you",
                precedingText: "Hello this "
            ),
            "is the deal for you"
        )
        XCTAssertEqual(
            TranscriptFormatter.adjustedForCursor("Testing the feature.", precedingText: "I am "),
            "testing the feature."
        )
        XCTAssertEqual(
            TranscriptFormatter.adjustedForCursor("Testing", precedingText: "First, "),
            "testing"
        )
        XCTAssertEqual(
            TranscriptFormatter.adjustedForCursor("“Testing”", precedingText: "She called it "),
            "“testing”"
        )
    }

    func testCursorSentenceBoundaryPreservesCapitalization() {
        XCTAssertEqual(
            TranscriptFormatter.adjustedForCursor("Testing again.", precedingText: "Done. "),
            "Testing again."
        )
        XCTAssertEqual(
            TranscriptFormatter.adjustedForCursor("Testing again.", precedingText: "She said “done.” "),
            "Testing again."
        )
        XCTAssertEqual(
            TranscriptFormatter.adjustedForCursor("Testing again.", precedingText: "Draft\n"),
            "Testing again."
        )
        XCTAssertEqual(
            TranscriptFormatter.adjustedForCursor("Testing again.", precedingText: ""),
            "Testing again."
        )
        XCTAssertEqual(
            TranscriptFormatter.adjustedForCursor("Testing again.", precedingText: nil),
            "Testing again."
        )
    }

    func testCursorContinuationPreservesPronounAndAcronym() {
        XCTAssertEqual(
            TranscriptFormatter.adjustedForCursor("I am ready.", precedingText: "and "),
            "I am ready."
        )
        XCTAssertEqual(
            TranscriptFormatter.adjustedForCursor("I'm ready.", precedingText: "and "),
            "I'm ready."
        )
        XCTAssertEqual(
            TranscriptFormatter.adjustedForCursor("NASA agreed.", precedingText: "then "),
            "NASA agreed."
        )
        XCTAssertEqual(
            TranscriptFormatter.adjustedForCursor("测试", precedingText: "继续"),
            "测试"
        )
    }

    func testSpokenNumbersBecomeDigits() {
        XCTAssertEqual(SpokenNumberNormalizer.normalize("I need twenty four apples"), "I need 24 apples")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("one hundred and five"), "105")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("the code is one two three"), "the code is 123")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("the code is zero one"), "the code is 01")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("twenty-four"), "24")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("temperature is twenty point five degrees"), "temperature is 20.5 degrees")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("version one point two point three"), "version 1.2.3")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("one point two point three point four"), "1.2.3.4")
    }

    func testIsolatedSmallNumberWordsStayNaturalInEnglishProse() {
        XCTAssertEqual(
            SpokenNumberNormalizer.normalize("There is one problem"),
            "There is one problem"
        )
        XCTAssertEqual(SpokenNumberNormalizer.normalize("I won one."), "I won one.")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("version one"), "version one")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("minus five"), "-5")
    }

    func testChineseDigitSequencesAndStructuredNumbersBecomeDigits() {
        XCTAssertEqual(SpokenNumberNormalizer.normalize("一三五七九"), "13579")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("〇〇七"), "007")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("验证码是零一二三"), "验证码是0123")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("一百三十五"), "135")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("一千零二"), "1002")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("二点五"), "2.5")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("負二點五"), "-2.5")
    }

    func testChineseNormalizerPreservesAmbiguousLexicalUses() {
        XCTAssertEqual(SpokenNumberNormalizer.normalize("只有一个问题"), "只有一个问题")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("星期一见"), "星期一见")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("千万不要"), "千万不要")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("一心一意"), "一心一意")
    }

    func testSpokenNumbersPreserveUnrelatedTextAndPunctuation() {
        XCTAssertEqual(
            SpokenNumberNormalizer.normalize("Please call 416-555-0100. I won one."),
            "Please call 416-555-0100. I won one."
        )
        XCTAssertEqual(SpokenNumberNormalizer.normalize("one and two"), "one and two")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("one hundred."), "100.")
        XCTAssertEqual(SpokenNumberNormalizer.normalize("one point two point"), "one point two point")
    }

    func testSpokenSlashBecomesPathPunctuation() {
        XCTAssertEqual(SpokenSymbolNormalizer.normalize("slash retest"), "/retest")
        XCTAssertEqual(SpokenSymbolNormalizer.normalize("slash retest."), "/retest")
        XCTAssertEqual(SpokenSymbolNormalizer.normalize("slash retest.com."), "/retest.com")
        XCTAssertEqual(SpokenSymbolNormalizer.normalize("forward slash retest"), "/retest")
        XCTAssertEqual(SpokenSymbolNormalizer.normalize("docs slash retest"), "docs/retest")
        XCTAssertEqual(SpokenSymbolNormalizer.normalize("run slash retest."), "run/retest.")
        XCTAssertEqual(SpokenSymbolNormalizer.normalize("slash slash retest"), "//retest")
        XCTAssertEqual(SpokenSymbolNormalizer.normalize("slash the budget"), "slash the budget")
    }

    func testNormalizationIgnoresCasePunctuationAndWhitespace() {
        XCTAssertEqual(
            VoiceShortcutValidation.normalizedTrigger("haha github"),
            VoiceShortcutValidation.normalizedTrigger("HAHA,   GITHUB!")
        )
        XCTAssertEqual(
            VoiceShortcutValidation.normalizedTrigger("pineapple"),
            VoiceShortcutValidation.normalizedTrigger("PINEAPPLE!")
        )
        XCTAssertEqual(
            VoiceShortcutValidation.normalizedTrigger("pineapple"),
            VoiceShortcutValidation.normalizedTrigger("ｐｉｎｅａｐｐｌｅ")
        )
        XCTAssertEqual(
            VoiceShortcutValidation.normalizedTrigger("hello world"),
            VoiceShortcutValidation.normalizedTrigger("hello\nworld")
        )
        XCTAssertNotEqual(
            VoiceShortcutValidation.normalizedTrigger("hello-world"),
            VoiceShortcutValidation.normalizedTrigger("helloworld")
        )
    }

    func testNormalizationKeepsTokenAndDiacriticDifferences() {
        XCTAssertNotEqual(
            VoiceShortcutValidation.normalizedTrigger("haha"),
            VoiceShortcutValidation.normalizedTrigger("ha ha")
        )
        XCTAssertNotEqual(
            VoiceShortcutValidation.normalizedTrigger("resume"),
            VoiceShortcutValidation.normalizedTrigger("résumé")
        )
    }

    func testChineseAndMixedLanguageNormalization() {
        XCTAssertEqual(
            VoiceShortcutValidation.normalizedTrigger("你好。"),
            VoiceShortcutValidation.normalizedTrigger("你好")
        )
        XCTAssertEqual(
            VoiceShortcutValidation.normalizedTrigger("你好 GitHub"),
            VoiceShortcutValidation.normalizedTrigger("你好, GITHUB!")
        )
    }

    func testPunctuationOnlyTriggerIsInvalid() {
        let shortcut = VoiceShortcut(id: UUID(), trigger: "!?", replacement: "text", isEnabled: true)
        XCTAssertThrowsError(try VoiceShortcutValidation.validate(shortcut, against: [])) { error in
            XCTAssertEqual(error as? VoiceShortcutValidationError, .emptyTrigger)
        }
    }

    func testEnabledSingleWordAndPhraseExpand() {
        let single = VoiceShortcut(id: UUID(), trigger: "pineapple", replacement: "🍍", isEnabled: true)
        let phrase = VoiceShortcut(id: UUID(), trigger: "haha github", replacement: "https://github.com/Leo6Leo", isEnabled: true)

        XCTAssertEqual(TranscriptExpander.expand("Pineapple!", using: [single]).text, "🍍")
        XCTAssertEqual(
            TranscriptExpander.expand("Haha, GitHub.", using: [phrase]),
            TranscriptExpansionResult(text: "https://github.com/Leo6Leo", matchedShortcutID: phrase.id)
        )
    }

    func testDisabledTriggerDoesNotExpandAndInlineTriggerDoesExpand() {
        let shortcut = VoiceShortcut(id: UUID(), trigger: "pineapple", replacement: "expanded", isEnabled: false)
        XCTAssertEqual(TranscriptExpander.expand("pineapple", using: [shortcut]).text, "pineapple")

        let enabled = VoiceShortcut(id: UUID(), trigger: "haha github", replacement: "expanded", isEnabled: true)
        XCTAssertEqual(
            TranscriptExpander.expand("Open haha github", using: [enabled]).text,
            "Open expanded"
        )
        XCTAssertEqual(
            TranscriptExpander.expand("Please use Haha, GitHub.", using: [enabled]).text,
            "Please use expanded."
        )
    }

    func testNearMatchAndNoMatchReturnOriginalTextExactly() {
        let shortcut = VoiceShortcut(id: UUID(), trigger: "haha github", replacement: "expanded", isEnabled: true)
        XCTAssertEqual(TranscriptExpander.expand("ha ha github", using: [shortcut]).text, "ha ha github")
        let original = "  Unmatched\ntext  "
        XCTAssertEqual(TranscriptExpander.expand(original, using: [shortcut]).text, original)
    }

    func testReplacementIsLiteralAndNotRecursive() {
        let first = VoiceShortcut(id: UUID(), trigger: "alpha", replacement: "beta\nγamma", isEnabled: true)
        let second = VoiceShortcut(id: UUID(), trigger: "beta", replacement: "recursive", isEnabled: true)
        let result = TranscriptExpander.expand("ALPHA!", using: [first, second])
        XCTAssertEqual(result.text, "beta\nγamma")
        XCTAssertEqual(result.matchedShortcutID, first.id)
    }

    func testLongerPhraseWinsOverSingleWordAndMultipleMatchesExpand() {
        let single = VoiceShortcut(id: UUID(), trigger: "blue", replacement: "BLUE", isEnabled: true)
        let phrase = VoiceShortcut(id: UUID(), trigger: "blue pineapple", replacement: "FRUIT", isEnabled: true)
        XCTAssertEqual(
            TranscriptExpander.expand("blue pineapple and blue", using: [single, phrase]).text,
            "FRUIT and BLUE"
        )
    }

    func testSingleWordDoesNotMatchInsideLongerToken() {
        let shortcut = VoiceShortcut(id: UUID(), trigger: "pineapple", replacement: "expanded", isEnabled: true)
        XCTAssertEqual(
            TranscriptExpander.expand("pineapples are ready", using: [shortcut]).text,
            "pineapples are ready"
        )
    }

    func testFullWidthTranscriptCanBeExpandedWithoutInvalidStringIndices() {
        let shortcut = VoiceShortcut(id: UUID(), trigger: "pineapple", replacement: "expanded", isEnabled: true)
        XCTAssertEqual(TranscriptExpander.expand("ｐｉｎｅａｐｐｌｅ！", using: [shortcut]).text, "expanded")
    }

    func testDuplicateNormalizedTriggersUseFirstShortcut() {
        let first = VoiceShortcut(id: UUID(), trigger: "hello", replacement: "first", isEnabled: true)
        let second = VoiceShortcut(id: UUID(), trigger: "HELLO!", replacement: "second", isEnabled: true)
        XCTAssertEqual(TranscriptExpander.expand("hello", using: [first, second]).text, "first")
    }

    func testDuplicateNormalizedTriggersAreRejected() {
        let existing = VoiceShortcut(id: UUID(), trigger: "haha github", replacement: "one", isEnabled: false)
        let candidate = VoiceShortcut(id: UUID(), trigger: "HAHA, GITHUB!", replacement: "two", isEnabled: true)
        XCTAssertThrowsError(try VoiceShortcutValidation.validate(candidate, against: [existing])) { error in
            XCTAssertEqual(error as? VoiceShortcutValidationError, .duplicateTrigger)
        }
    }
}
