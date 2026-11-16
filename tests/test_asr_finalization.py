"""Preview-to-final regression tests with deterministic decoder output."""

import sys
import threading
import time
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


def silence(seconds):
    return np.zeros(int(seconds * asr_server.SAMPLE_RATE), dtype=np.float32)


def samples(seconds):
    return int(seconds * asr_server.SAMPLE_RATE)


class FinalizationTests(unittest.TestCase):
    def make_server(self, outputs, *, seconds=5.0, context="", language=None):
        calls = []
        lengths = []
        responses = iter(outputs)

        def transcribe(audio, **kwargs):
            calls.append(kwargs)
            lengths.append(len(audio))
            response = next(responses)
            if isinstance(response, Exception):
                raise response
            return SimpleNamespace(text=response, language=language or "Chinese")

        session = SimpleNamespace(transcribe=transcribe, calls=calls, lengths=lengths)
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
        self.assertEqual(final["reviews"], [review])

    def test_resolved_flip_does_not_ask_user_to_choose(self):
        server = self.make_server(["Use Codex."] * 2 + ["Use Codec.", "Use Codex."])
        self.preview(server, [voice(0.2)] * 3)
        final = self.final(server)
        self.assertNotIn("review", final)
        self.assertNotIn("reviews", final)

    def test_learned_terms_are_hints_without_forced_spelling_replacement(self):
        server = self.make_server(["Use Codec."])
        server.set_learned_context("Codex")
        self.preview(server, [])
        self.assertEqual(self.final(server)["text"], "Use Codec.")
        self.assertEqual(server.session.calls, [{"context": "Codex"}])

    def test_everyday_words_never_become_learned_hints(self):
        server = self.make_server(["Use Codec."])
        server.set_learned_context("the\na\nCodex\n它\nthe")
        self.assertEqual(server.learned_context, "Codex")
        self.preview(server, [])
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
                    if old == "Use Codex and Vim":
                        # Two word swaps are a stepped choice, not a rewrite.
                        self.assertEqual(
                            [(r["preferred"], r["alternative"]) for r in final["reviews"]],
                            [("Codec", "Codex"), ("Emacs", "Vim")],
                        )
                    else:
                        self.assertNotIn("reviews", final)
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

    def test_thinking_pause_is_compressed_only_for_the_final_decode(self):
        # Previews decode the real timeline and already show the spurious 。;
        # the final pass must decode the shrunken pause and not reuse them.
        # The pause itself is never decoded as a preview.
        with_period = "所以我要。多花几秒钟时间"
        server = self.make_server(
            ["所以我要", with_period, "所以我要多花几秒钟时间"]
        )
        self.preview(server, [silence(3.0), voice(2.0)])
        final = self.final(server)
        self.assertEqual(final["text"], "所以我要多花几秒钟时间")
        self.assertEqual(final["mode"], "fresh-final-pause-compressed")
        self.assertEqual(final["secs"], 10.0)
        self.assertEqual(
            server.session.lengths,
            [samples(5.0), samples(10.0), samples(7.5)],
        )

    def test_stable_preview_spanning_a_pause_is_not_reused_at_stop(self):
        with_period = "所以我要。多花几秒钟时间"
        server = self.make_server([with_period] * 3 + ["所以我要多花几秒钟时间"])
        server.buf = np.concatenate((voice(2.0), silence(2.0), voice(2.0)))
        self.preview(server, [voice(0.2)] * 2)
        final = self.final(server)
        self.assertEqual(final["text"], "所以我要多花几秒钟时间")
        self.assertEqual(final["mode"], "fresh-final-pause-compressed")
        self.assertEqual(server.session.lengths[-1], samples(6.4 - 2.0 + 0.5))

    def test_short_internal_pause_keeps_exact_preview_reuse(self):
        original = "先打开设置"
        server = self.make_server([original, original, "unexpected"])
        self.preview(server, [np.concatenate((silence(1.0), voice(0.5)))])
        final = self.final(server)
        self.assertEqual(final["text"], original)
        self.assertEqual(final["mode"], "reuse-exact")
        self.assertEqual(len(server.session.calls), 2)

    def test_long_trailing_silence_is_not_compressed_and_preview_is_reused(self):
        original = "我用Codex写代码。"
        server = self.make_server([original, original, "unexpected"])
        events = self.preview(server, [voice(0.2), silence(1.8)])
        self.assertEqual(events[-1]["committed"] + events[-1]["tail"], original)
        final = self.final(server)
        self.assertEqual(final["text"], original)
        self.assertEqual(final["mode"], "reuse-silent-tail")
        self.assertEqual(len(server.session.calls), 2)

    def test_short_clip_language_follows_spoken_length_not_compressed_length(self):
        # 0.3 s + 1.6 s pause + 0.3 s is 2.2 s spoken: automatic detection.
        # Compressed it is 1.1 s, which must not re-enable the short-clip hint.
        server = self.make_server(["打开 settings"], seconds=0.0)
        server._utterance_short_language = "Chinese"
        server.buf = np.concatenate((voice(0.3), silence(1.6), voice(0.3)))
        final = self.final(server)
        self.assertEqual(final["mode"], "fresh-final-pause-compressed")
        self.assertEqual(server.session.calls, [{}])
        self.assertEqual(server.session.lengths, [samples(1.1)])

    def test_cold_model_before_the_first_preview_is_reported_and_cleared(self):
        server = self.make_server([])
        server._utterance_seq = 1
        server._first_preview_pending = True
        server._model_busy_since = time.perf_counter() - 1.2
        emitted = []
        with patch.object(asr_server, "emit", emitted.append):
            watcher = threading.Thread(target=server._watch_warming, args=(1,))
            watcher.start()
            time.sleep(0.3)
            self.assertEqual(emitted, [{"type": "warming"}])
            server._model_busy_since = None
            time.sleep(0.3)
            self.assertEqual(emitted, [{"type": "warming"}, {"type": "warmed"}])
            # A slow first preview right after the slow pre-roll warns again.
            server._model_busy_since = time.perf_counter() - 1.2
            time.sleep(0.3)
            server._model_busy_since = None
            server._first_preview_pending = False
            watcher.join(timeout=2)
        self.assertFalse(watcher.is_alive())
        self.assertEqual(
            emitted,
            [{"type": "warming"}, {"type": "warmed"}, {"type": "warming"}, {"type": "warmed"}],
        )

    def test_fast_model_never_reports_warming(self):
        server = self.make_server([])
        server._utterance_seq = 1
        server._first_preview_pending = True
        server._model_busy_since = time.perf_counter()
        emitted = []
        with patch.object(asr_server, "emit", emitted.append):
            watcher = threading.Thread(target=server._watch_warming, args=(1,))
            watcher.start()
            time.sleep(0.2)
            server._model_busy_since = None
            server._first_preview_pending = False
            watcher.join(timeout=2)
        self.assertFalse(watcher.is_alive())
        self.assertEqual(emitted, [])

    def test_preview_stays_idle_through_a_pause_until_speech_returns(self):
        # Three seconds of room tone are never decoded. Speech after the
        # pause waits for 200 ms of voice, so the decode has a word to show.
        server = self.make_server(["所以我要", "所以我要多花"], seconds=1.0)
        self.preview(
            server,
            [silence(1.0), silence(1.0), silence(1.0), voice(0.1), voice(0.2)],
        )
        self.assertEqual(server.session.lengths, [samples(1.0), samples(4.3)])

    def test_vocabulary_check_uses_the_spoken_length_for_its_language(self):
        # 1.8 s idle + 0.5 s + 0.3 s is 2.6 s spoken; trimmed it is 1.3 s.
        # The unbiased check must run in the same automatic mode as the
        # prompted decode it verifies, not the short-clip language.
        server = self.make_server(["用 Codex", "用 Codex"], seconds=0.0, context="Codex")
        server._utterance_short_language = "Chinese"
        server.buf = np.concatenate((silence(1.8), voice(0.5), silence(0.3)))
        final = self.final(server)
        self.assertEqual(final["text"], "用 Codex")
        self.assertEqual(server.session.calls, [{"context": "Codex"}, {}])
        self.assertEqual(server.session.lengths, [samples(1.3), samples(1.3)])


    def test_long_trailing_silence_is_trimmed_for_the_fresh_final_decode(self):
        # Twelve idle seconds after two words are far past the 2 s reuse tail,
        # so this is a fresh decode; it must see half a second of that idle.
        server = self.make_server(["Okay, so."], seconds=0.0)
        server.buf = np.concatenate((voice(2.0), silence(12.0)))
        final = self.final(server)
        self.assertEqual(final["text"], "Okay, so.")
        self.assertEqual(final["mode"], "fresh-final-edge-trimmed")
        self.assertEqual(final["secs"], 14.0)
        self.assertEqual(server.session.lengths, [samples(2.5)])

    def test_long_leading_silence_is_trimmed_and_blocks_preview_reuse(self):
        # Every preview saw the six quiet seconds before the speech and may
        # carry invented words ahead of it, so a stable preview is not reused.
        original = "测试一下"
        server = self.make_server([original] * 3 + [original], seconds=0.0)
        server.buf = np.concatenate((silence(6.0), voice(1.0)))
        self.preview(server, [voice(0.2)] * 2)
        final = self.final(server)
        self.assertEqual(final["text"], original)
        self.assertEqual(final["mode"], "fresh-final-edge-trimmed")
        self.assertEqual(final["secs"], 7.4)
        self.assertEqual(server.session.lengths[-1], samples(0.5 + 1.4))

    def test_pause_compression_and_edge_trimming_combine(self):
        server = self.make_server(["好的"], seconds=0.0)
        server.buf = np.concatenate(
            (silence(3.0), voice(1.0), silence(3.0), voice(1.0), silence(4.0))
        )
        final = self.final(server)
        self.assertEqual(final["mode"], "fresh-final-pause-compressed-edge-trimmed")
        self.assertEqual(final["secs"], 12.0)
        self.assertEqual(server.session.lengths, [samples(0.5 + 1.0 + 0.5 + 1.0 + 0.5)])


