import XCTest
@testable import WhisprStream

final class FillerWordNormalizerTests: XCTestCase {
    private func assertNormalized(
        _ input: String,
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(FillerWordNormalizer.normalize(input), expected, file: file, line: line)
    }

    // Sentences below come from real dictations captured by the review panel.

    func testRemovesEnglishHesitationsWithTheirCommas() {
        assertNormalized(
            "Question is um, ah, in the paper they say the harness can affect ASR.",
            "Question is in the paper they say the harness can affect ASR."
        )
        assertNormalized(
            "if the model doesn't, sure, um, which word to pick",
            "if the model doesn't, sure, which word to pick"
        )
    }

    func testCarriesSentenceStartCapitalizationToTheNextWord() {
        assertNormalized(
            "they find that it is different across that. Um, so why would the harness matter?",
            "they find that it is different across that. So why would the harness matter?"
        )
        assertNormalized("But for. Uh, iterating and testing", "But for. Iterating and testing")
        assertNormalized("Um, iPhone users", "iPhone users")
    }

    func testLeavesLowercaseSentenceStartsAsTranscribed() {
        assertNormalized(
            "overall accuracy. uh that feedback loop",
            "overall accuracy. that feedback loop"
        )
    }

    func testRemovesChineseHesitations() {
        assertNormalized(
            "对，我觉得这个呃，Warmer的这个动画，非常的影响体验。",
            "对，我觉得这个Warmer的这个动画，非常的影响体验。"
        )
        assertNormalized(
            "或者是这种一呃 meet up 的 dinner 这种 invite。",
            "或者是这种一 meet up 的 dinner 这种 invite。"
        )
    }

    func testRemovesParticlesOnlyWhenIsolatedMidSentence() {
        assertNormalized(
            "或者是参加什么活动，啊，大家就需要 physically 在那边排着队。",
            "或者是参加什么活动，大家就需要 physically 在那边排着队。"
        )
        assertNormalized("我觉得，嗯，可以。", "我觉得，可以。")
        assertNormalized("so, ah, I think", "so, I think")
        assertNormalized("我觉得，嗯。", "我觉得。")
    }

    func testRemovesSentenceOpeningHesitations() {
        assertNormalized("嗯，啊，我觉得还是不错的", "我觉得还是不错的")
        assertNormalized(
            "好的，我来试一下。嗯，啊，我觉得还是不错的",
            "好的，我来试一下。我觉得还是不错的"
        )
        assertNormalized("嗯，英文的表现不错", "英文的表现不错")
        assertNormalized("Ah, that works.", "That works.")
    }

    func testKeepsSentenceOpeningReplies() {
        assertNormalized("嗯，对。", "嗯，对。")
        assertNormalized("嗯，嗯，好的", "嗯，嗯，好的")
        assertNormalized("我看到了。嗯，没问题。", "我看到了。嗯，没问题。")
        assertNormalized("啊，原来是这样。", "啊，原来是这样。")
        assertNormalized("Ah okay, got it.", "Ah okay, got it.")
        assertNormalized("Ah, okra is great.", "Okra is great.")
    }

    func testKeepsParticlesThatCarryMeaning() {
        assertNormalized(
            "然后他就带我一起分析我这个ID啊，然后怎么能Pivot。",
            "然后他就带我一起分析我这个ID啊，然后怎么能Pivot。"
        )
        assertNormalized(
            "然后创建这种啊 birthday party invite",
            "然后创建这种啊 birthday party invite"
        )
        assertNormalized("好啊。", "好啊。")
        assertNormalized("嗯，好的。", "嗯，好的。")
        assertNormalized("嗯嗯好的", "嗯嗯好的")
        assertNormalized("Ah, I see.", "Ah, I see.")
        assertNormalized("这个额度不够，额外再加一点。", "这个额度不够，额外再加一点。")
    }

    func testKeepsWordsThatOnlyLookLikeFillers() {
        assertNormalized("Bring an umbrella.", "Bring an umbrella.")
        assertNormalized("Uh-oh, that broke.", "Uh-oh, that broke.")
        assertNormalized("I applied to UM and UH.", "I applied to UM and UH.")
        assertNormalized("他一直呃逆。", "他一直呃逆。")
        assertNormalized("Let me check the humidity.", "Let me check the humidity.")
    }

    func testRepairsTrailingAndWholeSentenceHesitations() {
        assertNormalized("I think, um.", "I think.")
        assertNormalized("and then um", "and then")
        assertNormalized("That works. Um. So next", "That works. So next")
        assertNormalized("Um.", "")
        assertNormalized("呃，", "")
    }

    func testRejoinsASentenceSplitAtAHesitation() {
        // Field report: a pause filled with "um" ended the sentence after "to".
        assertNormalized("I want an ability to. Um, export it as PDF.",
                         "I want an ability to export it as PDF.")
        assertNormalized("I want to. Um, um, export it.", "I want to export it.")
        assertNormalized("Use the. Um, Claude app.", "Use the Claude app.")
        assertNormalized("我觉得因为。嗯，这个比较好。", "我觉得因为这个比较好。")
        assertNormalized("所以。呃，我们先发布。", "所以我们先发布。")
    }

    func testKeepsSentenceBreaksThatCanStand() {
        // The word before the period can end a sentence, or the period is
        // part of an abbreviation, so the break is the speaker's.
        assertNormalized("That's done. Um, next I want to ship it.",
                         "That's done. Next I want to ship it.")
        assertNormalized("这是我的。嗯，你的呢？", "这是我的。你的呢？")
        assertNormalized("Is it ready to? Um, maybe.", "Is it ready to? Maybe.")
        assertNormalized("Check the U.S. Um, rules.", "Check the U.S. Rules.")
        assertNormalized("e.g. Um, this one.", "e.g. This one.")
        // Nothing follows the hesitation, so there is nothing to rejoin.
        assertNormalized("Push it to. Um.", "Push it to. ")
    }

    func testLeavesTextWithoutFillersUnchanged() {
        let text = "你帮我检查一下，这个软件没有什么漏洞吧？就他有没有Backdoor。"
        assertNormalized(text, text)
        assertNormalized("", "")
    }

    func testIsIdempotent() {
        let once = FillerWordNormalizer.normalize("Question is um, ah, in the paper. Um, so why?")
        XCTAssertEqual(FillerWordNormalizer.normalize(once), once)
    }
}
