#!/usr/bin/env python3
"""ASR sidecar for the WhisprStream macOS app.

Speaks newline-delimited JSON on stdin/stdout so Swift can drive it:

    in : {"cmd":"start"}
         {"cmd":"audio","pcm":"<base64 int16 mono 16k>"}
         {"cmd":"stop"}
    out: {"type":"ready","ms":850}
         {"type":"partial","committed":"...","tail":"..."}
         {"type":"final","text":"...","secs":2.6,"ms":140}
         {"type":"error","message":"..."}

Final passes re-decode the complete utterance (RTF ~0.024 at 8-bit), preserving
zh/en code-switching. Long live previews use a bounded recent window so they do
not compete with another full-length pass. Token agreement protects settled
words from a single conflicting pass while allowing confirmed corrections.
"""

from __future__ import annotations

import base64
from dataclasses import dataclass
from difflib import SequenceMatcher
import json
import os
import re
import sys
import threading
import time
import unicodedata

import numpy as np

SAMPLE_RATE = 16000
MIN_SECONDS = 0.3
SHORT_UTTERANCE_MAX_SEC = 2.0
POLL_INTERVAL = 0.02
MIN_NEW_AUDIO = 0.15
# Swift stops dictation at 45 seconds. Keep several seconds of transport/timer
# headroom so the rolling buffer can never trim the beginning before that stop
# command reaches the sidecar.
MAX_BUFFER_SEC = 50.0

# A completed preview may be reused when the only audio it has not seen is a
# short, confidently silent tail. These thresholds are deliberately
# conservative: ordinary room noise passes, while even quiet speech or a sharp
# transient falls back to the authoritative final decode.
# Adaptive preview pacing deliberately creates idle decoder windows once an
# utterance grows beyond five seconds. A stable preview may remain reusable
# across that idle time, but only when every unseen frame is confidently
# silent. Speech-like audio always takes the authoritative final-decode path.
MAX_SILENT_REUSE_TAIL = 2.0
SILENCE_WINDOW_SEC = 0.02
SILENCE_MAX_PEAK = 0.06

# Decoding mere elapsed audio lets a vocabulary prompt hallucinate one of its
# terms (for example "Claude") from room tone. Require several speech-level
# frames before the first preview or final pass. Three 20 ms frames reject a
# key click or isolated bump while adding at most 60 ms before live text starts.
SPEECH_MIN_WINDOW_RMS = 0.015
SPEECH_MIN_ACTIVE_WINDOWS = 3

PREVIEW_FULL_SPEED_SEC = 4.0
PREVIEW_ADAPTIVE_RAMP_SEC = 4.0
PREVIEW_COOLDOWN_DECODE_RATIO = 2.0
PREVIEW_MAX_COOLDOWN_SEC = 1.5

# Re-decoding a full 45-second buffer for every HUD update makes both the live
# text and the later final pass compete with multi-second preview work. Once an
# utterance exceeds this size, previews use only the recent window. The final
# decode still receives the complete buffer, so inserted text and code-switching
# accuracy are unchanged.
PREVIEW_MAX_AUDIO_SEC = 12.0
WINDOWED_PREVIEW_COOLDOWN_RATIO = 0.75
WINDOWED_PREVIEW_MAX_COOLDOWN_SEC = 0.4

LATIN_WORD_RE = re.compile(r"[A-Za-z]+(?:['’][A-Za-z]+)*")
ASCII_WORD_RE = re.compile(r"[A-Za-z0-9]+(?:['’][A-Za-z0-9]+)*")
# Keep Latin words whole and CJK characters individually alignable. Preserve
# whitespace and punctuation verbatim when assembling the selected transcript.
PREVIEW_TOKEN_RE = re.compile(r"[A-Za-z0-9_]+(?:['’][A-Za-z0-9_]+)*|\s+|.", re.DOTALL)

# Context is a strong generative hint rather than a constrained hotword list.
# On acoustically unfamiliar one-word clips, Qwen can emit one context line
# verbatim (often the first one) even when the speaker said something unrelated.
# Only that narrow result shape receives an unprompted verification pass.
CONTEXT_SUPPORT_MIN_SIMILARITY = 2 / 3
CONTEXT_PREVIEW_MAX_UNSEEN_SEC = 1.0
CONTEXT_SPLIT_MIN_SIMILARITY = 0.75
CONTEXT_SPLIT_MAX_WORDS = 3
CONTEXT_SPLIT_MIN_TERM_LENGTH = 5


@dataclass(frozen=True)
class DecodeResult:
    text: str
    language: str | None
    # A live preview has already passed the same vocabulary checks as a final.
    # Failed/unresolved checks remain retryable when recording stops.
    context_verified: bool = False


@dataclass(frozen=True)
class ReviewChoice:
    prefix: str
    preferred: str
    alternative: str
    suffix: str

    @property
    def text(self) -> str:
        return self.prefix + self.preferred + self.suffix

    def payload(self) -> dict:
        return dict(prefix=self.prefix, preferred=self.preferred,
                    alternative=self.alternative, suffix=self.suffix)

    def for_transcript(self, text: str) -> ReviewChoice | None:
        """Offer the held preview as an alternative, never as a final override."""
        if text == self.text:
            return self
        if text == self.prefix + self.alternative + self.suffix:
            return ReviewChoice(self.prefix, self.alternative, self.preferred, self.suffix)
        return None


@dataclass(frozen=True)
class ReusablePreview:
    result: DecodeResult
    mode: str
    unseen_samples: int
    review: ReviewChoice | None = None


@dataclass(frozen=True)
class TextToken:
    text: str
    start: int
    end: int


