"""Preview-to-final regression tests with deterministic decoder output."""

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np

RESOURCES = Path(__file__).parents[1] / "WhisprStream" / "Resources"
sys.path.insert(0, str(RESOURCES))

import asr_engine  # noqa: E402
import asr_server  # noqa: E402


def voice(seconds):
    samples = np.arange(int(seconds * asr_server.SAMPLE_RATE), dtype=np.float32)
    return 0.04 * np.sin(2 * np.pi * 180 * samples / asr_server.SAMPLE_RATE)


class FinalizationTests(unittest.TestCase):
    def make_server(self, outputs, *, seconds=5.0, context="", language=None):
        calls = []
        responses = iter(outputs)

        def transcribe(audio, **kwargs):
            calls.append(kwargs)
            response = next(responses)
            if isinstance(response, Exception):
                raise response
            return SimpleNamespace(text=response, language=language or "Chinese")

        session = SimpleNamespace(transcribe=transcribe, calls=calls)
        with patch.object(asr_engine, "build_session", return_value=(session, 0)), \
             patch.object(asr_server, "emit"):
            server = asr_server.Server("test", 8, context)
        server.buf = voice(seconds)
        server.active = True
        return server

    def preview(self, server, additions):
        """Drive the real loop; each cooldown appends audio or ends the loop."""
        remaining = iter(additions)

        class AdvanceAudio:
            def wait(self, timeout):
                addition = next(remaining, None)
                if addition is None:
                    return True
                server.buf = np.concatenate((server.buf, addition))
                return False

            def set(self):
                pass

        server._preview_stop = AdvanceAudio()
        with patch.object(asr_server, "emit") as emitted:
            server._loop()
        return [call.args[0] for call in emitted.call_args_list]

    def final(self, server):
        with patch.object(asr_server, "emit") as emitted:
            server.stop()
        events = [call.args[0] for call in emitted.call_args_list]
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["type"], "final")
        return events[0]

    def test_preview_retracts_stale_prefix_after_confirmed_revision(self):
        original = "我用Codex写代码。"
        for revised in ("我用Codec写代码。", "我用Codex。", "我想用Codex写代码。"):
            with self.subTest(revised=revised):
                outputs = [original, original, revised, revised]
                server = self.make_server(outputs)
                events = self.preview(server, [voice(0.2)] * 3)
                self.assertEqual(
                    [event["committed"] + event["tail"] for event in events],
                    [original, original, original, revised],
                )
                self.assertTrue(revised.startswith(events[-1]["committed"]))
                self.assertEqual(self.final(server)["text"], revised)

    def test_stable_display_does_not_override_latest_decoded_text_at_stop(self):
        original = "我用Codex写代码。"
        server = self.make_server([original, original, "我用Codec写代码。"])
        events = self.preview(server, [voice(0.2)] * 2)
        self.assertEqual(
            [event["committed"] + event["tail"] for event in events], [original] * 3
        )
        self.assertEqual(self.final(server)["text"], "我用Codec写代码。")
        self.assertEqual(len(server.session.calls), 3)

    def test_unresolved_flip_exposes_a_local_choice_on_final(self):
        server = self.make_server(["Use Codex."] * 2 + ["Use Codec."])
        self.preview(server, [voice(0.2)] * 2)
        final = self.final(server)
        review = final["review"]
        self.assertEqual(review["prefix"] + review["preferred"] + review["suffix"], final["text"])
        self.assertEqual(review["prefix"] + review["alternative"] + review["suffix"], "Use Codex.")
        self.assertEqual(review["preferred"], "Codec")

    def test_resolved_flip_does_not_ask_user_to_choose(self):
        server = self.make_server(["Use Codex."] * 2 + ["Use Codec.", "Use Codex."])
        self.preview(server, [voice(0.2)] * 3)
        self.assertNotIn("review", self.final(server))

    def test_learned_terms_are_hints_without_forced_spelling_replacement(self):
        server = self.make_server(["Use Codec."])
        server.set_learned_context("Codex")
        self.preview(server, [])
        self.assertEqual(self.final(server)["text"], "Use Codec.")
        self.assertEqual(server.session.calls, [{"context": "Codex"}])

    def test_unbiased_vocabulary_check_excludes_learned_hints(self):
        server = self.make_server(["Use Claude", "Use Cloud"], context="Claude")
        server.set_learned_context("Codex")
        self.preview(server, [])
        self.assertEqual(server.session.calls, [{"context": "Claude\nCodex"}, {}])

    def test_changing_learned_hints_invalidates_cached_preview(self):
        server = self.make_server(["Use Codec.", "Use Codex."])
        self.preview(server, [])
        server.set_learned_context("Codex")
        final = self.final(server)
        self.assertEqual(final["mode"], "fresh-final")
        self.assertEqual(final["text"], "Use Codex.")

    def test_fresh_final_keeps_latest_word_and_offers_preview_as_alternative(self):
        server = self.make_server(["Use Codex.", "Use Codex.", "Use Codec, then test."])
        self.preview(server, [voice(0.2)])
        server.buf = np.concatenate((server.buf, voice(0.2)))
        final = self.final(server)
        self.assertEqual(final["text"], "Use Codec, then test.")
        self.assertEqual(final["mode"], "fresh-final")
        self.assertEqual(final["review"]["preferred"], "Codec")
        self.assertEqual(final["review"]["alternative"], "Codex")
        self.assertEqual(len(server.session.calls), 3)

    def test_final_preserves_negation_rewrites_and_appended_speech(self):
        changes = [
            ("先删除文件", "先不要删除文件"),
            ("先不要删除文件", "先删除文件"),
            ("I accept this offer.", "I do not accept this offer."),
            ("Please call John.", "Please call Sarah tomorrow after lunch."),
            ("Use Codex and Vim", "Use Codec and Emacs"),
        ]
        for old, latest in changes:
            for cached in (False, True):
                with self.subTest(old=old, latest=latest, cached=cached):
                    server = self.make_server([old, old, latest])
                    self.preview(server, [voice(0.2)] * (2 if cached else 1))
                    if not cached:
                        server.buf = np.concatenate((server.buf, voice(0.2)))
                    final = self.final(server)
                    self.assertEqual(final["text"], latest)
                    self.assertNotIn("review", final)
                    self.assertEqual(final["mode"], "reuse-exact" if cached else "fresh-final")
                    self.assertEqual(len(server.session.calls), 3)

    def test_fresh_final_can_confirm_a_preview_correction(self):
        server = self.make_server(["Use Codec"] * 2 + ["Use Codex", "Use Codex, then test"])
        self.preview(server, [voice(0.2)] * 2)
        server.buf = np.concatenate((server.buf, voice(0.2)))
        self.assertEqual(self.final(server)["text"], "Use Codex, then test")

    def test_stability_history_is_cleared_on_start(self):
        server = self.make_server(["Codec", "Codec", "Codex"])
        self.preview(server, [voice(0.2)])
        server._preview_stop = asr_server.threading.Event()
        # Keep the command's real reset behavior without starting a background
        # decoder in this deterministic test.
        with patch.object(asr_server.threading, "Thread"):
            server.start()
        server._thread = None
        server.buf = voice(5.0)
        events = self.preview(server, [])
        self.assertEqual(events[0]["committed"] + events[0]["tail"], "Codex")

    def test_rolling_preview_does_not_override_full_final(self):
        recent = "we use Codex to write tests"
        server = self.make_server(
            [recent, recent, "Earlier we used Vim. Now we use Codec to write tests quickly"],
            seconds=13.0,
        )
        self.preview(server, [voice(0.2)])
        self.assertGreater(server._last_preview_start, 0)
        server.buf = np.concatenate((server.buf, voice(0.2)))
        final = self.final(server)
        self.assertEqual(
            final["text"], "Earlier we used Vim. Now we use Codec to write tests quickly"
        )
        self.assertEqual(final["mode"], "fresh-final")

    def test_explicit_short_language_overrides_stable_automatic_preview(self):
        server = self.make_server(["打开 settings"] * 2 + ["打开设置"], seconds=1.0)
        server._utterance_short_language = "Chinese"
        self.preview(server, [voice(0.2)])
        self.assertEqual(self.final(server)["text"], "打开设置")

    def test_changed_context_overrides_stable_preview(self):
        server = self.make_server(["Use Codec"] * 2 + ["Use Codex", "Use Codex"])
        self.preview(server, [voice(0.2)])
        server.set_context("Codex")
        self.assertEqual(self.final(server)["text"], "Use Codex")

    def test_unverified_previews_do_not_vote_for_wrong_word(self):
        server = self.make_server(
            ["Use Claude", RuntimeError("temporary failure")] * 2 + ["Use coffee"],
            context="Claude",
        )
        with patch("sys.stderr"):
            self.preview(server, [voice(0.2)] * 2)
        self.assertEqual(self.final(server)["text"], "Use coffee")

    def test_silence_does_not_trigger_another_decode_of_stable_preview(self):
        original = "我用Codex写代码。"
        server = self.make_server([original, original, "我用Codec写代码。"])
        silence = np.zeros(int(0.2 * asr_server.SAMPLE_RATE), dtype=np.float32)
        events = self.preview(server, [voice(0.2), silence])
        self.assertEqual(len(server.session.calls), 2)
        self.assertEqual(events[-1]["committed"] + events[-1]["tail"], original)
        final = self.final(server)
        self.assertEqual(final["text"], original)
        self.assertEqual(final["mode"], "reuse-silent-tail")

    def test_quiet_spoken_tail_updates_preview_and_final(self):
        # RMS ~= 0.017: above the speech floor, below the former silence ceiling.
        quiet_tail = voice(0.2) * 0.6
        self.assertTrue(asr_server.has_speech(quiet_tail))
        server = self.make_server(["先打开", "先打开", "先打开设置"])
        events = self.preview(server, [voice(0.2), quiet_tail])
        self.assertEqual(len(server.session.calls), 3)
        self.assertEqual(
            events[-1]["committed"] + events[-1]["tail"], "先打开设置"
        )
        self.assertEqual(self.final(server)["text"], "先打开设置")

    def test_quiet_spoken_tail_at_release_gets_a_fresh_final(self):
        quiet_tail = voice(0.2) * 0.6
        server = self.make_server(["先打开", "先打开", "先打开设置"])
        self.preview(server, [voice(0.2)])
        # Release before the preview thread has decoded the new, quieter word.
        server.buf = np.concatenate((server.buf, quiet_tail))
        final = self.final(server)
        self.assertEqual(final["text"], "先打开设置")
        self.assertEqual(final["mode"], "fresh-final")
        self.assertEqual(len(server.session.calls), 3)

    def test_fresh_final_keeps_automatic_code_switching(self):
        for text, language in (("打开 settings", "Chinese"), ("让我 take a look", "English")):
            with self.subTest(text=text):
                server = self.make_server(
                    [text, "打开设置" if language == "Chinese" else "Let me take a look"],
                    seconds=3.0,
                    language=language,
                )
                final = self.final(server)
                self.assertEqual(final["text"], text)
                self.assertEqual(final["mode"], "fresh-final")
                self.assertEqual(server.session.calls, [{}])

    def test_reusable_mixed_preview_is_not_translated_at_stop(self):
        text = "打开 settings"
        server = self.make_server([text, text, "打开设置"], seconds=3.0)
        self.preview(server, [voice(0.2)])
        self.assertEqual(self.final(server)["text"], text)
        self.assertEqual(len(server.session.calls), 2)

    def test_verified_vocabulary_preview_is_not_rechecked_at_stop(self):
        for silent_tail in (False, True):
            with self.subTest(silent_tail=silent_tail):
                server = self.make_server(
                    ["Testing LoRA", "Testing Laura"] * 2 + ["Testing coffee"],
                    context="LoRA",
                    language="English",
                )
                self.preview(server, [voice(0.2)])
                if silent_tail:
                    server.buf = np.concatenate((server.buf, np.zeros(3200, dtype=np.float32)))
                final = self.final(server)
                self.assertEqual(final["text"], "Testing LoRA")
                self.assertEqual(final["mode"], "reuse-silent-tail" if silent_tail else "reuse-exact")
                self.assertEqual(len(server.session.calls), 4)

    def test_failed_preview_context_check_is_retried_at_stop(self):
        server = self.make_server(
            ["Claude", RuntimeError("temporary decoder failure"), "blorp"],
            context="Claude",
            language="English",
        )
        with patch("sys.stderr"):
            self.preview(server, [])
        final = self.final(server)
        self.assertEqual(final["text"], "blorp")
        self.assertEqual(final["mode"], "reuse-exact-context-check-fallback")
        self.assertEqual(len(server.session.calls), 3)

    def test_unresolved_preview_context_check_is_retried_at_stop(self):
        server = self.make_server(
            ["Use Claude", "", "Use coffee"], context="Claude", language="English"
        )
        self.preview(server, [])
        final = self.final(server)
        self.assertEqual(final["text"], "Use coffee")
        self.assertEqual(final["mode"], "reuse-exact-context-check-fallback")

    def test_new_speech_still_gets_a_fresh_complete_final(self):
        server = self.make_server(["打开", "打开", "打开 settings"])
        self.preview(server, [voice(0.2)])
        server.buf = np.concatenate((server.buf, voice(0.2)))
        final = self.final(server)
        self.assertEqual(final["text"], "打开 settings")
        self.assertEqual(final["mode"], "fresh-final")
        self.assertEqual(len(server.session.calls), 3)

    def test_explicit_short_language_preference_is_still_honored(self):
        server = self.make_server(["打开 settings", "打开设置"], seconds=1.0)
        server._utterance_short_language = "Chinese"
        self.preview(server, [])
        final = self.final(server)
        self.assertEqual(final["text"], "打开设置")
        self.assertEqual(server.session.calls, [{}, {"language": "Chinese"}])

    def test_context_change_invalidates_verified_preview(self):
        server = self.make_server(
            ["Testing LoRA", "Testing Laura", "Use Python"],
            context="LoRA",
            language="English",
        )
        self.preview(server, [])
        server.set_context("")
        final = self.final(server)
        self.assertEqual(final["text"], "Use Python")
        self.assertEqual(final["mode"], "fresh-final")

    def test_preview_completed_during_stop_keeps_verified_text(self):
        server = self.make_server(
            ["Testing LoRA", "Testing Laura", "Testing coffee"],
            context="LoRA",
            language="English",
        )

        class FinishingPreview:
            def join(_self, timeout):
                # stop() has set active=False; finish the pending decode just
                # as a real inference thread does before returning from join.
                result = server._decode_preview_result(server.buf, server.context)
                server._last_preview_text = result.text
                server._last_preview_len = len(server.buf)
                server._last_preview_context_revision = server._context_revision
                server._last_preview_detected_language = result.language
                server._last_preview_context_verified = getattr(result, "context_verified", False)

            def is_alive(_self):
                return False

        server._thread = FinishingPreview()
        final = self.final(server)
        self.assertEqual(final["text"], "Testing LoRA")
        self.assertEqual(final["mode"], "reuse-exact")
        self.assertEqual(len(server.session.calls), 2)
