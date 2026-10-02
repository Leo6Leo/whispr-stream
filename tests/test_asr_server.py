import sys
import threading
import unittest
from unittest.mock import patch
from pathlib import Path
from types import SimpleNamespace

import numpy as np


RESOURCES = Path(__file__).parents[1] / "WhisprStream" / "Resources"
sys.path.insert(0, str(RESOURCES))

import asr_server  # noqa: E402


class SilenceDetectionTests(unittest.TestCase):
    def test_audio_buffer_has_headroom_over_ui_limit(self):
        self.assertGreater(asr_server.MAX_BUFFER_SEC, 45.0)

    def test_room_noise_is_silence(self):
        rng = np.random.default_rng(7)
        audio = rng.normal(0, 0.008, int(0.4 * asr_server.SAMPLE_RATE)).astype(np.float32)
        self.assertTrue(asr_server.is_confident_silence(audio))

    def test_quiet_speech_level_is_not_silence(self):
        samples = np.arange(int(0.2 * asr_server.SAMPLE_RATE), dtype=np.float32)
        audio = 0.035 * np.sin(2 * np.pi * 180 * samples / asr_server.SAMPLE_RATE)
        self.assertFalse(asr_server.is_confident_silence(audio))

    def test_speech_floor_is_excluded_from_confident_silence(self):
        window = int(asr_server.SILENCE_WINDOW_SEC * asr_server.SAMPLE_RATE)
        for rms in (asr_server.SPEECH_MIN_WINDOW_RMS, 0.017, 0.019, 0.02):
            for dtype in (np.float32, np.float64):
                with self.subTest(rms=rms, dtype=dtype):
                    audio = np.full(3 * window, rms, dtype=dtype)
                    self.assertTrue(asr_server.has_speech(audio))
                    self.assertFalse(asr_server.is_confident_silence(audio))

    def test_brief_speech_level_tail_is_not_confident_silence(self):
        window = int(asr_server.SILENCE_WINDOW_SEC * asr_server.SAMPLE_RATE)
        # Startup requires three active frames. Tail preservation must also
        # protect a single frame or incomplete final frame of a quiet word.
        for tail_samples in (1, window // 2, window):
            with self.subTest(tail_samples=tail_samples):
                audio = np.concatenate((
                    np.zeros(window, dtype=np.float32),
                    np.full(tail_samples, 0.017, dtype=np.float32),
                ))
                self.assertFalse(asr_server.has_speech(audio))
                self.assertFalse(asr_server.is_confident_silence(audio))

    def test_transient_is_not_silence(self):
        audio = np.zeros(int(0.2 * asr_server.SAMPLE_RATE), dtype=np.float32)
        audio[len(audio) // 2] = 0.08
        self.assertFalse(asr_server.is_confident_silence(audio))

    def test_room_noise_does_not_count_as_speech(self):
        rng = np.random.default_rng(7)
        audio = rng.normal(0, 0.008, int(0.4 * asr_server.SAMPLE_RATE)).astype(np.float32)
        self.assertFalse(asr_server.has_speech(audio))

    def test_quiet_voice_counts_as_speech(self):
        samples = np.arange(int(0.2 * asr_server.SAMPLE_RATE), dtype=np.float32)
        audio = 0.035 * np.sin(2 * np.pi * 180 * samples / asr_server.SAMPLE_RATE)
        self.assertTrue(asr_server.has_speech(audio))

    def test_single_loud_click_does_not_count_as_speech(self):
        audio = np.zeros(int(0.4 * asr_server.SAMPLE_RATE), dtype=np.float32)
        window = int(asr_server.SILENCE_WINDOW_SEC * asr_server.SAMPLE_RATE)
        audio[window:2 * window] = 0.5
        self.assertFalse(asr_server.has_speech(audio))

    def test_silent_final_never_calls_decoder_or_reuses_context_hallucination(self):
        server = asr_server.Server.__new__(asr_server.Server)
        server.lock = threading.Lock()
        server.buf = np.zeros(asr_server.SAMPLE_RATE, dtype=np.float32)
        server.context = "Claude"
        server._context_revision = 0
        server._thread = None
        server._preview_stop = threading.Event()
        server.active = True

        with patch.object(server, "_decode", side_effect=AssertionError("decoded silence")), \
             patch.object(server, "_reusable_preview", side_effect=AssertionError("reused silence")), \
             patch.object(asr_server, "emit") as emitted:
            server.stop()

        final = emitted.call_args.args[0]
        self.assertEqual(final["type"], "final")
        self.assertEqual(final["text"], "")
        self.assertEqual(final["mode"], "no-speech")


class ContextHallucinationTests(unittest.TestCase):
    class FakeSession:
        def __init__(self, unprompted_text):
            self.unprompted_text = unprompted_text
            self.calls = []

        def transcribe(self, _audio, **kwargs):
            self.calls.append(kwargs)
            return SimpleNamespace(
                text=self.unprompted_text,
                language="English",
            )

    def make_server(self, unprompted_text):
        server = asr_server.Server.__new__(asr_server.Server)
        server.session = self.FakeSession(unprompted_text)
        server.short_utterance_language = None
        server._utterance_short_language = None
        return server

    def test_detects_complete_context_words_inside_transcript(self):
        context = "Claude\nCodex\n/retest-required"
        self.assertTrue(
            asr_server.transcript_contains_context_word("Use Claude here", context)
        )
        self.assertTrue(
            asr_server.transcript_contains_context_word("CODEX", context)
        )
        self.assertFalse(
            asr_server.transcript_contains_context_word("preClaude", context)
        )

    def test_non_latin_context_does_not_use_edit_distance_guard(self):
        self.assertFalse(
            asr_server.transcript_contains_context_word("你好", "你好")
        )
        self.assertFalse(
            asr_server.transcript_contains_context_word(
                "你好 GitHub",
                "你好 GitHub",
            )
        )

    def test_near_unprompted_spelling_supports_vocabulary_correction(self):
        self.assertTrue(
            asr_server.context_term_has_unprompted_support("Claude", "Cloud")
        )
        self.assertEqual(
            asr_server.best_supported_context_term(
                "Claude\nLoRA",
                "Laura",
            ),
            "LoRA",
        )
        self.assertFalse(
            asr_server.context_term_has_unprompted_support("Claude", "code")
        )

    def test_unrelated_or_empty_unprompted_result_rejects_context_term(self):
        self.assertFalse(
            asr_server.context_term_has_unprompted_support("Claude", "blorp")
        )
        self.assertFalse(
            asr_server.context_term_has_unprompted_support("Claude", "")
        )

    def test_canonicalizes_split_tooltips_and_lora_spelling(self):
        context = "Claude\nLoRA\ntooltips"
        self.assertEqual(
            asr_server.canonicalize_context_variants(
                "Open the two tips panel",
                context,
            ),
            "Open the tooltips panel",
        )
        self.assertEqual(
            asr_server.canonicalize_context_variants("Testing Laura", context),
            "Testing LoRA",
        )

    def test_does_not_join_unrelated_words_or_short_context_terms(self):
        self.assertEqual(
            asr_server.canonicalize_context_variants(
                "Here are two useful tips for PR",
                "tooltips\nPR",
            ),
            "Here are two useful tips for PR",
        )

    def test_verification_canonicalizes_split_tooltips_without_extra_decode(self):
        server = self.make_server("unused")

        result, mode = server._verify_context_result(
            np.zeros(asr_server.SAMPLE_RATE, dtype=np.float32),
            "Claude\ntooltips",
            asr_server.DecodeResult("Show two tips", "English"),
        )

        self.assertEqual(result.text, "Show tooltips")
        self.assertEqual(mode, "context-variant-canonicalized")
        self.assertEqual(server.session.calls, [])

    def test_split_unprompted_result_supports_prompted_tooltips(self):
        server = self.make_server("Show two tips")

        result, mode = server._verify_context_result(
            np.zeros(asr_server.SAMPLE_RATE, dtype=np.float32),
            "Claude\ntooltips",
            asr_server.DecodeResult("Show tooltips", "English"),
        )

        self.assertEqual(result.text, "Show tooltips")
        self.assertEqual(mode, "context-check-supported")
        self.assertEqual(server.session.calls, [{}])

    def test_verification_keeps_acoustically_supported_term(self):
        server = self.make_server("Cloud")
        original = asr_server.DecodeResult("Claude", "English")

        result, mode = server._verify_context_result(
            np.zeros(asr_server.SAMPLE_RATE, dtype=np.float32),
            "Claude\nCodex",
            original,
        )

        self.assertEqual(result, original)
        self.assertEqual(mode, "context-check-supported")
        self.assertEqual(server.session.calls, [{}])

    def test_verification_restores_saved_context_casing(self):
        server = self.make_server("Lora")

        result, mode = server._verify_context_result(
            np.zeros(asr_server.SAMPLE_RATE, dtype=np.float32),
            "Claude\nLoRA",
            asr_server.DecodeResult("LORA", "English"),
        )

        self.assertEqual(result.text, "LoRA")
        self.assertEqual(mode, "context-check-supported")

    def test_verification_redirects_wrong_context_term_to_supported_term(self):
        server = self.make_server("Laura")

        result, mode = server._verify_context_result(
            np.zeros(asr_server.SAMPLE_RATE, dtype=np.float32),
            "Claude\nLoRA",
            asr_server.DecodeResult("Claude", "English"),
        )

        self.assertEqual(result.text, "LoRA")
        self.assertEqual(mode, "context-check-redirected")

    def test_plain_final_spelling_canonicalizes_without_preview_dependency(self):
        server = self.make_server("unused")

        result, mode = server._verify_context_result(
            np.zeros(asr_server.SAMPLE_RATE, dtype=np.float32),
            "Claude\nLoRA",
            asr_server.DecodeResult("Testing Laura now", "English"),
            "Testing Claude now",
        )

        self.assertEqual(result.text, "Testing LoRA now")
        self.assertEqual(mode, "context-variant-canonicalized")
        self.assertEqual(server.session.calls, [])

    def test_live_preview_redirects_prompted_claude_to_lora(self):
        class PromptAwareSession:
            def __init__(self):
                self.calls = []

            def transcribe(self, _audio, **kwargs):
                self.calls.append(kwargs)
                text = "Testing Claude" if kwargs.get("context") else "Testing Laura"
                return SimpleNamespace(text=text, language="English")

        server = asr_server.Server.__new__(asr_server.Server)
        server.session = PromptAwareSession()
        server.short_utterance_language = "Chinese"
        server._utterance_short_language = "Chinese"

        result = server._decode_preview_result(
            np.zeros(asr_server.SAMPLE_RATE, dtype=np.float32),
            "Claude\nLoRA",
        )

        self.assertEqual(result.text, "Testing LoRA")
        self.assertEqual(
            server.session.calls,
            [{"context": "Claude\nLoRA"}, {}],
        )

    def test_verification_uses_unprompted_result_for_unrelated_audio(self):
        server = self.make_server("blorp")

        result, mode = server._verify_context_result(
            np.zeros(asr_server.SAMPLE_RATE, dtype=np.float32),
            "Claude\nCodex",
            asr_server.DecodeResult("Claude", "English"),
        )

        self.assertEqual(result.text, "blorp")
        self.assertEqual(mode, "context-check-fallback")
        self.assertEqual(server.session.calls, [{}])

    def test_ordinary_transcript_does_not_add_decode(self):
        server = self.make_server("unused")
        original = asr_server.DecodeResult("I use a model", "English")

        result, mode = server._verify_context_result(
            np.zeros(asr_server.SAMPLE_RATE, dtype=np.float32),
            "Claude\nCodex",
            original,
        )

        self.assertEqual(result, original)
        self.assertIsNone(mode)
        self.assertEqual(server.session.calls, [])

    def test_failed_verification_preserves_prompted_result(self):
        server = self.make_server("unused")
        server.session.transcribe = lambda *_args, **_kwargs: (_ for _ in ()).throw(
            RuntimeError("decoder unavailable")
        )
        original = asr_server.DecodeResult("Claude", "English")

        with patch("sys.stderr"):
            result, mode = server._verify_context_result(
                np.zeros(asr_server.SAMPLE_RATE, dtype=np.float32),
                "Claude\nCodex",
                original,
            )

        self.assertEqual(result, original)
        self.assertEqual(mode, "context-check-error")

    def test_stop_verifies_fresh_final_before_emitting(self):
        class PromptAwareSession:
            def __init__(self):
                self.calls = []

            def transcribe(self, _audio, **kwargs):
                self.calls.append(kwargs)
                text = "Claude" if kwargs.get("context") else "blorp"
                return SimpleNamespace(text=text, language="English")

        server = asr_server.Server.__new__(asr_server.Server)
        server.session = PromptAwareSession()
        server.lock = threading.Lock()
        samples = np.arange(asr_server.SAMPLE_RATE, dtype=np.float32)
        server.buf = 0.04 * np.sin(
            2 * np.pi * 180 * samples / asr_server.SAMPLE_RATE
        )
        server.context = "Claude\nCodex"
        server._context_revision = 0
        server._stabilizer = asr_server.PreviewStabilizer()
        server._thread = None
        server._preview_stop = threading.Event()
        server.active = True
        server.short_utterance_language = None
        server._utterance_short_language = None
        server._last_preview_text = None
        server._last_preview_len = 0
        server._last_preview_start = 0
        server._last_preview_context_revision = -1
        server._last_preview_language = None
        server._last_preview_detected_language = None
        server._last_preview_stable = False

        with patch.object(asr_server, "emit") as emitted:
            server.stop()

        final = emitted.call_args.args[0]
        self.assertEqual(final["text"], "blorp")
        self.assertEqual(final["mode"], "fresh-final-context-check-fallback")
        self.assertEqual(
            server.session.calls,
            [{"context": "Claude\nCodex"}, {}],
        )

    def test_stop_recovers_lora_when_final_flips_from_correct_preview(self):
        class PromptAwareSession:
            def __init__(self):
                self.calls = []

            def transcribe(self, _audio, **kwargs):
                self.calls.append(kwargs)
                text = "Testing Claude" if kwargs.get("context") else "Testing Laura"
                return SimpleNamespace(text=text, language="English")

        server = asr_server.Server.__new__(asr_server.Server)
        server.session = PromptAwareSession()
        server.lock = threading.Lock()
        samples = np.arange(asr_server.SAMPLE_RATE, dtype=np.float32)
        server.buf = 0.04 * np.sin(
            2 * np.pi * 180 * samples / asr_server.SAMPLE_RATE
        )
        server.context = "Claude\nLoRA"
        server._context_revision = 3
        server._stabilizer = asr_server.PreviewStabilizer()
        server._thread = None
        server._preview_stop = threading.Event()
        server.active = True
        server.short_utterance_language = None
        server._utterance_short_language = None
        server._last_preview_text = "Testing LoRA"
        server._last_preview_len = int(0.8 * asr_server.SAMPLE_RATE)
        server._last_preview_start = 0
        server._last_preview_context_revision = 3
        server._last_preview_language = None
        server._last_preview_detected_language = "English"
        server._last_preview_stable = True

        with patch.object(asr_server, "emit") as emitted:
            server.stop()

        final = emitted.call_args.args[0]
        self.assertEqual(final["text"], "Testing LoRA")
        self.assertEqual(
            final["mode"],
            "fresh-final-context-check-redirected",
        )
        self.assertEqual(
            server.session.calls,
            [{"context": "Claude\nLoRA"}, {}],
        )

    def test_stop_canonicalizes_lora_without_an_extra_decode(self):
        class FinalSession:
            def __init__(self):
                self.calls = []

            def transcribe(self, _audio, **kwargs):
                self.calls.append(kwargs)
                return SimpleNamespace(text="Testing Laura", language="English")

        server = asr_server.Server.__new__(asr_server.Server)
        server.session = FinalSession()
        server.lock = threading.Lock()
        samples = np.arange(asr_server.SAMPLE_RATE, dtype=np.float32)
        server.buf = 0.04 * np.sin(
            2 * np.pi * 180 * samples / asr_server.SAMPLE_RATE
        )
        server.context = "Claude\nLoRA"
        server._context_revision = 4
        server._stabilizer = asr_server.PreviewStabilizer()
        server._thread = None
        server._preview_stop = threading.Event()
        server.active = True
        server.short_utterance_language = None
        server._utterance_short_language = None
        server._last_preview_text = None
        server._last_preview_len = 0
        server._last_preview_start = 0
        server._last_preview_context_revision = -1
        server._last_preview_language = None
        server._last_preview_detected_language = None
        server._last_preview_stable = False
        server._last_context_preview_text = "Testing LoRA"
        server._last_context_preview_len = len(server.buf)
        server._last_context_preview_start = 0
        server._last_context_preview_revision = 4

        with patch.object(asr_server, "emit") as emitted:
            server.stop()

        final = emitted.call_args.args[0]
        self.assertEqual(final["text"], "Testing LoRA")
        self.assertEqual(
            final["mode"],
            "fresh-final-context-variant-canonicalized",
        )
        self.assertEqual(server.session.calls, [{"context": "Claude\nLoRA"}])

    def test_stop_does_not_emit_suspicious_reusable_preview_early(self):
        server = asr_server.Server.__new__(asr_server.Server)
        server.session = self.FakeSession("blorp")
        server.lock = threading.Lock()
        samples = np.arange(asr_server.SAMPLE_RATE, dtype=np.float32)
        server.buf = 0.04 * np.sin(
            2 * np.pi * 180 * samples / asr_server.SAMPLE_RATE
        )
        server.context = "Claude\nCodex"
        server._context_revision = 2
        server._thread = None
        server._preview_stop = threading.Event()
        server.active = True
        server.short_utterance_language = None
        server._utterance_short_language = None
        server._last_preview_text = "Claude"
        server._last_preview_len = len(server.buf)
        server._last_preview_start = 0
        server._last_preview_context_revision = 2
        server._last_preview_language = None
        server._last_preview_detected_language = "English"
        server._last_preview_stable = True

        with patch.object(asr_server, "emit") as emitted:
            server.stop()

        final = emitted.call_args.args[0]
        self.assertEqual(final["text"], "blorp")
        self.assertEqual(
            final["mode"],
            "reuse-exact-context-check-fallback",
        )
        self.assertEqual(server.session.calls, [{}])


class PreviewSchedulingTests(unittest.TestCase):
    def test_short_utterances_keep_original_cadence(self):
        self.assertEqual(
            asr_server.preview_cooldown(4.0, 0.4),
            asr_server.POLL_INTERVAL,
        )

    def test_medium_utterances_ramp_toward_idle_decoder(self):
        self.assertAlmostEqual(
            asr_server.preview_cooldown(6.0, 0.45),
            0.45,
        )

    def test_eight_second_utterances_target_one_third_decoder_duty(self):
        self.assertAlmostEqual(
            asr_server.preview_cooldown(8.0, 0.45),
            0.9,
        )

    def test_cooldown_is_capped(self):
        self.assertEqual(
            asr_server.preview_cooldown(45.0, 4.0),
            asr_server.PREVIEW_MAX_COOLDOWN_SEC,
        )

    def test_windowed_preview_uses_faster_hud_cadence(self):
        cooldown = asr_server.preview_cooldown(45.0, 0.5, windowed=True)
        self.assertAlmostEqual(cooldown, 0.375)

    def test_windowed_preview_cooldown_is_capped(self):
        self.assertEqual(
            asr_server.preview_cooldown(45.0, 2.0, windowed=True),
            asr_server.WINDOWED_PREVIEW_MAX_COOLDOWN_SEC,
        )

    def test_short_preview_keeps_complete_audio(self):
        audio = np.arange(8 * asr_server.SAMPLE_RATE, dtype=np.float32)
        preview, start = asr_server.preview_audio(audio)
        self.assertEqual(start, 0)
        np.testing.assert_array_equal(preview, audio)

    def test_long_preview_keeps_only_recent_window(self):
        audio = np.arange(45 * asr_server.SAMPLE_RATE, dtype=np.float32)
        preview, start = asr_server.preview_audio(audio)
        expected_len = int(asr_server.PREVIEW_MAX_AUDIO_SEC * asr_server.SAMPLE_RATE)
        self.assertEqual(len(preview), expected_len)
        self.assertEqual(start, len(audio) - expected_len)
        np.testing.assert_array_equal(preview, audio[-expected_len:])


class ShortUtteranceLanguageTests(unittest.TestCase):
    class FakeSession:
        def __init__(self):
            self.calls = []

        def transcribe(self, _audio, **kwargs):
            self.calls.append(kwargs)
            return SimpleNamespace(text=" testing ")

    def make_server(self, language):
        server = asr_server.Server.__new__(asr_server.Server)
        server.session = self.FakeSession()
        server.short_utterance_language = language
        server._utterance_short_language = language
        return server

    def test_preference_values_map_to_model_language_names(self):
        self.assertEqual(
            asr_server.normalize_short_utterance_language("english"),
            "English",
        )
        self.assertEqual(
            asr_server.normalize_short_utterance_language("CHINESE"),
            "Chinese",
        )
        self.assertEqual(
            asr_server.normalize_short_utterance_language("macedonian"),
            "Macedonian",
        )
        self.assertIsNone(
            asr_server.normalize_short_utterance_language("automatic")
        )
        self.assertIsNone(
            asr_server.normalize_short_utterance_language("Automatic multilingual")
        )

    def test_all_official_languages_are_available(self):
        self.assertEqual(len(asr_server.SUPPORTED_SHORT_UTTERANCE_LANGUAGES), 30)
        for language in asr_server.SUPPORTED_SHORT_UTTERANCE_LANGUAGES:
            self.assertEqual(
                asr_server.normalize_short_utterance_language(language),
                language,
            )

    def test_short_final_uses_preferred_language(self):
        server = self.make_server("English")
        audio = np.zeros(
            int(asr_server.SHORT_UTTERANCE_MAX_SEC * asr_server.SAMPLE_RATE),
            dtype=np.float32,
        )

        self.assertEqual(server._decode_final(audio, "Codex"), "testing")
        self.assertEqual(
            server.session.calls,
            [{"context": "Codex", "language": "English"}],
        )

    def test_short_preview_remains_automatic(self):
        server = self.make_server("English")
        audio = np.zeros(asr_server.SAMPLE_RATE, dtype=np.float32)

        self.assertEqual(server._decode_preview(audio, "Codex"), "testing")
        self.assertEqual(server.session.calls, [{"context": "Codex"}])

    def test_longer_clip_remains_automatic(self):
        server = self.make_server("English")
        audio = np.zeros(
            int(asr_server.SHORT_UTTERANCE_MAX_SEC * asr_server.SAMPLE_RATE) + 1,
            dtype=np.float32,
        )

        server._decode_final(audio, "")
        self.assertEqual(server.session.calls, [{}])

    def test_automatic_mode_never_forces_language(self):
        server = self.make_server(None)
        server._decode_final(
            np.zeros(asr_server.SAMPLE_RATE, dtype=np.float32),
            "",
        )
        self.assertEqual(server.session.calls, [{}])

    def test_per_utterance_hint_overrides_configured_language(self):
        server = self.make_server("English")
        server._utterance_short_language = "Chinese"
        audio = np.zeros(asr_server.SAMPLE_RATE, dtype=np.float32)

        server._decode_final(audio, "")
        self.assertEqual(server.session.calls, [{"language": "Chinese"}])


class PreviewReuseTests(unittest.TestCase):
    def make_server(self, text="hello", decoded_len=3200, revision=2, stable=True):
        server = asr_server.Server.__new__(asr_server.Server)
        server.lock = threading.Lock()
        server._last_preview_text = text
        server._last_preview_len = decoded_len
        server._last_preview_start = 0
        server._last_preview_context_revision = revision
        server._last_preview_language = None
        server._last_preview_stable = stable
        server.short_utterance_language = None
        server._utterance_short_language = None
        return server

    def test_exact_buffer_is_reused(self):
        server = self.make_server()
        audio = np.zeros(3200, dtype=np.float32)
        self.assertEqual(
            server._reusable_preview(audio, 2),
            asr_server.ReusablePreview(asr_server.DecodeResult("hello", None), "reuse-exact", 0),
        )

    def test_stable_preview_with_silent_tail_is_reused(self):
        server = self.make_server()
        audio = np.zeros(4000, dtype=np.float32)
        self.assertEqual(
            server._reusable_preview(audio, 2),
            asr_server.ReusablePreview(asr_server.DecodeResult("hello", None), "reuse-silent-tail", 800),
        )

    def test_stable_preview_remains_reusable_across_adaptive_cooldown(self):
        server = self.make_server(decoded_len=3200)
        tail = int(1.8 * asr_server.SAMPLE_RATE)
        audio = np.zeros(3200 + tail, dtype=np.float32)
        self.assertEqual(
            server._reusable_preview(audio, 2),
            asr_server.ReusablePreview(asr_server.DecodeResult("hello", None), "reuse-silent-tail", tail),
        )

    def test_silent_tail_beyond_adaptive_headroom_falls_back(self):
        server = self.make_server(decoded_len=3200)
        tail = int(2.1 * asr_server.SAMPLE_RATE)
        audio = np.zeros(3200 + tail, dtype=np.float32)
        self.assertIsNone(server._reusable_preview(audio, 2))

    def test_unstable_preview_with_silent_tail_falls_back(self):
        server = self.make_server(stable=False)
        audio = np.zeros(4000, dtype=np.float32)
        self.assertIsNone(server._reusable_preview(audio, 2))

    def test_context_change_falls_back(self):
        server = self.make_server()
        audio = np.zeros(3200, dtype=np.float32)
        self.assertIsNone(server._reusable_preview(audio, 3))

    def test_preview_is_not_reused_across_short_language_boundary(self):
        decoded_len = int(1.9 * asr_server.SAMPLE_RATE)
        server = self.make_server(decoded_len=decoded_len)
        server.short_utterance_language = "English"
        server._utterance_short_language = "English"
        server._last_preview_language = None
        audio = np.zeros(decoded_len, dtype=np.float32)

        self.assertIsNone(server._reusable_preview(audio, 2))

    def test_automatic_preview_can_be_reused_for_long_final(self):
        decoded_len = int(2.1 * asr_server.SAMPLE_RATE)
        server = self.make_server(decoded_len=decoded_len)
        server.short_utterance_language = "English"
        server._utterance_short_language = "English"
        server._last_preview_language = None
        audio = np.zeros(decoded_len, dtype=np.float32)

        self.assertEqual(
            server._reusable_preview(audio, 2),
            asr_server.ReusablePreview(asr_server.DecodeResult("hello", None), "reuse-exact", 0),
        )

    def test_rolling_window_preview_is_never_reused_as_full_final(self):
        server = self.make_server(decoded_len=3200)
        server._last_preview_start = 800
        audio = np.zeros(3200, dtype=np.float32)
        self.assertIsNone(server._reusable_preview(audio, 2))

    def test_voiced_tail_falls_back(self):
        server = self.make_server()
        audio = np.zeros(4000, dtype=np.float32)
        audio[3200:] = 0.08
        self.assertIsNone(server._reusable_preview(audio, 2))

    def test_timed_out_cleanup_is_preserved_then_can_be_awaited(self):
        class SlowThread:
            def __init__(self):
                self.alive = True
                self.timeouts = []

            def join(self, timeout=None):
                self.timeouts.append(timeout)
                if timeout is None:
                    self.alive = False

            def is_alive(self):
                return self.alive

        server = self.make_server()
        thread = SlowThread()
        server._thread = thread

        self.assertFalse(server._join_preview_thread())
        self.assertIs(server._thread, thread)
        self.assertTrue(server._join_preview_thread(timeout=None))
        self.assertIsNone(server._thread)
        self.assertEqual(thread.timeouts, [5.0, None])


if __name__ == "__main__":
    unittest.main()
