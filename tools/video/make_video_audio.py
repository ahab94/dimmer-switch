#!/usr/bin/env python3
"""Sound for the marketing videos: comedy stingers, the game's own effects
(the game itself is silent in v0.1) and an original spy-jazz theme.
Everything is synthesized from scratch with tools/synth.py.

    python3 tools/video/make_video_audio.py   ->  build/video_audio/*.wav
"""
import math
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import synth as A  # noqa: E402

OUT = os.path.join(A.HERE, "..", "build", "video_audio")
tone, noise, layer, at, hz = A.tone, A.noise, A.layer, A.at, A.hz


def vibrato(freq, dur, vol, depth, rate, shape="sine", glide_to=None, decay=None, lowpass=None):
    """A note with wobble: the basis of slide whistles and trombones."""
    n = int(dur * A.SR)
    out = [0.0] * n
    p = 0.0
    y = 0.0
    k = 1 - math.exp(-A.TAU * lowpass / A.SR) if lowpass else None
    for i in range(n):
        t = i / A.SR
        f = freq if glide_to is None else freq * (glide_to / freq) ** (t / dur)
        f *= 1 + depth * math.sin(A.TAU * rate * t)
        p = (p + f / A.SR) % 1.0
        s = A._wave(shape, p)
        if k:
            y += k * (s - y)
            s = y
        env = min(1.0, t / 0.02) * (math.exp(-t / decay) if decay else 1.0)
        env *= min(1.0, (dur - t) / 0.04)
        out[i] = s * env * vol
    return out