class PauseCompressionTests(unittest.TestCase):
    def test_only_internal_long_pauses_shrink(self):
        lead, a, pause, b, tail = silence(2.0), voice(1.0), silence(3.0), voice(1.0), silence(2.5)
        audio = np.concatenate((lead, a, pause, b, tail))
        out = asr_server.compress_internal_pauses(audio)
        self.assertEqual(len(out), len(audio) - samples(2.5))
        head = len(lead) + len(a) + samples(0.25)
        np.testing.assert_array_equal(out[:head], audio[:head])
        tail_len = len(tail) + len(b) + samples(0.25)
        np.testing.assert_array_equal(out[-tail_len:], audio[-tail_len:])

    def test_every_long_pause_shrinks_and_short_ones_stay(self):
        audio = np.concatenate(
            (voice(1.0), silence(1.4), voice(1.0), silence(5.0), voice(0.5), silence(1.6), voice(0.5))
        )
        out = asr_server.compress_internal_pauses(audio)
        self.assertEqual(len(out), len(audio) - samples(4.5) - samples(1.1))

    def test_unchanged_audio_is_returned_as_the_same_object(self):
        for audio in (
            np.concatenate((voice(1.0), silence(1.4), voice(1.0))),
            silence(6.0),
            voice(3.0),
            np.zeros(0, dtype=np.float32),
        ):
            self.assertIs(asr_server.compress_internal_pauses(audio), audio)

    def test_room_tone_pause_counts_as_quiet(self):
        rng = np.random.default_rng(1)
        tone = (rng.standard_normal(samples(3.0)) * 0.004).astype(np.float32)
        audio = np.concatenate((voice(1.0), tone, voice(1.0)))
        self.assertEqual(len(asr_server.compress_internal_pauses(audio)), samples(2.5))

    def test_quiet_speech_inside_a_gap_is_preserved(self):
        # RMS ~0.017 is speech-level for has_speech; it must break the run.
        murmur = voice(0.4) * 0.6
        audio = np.concatenate((voice(1.0), silence(1.0), murmur, silence(1.0), voice(1.0)))
        self.assertIs(asr_server.compress_internal_pauses(audio), audio)


