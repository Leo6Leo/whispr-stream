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