def sfx():
    s = {}
    # Slide whistle up and down: the classic cartoon "zip".
    s["slide_up"] = vibrato(500, 0.55, 0.5, 0.012, 7, glide_to=1900)
    s["slide_down"] = vibrato(1900, 0.6, 0.5, 0.012, 7, glide_to=420)
    # Boing: a spring, a pitch that bends up and down while wobbling hard.
    s["boing"] = vibrato(180, 0.6, 0.6, 0.35, 11, shape="tri", glide_to=320, decay=0.25)
    # Sad trombone: wah, wah, wah, waaaah (descending, with a buzzy brassy tone).
    notes = [("D4", 0.32), ("C#4", 0.32), ("C4", 0.32), ("B3", 1.1)]
    t = 0.0
    parts = []
    for i, (n, d) in enumerate(notes):
        last = i == len(notes) - 1
        parts.append(at(t, vibrato(hz(n), d, 0.35, 0.03 if last else 0.012, 5.5, shape="saw",
                                   glide_to=hz(n) * (0.97 if last else 0.995), lowpass=1500)))
        t += d * 0.95
    s["sad_trombone"] = layer(*parts)
    # Record scratch: a fast up-down noise sweep with a tonal rasp.
    s["record_scratch"] = layer(
        noise(0.12, 0.6, decay=0.08, lowpass=900, sweep_to=4500, seed=21),
        at(0.1, noise(0.16, 0.6, decay=0.1, lowpass=4500, sweep_to=600, seed=22)),
        tone(300, 0.26, "saw", 0.12, glide_to=900, lowpass=2500, decay=0.12),
    )
    # Bonk: a hollow wood-block knock.
    s["bonk"] = layer(tone(620, 0.25, "sine", 0.6, decay=0.05, glide_to=380),
                      tone(1240, 0.1, "sine", 0.2, decay=0.02))
    # Pop: a tiny cork pop.
    s["pop"] = layer(tone(900, 0.08, "sine", 0.6, decay=0.015, glide_to=1800),
                     noise(0.03, 0.2, decay=0.006, highpass=2000, seed=23))
    # Whoosh: a breathy sweep for transitions.
    s["whoosh"] = noise(0.45, 0.5, decay=None, lowpass=300, sweep_to=5000, highpass=150, seed=24, attack=0.2)
    # Ding: a bright bell, "correct!".
    s["ding"] = layer(tone(hz("E6"), 0.9, "sine", 0.4, decay=0.3), tone(hz("E6") * 2.76, 0.4, "sine", 0.1, decay=0.1))
    # Tiptoe: two tiny plucks, for sneaky moments.
    s["tiptoe"] = layer(tone(hz("E5"), 0.09, "tri", 0.4, decay=0.03),
                        at(0.16, tone(hz("G5"), 0.09, "tri", 0.4, decay=0.03)))
    # Gasp-like "uh oh": two falling notes.
    s["uh_oh"] = layer(vibrato(hz("A5"), 0.18, 0.4, 0.01, 6, shape="tri"),
                       at(0.2, vibrato(hz("E5"), 0.32, 0.4, 0.01, 6, shape="tri", glide_to=hz("D5"))))

    # --- The game's own sounds, placed at logged event times in the videos.
    # Suppressed pistol: a short breathy "pfft" with a soft low thump.
    s["shot"] = layer(noise(0.12, 0.6, decay=0.025, lowpass=2200, highpass=300, seed=31),
                      tone(140, 0.1, "sine", 0.4, decay=0.03, glide_to=70))
    # Glass shatter: a crack, then a shower of tiny tinkling shards.
    rng = random.Random(7)
    parts = [noise(0.25, 0.7, decay=0.05, highpass=2500, seed=32)]
    for k in range(14):
        f = rng.uniform(2800, 6500)
        parts.append(at(0.02 + rng.uniform(0, 0.45), tone(f, 0.18, "sine", rng.uniform(0.08, 0.18), decay=0.04)))
        parts.append(at(0.03 + rng.uniform(0, 0.4), noise(0.05, 0.15, decay=0.01, highpass=4000, seed=40 + k)))
    s["shatter"] = layer(*parts)
    # Lights out: the comic power-down "bwoooop" of a dying bulb.
    s["lights_out"] = layer(tone(420, 0.75, "saw", 0.35, decay=0.4, glide_to=55, lowpass=1200),
                            noise(0.04, 0.4, decay=0.008, highpass=3000, seed=33))
    # Takedown: a dull thump and a cartoon "oof".
    s["takedown"] = layer(tone(95, 0.25, "sine", 0.8, decay=0.07, glide_to=45),
                          noise(0.08, 0.3, decay=0.02, lowpass=900, seed=34),
                          at(0.06, vibrato(260, 0.28, 0.3, 0.04, 9, shape="saw", glide_to=170, lowpass=700)))
    # Night vision powering up: a rising whine with a click.
    s["nv_on"] = layer(noise(0.03, 0.4, decay=0.006, highpass=2500, seed=35),
                       at(0.02, tone(700, 0.6, "sine", 0.22, glide_to=3200, tremolo=0.4, tremolo_hz=30, release=0.2)))
    # Alarm klaxon when you get spotted.
    s["alarm"] = layer(*[at(i * 0.36, tone(660 if i % 2 == 0 else 440, 0.34, "square", 0.18, lowpass=2400))
                         for i in range(4)])
    # Keycard beep.
    s["key"] = layer(tone(hz("A5"), 0.08, "square", 0.15, lowpass=3000), at(0.09, tone(hz("E6"), 0.12, "square", 0.15, lowpass=3000)))
    # A guard's "huh?": two rising questioning notes.
    s["huh"] = layer(vibrato(hz("C4"), 0.16, 0.3, 0.02, 6, shape="saw", lowpass=900),
                     at(0.15, vibrato(hz("C4"), 0.26, 0.3, 0.02, 6, shape="saw", glide_to=hz("G4"), lowpass=900)))
    return s


