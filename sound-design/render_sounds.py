#!/usr/bin/env python3
"""Render the sound-design pairs from index.html to .caf files for the app.

index.html synthesises everything live in Web Audio, so there are no audio files
to copy — this is a faithful offline port of that graph. Every primitive below
mirrors the JS one-for-one (same envelope semantics, same biquad, same note
table), so editing a `build*` function here and re-running reproduces exactly
what the page plays.

The page's own export path renders through `OfflineAudioContext` straight to
`destination` — no compressor, no master gain — so this does the same.

    ./render_sounds.py            # writes ../WhisprStream/Resources/Sounds/*.caf

CAF rather than WAV because AudioServices reads it with the least startup
latency, which is the whole point for a sound that fires on a keypress.
"""

from __future__ import annotations

import math
import os
import shutil
import struct
import subprocess
import sys
import wave

import numpy as np

SAMPLE_RATE = 44100
TAIL = 0.15      # index.html renders duration + 0.15s
OFFSET = 0.005   # ...and builds at t=0.005

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "WhisprStream", "Resources", "Sounds")


# ---------------------------------------------------------------------------
# AudioParam envelope semantics (Web Audio spec)
# ---------------------------------------------------------------------------

def _linear_ramp(buf, t0, v0, t1, v1):
    """`linearRampToValueAtTime` — linear from (t0,v0) to (t1,v1)."""
    i0, i1 = int(t0 * SAMPLE_RATE), int(t1 * SAMPLE_RATE)
    if i1 <= i0:
        return
    i1 = min(i1, len(buf))
    if i1 <= i0:
        return
    n = i1 - i0
    buf[i0:i1] = np.linspace(v0, v1, n, endpoint=False)


def _exp_ramp(buf, t0, v0, t1, v1):
    """`exponentialRampToValueAtTime` — v0*(v1/v0)^((t-t0)/(t1-t0)).

    Web Audio requires both endpoints non-zero and > 0; the page always ramps
    down to 0.0001 rather than 0 for exactly this reason.
    """
    i0, i1 = int(t0 * SAMPLE_RATE), int(t1 * SAMPLE_RATE)
    if i1 <= i0:
        return
    i1 = min(i1, len(buf))
    if i1 <= i0:
        return
    n = i1 - i0
    frac = np.arange(n, dtype=np.float64) / (t1 - t0) / SAMPLE_RATE
    buf[i0:i1] = v0 * (v1 / v0) ** frac


def _biquad_bandpass(x, freq, q):
    """Web Audio `BiquadFilterNode` type="bandpass" (RBJ, constant 0 dB peak)."""
    w0 = 2.0 * math.pi * freq / SAMPLE_RATE
    alpha = math.sin(w0) / (2.0 * q)
    b0, b1, b2 = alpha, 0.0, -alpha
    a0, a1, a2 = 1.0 + alpha, -2.0 * math.cos(w0), 1.0 - alpha
    b0, b1, b2 = b0 / a0, b1 / a0, b2 / a0
    a1, a2 = a1 / a0, a2 / a0

    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i, xn in enumerate(x):
        yn = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        y[i] = yn
        x2, x1 = x1, xn
        y2, y1 = y1, yn
    return y


def _osc(kind, freq_curve, n):
    """Band-limited oscillator, matching Web Audio's PeriodicWave behaviour.

    A naive triangle would alias badly: at C7 (2093 Hz) its harmonics run well
    past Nyquist. Web Audio band-limits its built-in waveforms, so the additive
    form below is the honest equivalent rather than a cheap approximation.
    """
    phase = np.cumsum(2.0 * np.pi * freq_curve / SAMPLE_RATE)
    if kind == "sine":
        return np.sin(phase)

    if kind == "triangle":
        out = np.zeros(n)
        nyquist = SAMPLE_RATE / 2.0
        top = float(np.max(freq_curve))
        k = 0
        while True:
            h = 2 * k + 1
            if h * top >= nyquist:
                break
            out += ((-1) ** k) * np.sin(h * phase) / (h * h)
            k += 1
        return out * (8.0 / (math.pi ** 2))

    raise ValueError(f"unsupported oscillator: {kind}")


# ---------------------------------------------------------------------------
# Synthesis primitives — direct ports of the JS
# ---------------------------------------------------------------------------