class PreviewStabilizer:
    """Require two audio observations to revise words already seen twice.

    Agreement is token-local, so appending speech does not prevent an earlier
    word from settling. Only raw decoder observations count as evidence: a
    held display value cannot vote for itself. This is a stability heuristic,
    not a calibrated confidence score or a permanent transcript lock.
    """

    def __init__(self) -> None:
        self.tokens: list[str] = []
        self.support: list[int] = []
        self.raw: list[str] = []
        self.raw_support: list[int] = []
        self.start = 0
        self.end = -1
        self.revision = -1
        self.review: ReviewChoice | None = None

    @staticmethod
    def _lexical(token: str) -> bool:
        return any(char.isalnum() for char in token)

    @staticmethod
    def _align(old: list[str], new: list[str], from_end: bool = False):
        if not from_end:
            edits = SequenceMatcher(None, old, new, autojunk=False).get_opcodes()
        else:
            # Prefer recent anchors when a full final restores earlier audio.
            reverse = SequenceMatcher(None, old[::-1], new[::-1], autojunk=False)
            edits = [
                (tag, len(old) - i2, len(old) - i1, len(new) - j2, len(new) - j1)
                for tag, i1, i2, j1, j2 in reversed(reverse.get_opcodes())
            ]
        aligned = []
        for tag, i1, i2, j1, j2 in edits:
            old_words = [i for i in range(i1, i2) if PreviewStabilizer._lexical(old[i])]
            new_words = [j for j in range(j1, j2) if PreviewStabilizer._lexical(new[j])]
            nearby_words = bool(old_words) and len(new_words) >= len(old_words) and all(
                SequenceMatcher(None, old[i], new[j], autojunk=False).ratio() >= 0.6
                or (len(old[i]) == len(new[j]) == 1
                    and not old[i].isascii() and not new[j].isascii())
                for i, j in zip(old_words, new_words)
            )
            if (
                tag == "replace" and not any(map(PreviewStabilizer._lexical, old[i2:]))
                and 0 < len(old_words) <= 2 and nearby_words
            ):
                # "Use Codex." -> "Use Codec, then test" is a word revision
                # plus an appended tail, not one large replacement. Separate
                # them so protecting the name cannot swallow the new speech.
                old_end = old_words[-1] + 1
                new_end = new_words[len(old_words) - 1] + 1
                aligned.append((tag, i1, old_end, j1, new_end))
                aligned.append(("replace", old_end, i2, new_end, j2))
            else:
                aligned.append((tag, i1, i2, j1, j2))
        return aligned

    def update(self, text: str, start: int, end: int, revision: int) -> str:
        self.review = None
        incoming = PREVIEW_TOKEN_RE.findall(text)
        scope_changed = start != self.start
        edits = self._align(self.tokens, incoming, from_end=scope_changed)
        # Changed vocabulary, a new recording, or non-overlapping windows have
        # no comparable history. Do not splice unrelated transcripts together.
        reset = revision != self.revision or end < self.end or start >= self.end
        if scope_changed:
            matched = sum(
                self._lexical(token)
                for tag, i1, i2, _, _ in edits if tag == "equal"
                for token in self.tokens[i1:i2]
            )
            shorter = min(
                sum(map(self._lexical, self.tokens)),
                sum(map(self._lexical, incoming)),
            )
            reset = reset or matched < max(2, shorter / 2)
        if reset:
            self.tokens = incoming
            self.support = [1] * len(incoming)
            self.raw = incoming
            self.raw_support = self.support.copy()
            self.start, self.end, self.revision = start, end, revision
            return text

        new_observation = end > self.end
        raw_support = [1] * len(incoming)
        if new_observation:
            for tag, i1, i2, j1, j2 in self._align(
                self.raw, incoming, from_end=scope_changed
            ):
                if tag == "equal":
                    raw_support[j1:j2] = [
                        min(2, count + 1) for count in self.raw_support[i1:i2]
                    ]

        # Align the previous *raw* pass to today's display, rather than keeping
        # position keys which become stale when an earlier edit is accepted.
        previous_edits = {
            (i1, i2, tuple(self.raw[j1:j2]))
            for tag, i1, i2, j1, j2 in self._align(self.tokens, self.raw)
            if tag != "equal"
        }
        removed = {
            token for tag, i1, i2, _, _ in edits if tag != "equal"
            for token in self.tokens[i1:i2] if self._lexical(token)
        }
        added = {
            token for tag, _, _, j1, j2 in edits if tag != "equal"
            for token in incoming[j1:j2] if self._lexical(token)
        }
        if removed & added:
            # Reordering/repeated anchors are not independent local edits.
            # Keeping a deletion while accepting its insertion would duplicate
            # words ("red blue" -> "blue red blue"). Prefer the raw candidate
            # when the alignment cannot safely isolate a word substitution.
            self.tokens, self.support = incoming, raw_support
            self.raw, self.raw_support = incoming, raw_support
            self.start, self.end, self.revision = start, end, revision
            return text
        selected: list[str] = []
        support: list[int] = []
        disputes: list[tuple[int, str, str]] = []
        for tag, i1, i2, j1, j2 in edits:
            replacement = incoming[j1:j2]
            if tag == "equal":
                selected.extend(replacement)
                support.extend(
                    max(old, new)
                    for old, new in zip(self.support[i1:i2], raw_support[j1:j2])
                )
                continue

            protected = any(
                count >= 2 and self._lexical(token)
                for token, count in zip(self.tokens[i1:i2], self.support[i1:i2])
            )
            if tag == "insert":
                # Appended speech is always immediate. Interior insertions
                # (including negation) need confirmation between settled words.
                left = next((i for i in range(i1 - 1, -1, -1)
                             if self._lexical(self.tokens[i])), None)
                right = next((i for i in range(i1, len(self.tokens))
                              if self._lexical(self.tokens[i])), None)
                protected = (
                    left is not None and right is not None
                    and self.support[left] >= 2 and self.support[right] >= 2
                    and any(map(self._lexical, replacement))
                )
            # The left edge changes when old audio falls out of the window or
            # the full final restores it. Its edits are not linguistic votes.
            if scope_changed and i1 == 0:
                protected = False
            confirmed = new_observation and (
                i1, i2, tuple(replacement)
            ) in previous_edits
            if protected and not confirmed:
                disputes.append((sum(map(len, selected)),
                                 "".join(self.tokens[i1:i2]), "".join(replacement)))
                selected.extend(self.tokens[i1:i2])
                support.extend(self.support[i1:i2])
            else:
                selected.extend(replacement)
                support.extend(raw_support[j1:j2])

        self.tokens, self.support = selected, support
        if new_observation:
            self.raw, self.raw_support = incoming, raw_support
        self.start, self.end, self.revision = start, end, revision
        selected_text = "".join(selected)
        if len(disputes) == 1:
            offset, preferred, alternative = disputes[0]
            # Ask only about one bounded lexical substitution. Whole-sentence
            # rewrites, punctuation, omissions, and ambiguous alignments are
            # not useful word choices and should not interrupt dictation.
            if (
                0 < len(preferred.strip()) <= 48 and 0 < len(alternative.strip()) <= 48
                and preferred.casefold() != alternative.casefold()
                and all(any(c.isalnum() for c in term) for term in (preferred, alternative))
                and all(len(term.split()) <= 3 and "\n" not in term
                        for term in (preferred, alternative))
            ):
                self.review = ReviewChoice(
                    selected_text[:offset], preferred, alternative,
                    selected_text[offset + len(preferred):],
                )
        return selected_text


def emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def commonprefix(a: str, b: str) -> str:
    n = min(len(a), len(b))
    i = 0
    while i < n and a[i] == b[i]:
        i += 1
    return a[:i]


def normalize_detected_language(value: object) -> str | None:
    """Return canonical language names for decoder metadata."""
    normalized = str(value or "").strip().casefold().replace("_", "-")
    if normalized in {"english", "en"} or normalized.startswith("en-"):
        return "English"
    if normalized in {"chinese", "zh"} or normalized.startswith("zh-"):
        return "Chinese"
    return str(value).strip() if value else None


def normalized_context_text(text: str) -> str:
    """Return a punctuation/spacing-insensitive form for context checks."""
    normalized = unicodedata.normalize("NFKC", text).casefold()
    return "".join(character for character in normalized if character.isalnum())


def comparable_context_terms(context: str) -> list[str]:
    """Return context lines that are safe to compare by Latin edit distance."""
    return [
        term
        for line in context.splitlines()
        if (
            (term := line.strip())
            and term.isascii()
            and LATIN_WORD_RE.search(term)
        )
    ]


def text_tokens(text: str) -> list[TextToken]:
    """Return ASCII word tokens with source ranges for surgical replacement."""
    return [
        TextToken(match.group(), match.start(), match.end())
        for match in ASCII_WORD_RE.finditer(text)
    ]


def single_word_context_terms(context: str) -> list[str]:
    """Return comparable context entries represented by exactly one word."""
    return [
        term
        for term in comparable_context_terms(context)
        if len(text_tokens(term)) == 1
    ]


def transcript_contains_context_word(transcript: str, context: str) -> bool:
    """Return True when any complete transcript word is a context entry."""
    terms = {
        normalized_context_text(term)
        for term in single_word_context_terms(context)
    }
    return any(
        normalized_context_text(token.text) in terms
        for token in text_tokens(transcript)
    )


def edit_distance(left: str, right: str) -> int:
    """Return Levenshtein distance using one row of working memory."""
    if len(left) < len(right):
        left, right = right, left
    previous = list(range(len(right) + 1))
    for left_index, left_character in enumerate(left, start=1):
        current = [left_index]
        for right_index, right_character in enumerate(right, start=1):
            current.append(min(
                current[-1] + 1,
                previous[right_index] + 1,
                previous[right_index - 1] + (left_character != right_character),
            ))
        previous = current
    return previous[-1]


def context_text_similarity(term: str, transcript: str) -> float:
    """Return normalized edit similarity for one context term and transcript."""
    expected = normalized_context_text(term)
    observed = normalized_context_text(transcript)
    if not expected or not observed:
        return 0.0
    return 1.0 - edit_distance(expected, observed) / max(
        len(expected),
        len(observed),
    )


def latin_consonant_skeleton(text: str) -> str:
    """Return a small pronunciation hint for vowel-spelling variants."""
    normalized = normalized_context_text(text)
    return "".join(
        character
        for character in normalized
        if character.isascii()
        and (character.isdigit() or character not in "aeiouy")
    )


def context_support_score(term: str, transcript: str) -> float:
    """Score spelling evidence, including variants such as LoRA/Laura."""
    score = context_text_similarity(term, transcript)
    expected_skeleton = latin_consonant_skeleton(term)
    observed_skeleton = latin_consonant_skeleton(transcript)
    if (
        len(expected_skeleton) >= 2
        and expected_skeleton == observed_skeleton
    ):
        return 1.0
    return score


def best_supported_term(
    terms: list[str],
    transcript: str,
) -> tuple[str | None, float]:
    """Return the best context spelling and its unprompted support score."""
    best_term = None
    best_score = 0.0
    for term in terms:
        score = context_support_score(term, transcript)
        if score > best_score:
            best_term = term
            best_score = score
    if best_score < CONTEXT_SUPPORT_MIN_SIMILARITY:
        return None, best_score
    return best_term, best_score


def best_supported_context_term(context: str, transcript: str) -> str | None:
    """Return the context spelling best supported by an unprompted decode."""
    term, _score = best_supported_term(
        comparable_context_terms(context),
        transcript,
    )
    return term


def context_term_has_unprompted_support(term: str, transcript: str) -> bool:
    """Return True when an unprompted spelling is close to the context term."""
    return (
        context_support_score(term, transcript)
        >= CONTEXT_SUPPORT_MIN_SIMILARITY
    )