class EdgeTrimTests(unittest.TestCase):
    def test_only_long_edges_shrink_and_keep_their_half_second(self):
        lead, speech, tail = silence(3.0), voice(1.0), silence(2.5)
        audio = np.concatenate((lead, speech, tail))
        out, lead_trimmed, tail_trimmed = asr_server.trim_edge_silence(audio)
        self.assertTrue(lead_trimmed and tail_trimmed)
        self.assertEqual(len(out), samples(0.5 + 1.0 + 0.5))
        np.testing.assert_array_equal(out[samples(0.5):samples(1.5)], speech)

    def test_short_edges_are_left_alone(self):
        audio = np.concatenate((silence(1.4), voice(1.0), silence(1.5)))
        out, lead_trimmed, tail_trimmed = asr_server.trim_edge_silence(audio)
        self.assertIs(out, audio)
        self.assertFalse(lead_trimmed or tail_trimmed)

    def test_internal_pauses_are_not_touched_by_edge_trimming(self):
        audio = np.concatenate((voice(1.0), silence(5.0), voice(1.0)))
        self.assertIs(asr_server.trim_edge_silence(audio)[0], audio)

    def test_quiet_only_audio_is_returned_unchanged(self):
        for audio in (silence(6.0), np.zeros(0, dtype=np.float32)):
            self.assertIs(asr_server.trim_edge_silence(audio)[0], audio)