class Ctx:
    """Accumulates scheduled voices into one mono buffer."""

    def __init__(self, seconds):
        self.n = int(math.ceil(seconds * SAMPLE_RATE))
        self.buf = np.zeros(self.n, dtype=np.float64)
        # Fixed seed: the noise bursts are perceptually identical either way,
        # but a stable seed makes re-renders byte-identical and diffable.
        self.rng = np.random.default_rng(20260801)

    def add(self, start, samples):
        i0 = int(start * SAMPLE_RATE)
        if i0 >= self.n:
            return
        i1 = min(self.n, i0 + len(samples))
        self.buf[i0:i1] += samples[: i1 - i0]


def tick(ctx, *, start, dur=0.009, peak=0.1, freq=5000, q=0.6):
    n = max(1, int(math.ceil(SAMPLE_RATE * dur)))
    noise = ctx.rng.random(n) * 2.0 - 1.0
    filtered = _biquad_bandpass(noise, freq, q)

    env = np.zeros(n)
    _exp_ramp(env, 0.0, peak, dur, 0.0001)
    if int(dur * SAMPLE_RATE) < n:
        env[int(dur * SAMPLE_RATE):] = 0.0001
    ctx.add(start, filtered * env)


def tone(ctx, *, freq, start, dur, type="sine", peak=0.28, attack=0.004, detuneCents=0):
    if detuneCents:
        freq = freq * (2.0 ** (detuneCents / 1200.0))
    n = max(1, int(math.ceil(SAMPLE_RATE * dur)))
    wave_ = _osc(type, np.full(n, float(freq)), n)

    env = np.zeros(n)
    _linear_ramp(env, 0.0, 0.0, attack, peak)
    _exp_ramp(env, attack, peak, dur, 0.0001)
    ctx.add(start, wave_ * env)


def pitchTone(ctx, *, f0, f1, start, dur, type="sine", peak=0.3, attack=0.003):
    n = max(1, int(math.ceil(SAMPLE_RATE * dur)))
    # frequency.exponentialRampToValueAtTime(f1, start + dur*0.85)
    ramp_n = max(1, int(dur * 0.85 * SAMPLE_RATE))
    curve = np.empty(n)
    frac = np.arange(min(ramp_n, n)) / float(ramp_n)
    curve[: min(ramp_n, n)] = f0 * (max(f1, 1) / f0) ** frac
    if ramp_n < n:
        curve[ramp_n:] = max(f1, 1)
    wave_ = _osc(type, curve, n)

    env = np.zeros(n)
    _linear_ramp(env, 0.0, 0.0, attack, peak)
    _exp_ramp(env, attack, peak, dur, 0.0001)
    ctx.add(start, wave_ * env)


def bloom(ctx, *, freq, start, dur, peak=0.06):
    tone(ctx, freq=freq, start=start, dur=dur, type="sine", peak=peak, attack=0.02, detuneCents=7)
    tone(ctx, freq=freq, start=start + 0.01, dur=dur * 0.8, type="sine",
         peak=peak * 0.7, attack=0.02, detuneCents=-6)


def twinkle(ctx, *, freq, start, dur=0.09, peak=0.035):
    tone(ctx, freq=freq * 2, start=start, dur=dur, type="sine", peak=peak, attack=0.003)


N = {
    "A4": 440.0, "C5": 523.25, "A5": 880.0,
    "C6": 1046.5, "D6": 1174.66, "E6": 1318.51, "G6": 1567.98,
    "C7": 2093.0,
}


# ---------------------------------------------------------------------------
# The pairs — one function per sound, mirroring index.html
# ---------------------------------------------------------------------------

def buildOpenStart(c, t0):
    tick(c, start=t0, peak=0.08, freq=6500, dur=0.006)
    tone(c, freq=N["C6"], start=t0, dur=0.07, type="triangle", peak=0.22)
    tone(c, freq=N["E6"], start=t0 + 0.048, dur=0.13, type="sine", peak=0.30)
    tone(c, freq=N["E6"] * 2, start=t0 + 0.05, dur=0.09, type="sine", peak=0.04)


