#!/usr/bin/env python3
"""Tiny synthesizer: tones, filtered noise and mixing, standard library only.
Every sound in Dimmer Switch (and its videos) is built from these, so there
are no samples and no licensing questions. Copied from Cardboard Espionage
Action's tools/make_audio.py.
"""
import array
import math
import os
import random
import wave

SR = 44100
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "audio")
TAU = 2 * math.pi

NOTE_INDEX = {"C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "F": 5, "F#": 6,
              "Gb": 6, "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11}


def hz(note):
    """'D3', 'Bb4', 'F#2' -> frequency in Hz (A4 = 440)."""
    name, octave = note[:-1], int(note[-1])
    midi = 12 * (octave + 1) + NOTE_INDEX[name]
    return 440.0 * 2 ** ((midi - 69) / 12)


# --- Sound sources ---------------------------------------------------------

def tone(freq, dur, shape="sine", vol=0.3, attack=0.005, decay=None, release=0.03,
         glide_to=None, lowpass=None, detune=0.0, tremolo=0.0, tremolo_hz=0.0):
    """One note. `decay` = exponential fade time constant (None = sustain).
    `glide_to` slides the pitch, `detune` adds a second slightly sharp oscillator."""
    n = int(dur * SR)
    out = [0.0] * n
    p1 = p2 = 0.0
    y = 0.0
    k = 1 - math.exp(-TAU * lowpass / SR) if lowpass else None
    for i in range(n):
        t = i / SR
        f = freq if glide_to is None else freq * (glide_to / freq) ** (t / dur)
        p1 = (p1 + f / SR) % 1.0
        s = _wave(shape, p1)
        if detune:
            p2 = (p2 + f * (1 + detune) / SR) % 1.0
            s = 0.5 * (s + _wave(shape, p2))
        if k:
            y += k * (s - y)
            s = y
        env = min(1.0, t / attack) if attack > 0 else 1.0
        if decay:
            env *= math.exp(-t / decay)
        if t > dur - release:
            env *= max(0.0, (dur - t) / release)
        if tremolo:
            env *= 1 - tremolo * (0.5 + 0.5 * math.sin(TAU * tremolo_hz * t))
        out[i] = s * env * vol
    return out


def _wave(shape, p):
    if shape == "sine":
        return math.sin(TAU * p)
    if shape == "saw":
        return 2 * p - 1
    if shape == "square":
        return 1.0 if p < 0.5 else -1.0
    if shape == "tri":
        return 4 * abs(p - 0.5) - 1
    raise ValueError(shape)


def noise(dur, vol=0.3, decay=0.05, lowpass=None, highpass=None, seed=1, attack=0.001,
          sweep_to=None):
    """Filtered white noise burst. `sweep_to` moves the lowpass cutoff over time."""
    rng = random.Random(seed)
    n = int(dur * SR)
    out = [0.0] * n
    lo = hi_lp = 0.0
    for i in range(n):
        t = i / SR
        s = rng.uniform(-1, 1)
        if lowpass:
            fc = lowpass if sweep_to is None else lowpass * (sweep_to / lowpass) ** (t / dur)
            lo += (1 - math.exp(-TAU * fc / SR)) * (s - lo)
            s = lo
        if highpass:
            hi_lp += (1 - math.exp(-TAU * highpass / SR)) * (s - hi_lp)
            s = s - hi_lp
        env = min(1.0, t / attack) * (math.exp(-t / decay) if decay else 1.0)
        if t > dur - 0.01:
            env *= max(0.0, (dur - t) / 0.01)
        out[i] = s * env * vol
    return out


# --- Mixing ------------------------------------------------------------------

class Track:
    """A mono buffer. With loop=True, anything that runs past the end wraps
    to the start, so the file loops seamlessly."""

    def __init__(self, seconds, loop=False):
        self.buf = array.array("f", bytes(4 * int(seconds * SR)))
        self.loop = loop

    def add(self, start, samples, gain=1.0):
        b = self.buf
        n = len(b)
        i0 = int(start * SR)
        for i, s in enumerate(samples):
            j = i0 + i
            if j >= n:
                if not self.loop:
                    break
                j %= n
            b[j] += s * gain

    def mix(self, other, gain=1.0):
        self.add(0, other.buf, gain)

    def echo(self, delay, feedback=0.35, mix=0.3):
        """Feedback delay. On a loop, run it twice so the tail wraps too."""
        b = self.buf
        n = len(b)
        d = int(delay * SR)
        wet = array.array("f", bytes(4 * n))
        for _ in range(2 if self.loop else 1):
            for i in range(n):
                j = i - d
                if j < 0 and not self.loop:
                    continue
                wet[i] = b[j % n] + feedback * wet[j % n]
        for i in range(n):
            b[i] += wet[i] * mix


def write_wav(path, samples, peak=0.89):
    """Soft-clip, normalize to `peak`, write 16-bit mono."""
    m = max(1e-9, max(abs(s) for s in samples))
    data = array.array("h", (int(32767 * peak * math.tanh(1.2 * s / m) / math.tanh(1.2)) for s in samples))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())
    print("wrote", os.path.relpath(path, os.path.join(HERE, "..")))


def cat(*parts):
    out = []
    for p in parts:
        out.extend(p)
    return out


def at(offset, samples):
    """Prefix with silence."""
    return [0.0] * int(offset * SR) + samples


def layer(*parts):
    n = max(len(p) for p in parts)
    out = [0.0] * n
    for p in parts:
        for i, s in enumerate(p):
            out[i] += s
    return out