def spy_theme():
    """Original cool spy-jazz loop in E minor, 92 BPM with a swing: walking
    upright bass, brushed ride, vibraphone chords and a muted-horn hook.
    16 bars, loops seamlessly."""
    bpm = 92
    beat = 60 / bpm
    bar = 4 * beat
    mix = A.Track(16 * bar, loop=True)
    swing = beat * 0.62   # the off-beat eighth lands late: that's the swing
    chords = [  # bass walk (4 beats), vibraphone voicing
        (["E2", "G2", "B2", "D3"], ["G3", "B3", "D4", "F#4"]),
        (["C2", "E2", "G2", "B2"], ["E3", "G3", "B3", "D4"]),
        (["A1", "C2", "E2", "G2"], ["C4", "E4", "G4", "B4"]),
        (["B1", "D#2", "F#2", "A2"], ["D#4", "F#4", "A4", "C5"]),
    ]
    hook = [  # (beat offset in bar, note, length in beats) per bar of the 4-bar phrase
        [(0.0, "B4", 0.5), (0.62, "E5", 0.5), (1.5, "G5", 1.0), (3.0, "F#5", 0.5), (3.62, "E5", 0.4)],
        [(0.5, "D5", 0.5), (1.0, "E5", 2.0)],
        [(0.0, "C5", 0.5), (0.62, "E5", 0.5), (1.5, "A5", 1.0), (3.0, "G5", 0.5), (3.62, "E5", 0.4)],
        [(0.0, "D#5", 1.5), (2.0, "F#5", 0.5), (2.62, "B4", 1.2)],
    ]
    rng = random.Random(11)
    for b in range(16):
        t0 = b * bar
        walk, voicing = chords[b % 4]
        for k, n in enumerate(walk):   # upright bass: plucky, warm
            f = hz(n)
            mix.add(t0 + k * beat, layer(tone(f, beat * 0.9, "tri", 0.45, decay=0.25, lowpass=500),
                                         tone(f * 2, 0.06, "sine", 0.12, decay=0.02)))
        for k in range(4):             # brushed ride: ding on the beat, swung skip
            mix.add(t0 + k * beat, noise(0.18, 0.06, decay=0.08, highpass=6000, seed=rng.randrange(10 ** 6)))
            if k % 2 == 1:
                mix.add(t0 + k * beat + swing, noise(0.1, 0.04, decay=0.04, highpass=6000, seed=rng.randrange(10 ** 6)))
            if k % 2 == 1:             # brush snare on 2 and 4
                mix.add(t0 + k * beat, noise(0.2, 0.05, decay=0.07, lowpass=3500, highpass=800, seed=rng.randrange(10 ** 6)))
        if b % 2 == 0:                 # vibraphone stabs, shimmering
            for when in (0.0, 2.0 + 0.62):
                for n in voicing:
                    mix.add(t0 + when * beat, tone(hz(n), beat * 1.4, "sine", 0.07, decay=0.6, tremolo=0.35, tremolo_hz=5.5))
        if b >= 4:                     # the horn comes in after the groove settles
            for off, n, ln in hook[b % 4]:
                mix.add(t0 + off * beat, vibrato(hz(n), ln * beat, 0.16, 0.012 if ln < 1 else 0.02, 5.0,
                                                 shape="saw", lowpass=1300))
    return mix.buf


BASE = {"ostinato", "bass", "hats", "lead", "riser"}
DRIVE = {"kick", "snare", "brass", "toms"}