def buildResolveFinish(c, t0):
    tick(c, start=t0, peak=0.08, freq=6500, dur=0.006)
    tone(c, freq=N["E6"], start=t0, dur=0.06, type="triangle", peak=0.17)
    tone(c, freq=N["G6"], start=t0 + 0.04, dur=0.09, type="sine", peak=0.25)
    tone(c, freq=N["C7"], start=t0 + 0.08, dur=0.22, type="sine", peak=0.32)
    tone(c, freq=N["C5"], start=t0 + 0.075, dur=0.28, type="sine", peak=0.05, attack=0.02)
    bloom(c, freq=N["C7"], start=t0 + 0.095, dur=0.34, peak=0.06)
    twinkle(c, freq=N["C7"], start=t0 + 0.1, dur=0.1)


def buildRunStart(c, t0):
    tick(c, start=t0, peak=0.08, freq=6500, dur=0.006)
    tone(c, freq=N["C6"], start=t0, dur=0.05, type="triangle", peak=0.20)
    tone(c, freq=N["D6"], start=t0 + 0.035, dur=0.05, type="triangle", peak=0.22)
    tone(c, freq=N["E6"], start=t0 + 0.07, dur=0.10, type="sine", peak=0.28)
    tone(c, freq=N["E6"] * 2, start=t0 + 0.072, dur=0.08, type="sine", peak=0.04)


def buildCascadeFinish(c, t0):
    tick(c, start=t0, peak=0.08, freq=6500, dur=0.006)
    tone(c, freq=N["C6"], start=t0, dur=0.045, type="triangle", peak=0.14)
    tone(c, freq=N["D6"], start=t0 + 0.03, dur=0.045, type="triangle", peak=0.16)
    tone(c, freq=N["E6"], start=t0 + 0.06, dur=0.06, type="sine", peak=0.20)
    tone(c, freq=N["G6"], start=t0 + 0.10, dur=0.09, type="sine", peak=0.26)
    tone(c, freq=N["C7"], start=t0 + 0.15, dur=0.22, type="sine", peak=0.32)
    tone(c, freq=N["C5"], start=t0 + 0.145, dur=0.28, type="sine", peak=0.05, attack=0.02)
    bloom(c, freq=N["C7"], start=t0 + 0.165, dur=0.34, peak=0.06)
    twinkle(c, freq=N["C7"], start=t0 + 0.17, dur=0.1)


def buildMotifStart(c, t0):
    tick(c, start=t0, peak=0.08, freq=6500, dur=0.006)
    tone(c, freq=N["E6"], start=t0, dur=0.055, type="triangle", peak=0.22)
    tone(c, freq=N["C6"], start=t0 + 0.045, dur=0.055, type="triangle", peak=0.20)
    tone(c, freq=N["E6"], start=t0 + 0.09, dur=0.10, type="sine", peak=0.28)


def buildPhraseFinish(c, t0):
    tick(c, start=t0, peak=0.08, freq=6500, dur=0.006)
    tone(c, freq=N["E6"], start=t0, dur=0.045, type="triangle", peak=0.15)
    tone(c, freq=N["C6"], start=t0 + 0.035, dur=0.045, type="triangle", peak=0.14)
    tone(c, freq=N["E6"], start=t0 + 0.07, dur=0.06, type="sine", peak=0.20)
    tone(c, freq=N["G6"], start=t0 + 0.11, dur=0.09, type="sine", peak=0.26)
    tone(c, freq=N["C7"], start=t0 + 0.16, dur=0.22, type="sine", peak=0.32)
    tone(c, freq=N["C5"], start=t0 + 0.155, dur=0.28, type="sine", peak=0.05, attack=0.02)
    bloom(c, freq=N["C7"], start=t0 + 0.175, dur=0.34, peak=0.06)
    twinkle(c, freq=N["C7"], start=t0 + 0.18, dur=0.1)


def buildCallStart(c, t0):
    tick(c, start=t0, peak=0.08, freq=6500, dur=0.006)
    tone(c, freq=N["A5"], start=t0, dur=0.06, type="triangle", peak=0.20)
    tone(c, freq=N["C6"], start=t0 + 0.05, dur=0.06, type="triangle", peak=0.22)
    tone(c, freq=N["E6"], start=t0 + 0.10, dur=0.12, type="sine", peak=0.28)
    tone(c, freq=N["E6"] * 2, start=t0 + 0.102, dur=0.08, type="sine", peak=0.04)