class FirstPreviewTests(FinalizationTests):
    """The first preview of an utterance waits for real speech, and an empty
    preview re-arms on the next microphone chunk instead of MIN_NEW_AUDIO."""

    def make_utterance(self, outputs, audio):
        server = self.make_server(outputs)
        server.buf = audio
        server._first_preview_pending = True
        server._speech_gate_misses = 0
        server._utterance_started = asr_server.time.perf_counter()
        return server

    def run_loop(self, server, *, on_cooldown=(), on_sleep=()):
        """Drive the real loop. Cooldowns and poll sleeps each append audio;
        once a list is exhausted its next call ends the loop."""
        cooldowns = iter(on_cooldown)
        sleeps = iter(on_sleep)

        class AdvanceAudio:
            def wait(self, timeout):
                addition = next(cooldowns, None)
                if addition is None:
                    return True
                server.buf = np.concatenate((server.buf, addition))
                return False

            def set(self):
                pass

        def fake_sleep(_seconds):
            addition = next(sleeps, None)
            if addition is None:
                server.active = False
                return
            server.buf = np.concatenate((server.buf, addition))

        server._preview_stop = AdvanceAudio()
        with patch.object(asr_server, "emit") as emitted, \
             patch.object(asr_server.time, "sleep", new=fake_sleep):
            server._loop()
        return [call.args[0] for call in emitted.call_args_list]

    def test_first_preview_waits_for_200ms_of_speech(self):
        # 0.4 s of audio with 100 ms of speech passes the final-decode gate
        # but is not enough for a first preview; one more 100 ms chunk is.
        opening = np.concatenate((silence(0.3), voice(0.1)))
        self.assertTrue(asr_server.has_speech(opening))
        server = self.make_utterance(["Hello"], opening)
        events = self.run_loop(server, on_sleep=[voice(0.1)])
        self.assertEqual(server.session.lengths, [samples(0.5)])
        self.assertEqual(server._speech_gate_misses, 1)
        self.assertEqual(events[-1]["committed"] + events[-1]["tail"], "Hello")

    def test_later_previews_keep_the_normal_cadence(self):
        server = self.make_utterance(["Hello", "Hello there"], voice(0.5))
        events = self.run_loop(server, on_cooldown=[voice(0.2)])
        self.assertFalse(server._first_preview_pending)
        self.assertEqual(server.session.lengths, [samples(0.5), samples(0.7)])
        self.assertEqual(events[-1]["committed"] + events[-1]["tail"], "Hello there")

    def test_empty_preview_rearms_on_the_next_microphone_chunk(self):
        server = self.make_utterance(["", "Hello"], voice(0.5))
        events = self.run_loop(server, on_cooldown=[voice(0.04)])
        self.assertEqual(server.session.lengths, [samples(0.5), samples(0.54)])
        self.assertEqual(events[-1]["committed"] + events[-1]["tail"], "Hello")

    def test_utterance_start_prerolls_the_model_before_audio_arrives(self):
        # The fake decoder answers the silent pre-roll first, then the speech.
        server = self.make_utterance(["", "Hello"], silence(0))
        chunks = [voice(0.1)] * 5
        events = self.run_loop(server, on_sleep=chunks)
        # One silent pre-roll decode, no partial for it, then the real decode
        # once 0.3 s of audio holds 200 ms of speech.
        self.assertEqual(server.session.lengths[0], samples(asr_server.PREROLL_SEC))
        self.assertEqual(server.session.lengths[1:], [samples(0.3)])
        self.assertGreaterEqual(server._preroll_ms, 0)
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["committed"] + events[0]["tail"], "Hello")

    def test_no_preroll_when_audio_is_already_waiting(self):
        server = self.make_utterance(["Hello"], voice(0.5))
        self.run_loop(server)
        self.assertEqual(server.session.lengths, [samples(0.5)])

    def test_non_empty_preview_still_waits_for_min_new_audio(self):
        server = self.make_utterance(["Hi", "Hi there"], voice(0.5))
        events = self.run_loop(server, on_cooldown=[voice(0.04)], on_sleep=[voice(0.04)] * 2)
        # 40 ms chunks accumulate to 120 ms < MIN_NEW_AUDIO; the loop polls
        # without decoding until the harness ends it.
        self.assertEqual(server.session.lengths, [samples(0.5)])
        self.assertEqual(events[-1]["committed"] + events[-1]["tail"], "Hi")