def canonicalize_context_variants(transcript: str, context: str) -> str:
    """Restore vocabulary spelling for strong one- or multi-token variants.

    One-token variants must have identical normalized spelling or consonant
    skeleton (``Laura`` -> ``LoRA``). Split variants use a conservative edit
    threshold (``two tips`` -> ``tooltips``) and ignore short context terms.
    """
    terms = single_word_context_terms(context)
    tokens = text_tokens(transcript)
    if not terms or not tokens:
        return transcript

    replacements: list[tuple[int, int, str]] = []
    token_index = 0
    while token_index < len(tokens):
        best: tuple[float, int, str] | None = None
        max_width = min(CONTEXT_SPLIT_MAX_WORDS, len(tokens) - token_index)
        for width in range(1, max_width + 1):
            end_index = token_index + width
            start = tokens[token_index].start
            end = tokens[end_index - 1].end
            observed = transcript[start:end]
            for term in terms:
                if width == 1:
                    score = context_support_score(term, observed)
                    supported = score == 1.0
                else:
                    if (
                        len(normalized_context_text(term))
                        < CONTEXT_SPLIT_MIN_TERM_LENGTH
                    ):
                        continue
                    score = context_text_similarity(term, observed)
                    supported = score >= CONTEXT_SPLIT_MIN_SIMILARITY
                if supported and (best is None or (score, width) > best[:2]):
                    best = (score, width, term)

        if best is None:
            token_index += 1
            continue
        _score, width, term = best
        end_index = token_index + width
        replacements.append((
            tokens[token_index].start,
            tokens[end_index - 1].end,
            term,
        ))
        token_index = end_index

    canonical = transcript
    for start, end, replacement in reversed(replacements):
        canonical = canonical[:start] + replacement + canonical[end:]
    return canonical


def reconcile_context_words(
    prompted: str,
    unprompted: str,
    context: str,
) -> tuple[str, str | None]:
    """Resolve context-word disagreements while preserving surrounding text."""
    terms = single_word_context_terms(context)
    term_by_key = {
        normalized_context_text(term): term
        for term in terms
    }
    prompted_tokens = text_tokens(prompted)
    unprompted_tokens = text_tokens(unprompted)
    prompted_keys = [normalized_context_text(token.text) for token in prompted_tokens]
    unprompted_keys = [normalized_context_text(token.text) for token in unprompted_tokens]
    if not any(key in term_by_key for key in prompted_keys):
        return prompted, None

    replacements: list[tuple[int, int, str]] = []
    statuses: list[str] = []
    matcher = SequenceMatcher(
        None,
        prompted_keys,
        unprompted_keys,
        autojunk=False,
    )
    for tag, prompted_start, prompted_end, unbiased_start, unbiased_end in matcher.get_opcodes():
        prompted_indices = range(prompted_start, prompted_end)
        unbiased_indices = range(unbiased_start, unbiased_end)
        if (
            tag == "replace"
            and len(prompted_indices) == 1
            and len(unbiased_indices) > 1
            and prompted_keys[prompted_start] in term_by_key
        ):
            # A vocabulary word can legitimately be split by the unbiased
            # decode (``tooltips`` -> ``two tips``). Compare the complete
            # replacement span before falling back to individual tokens.
            observed = unprompted[
                unprompted_tokens[unbiased_start].start:
                unprompted_tokens[unbiased_end - 1].end
            ]
            prompted_key = prompted_keys[prompted_start]
            supported_term, _score = best_supported_term(terms, observed)
            if supported_term is None:
                replacement = observed
                status = "fallback"
            elif normalized_context_text(supported_term) == prompted_key:
                replacement = supported_term
                status = "supported"
            else:
                replacement = supported_term
                status = "redirected"
            token = prompted_tokens[prompted_start]
            replacements.append((token.start, token.end, replacement))
            statuses.append(status)
            continue
        if tag in {"equal", "replace"} and len(prompted_indices) == len(unbiased_indices):
            pairs = zip(prompted_indices, unbiased_indices)
        elif tag == "replace":
            pairs = []
            for prompted_index in prompted_indices:
                if prompted_keys[prompted_index] not in term_by_key:
                    continue
                best_index = None
                best_score = 0.0
                for unbiased_index in unbiased_indices:
                    _term, score = best_supported_term(
                        terms,
                        unprompted_tokens[unbiased_index].text,
                    )
                    if score > best_score:
                        best_index = unbiased_index
                        best_score = score
                if best_index is not None:
                    pairs.append((prompted_index, best_index))
        else:
            pairs = []

        for prompted_index, unbiased_index in pairs:
            prompted_key = prompted_keys[prompted_index]
            prompted_term = term_by_key.get(prompted_key)
            if prompted_term is None:
                continue
            unbiased_word = unprompted_tokens[unbiased_index].text
            supported_term, _score = best_supported_term(terms, unbiased_word)
            if supported_term is None:
                replacement = unbiased_word
                status = "fallback"
            elif normalized_context_text(supported_term) == prompted_key:
                replacement = supported_term
                status = "supported"
            else:
                replacement = supported_term
                status = "redirected"
            token = prompted_tokens[prompted_index]
            replacements.append((token.start, token.end, replacement))
            statuses.append(status)

    if not replacements:
        return prompted, "context-check-unresolved"

    reconciled = prompted
    for start, end, replacement in reversed(replacements):
        reconciled = reconciled[:start] + replacement + reconciled[end:]
    for status in ("redirected", "fallback", "supported"):
        if status in statuses:
            return reconciled, f"context-check-{status}"
    return reconciled, "context-check-unresolved"


def canonicalize_from_preview_context(
    transcript: str,
    preview: str,
    context: str,
) -> str:
    """Apply canonical context spelling where a recent preview signaled it."""
    terms = single_word_context_terms(context)
    term_keys = {normalized_context_text(term) for term in terms}
    preview_tokens = text_tokens(preview)
    transcript_tokens = text_tokens(transcript)
    if not preview_tokens or not transcript_tokens:
        return transcript

    preview_denominator = max(1, len(preview_tokens) - 1)
    signal_positions = [
        index / preview_denominator
        for index, token in enumerate(preview_tokens)
        if normalized_context_text(token.text) in term_keys
    ]
    if not signal_positions:
        return transcript

    transcript_denominator = max(1, len(transcript_tokens) - 1)
    candidates: list[tuple[int, float, str]] = []
    for index, token in enumerate(transcript_tokens):
        term, score = best_supported_term(terms, token.text)
        # Preview evidence is weaker than an unprompted verification pass, so
        # require exact normalized spelling or an identical consonant skeleton.
        if term is not None and score == 1.0:
            candidates.append((index, index / transcript_denominator, term))

    replacements: list[tuple[int, int, str]] = []
    unused = list(candidates)
    for signal_position in signal_positions:
        if not unused:
            break
        candidate = min(unused, key=lambda item: abs(item[1] - signal_position))
        unused.remove(candidate)
        token = transcript_tokens[candidate[0]]
        replacements.append((token.start, token.end, candidate[2]))

    canonical = transcript
    for start, end, replacement in reversed(replacements):
        canonical = canonical[:start] + replacement + canonical[end:]
    return canonical