def buildAnswerFinish(c, t0):
    tick(c, start=t0, peak=0.08, freq=6500, dur=0.006)
    tone(c, freq=N["E6"], start=t0, dur=0.06, type="triangle", peak=0.16)
    tone(c, freq=N["D6"], start=t0 + 0.05, dur=0.08, type="sine", peak=0.22)
    tone(c, freq=N["C6"], start=t0 + 0.10, dur=0.09, type="sine", peak=0.24)
    tone(c, freq=N["A5"], start=t0 + 0.16, dur=0.24, type="sine", peak=0.30)
    tone(c, freq=N["A4"], start=t0 + 0.15, dur=0.30, type="sine", peak=0.05, attack=0.02)
    bloom(c, freq=N["A5"], start=t0 + 0.18, dur=0.32, peak=0.055)
    twinkle(c, freq=N["A5"], start=t0 + 0.185, dur=0.1)


def buildClickStart(c, t0):
    tick(c, start=t0, peak=0.16, freq=3800, dur=0.012, q=1.2)
    tone(c, freq=700, start=t0, dur=0.03, type="sine", peak=0.08, attack=0.001)


def buildDoubleClickFinish(c, t0):
    tick(c, start=t0, peak=0.16, freq=3800, dur=0.012, q=1.2)
    tone(c, freq=700, start=t0, dur=0.03, type="sine", peak=0.08, attack=0.001)
    tick(c, start=t0 + 0.07, peak=0.14, freq=5200, dur=0.012, q=1.2)
    tone(c, freq=N["C6"], start=t0 + 0.07, dur=0.09, type="sine", peak=0.13, attack=0.002)


def buildCrispStart(c, t0):
    tick(c, start=t0, peak=0.18, freq=7000, dur=0.007, q=1.8)


def buildCrispFinish(c, t0):
    tick(c, start=t0, peak=0.18, freq=7000, dur=0.007, q=1.8)
    tick(c, start=t0 + 0.06, peak=0.16, freq=8500, dur=0.007, q=1.8)


def buildDeepStart(c, t0):
    tick(c, start=t0, peak=0.18, freq=1800, dur=0.014, q=1.0)
    tone(c, freq=220, start=t0, dur=0.05, type="sine", peak=0.09, attack=0.002)


def buildDeepFinish(c, t0):
    tick(c, start=t0, peak=0.18, freq=1800, dur=0.014, q=1.0)
    tone(c, freq=220, start=t0, dur=0.05, type="sine", peak=0.09, attack=0.002)
    tick(c, start=t0 + 0.08, peak=0.16, freq=2400, dur=0.014, q=1.0)
    tone(c, freq=330, start=t0 + 0.08, dur=0.08, type="sine", peak=0.10, attack=0.002)


def buildTripleFinish(c, t0):
    tick(c, start=t0, peak=0.16, freq=3800, dur=0.012, q=1.2)
    tone(c, freq=700, start=t0, dur=0.03, type="sine", peak=0.08, attack=0.001)
    tick(c, start=t0 + 0.07, peak=0.14, freq=5200, dur=0.012, q=1.2)
    tone(c, freq=N["C6"], start=t0 + 0.07, dur=0.09, type="sine", peak=0.13, attack=0.002)
    tick(c, start=t0 + 0.13, peak=0.09, freq=6200, dur=0.01, q=1.2)


def buildChirpFinish(c, t0):
    tick(c, start=t0, peak=0.16, freq=3800, dur=0.012, q=1.2)
    tone(c, freq=700, start=t0, dur=0.03, type="sine", peak=0.08, attack=0.001)
    tick(c, start=t0 + 0.07, peak=0.14, freq=5200, dur=0.012, q=1.2)
    pitchTone(c, f0=900, f1=1700, start=t0 + 0.07, dur=0.06, peak=0.13, attack=0.002)


def buildAppleStart(c, t0):
    tone(c, freq=659.25, start=t0, dur=0.09, type="sine", peak=0.26, attack=0.006)
    tone(c, freq=880.0, start=t0 + 0.075, dur=0.13, type="sine", peak=0.28, attack=0.006)


