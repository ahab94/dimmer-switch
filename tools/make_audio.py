#!/usr/bin/env python3
"""Synthesizes every sound in the game, Python standard library only.

    python3 tools/make_audio.py

Writes 16-bit mono WAVs (Godot compresses them on import):
  audio/sfx/*.wav     short effects, 44.1 kHz
  audio/music/*.wav   seamless 22.05 kHz loops: thriller_base and
                      thriller_drive are two stems of the same cue (the game
                      starts them together and fades "drive" in with
                      danger); menu is the full mix.

The effects are shared with the marketing videos
(tools/video/make_video_audio.py), plus a few only the game needs. Repeating
sounds (footsteps, vent taps) are kept short, low and dark: loud bright
footsteps get annoying fast. Output is deterministic (fixed seeds).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "video"))
import synth as A  # noqa: E402
import make_video_audio as V  # noqa: E402

OUT = os.path.join(HERE, "..", "audio")
tone, noise, layer, at, hz = A.tone, A.noise, A.layer, A.at, A.hz


def game_sfx():
    shared = V.sfx()
    s = {name: shared[name] for name in
         ("shot", "shatter", "lights_out", "takedown", "nv_on", "alarm", "key", "huh", "ding")}
    # Footstep: a soft, muffled tap on carpet. Quiet and dark on purpose.
    s["step"] = layer(noise(0.07, 0.5, decay=0.015, lowpass=500, seed=301),
                      tone(90, 0.06, "sine", 0.3, decay=0.015))
    # A crawl tap inside a metal air duct: dull, slightly hollow.
    s["vent"] = layer(noise(0.06, 0.35, decay=0.012, lowpass=900, highpass=150, seed=302),
                      tone(240, 0.08, "sine", 0.15, decay=0.02))
    # Climbing a ladder rung.
    s["rung"] = layer(tone(420, 0.06, "tri", 0.18, decay=0.015), noise(0.03, 0.2, decay=0.008, lowpass=2500, seed=303))
    # Working on the objective: a little burst of computer beeps.
    s["interact"] = layer(*[at(i * 0.11, tone(hz(n), 0.07, "square", 0.08, decay=0.03, lowpass=3500))
                            for i, n in enumerate(["E6", "B5", "G6", "D6", "A6", "E6", "B6"])])
    # Objective complete: keycard chirp into a bell.
    s["objective"] = layer(V.sfx()["key"], at(0.18, shared["ding"]))
    # First moment a guard notices you: a sharp string "stab".
    s["spotted"] = layer(tone(hz("B4"), 0.35, "saw", 0.2, decay=0.12, lowpass=2600, detune=0.01),
                         tone(hz("F5"), 0.35, "saw", 0.15, decay=0.12, lowpass=2600, detune=0.01))
    # Door / exit still locked: a dull buzz.
    s["locked"] = tone(110, 0.22, "square", 0.12, lowpass=900)
    # Menu tap.
    s["click"] = tone(1200, 0.04, "sine", 0.25, decay=0.01)
    # Mission complete: a short rising fanfare.
    s["complete"] = layer(*[at(i * 0.12, tone(hz(n), 0.35, "saw", 0.12, decay=0.18, lowpass=2400, detune=0.006))
                            for i, n in enumerate(["E4", "G4", "B4", "E5"])])
    return s


def main():
    for name, samples in game_sfx().items():
        A.write_wav(os.path.join(OUT, "sfx", name + ".wav"), samples)
    A.SR = 22050
    A.write_wav(os.path.join(OUT, "music", "thriller_base.wav"), V.thriller_theme(V.BASE), peak=0.7)
    A.write_wav(os.path.join(OUT, "music", "thriller_drive.wav"), V.thriller_theme(V.DRIVE), peak=0.7)
    A.write_wav(os.path.join(OUT, "music", "menu.wav"), V.thriller_theme(), peak=0.7)


if __name__ == "__main__":
    main()