def is_confident_silence(audio: np.ndarray) -> bool:
    """Return True only when every short window looks safely non-speech."""
    if len(audio) == 0:
        return True
    if float(np.max(np.abs(audio))) > SILENCE_MAX_PEAK:
        return False

    window = max(1, int(SILENCE_WINDOW_SEC * SAMPLE_RATE))
    complete_samples = len(audio) // window * window
    frames = audio[:complete_samples].reshape(-1, window)
    rms = np.sqrt(np.mean(frames * frames, axis=1))
    # Use the same threshold, inclusive comparison, and array arithmetic as
    # has_speech. A speech-level frame can never also be confident silence.
    # Unlike the startup gate, even one such frame may be a trailing phoneme.
    if np.any(rms >= SPEECH_MIN_WINDOW_RMS):
        return False
    tail = audio[complete_samples:]
    if len(tail):
        tail_rms = np.sqrt(np.mean(tail * tail, keepdims=True))
        if np.any(tail_rms >= SPEECH_MIN_WINDOW_RMS):
            return False
    return True


def has_speech(audio: np.ndarray) -> bool:
    """Return True after enough speech-level frames, ignoring room tone/clicks."""
    window = max(1, int(SILENCE_WINDOW_SEC * SAMPLE_RATE))
    complete_frames = len(audio) // window
    if complete_frames < SPEECH_MIN_ACTIVE_WINDOWS:
        return False

    frames = audio[:complete_frames * window].reshape(complete_frames, window)
    rms = np.sqrt(np.mean(frames * frames, axis=1))
    return int(np.count_nonzero(rms >= SPEECH_MIN_WINDOW_RMS)) >= SPEECH_MIN_ACTIVE_WINDOWS


def preview_cooldown(
    audio_seconds: float,
    decode_seconds: float,
    *,
    windowed: bool = False,
) -> float:
    """Return an idle interval that keeps medium/long final decoding responsive.

    Short utterances retain the original live-preview cadence. From four
    seconds onward the idle interval ramps toward twice the duration of the
    previous preview pass, targeting roughly a 33% decoder duty cycle by eight
    seconds. This gives a stop command a useful chance to arrive while the
    model is idle, without changing the audio or authoritative final transcript.
    """
    if audio_seconds <= PREVIEW_FULL_SPEED_SEC or decode_seconds <= 0:
        return POLL_INTERVAL

    if windowed:
        adaptive = decode_seconds * WINDOWED_PREVIEW_COOLDOWN_RATIO
        return max(
            POLL_INTERVAL,
            min(WINDOWED_PREVIEW_MAX_COOLDOWN_SEC, adaptive),
        )

    progress = min(
        1.0,
        (audio_seconds - PREVIEW_FULL_SPEED_SEC) / PREVIEW_ADAPTIVE_RAMP_SEC,
    )
    adaptive = decode_seconds * PREVIEW_COOLDOWN_DECODE_RATIO * progress
    return max(POLL_INTERVAL, min(PREVIEW_MAX_COOLDOWN_SEC, adaptive))


def preview_audio(full_audio: np.ndarray) -> tuple[np.ndarray, int]:
    """Return the bounded HUD preview audio and its full-buffer start index."""
    preview_cap = int(PREVIEW_MAX_AUDIO_SEC * SAMPLE_RATE)
    preview_start = max(0, len(full_audio) - preview_cap)
    return full_audio[preview_start:], preview_start


SUPPORTED_SHORT_UTTERANCE_LANGUAGES = (
    "Chinese", "English", "Cantonese", "Arabic", "German", "French",
    "Spanish", "Portuguese", "Indonesian", "Italian", "Korean", "Russian",
    "Thai", "Vietnamese", "Japanese", "Turkish", "Hindi", "Malay", "Dutch",
    "Swedish", "Danish", "Finnish", "Polish", "Czech", "Filipino", "Persian",
    "Greek", "Hungarian", "Macedonian", "Romanian",
)


def normalize_short_utterance_language(value: str) -> str | None:
    """Return a canonical Qwen3-ASR forced-language name."""
    normalized = (value or "").strip().casefold()
    return next(
        (name for name in SUPPORTED_SHORT_UTTERANCE_LANGUAGES
         if name.casefold() == normalized),
        None,
    )