class FinalModelTests(unittest.TestCase):
    """Previews on the fast model, the final text from a second model."""

    def make_server(self, preview_outputs, final_outputs, *, context="",
                    final_model="large", fail_final_load=False, seconds=5.0,
                    model="small", language="Chinese"):
        def fake_session(outputs):
            calls = []
            responses = iter(outputs)

            def transcribe(audio, **kwargs):
                calls.append(kwargs)
                return SimpleNamespace(text=next(responses), language=language)

            return SimpleNamespace(transcribe=transcribe, calls=calls)

        preview_session = fake_session(preview_outputs)
        final_session = fake_session(final_outputs)
        loaded = []

        def build_session(model_id, bits, *, engine="qwen3", warm=True):
            loaded.append(model_id)
            if model_id in ("large", "Qwen/Qwen3-ASR-1.7B") and model_id != model:
                if fail_final_load:
                    raise RuntimeError("weights missing")
                return final_session, 0
            return preview_session, 0

        with patch.object(asr_engine, "build_session", side_effect=build_session), \
             patch.object(asr_server, "emit") as emitted:
            server = asr_server.Server(model, 8, context, final_model_id=final_model)
        self.ready = [call.args[0] for call in emitted.call_args_list]
        self.loaded = loaded
        self.preview_session, self.final_session = preview_session, final_session
        server.buf = voice(seconds)
        server.active = True
        return server

    preview = FinalizationTests.preview
    final = FinalizationTests.final

    def test_final_text_comes_from_the_final_model_even_with_an_exact_preview(self):
        server = self.make_server(["我明日了。"], ["我 merge 了。"])
        self.preview(server, [])
        final = self.final(server)
        self.assertEqual(final["text"], "我 merge 了。")
        self.assertEqual(final["mode"], "fresh-final-final-model")
        self.assertEqual(len(self.preview_session.calls), 1)
        self.assertEqual(len(self.final_session.calls), 1)

    def test_disagreement_with_the_preview_never_asks_a_question(self):
        server = self.make_server(["Use Codex."] * 3, ["Use Codec."])
        self.preview(server, [voice(0.2)] * 2)
        final = self.final(server)
        self.assertEqual(final["text"], "Use Codec.")
        self.assertNotIn("review", final)
        self.assertNotIn("reviews", final)

    def test_vocabulary_check_runs_on_the_final_model(self):
        server = self.make_server(["Use Claude"] * 2, ["Use Claude", "Use Cloud"], context="Claude")
        self.preview(server, [])
        before = len(self.preview_session.calls)
        self.final(server)
        self.assertEqual(len(self.preview_session.calls), before)
        self.assertEqual(self.final_session.calls, [{"context": "Claude", "language": "Chinese"}, {}])

    def test_same_or_empty_final_model_loads_one_session(self):
        for final_model in ("", "small"):
            with self.subTest(final_model=final_model):
                server = self.make_server(["你好。"], [], final_model=final_model)
                self.assertIsNone(server.final_session)
                self.assertEqual(self.loaded, ["small"])
                self.preview(server, [])
                self.assertEqual(self.final(server)["mode"], "reuse-exact")

    def test_final_model_that_cannot_load_falls_back_to_the_preview_model(self):
        server = self.make_server(["你好。"], [], fail_final_load=True)
        self.assertIsNone(server.final_session)
        self.assertEqual([event["type"] for event in self.ready], ["ready"])
        self.preview(server, [])
        self.assertEqual(self.final(server)["text"], "你好。")

    def test_idle_final_model_is_woken_once_while_speaking(self):
        server = self.make_server(["你好。"] * 3, ["", "你好啊。"])
        server._final_session_used_at = time.perf_counter() - 60
        self.preview(server, [voice(0.2)] * 2)
        self.assertEqual(self.final_session.calls, [{}])
        self.assertEqual(self.final(server)["text"], "你好啊。")

    def test_recently_used_final_model_is_not_woken(self):
        server = self.make_server(["你好。"] * 2, ["你好啊。"])
        self.preview(server, [voice(0.2)])
        self.assertEqual(self.final_session.calls, [])

    def test_final_model_is_woken_once_per_long_utterance(self):
        # Previously every preview past FINAL_MODEL_IDLE_WAKE_SEC re-woke the
        # model, stalling live text every 15 s of one long dictation.
        server = self.make_server(["你好。"] * 5, ["", "你好啊。"])
        with patch.object(asr_server, "FINAL_MODEL_IDLE_WAKE_SEC", 0.0):
            self.preview(server, [voice(0.2)] * 4)
            self.assertEqual(self.final_session.calls, [{}])
            self.assertEqual(self.final(server)["text"], "你好啊。")

    def test_long_utterance_rewakes_only_after_the_long_interval(self):
        server = self.make_server(["你好。"] * 4, ["", ""])
        server._final_session_used_at = time.perf_counter() - 60
        remaining = iter([voice(0.2)] * 3)

        class AgeFinalModel:
            def wait(self, timeout):
                addition = next(remaining, None)
                if addition is None:
                    return True
                server.buf = np.concatenate((server.buf, addition))
                # Pretend the model sat idle well past the 15 s threshold but
                # short of the re-wake interval, then past that interval too.
                idle = 16.0 if len(server.buf) < samples(5.5) else asr_server.FINAL_MODEL_REWAKE_SEC + 1
                server._final_session_used_at = time.perf_counter() - idle
                return False

            def set(self):
                pass

        server._preview_stop = AgeFinalModel()
        with patch.object(asr_server, "emit"):
            server._loop()
        # Woken after the first preview, not at 16 s idle, again past 60 s.
        self.assertEqual(self.final_session.calls, [{}, {}])

    def test_next_utterance_wakes_the_final_model_again(self):
        server = self.make_server(["你好。"] * 4, ["", ""])
        server._final_session_used_at = time.perf_counter() - 60
        self.preview(server, [])
        self.assertEqual(len(self.final_session.calls), 1)
        server._preview_stop = asr_server.threading.Event()
        with patch.object(asr_server.threading, "Thread"):
            server.start()
        server._thread = None
        server.buf = voice(5.0)
        server._final_session_used_at = time.perf_counter() - 60
        self.preview(server, [])
        self.assertEqual(len(self.final_session.calls), 2)

    # -- stop() while the preview thread is still decoding ------------------

    def run_preview_thread(self, server):
        server._preview_stop = threading.Event()
        server._thread = threading.Thread(target=server._loop, daemon=True)
        server._thread.start()

    def blocking(self, session, outputs, block_on_call):
        """Make call number ``block_on_call`` wait until the test releases it."""
        entered, release = threading.Event(), threading.Event()
        responses = iter(outputs)

        def transcribe(audio, **kwargs):
            session.calls.append(kwargs)
            if len(session.calls) == block_on_call:
                entered.set()
                release.wait(timeout=5)
            return SimpleNamespace(text=next(responses), language="Chinese")

        session.transcribe = transcribe
        return entered, release

    def test_stop_during_a_wake_waits_for_it_and_keeps_the_dictation(self):
        server = self.make_server(["你好。"] * 3, [])
        server._final_session_used_at = time.perf_counter() - 60
        entered, release = self.blocking(self.final_session, ["", "你好啊。"], 1)
        with patch.object(asr_server, "emit"):
            self.run_preview_thread(server)
            self.assertTrue(entered.wait(timeout=2))
        threading.Timer(0.05, release.set).start()
        final = self.final(server)
        self.assertEqual(final["text"], "你好啊。")
        self.assertIsNone(server._thread)
        # The wake, then the final; no second preview or wake after release.
        self.assertEqual(len(self.final_session.calls), 2)
        self.assertEqual(len(self.preview_session.calls), 1)

    def test_stop_during_a_preview_skips_the_wake(self):
        server = self.make_server([], ["你好啊。"])
        server._final_session_used_at = time.perf_counter() - 60
        entered, release = self.blocking(self.preview_session, ["你好。"] * 2, 1)
        with patch.object(asr_server, "emit"):
            self.run_preview_thread(server)
            self.assertTrue(entered.wait(timeout=2))
        threading.Timer(0.05, release.set).start()
        self.assertEqual(self.final(server)["text"], "你好啊。")
        # Only the final ran on the large model: the final pages it in itself.
        self.assertEqual(len(self.final_session.calls), 1)

    def test_large_final_model_never_sees_the_vocabulary_prompt(self):
        server = self.make_server(
            ["不要 post 任何东西。"], ["不要 post 任何东西，用 Cloud。"],
            context="Claude", final_model="Qwen/Qwen3-ASR-1.7B",
        )
        server.set_learned_context("Codex")
        self.preview(server, [])
        final = self.final(server)
        # One unprompted decode; the vocabulary spelling is restored after it.
        self.assertEqual(self.final_session.calls, [{"language": "Chinese"}])
        self.assertEqual(final["text"], "不要 post 任何东西，用 Claude。")
        self.assertEqual(final["mode"], "fresh-final-final-model-context-variant-canonicalized")
        self.assertEqual(self.preview_session.calls[0], {"context": "Claude\nCodex"})

    def test_large_model_on_its_own_is_also_unprompted(self):
        server = self.make_server(
            ["用 Cloud。", "用 Cloud。"], [], context="Claude",
            final_model="", model="Qwen/Qwen3-ASR-1.7B",
        )
        events = self.preview(server, [])
        self.assertEqual(self.preview_session.calls, [{}])
        self.assertEqual(events[-1]["committed"] + events[-1]["tail"], "用 Claude。")

    def test_other_final_models_keep_the_vocabulary_prompt(self):
        server = self.make_server(["Use Codec."], ["Use Codec."], context="Sharada")
        self.preview(server, [])
        self.final(server)
        self.assertEqual(self.final_session.calls, [{"context": "Sharada", "language": "Chinese"}])

    def test_final_model_takes_its_language_from_the_fast_model(self):
        server = self.make_server(["不要 post 任何东西。"], ["不要 post 任何东西。"])
        self.preview(server, [])
        self.final(server)
        self.assertEqual(self.final_session.calls, [{"language": "Chinese"}])

    def test_translated_final_is_replaced_by_the_fast_models_final(self):
        server = self.make_server(
            ["不要 post 任何东西。", "不要 post 任何东西。"], ["Don't post any things."]
        )
        self.preview(server, [])
        final = self.final(server)
        self.assertEqual(final["text"], "不要 post 任何东西。")
        self.assertEqual(final["mode"], "fresh-final-final-model-rejected")
        self.assertNotIn("reviews", final)

    def test_english_speech_written_in_chinese_is_replaced_too(self):
        server = self.make_server(
            ["When would you be free?"] * 2, ["你什么时候有空？"], language="English"
        )
        self.preview(server, [])
        self.assertEqual(self.final(server)["text"], "When would you be free?")

    def test_mixed_speech_is_not_mistaken_for_translation(self):
        cases = [
            ("那你 spin up 一个 sub agent 的 ops 来修复一下吧。", "那你 spin up 一个 sub agent 的 opus 来修复一下吧。"),
            ("十三。When would you be free?", "Sure thing. When would you be free?"),
            ("我明日了。", "我 merge 了。"),
            ("", "Don't post any things."),
        ]
        for preview, final in cases:
            with self.subTest(final=final):
                self.assertFalse(asr_server.final_translated_the_speech(preview, final))
        self.assertTrue(asr_server.final_translated_the_speech(
            "这个太麻烦了。我想先确定这个能不能 work", "This is too much. I want to first confirm if this can work."
        ))