def thriller_theme(parts=BASE | DRIVE):
    """Original action-thriller cue: E minor, 126 BPM, 16 bars, loops
    seamlessly. A pulsing 16th-note string ostinato drives it; sub bass,
    cinematic drums with tom fills and brass stabs build the tension; a
    soaring lead enters halfway and a riser pulls back into the loop.
    `parts` picks layers: the game plays BASE and DRIVE as two synced stems
    and fades DRIVE in with danger."""
    bpm = 126
    beat = 60 / bpm
    bar = 4 * beat
    six = beat / 4
    mix = A.Track(16 * bar, loop=True)
    chords = [("E", ["E3", "G3", "B3"]), ("E", ["E3", "G3", "B3"]), ("C", ["C3", "E3", "G3"]), ("C", ["C3", "E3", "G3"]),
              ("A", ["A2", "C3", "E3"]), ("A", ["A2", "C3", "E3"]), ("B", ["B2", "D#3", "F#3"]), ("B", ["B2", "D#3", "F#3"])]
    # Ostinato shape in semitones above the root, one per 16th: restless and pushing.
    shape = [0, 0, 7, 0, 8, 0, 7, 0, 0, 0, 7, 0, 10, 8, 7, 3]
    rng = random.Random(3)
    for b in range(16):
        t0 = b * bar
        root_name, triad = chords[b % 8]
        root = hz(root_name + "3")
        for k, semi in enumerate(shape if "ostinato" in parts else []):   # string ostinato
            f = root * 2 ** (semi / 12)
            accent = 1.0 if k % 4 == 0 else 0.7
            mix.add(t0 + k * six, tone(f, six * 0.9, "saw", 0.07 * accent, decay=0.07, lowpass=1600 + 600 * (b >= 8), detune=0.004))
        for k in range(8 if "bass" in parts else 0):   # sub bass on 8ths
            mix.add(t0 + k * beat / 2, tone(root / 2, beat * 0.45, "tri", 0.32, decay=0.12, lowpass=320))
        for when in ((0.0, 0.75, 1.5, 2.5, 3.25) if "kick" in parts else ()):   # kick: syncopated, urgent
            mix.add(t0 + when * beat, tone(120, 0.22, "sine", 0.7, decay=0.07, glide_to=42))
        if b >= 2 and "hats" in parts:             # ticking hats on 16ths
            for k in range(16):
                mix.add(t0 + k * six, noise(0.03, 0.035 if k % 2 else 0.05, decay=0.01, highpass=7000, seed=rng.randrange(10 ** 6)))
        if b >= 4 and "snare" in parts:            # snare cracks on 2 and 4
            for when in (1, 3):
                mix.add(t0 + when * beat, layer(noise(0.2, 0.32, decay=0.06, lowpass=6000, highpass=900, seed=rng.randrange(10 ** 6)),
                                                tone(190, 0.12, "tri", 0.25, decay=0.04)))
        if b % 2 == 0 and "brass" in parts:        # brass stab on the chord
            for n in triad:
                mix.add(t0, tone(hz(n), beat * 1.5, "saw", 0.06, decay=0.5, lowpass=1100, detune=0.006, attack=0.01))
                mix.add(t0, tone(hz(n) / 2, beat * 1.5, "saw", 0.05, decay=0.5, lowpass=700, detune=0.006))
        if b % 4 == 3 and "toms" in parts:         # tom fill into the next phrase
            for k, f in enumerate([180, 160, 140, 120, 100, 90]):
                mix.add(t0 + 3 * beat + k * six * 0.66, tone(f, 0.2, "sine", 0.45, decay=0.07, glide_to=f * 0.6))
    lead = ["B4", "B4", "C5", "C5", "E5", "D5", "D#5", "F#5"]   # one long note per bar, bars 8-15
    for i, n in enumerate(lead if "lead" in parts else []):
        mix.add((8 + i) * bar, vibrato(hz(n), bar * 0.98, 0.11, 0.008, 5.5, shape="saw", lowpass=2200))
        mix.add((8 + i) * bar, vibrato(hz(n) * 2, bar * 0.98, 0.04, 0.008, 5.5, shape="sine"))
    # Riser over the last bar: noise sweeping up, pulling back to the top.
    if "riser" in parts:
        mix.add(15 * bar, noise(bar, 0.25, decay=None, lowpass=400, sweep_to=9000, highpass=200, seed=77, attack=bar * 0.9))
    return mix.buf


def main():
    for name, samples in sfx().items():
        A.write_wav(os.path.join(OUT, name + ".wav"), samples)
    A.SR = 22050
    A.write_wav(os.path.join(OUT, "spy_theme.wav"), spy_theme(), peak=0.7)
    A.write_wav(os.path.join(OUT, "thriller_theme.wav"), thriller_theme(), peak=0.7)


if __name__ == "__main__":
    main()