class Server:
    def __init__(
        self,
        model_id: str,
        bits: int,
        context: str,
        short_utterance_language: str = "",
        engine: str = "qwen3",
        learned_context: str = "",
    ):
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from asr_engine import build_session

        self.session, load_secs = build_session(model_id, bits, engine=engine)
        emit({"type": "ready", "ms": int(load_secs * 1000)})

        self.lock = threading.Lock()
        self.context = context
        self.learned_context = learned_context
        self.short_utterance_language = normalize_short_utterance_language(
            short_utterance_language
        )
        self._utterance_short_language = self.short_utterance_language
        self._context_revision = 0
        self.buf = np.zeros(0, dtype=np.float32)
        self.active = False
        self.committed = ""
        self._prev = ""
        self._stabilizer = PreviewStabilizer()
        self._last_preview_text: str | None = None
        self._last_preview_len = 0
        self._last_preview_start = 0
        self._last_preview_context_revision = -1
        self._last_preview_language: str | None = None
        self._last_preview_detected_language: str | None = None
        self._last_preview_stable = False
        self._last_preview_context_verified = False
        self._last_preview_review: ReviewChoice | None = None
        self._last_context_preview_text: str | None = None
        self._last_context_preview_len = 0
        self._last_context_preview_start = 0
        self._last_context_preview_revision = -1
        self._thread: threading.Thread | None = None
        self._preview_stop = threading.Event()

    # -- transcription -------------------------------------------------
    def _language_for_audio(self, audio: np.ndarray) -> str | None:
        if len(audio) <= int(SHORT_UTTERANCE_MAX_SEC * SAMPLE_RATE):
            return self._utterance_short_language
        return None

    def _decode_result(
        self,
        audio: np.ndarray,
        context: str,
        language: str | None = None,
        use_learned_context: bool = True,
    ) -> DecodeResult:
        # Learned terms are soft decoder hints only. Keep them separate from
        # explicit vocabulary spelling canonicalization and unbiased checks.
        learned = getattr(self, "learned_context", "") if use_learned_context else ""
        prompt = "\n".join(part for part in (context, learned) if part)
        kw = {"context": prompt} if prompt else {}
        if language:
            kw["language"] = language
        raw_result = self.session.transcribe(audio, **kw)
        detected_language = normalize_detected_language(
            getattr(raw_result, "language", None)
        )
        return DecodeResult(
            text=(raw_result.text or "").strip(),
            language=detected_language or normalize_detected_language(language),
        )

    def _decode(
        self,
        audio: np.ndarray,
        context: str,
        language: str | None = None,
    ) -> str:
        return self._decode_result(audio, context, language).text

    def _decode_preview_result(
        self,
        audio: np.ndarray,
        context: str,
    ) -> DecodeResult:
        """Decode and verify vocabulary words before showing a live preview."""
        result = self._decode_result(audio, context)
        result, status = self._verify_context_result(
            audio,
            context,
            result,
            force_automatic_language=True,
        )
        return DecodeResult(
            result.text,
            result.language,
            context_verified=status not in {"context-check-error", "context-check-unresolved"},
        )

    def _decode_preview(self, audio: np.ndarray, context: str) -> str:
        """Decode live text without treating a sentence start as one word."""
        return self._decode_preview_result(audio, context).text

    def _decode_final_result(
        self,
        audio: np.ndarray,
        context: str,
    ) -> DecodeResult:
        """Apply explicit short-utterance guidance after clip length is known."""
        return self._decode_result(audio, context, self._language_for_audio(audio))

    def _decode_final(self, audio: np.ndarray, context: str) -> str:
        """Apply short-utterance guidance only after clip length is known."""
        return self._decode_final_result(audio, context).text

    def _verify_context_result(
        self,
        audio: np.ndarray,
        context: str,
        result: DecodeResult,
        preview_context: str | None = None,
        force_automatic_language: bool = False,
    ) -> tuple[DecodeResult, str | None]:
        """Verify generated context words against an unprompted decode.

        A nearby spelling such as ``Cloud`` still supports ``Claude``. When an
        embedded prompted word disagrees, only that aligned word is replaced;
        the prompted sentence and punctuation stay intact.
        """
        if not transcript_contains_context_word(result.text, context):
            canonical = canonicalize_context_variants(result.text, context)
            if canonical != result.text:
                return DecodeResult(
                    canonical,
                    result.language,
                ), "context-variant-canonicalized"
            if preview_context is None:
                return result, None
            canonical = canonicalize_from_preview_context(
                result.text,
                preview_context,
                context,
            )
            if canonical == result.text:
                return result, None
            return DecodeResult(
                canonical,
                result.language,
            ), "context-preview-canonicalized"

        try:
            unbiased = self._decode_result(
                audio,
                "",
                None if force_automatic_language else self._language_for_audio(audio),
                use_learned_context=False,
            )
        except Exception as error:
            print(
                f"context verification failed: {error}",
                file=sys.stderr,
                flush=True,
            )
            return result, "context-check-error"
        reconciled, status = reconcile_context_words(
            result.text,
            unbiased.text,
            context,
        )
        return DecodeResult(
            reconciled,
            unbiased.language or result.language,
        ), status

    def _recent_context_preview(
        self,
        audio: np.ndarray,
        context_revision: int,
    ) -> str | None:
        """Return recent full-window preview evidence for this utterance."""
        with self.lock:
            text = getattr(self, "_last_context_preview_text", None)
            decoded_len = getattr(self, "_last_context_preview_len", 0)
            decoded_start = getattr(self, "_last_context_preview_start", 0)
            decoded_revision = getattr(
                self,
                "_last_context_preview_revision",
                -1,
            )
        unseen = len(audio) - decoded_len
        max_unseen = int(CONTEXT_PREVIEW_MAX_UNSEEN_SEC * SAMPLE_RATE)
        if (
            text is None
            or decoded_revision != context_revision
            or decoded_start != 0
            or unseen < 0
            or unseen > max_unseen
        ):
            return None
        return text

    def _reusable_preview(
        self,
        audio: np.ndarray,
        context_revision: int,
    ) -> ReusablePreview | None:
        """Snapshot a full preview only when its audio and context still apply."""
        with self.lock:
            text = self._last_preview_text
            decoded_len = self._last_preview_len
            decoded_start = self._last_preview_start
            decoded_revision = self._last_preview_context_revision
            decoded_language = self._last_preview_language
            detected_language = getattr(
                self,
                "_last_preview_detected_language",
                None,
            )
            stable = self._last_preview_stable
            context_verified = getattr(self, "_last_preview_context_verified", False)
            review = getattr(self, "_last_preview_review", None)

        if text is None or decoded_revision != context_revision:
            return None
        # A preview decoded while the short-clip preference applied must not be
        # reused if the final buffer has since crossed into automatic language
        # detection (or vice versa).
        if decoded_language != self._language_for_audio(audio):
            return None
        # A rolling-window preview intentionally contains only the recent HUD
        # text. It can never stand in for the full authoritative transcript.
        if decoded_start != 0:
            return None
        if decoded_len > len(audio):
            return None

        unseen = len(audio) - decoded_len
        result = DecodeResult(text, detected_language, context_verified)
        if unseen == 0:
            # Same samples + same context produces the same deterministic final
            # result, so a second pass would be pure duplicate work.
            return ReusablePreview(result, "reuse-exact", 0, review)

        max_tail = int(MAX_SILENT_REUSE_TAIL * SAMPLE_RATE)
        tail = audio[decoded_len:]
        if unseen <= max_tail and stable and is_confident_silence(tail):
            return ReusablePreview(result, "reuse-silent-tail", unseen, review)
        return None

    @staticmethod
    def _emit_final(
        text: str,
        secs: float,
        inference_ms: int,
        stop_started: float,
        mode: str,
        wait_ms: int,
        unseen_samples: int = 0,
        language: str | None = None,
        review: ReviewChoice | None = None,
    ) -> None:
        event = {
            "type": "final",
            "text": text,
            "secs": round(secs, 2),
            "ms": inference_ms,
            "total_ms": int((time.perf_counter() - stop_started) * 1000),
            "wait_ms": wait_ms,
            "mode": mode,
            "unseen_ms": int(unseen_samples / SAMPLE_RATE * 1000),
            "language": language or "unknown",
        }
        if review is not None and review.text == text:
            event["review"] = review.payload()
        emit(event)

    def _join_preview_thread(self, timeout: float | None = 5.0) -> bool:
        """Wait for preview inference without losing a still-live thread."""
        if self._thread is None:
            return True
        self._thread.join(timeout=timeout)
        if self._thread.is_alive():
            return False
        self._thread = None
        return True

    def _loop(self) -> None:
        last_len = 0
        while self.active:
            with self.lock:
                full_audio = self.buf.copy()
                context = self.context
                context_revision = self._context_revision
            full_len = len(full_audio)
            grew = full_len - last_len >= int(MIN_NEW_AUDIO * SAMPLE_RATE)
            if full_len < int(MIN_SECONDS * SAMPLE_RATE) or not grew:
                time.sleep(POLL_INTERVAL)
                continue
            last_len = full_len
            if not has_speech(full_audio):
                # Context terms are strong decoder hints, so never ask the
                # model to interpret audio that contains only room tone.
                continue
            reusable = self._reusable_preview(full_audio, context_revision)
            if (
                reusable is not None
                and reusable.result.context_verified
                and reusable.mode == "reuse-silent-tail"
            ):
                # Added silence is not new linguistic evidence. Re-decoding
                # it can flip a settled word just before the key is released.
                if self._preview_stop.wait(timeout=POLL_INTERVAL):
                    break
                continue
            audio, preview_start = preview_audio(full_audio)
            try:
                decode_started = time.perf_counter()
                result = self._decode_preview_result(audio, context)
                if result.context_verified:
                    text = self._stabilizer.update(
                        result.text, preview_start, full_len, context_revision
                    )
                else:
                    # Failed vocabulary checks must not earn protection or
                    # carry earlier protection through an unverified result.
                    self._stabilizer = PreviewStabilizer()
                    text = result.text
                decode_seconds = time.perf_counter() - decode_started
                previous = (
                    self._prev
                    if context_revision == self._last_preview_context_revision
                    else ""
                )
                stable = (
                    context_revision == self._last_preview_context_revision
                    and result.text == self._last_preview_text
                )
                # Stabilization is presentation-only. Cache the verified raw
                # decode so final reuse cannot lose a negation, rewrite, or
                # new tail that the display is still waiting to confirm.
                self.committed = commonprefix(text, previous)
                self._prev = text
                with self.lock:
                    self._last_preview_text = result.text
                    self._last_preview_len = full_len
                    self._last_preview_start = preview_start
                    self._last_preview_context_revision = context_revision
                    # Live previews always use automatic multilingual
                    # recognition. Only a completed short clip receives the
                    # user's one-word language guidance.
                    self._last_preview_language = None
                    self._last_preview_detected_language = result.language
                    self._last_preview_stable = stable
                    self._last_preview_context_verified = result.context_verified
                    self._last_preview_review = (
                        self._stabilizer.review.for_transcript(result.text)
                        if self._stabilizer.review else None
                    )
                    if transcript_contains_context_word(result.text, context):
                        self._last_context_preview_text = result.text
                        self._last_context_preview_len = full_len
                        self._last_context_preview_start = preview_start
                        self._last_context_preview_revision = context_revision
                if self.active:
                    emit({
                        "type": "partial",
                        "committed": self.committed,
                        "tail": text[len(self.committed):],
                    })
            except Exception as e:
                if self.active:
                    emit({"type": "error", "message": f"partial: {e}"})
                decode_seconds = 0.0

            cooldown = preview_cooldown(
                full_len / SAMPLE_RATE,
                decode_seconds,
                windowed=preview_start > 0,
            )
            # Unlike time.sleep(), Event.wait() lets stop() wake an idle
            # preview thread immediately instead of adding up to one second to
            # release latency at the long-utterance cap.
            if self._preview_stop.wait(timeout=cooldown):
                break

    # -- commands ------------------------------------------------------
    def start(self, short_utterance_language: str | None = None) -> None:
        # A fast final can reach Swift before its superseded preview pass has
        # finished cleaning up. A new start command is already ordered ahead of
        # its audio in the pipe, so wait here instead of rejecting the press:
        # once cleanup finishes, every queued audio packet is still consumed.
        if self._thread is not None and self._thread.is_alive():
            self.active = False
            self._preview_stop.set()
            self._join_preview_thread(timeout=None)
        with self.lock:
            self.buf = np.zeros(0, dtype=np.float32)
            self._last_preview_text = None
            self._last_preview_len = 0
            self._last_preview_start = 0
            self._last_preview_context_revision = -1
            self._last_preview_language = None
            self._last_preview_detected_language = None
            self._last_preview_stable = False
            self._last_preview_context_verified = False
            self._last_preview_review = None
            self._last_context_preview_text = None
            self._last_context_preview_len = 0
            self._last_context_preview_start = 0
            self._last_context_preview_revision = -1
        self.committed = ""
        self._prev = ""
        self._stabilizer = PreviewStabilizer()
        requested_language = normalize_short_utterance_language(
            short_utterance_language
        )
        self._utterance_short_language = (
            requested_language
            if short_utterance_language is not None
            else self.short_utterance_language
        )
        self._preview_stop.clear()
        self.active = True
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def audio(self, b64: str) -> None:
        pcm = np.frombuffer(base64.b64decode(b64), dtype=np.int16)
        chunk = pcm.astype(np.float32) / 32768.0
        with self.lock:
            self.buf = np.append(self.buf, chunk)
            cap = int(MAX_BUFFER_SEC * SAMPLE_RATE)
            if len(self.buf) > cap:
                self.buf = self.buf[-cap:]

    def set_context(self, text: str) -> None:
        """Update the vocabulary bias without reloading the model.

        The revision travels with every preview so a result decoded against an
        older context can never be reused as the final transcript.
        """
        with self.lock:
            if text != self.context:
                self.context = text
                self._context_revision += 1

    def set_learned_context(self, text: str) -> None:
        with self.lock:
            if text != self.learned_context:
                self.learned_context = text
                self._context_revision += 1

    def stop(self) -> None:
        stop_started = time.perf_counter()
        self.active = False
        self._preview_stop.set()

        with self.lock:
            audio = self.buf.copy()
            context = self.context
            context_revision = self._context_revision
        secs = len(audio) / SAMPLE_RATE
        if secs < MIN_SECONDS:
            self._emit_final("", secs, 0, stop_started, "too-short", 0)
            self._join_preview_thread()
            return

        if not has_speech(audio):
            self._emit_final("", secs, 0, stop_started, "no-speech", 0)
            self._join_preview_thread()
            return

        # Fastest path: a previously completed preview already contains the
        # whole utterance (or differs only by a short stable silence tail). Emit
        # before waiting for a newer, now-unneeded preview that may be in flight.
        reusable = self._reusable_preview(audio, context_revision)
        if reusable is not None and reusable.result.context_verified:
            self._emit_final(
                reusable.result.text,
                secs,
                0,
                stop_started,
                reusable.mode,
                0,
                reusable.unseen_samples,
                reusable.result.language,
                review=reusable.review,
            )
            self._join_preview_thread()
            return

        wait_started = time.perf_counter()
        if not self._join_preview_thread():
            emit({"type": "error", "message": "final: preview decode did not stop"})
            return
        wait_ms = int((time.perf_counter() - wait_started) * 1000)

        # The in-flight preview may have completed on exactly the final buffer
        # while stop() was waiting. Reuse it before scheduling another pass.
        preview_context = self._recent_context_preview(audio, context_revision)
        reusable = self._reusable_preview(audio, context_revision)
        if reusable is not None:
            result = reusable.result
            inference_started = time.perf_counter()
            context_check = None
            try:
                if not result.context_verified:
                    result, context_check = self._verify_context_result(
                        audio,
                        context,
                        result,
                        preview_context,
                    )
            except Exception as e:
                emit({"type": "error", "message": f"final: {e}"})
                return
            inference_ms = int((time.perf_counter() - inference_started) * 1000)
            final_mode = reusable.mode
            if context_check is not None:
                final_mode += f"-{context_check}"
            self._emit_final(
                result.text,
                secs,
                inference_ms,
                stop_started,
                final_mode,
                wait_ms,
                reusable.unseen_samples,
                result.language,
                review=reusable.review if result.context_verified else None,
            )
            return

        inference_started = time.perf_counter()
        try:
            result = self._decode_final_result(audio, context)
            # Automatic language detection must preserve intentional mixed
            # speech. Script counts cannot distinguish it from a translation;
            # only the user's explicit short-clip preference forces a language.
            result, context_check = self._verify_context_result(
                audio,
                context,
                result,
                preview_context,
            )
            review = None
            if (
                self._language_for_audio(audio) is None
                and context_check not in {"context-check-error", "context-check-unresolved"}
            ):
                # The complete decode is authoritative. The stabilizer may
                # suggest a word choice, but must never veto its content.
                self._stabilizer.update(
                    result.text, 0, len(audio), context_revision
                )
                if self._stabilizer.review:
                    review = self._stabilizer.review.for_transcript(result.text)
        except Exception as e:
            emit({"type": "error", "message": f"final: {e}"})
            return
        inference_ms = int((time.perf_counter() - inference_started) * 1000)
        mode = "fresh-final"
        if context_check is not None:
            mode += f"-{context_check}"
        self._emit_final(
            result.text,
            secs,
            inference_ms,
            stop_started,
            mode,
            wait_ms,
            language=result.language,
            review=review,
        )