class StopWaitTests(unittest.TestCase):
    """stop() waits out a slow preview thread instead of dropping the text."""

    def make_server(self, outputs):
        session = SimpleNamespace(
            transcribe=lambda audio, **kw: SimpleNamespace(text=next(outputs), language="Chinese")
        )
        with patch.object(asr_engine, "build_session", return_value=(session, 0)), \
             patch.object(asr_server, "emit"):
            server = asr_server.Server("test", 8, "")
        server.buf = voice(3.0)
        server.active = True
        return server

    def scripted_thread(self, server, clock, decodes, ends_at):
        """A preview thread on a fake clock: decode boundaries, then exit."""

        class Thread:
            def join(self, timeout=None):
                clock[0] += timeout
                for boundary in decodes:
                    if boundary <= clock[0]:
                        server._decode_progress_at = boundary

            def is_alive(self):
                return ends_at is None or clock[0] < ends_at

        return Thread()

    def stop(self, server, thread, clock):
        server._thread = thread
        with patch.object(asr_server.time, "perf_counter", lambda: clock[0]), \
             patch.object(asr_server, "emit") as emitted:
            server.stop()
        return [call.args[0] for call in emitted.call_args_list]

    def test_slow_but_progressing_decodes_are_waited_out(self):
        # A 3.1 s cold wake, then a 4 s preview decode: 7.1 s in all, past the
        # old fixed 5 s join that threw the dictation away.
        clock = [100.0]
        server = self.make_server(iter(["你好。"]))
        thread = self.scripted_thread(server, clock, [100.0, 103.1, 103.1, 107.1], 107.1)
        events = self.stop(server, thread, clock)
        self.assertEqual([event["type"] for event in events], ["final"])
        self.assertEqual(events[0]["text"], "你好。")
        self.assertIsNone(server._thread)

    def test_a_hung_decode_still_gives_up_and_keeps_the_thread(self):
        clock = [100.0]
        server = self.make_server(iter([]))
        thread = self.scripted_thread(server, clock, [100.0], None)
        events = self.stop(server, thread, clock)
        self.assertEqual(events, [{"type": "error", "message": "final: preview decode did not stop"}])
        self.assertAlmostEqual(clock[0] - 100.0, asr_server.PREVIEW_DECODE_STALL_SEC, delta=0.1)
        # start() can still wait for it before the next dictation.
        self.assertIs(server._thread, thread)

    def test_endless_progress_is_still_bounded(self):
        clock = [100.0]
        server = self.make_server(iter([]))
        boundaries = [100.0 + 0.5 * step for step in range(1000)]
        thread = self.scripted_thread(server, clock, boundaries, None)
        events = self.stop(server, thread, clock)
        self.assertEqual(events[0]["type"], "error")
        self.assertAlmostEqual(clock[0] - 100.0, asr_server.STOP_PREVIEW_WAIT_MAX_SEC, delta=0.1)
