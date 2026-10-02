"""Selection-policy tests; scripted hypotheses are not model-accuracy claims."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "WhisprStream" / "Resources"))
from asr_server import PreviewStabilizer  # noqa: E402


class PreviewStabilityTests(unittest.TestCase):
    def select(self, candidates):
        selector = PreviewStabilizer()
        return [selector.update(text, 0, 100 + i, 0)
                for i, text in enumerate(candidates)]

    def test_single_flip_does_not_replace_confirmed_word(self):
        self.assertEqual(
            self.select(["我用Codex写代码。"] * 2 + ["我用Codec写代码。", "我用Codex写代码。"]),
            ["我用Codex写代码。"] * 4,
        )

    def test_unconfirmed_word_can_be_corrected_immediately(self):
        self.assertEqual(self.select(["Codec", "Codex"]), ["Codec", "Codex"])

    def test_confirmed_wrong_word_can_still_be_corrected(self):
        self.assertEqual(
            self.select(["Codec", "Codec", "Codex", "Codex"]),
            ["Codec", "Codec", "Codec", "Codex"],
        )

    def test_growing_sentence_settles_words_and_never_hides_new_tail(self):
        self.assertEqual(
            self.select(["我用Codex", "我用Codex写", "我用Codec写代码", "我用Codec写代码和测试"]),
            ["我用Codex", "我用Codex写", "我用Codex写代码", "我用Codec写代码和测试"],
        )

    def test_different_alternatives_do_not_vote_together(self):
        self.assertEqual(
            self.select(["Use Codex"] * 2 + ["Use Codec", "Use Code", "Use Codex"]),
            ["Use Codex"] * 5,
        )

    def test_stable_deletion_needs_confirmation(self):
        self.assertEqual(
            self.select(["先不要删除文件"] * 2 + ["先删除文件"] * 2),
            ["先不要删除文件"] * 3 + ["先删除文件"],
        )

    def test_stable_interior_insertion_needs_confirmation(self):
        self.assertEqual(
            self.select(["先删除文件"] * 2 + ["先不要删除文件"] * 2),
            ["先删除文件"] * 3 + ["先不要删除文件"],
        )

    def test_spacing_and_punctuation_are_preserved(self):
        self.assertEqual(
            self.select(["Use Codex."] * 2 + ["Use Codec, 然后测试！"]),
            ["Use Codex.", "Use Codex.", "Use Codex, 然后测试！"],
        )

    def test_repeated_phrase_does_not_lose_appended_words(self):
        self.assertEqual(
            self.select(["go go"] * 2 + ["go go go", "go go go home"]),
            ["go go", "go go", "go go go", "go go go home"],
        )

    def test_word_reordering_never_duplicates_a_held_word(self):
        for original, revised in (("red blue", "blue red"),
                                  ("我用Codex写代码", "我用写代码Codex")):
            with self.subTest(original=original):
                self.assertEqual(
                    self.select([original, original, revised, revised]),
                    [original, original, revised, revised],
                )

    def test_phrase_rewrite_is_not_mistaken_for_appended_speech(self):
        self.assertEqual(
            self.select(["I like cats"] * 2 + ["I like a cat"] * 2),
            ["I like cats"] * 3 + ["I like a cat"],
        )

    def test_same_audio_cannot_confirm_a_correction(self):
        selector = PreviewStabilizer()
        selector.update("Codex", 0, 100, 0)
        selector.update("Codex", 0, 110, 0)
        self.assertEqual(selector.update("Codec", 0, 120, 0), "Codex")
        self.assertEqual(selector.update("Codec", 0, 120, 0), "Codex")
        self.assertEqual(selector.update("Codec", 0, 130, 0), "Codec")

    def test_same_audio_cannot_make_a_word_stable(self):
        selector = PreviewStabilizer()
        selector.update("Codec", 0, 100, 0)
        selector.update("Codec", 0, 100, 0)
        self.assertEqual(selector.update("Codex", 0, 110, 0), "Codex")

    def test_vocabulary_change_resets_protection(self):
        selector = PreviewStabilizer()
        selector.update("Codec", 0, 100, 0)
        selector.update("Codec", 0, 110, 0)
        self.assertEqual(selector.update("Codex", 0, 120, 1), "Codex")

    def test_new_recording_resets_protection(self):
        selector = PreviewStabilizer()
        selector.update("Codec", 0, 100, 0)
        selector.update("Codec", 0, 110, 0)
        self.assertEqual(selector.update("Codex", 0, 90, 0), "Codex")

    def test_rolling_window_drops_old_prefix_but_protects_overlap(self):
        selector = PreviewStabilizer()
        selector.update("Yesterday we used Codex to write tests", 0, 120, 0)
        selector.update("Yesterday we used Codex to write tests", 0, 121, 0)
        self.assertEqual(
            selector.update("we used Codec to write tests today", 10, 130, 0),
            "we used Codex to write tests today",
        )
        self.assertEqual(
            selector.update("used Codec to write tests today again", 20, 140, 0),
            "used Codec to write tests today again",
        )

    def test_full_final_restores_beginning_and_preserves_recent_word(self):
        selector = PreviewStabilizer()
        recent = "we use Codex to write tests"
        selector.update(recent, 20, 140, 0)
        selector.update(recent, 21, 141, 0)
        self.assertEqual(
            selector.update("Earlier we tried Vim. Now we use Codec to write tests quickly", 0, 150, 0),
            "Earlier we tried Vim. Now we use Codex to write tests quickly",
        )

    def test_unrelated_windows_are_not_spliced(self):
        selector = PreviewStabilizer()
        selector.update("We use Codex here", 0, 120, 0)
        selector.update("We use Codex here", 0, 121, 0)
        self.assertEqual(selector.update("新的话题", 122, 250, 0), "新的话题")

    def test_repeated_correction_always_converges_without_latching_old_text(self):
        # Exercise ambiguous repeated anchors, deletions, rewrites, punctuation,
        # and mixed scripts. A persistent candidate must eventually win even
        # when only some of its edits were held on the first observation.
        candidates = [
            "", "Codex", "Codec", "Use Codex.", "Use Codec, then test.",
            "go go", "go home go", "red blue", "blue red", "我用Codex写代码。",
            "我用Codec写代码和测试。", "先删除文件", "先不要删除文件",
            "打开设置", "打开设计页面", "I like cats", "I like a cat",
        ]
        for original in candidates:
            for revised in candidates:
                with self.subTest(original=original, revised=revised):
                    self.assertEqual(
                        self.select([original, original, revised, revised])[-1],
                        revised,
                    )

    def test_nonlexical_and_multiple_disagreements_do_not_open_a_questionnaire(self):
        for old, new in (("Use Codex.", "Use Codex!"),
                         ("Use Codex and Vim", "Use Codec and Emacs"),
                         ("先不要删除", "先删除")):
            with self.subTest(old=old):
                selector = PreviewStabilizer()
                for i, text in enumerate((old, old, new)):
                    selector.update(text, 0, 100 + i, 0)
                self.assertIsNone(selector.review)


if __name__ == "__main__":
    unittest.main()