def main() -> int:
    model_id = os.environ.get("WHISPR_MODEL", "Qwen/Qwen3-ASR-0.6B")
    engine = os.environ.get("WHISPR_ENGINE", "qwen3")
    bits = int(os.environ.get("WHISPR_BITS", "8"))
    context = os.environ.get("WHISPR_CONTEXT", "")
    short_utterance_language = os.environ.get(
        "WHISPR_SHORT_UTTERANCE_LANGUAGE",
        "",
    )

    try:
        server = Server(
            model_id,
            bits,
            context,
            short_utterance_language,
            engine=engine,
            learned_context=os.environ.get("WHISPR_LEARNED_CONTEXT", ""),
        )
    except Exception as e:
        emit({"type": "error", "message": f"load: {e}"})
        return 1

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        cmd = msg.get("cmd")
        try:
            if cmd == "start":
                server.start(msg.get("short_utterance_language"))
            elif cmd == "audio":
                server.audio(msg["pcm"])
            elif cmd == "stop":
                server.stop()
            elif cmd == "context":
                server.set_context(msg.get("text", ""))
            elif cmd == "learned_context":
                server.set_learned_context(msg.get("text", ""))
            elif cmd == "quit":
                break
        except Exception as e:
            emit({"type": "error", "message": f"{cmd}: {e}"})
    return 0


if __name__ == "__main__":
    sys.exit(main())