def buildAppleFinish(c, t0):
    tone(c, freq=880.0, start=t0, dur=0.09, type="sine", peak=0.26, attack=0.006)
    tone(c, freq=659.25, start=t0 + 0.075, dur=0.15, type="sine", peak=0.24, attack=0.006)


# key -> (slug, (start_build, start_dur), (finish_build, finish_dur))
PAIRS = {
    "openResolve":    ("open-resolve",  (buildOpenStart, 0.22),   (buildResolveFinish, 0.55)),
    "clickDouble":    ("click-double",  (buildClickStart, 0.05),  (buildDoubleClickFinish, 0.20)),
    "risingRun":      ("rising-run",    (buildRunStart, 0.19),    (buildCascadeFinish, 0.55)),
    "motifPhrase":    ("motif-phrase",  (buildMotifStart, 0.21),  (buildPhraseFinish, 0.56)),
    "callAnswer":     ("call-answer",   (buildCallStart, 0.24),   (buildAnswerFinish, 0.55)),
    "crispClick":     ("crisp-click",   (buildCrispStart, 0.03),  (buildCrispFinish, 0.09)),
    "deepClick":      ("deep-click",    (buildDeepStart, 0.07),   (buildDeepFinish, 0.18)),
    "tripleClick":    ("triple-click",  (buildClickStart, 0.05),  (buildTripleFinish, 0.16)),
    "chirpClick":     ("chirp-click",   (buildClickStart, 0.05),  (buildChirpFinish, 0.15)),
    "appleReference": ("apple-ref",     (buildAppleStart, 0.21),  (buildAppleFinish, 0.24)),
}


# ---------------------------------------------------------------------------
# One-off interface sounds (not part of a start/finish pair)
# ---------------------------------------------------------------------------

def buildReviewConfirm(c, t0):
    """The "Check a word" pick: the house click, then a quick upward blip.

    Short enough to land with the card's 0.05 s press-in and finish before the
    panel fades, bright enough to read as "done" rather than "start".
    """
    tick(c, start=t0, peak=0.15, freq=4200, dur=0.010, q=1.2)
    tone(c, freq=700, start=t0, dur=0.025, type="sine", peak=0.07, attack=0.001)
    pitchTone(c, f0=988, f1=1568, start=t0 + 0.012, dur=0.075, peak=0.15, attack=0.002)
    twinkle(c, freq=N["E6"], start=t0 + 0.04, dur=0.07, peak=0.025)


# slug -> (build, duration)
SINGLES = {
    "review-confirm": (buildReviewConfirm, 0.12),
}


def render(build, duration):
    c = Ctx(duration + TAIL)
    build(c, OFFSET)
    return c.buf


def write_wav(path, samples):
    peak = float(np.max(np.abs(samples))) if len(samples) else 0.0
    clipped = int(np.sum(np.abs(samples) > 1.0))
    pcm = np.clip(samples, -1.0, 1.0)
    ints = np.where(pcm < 0, pcm * 0x8000, pcm * 0x7FFF).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(ints.tobytes())
    return peak, clipped


def main() -> int:
    if not shutil.which("afconvert"):
        print("error: afconvert not found", file=sys.stderr)
        return 1

    out = os.path.abspath(OUT_DIR)
    os.makedirs(out, exist_ok=True)
    tmp = os.path.join(out, "_tmp.wav")

    print(f"{'sound':<26}{'secs':>7}{'peak':>8}  clip")
    worst = 0.0
    jobs = [(f"{slug}-{half}", build, dur)
            for slug, (sb, sd), (fb, fd) in PAIRS.values()
            for half, build, dur in (("start", sb, sd), ("finish", fb, fd))]
    jobs += [(slug, build, dur) for slug, (build, dur) in SINGLES.items()]
    for name, build, dur in jobs:
            samples = render(build, dur)
            peak, clipped = write_wav(tmp, samples)
            worst = max(worst, peak)
            caf = os.path.join(out, f"{name}.caf")
            subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16", tmp, caf],
                           check=True, capture_output=True)
            flag = f" {clipped}" if clipped else ""
            print(f"{name:<26}{len(samples)/SAMPLE_RATE:>7.2f}{peak:>8.3f}{flag}")

    os.remove(tmp)
    print(f"\n{len(jobs)} files -> {out}")
    print(f"loudest peak {worst:.3f} (1.0 would clip)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
