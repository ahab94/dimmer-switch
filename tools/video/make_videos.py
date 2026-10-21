#!/usr/bin/env python3
"""Builds the marketing videos from recorded footage.

    bash tools/video/record_footage.sh           # raw gameplay -> build/footage/
    python3 tools/video/make_video_audio.py      # music + sounds -> build/video_audio/
    /usr/bin/python3 tools/video/make_videos.py [video-id ...]

Needs Pillow (captions) and ffmpeg. Writes build/videos/<id>.mp4 plus
docs/marketing/youtube.md (titles, descriptions, tags).

Each video is a list of segments cut from the footage (optionally sped up)
with captions burned on top. The game is silent in v0.1, so the soundtrack
is built here: the spy theme, the game's sounds placed at the event times
the game logged while recording (shots, shattering lamps, takedowns...),
and comedy stingers.

Name and link live in NAME / PLAY_SHORT below: change them and re-run to
re-render everything.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FOOTAGE = os.path.join(ROOT, "build", "footage")
OUT = os.path.join(ROOT, "build", "videos")
AUDIO = os.path.join(ROOT, "build", "video_audio")
FONT = "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf"

NAME = "DIMMER SWITCH"          # working title, not yet approved
PLAY_SHORT = ""                 # e.g. "ahab94.github.io/dimmer-switch" once it's live
PLAY = ""                       # full URL for descriptions

GREEN = (90, 255, 115)
AMBER = (255, 214, 120)
RED = (255, 70, 60)
WHITE = (255, 255, 255)
INK = (6, 8, 14)
NIGHT = (8, 10, 22)

# Game events -> (sound, volume). The shatter also gets the comic power-down.
EVENT_SOUNDS = {
    "shot": [("shot", 0.9)],
    "shatter": [("shatter", 0.8), ("lights_out", 0.55)],
    "takedown": [("takedown", 1.0)],
    "key": [("key", 0.8)],
    "heard": [("huh", 0.8)],
    "caught": [("alarm", 0.7)],
    "complete": [("ding", 0.7)],
    "nv_on": [("nv_on", 0.9)],
}

BASE_TAGS = ["dimmer switch", "indie game", "stealth game", "free game", "godot", "gamedev",
             "2d stealth", "spy game", "light and shadow"]

# --- The videos ----------------------------------------------------------------
# Segment times refer to the source clip; caption and sfx times refer to the
# finished video's gameplay (after the intro card, if any).

VIDEOS = [
    {
        "id": "01-trailer", "orient": "landscape",
        "segments": [("l-clean-02", 0.0, 7.0, 1.3), ("l-clean-03", 0.3, 4.0, 1.0), ("l-clean-05", 1.0, 9.0, 1.5),
                     ("l-clean-06", 0.5, 7.5, 1.4), ("l-clean-07", 0.0, 12.0, 1.5), ("l-clean-08", 1.6, 5.8, 1.0),
                     ("l-clean-10", 4.0, 19.0, 1.6)],
        "intro": ("EVERY LAMP\nIS YOUR ENEMY.", 2.6),
        "captions": "auto-trailer",
        "cut_whoosh": True, "caption_pop": False,
        "outro": 4.0,
        "title": "Every lamp is your enemy | free 2D stealth game trailer",
        "blurb": "A side-view light-and-shadow stealth game. Shoot out the lights, crawl through vents, hide in the dark.",
        "tags": BASE_TAGS + ["game trailer", "indie game trailer"],
    },
    {
        "id": "02-i-made-a-game", "orient": "portrait",
        "segments": [("p-clean-02", 0.0, 4.5, 1.4), ("p-clean-03", 0.4, 3.6, 1.0), ("p-clean-05", 1.0, 8.0, 1.6),
                     ("p-clean-06", 2.5, 6.5, 1.0), ("p-clean-08", 1.8, 5.0, 1.0)],
        "captions": [
            (0.0, 3.2, "I made a stealth game\nwhere LIGHT\nis the enemy", "hook"),
            (3.2, 6.4, "so you just...\nshoot the lights", "hook"),
            (6.4, 10.8, "nobody ever\nchecks the vents", "hook"),
            (10.8, 14.8, "nap time", "hook"),
            (14.8, 18.0, "and the lasers\nare invisible", "hook"),
        ],
        "cut_whoosh": True,
        "title": "I made a stealth game where LIGHT is the enemy 💡 #shorts",
        "blurb": "I made a 2D stealth game where every lamp is your enemy. Should I keep going?",
        "tags": BASE_TAGS + ["shorts", "i made a game", "devlog"],
    },
    {
        "id": "03-lights-out", "orient": "portrait",
        "segments": [("p-clean-03", 0.0, 8.9, 1.0)],
        "captions": [
            (0.0, 1.2, "guard can see\nin the light...", "hook"),
            (1.2, 2.6, "so turn it OFF", "hook"),
            (3.0, 5.5, "saving the planet\none bulb at a time 🌍", "hook"),
        ],
        "title": "Saving the planet, one lightbulb at a time 💡🔫 #shorts",
        "blurb": "Guards can't see you in the dark. So... make it dark. Every lamp you shoot saves 60 W.",
        "tags": BASE_TAGS + ["shorts", "energy saving", "funny game"],
    },
    {
        "id": "04-vents", "orient": "portrait",
        "segments": [("p-clean-05", 0.8, 11.9, 1.3)],
        "captions": [
            (0.0, 2.5, "Rule #1 of\nstealth games:", "hook"),
            (2.5, 6.0, "NOBODY checks\nthe vents", "hook"),
            (6.0, 8.5, "not once.", "hook"),
        ],
        "sfx": [(1.2, "tiptoe"), (3.8, "tiptoe")],
        "title": "Rule #1 of stealth games: nobody EVER checks the vents 🕳️ #shorts",
        "blurb": "Crawl through the air ducts right over the guards' heads. They never check the vents.",
        "tags": BASE_TAGS + ["shorts", "stealth", "game logic"],
    },
    {
        "id": "05-me-vs-guard", "orient": "portrait",
        "segments": [("p-clumsy-02", 0.0, 5.6, 1.0), ("p-clumsy-03", 2.0, 6.5, 1.0), ("p-clumsy-05", 1.5, 5.3, 1.0)],
        "captions": [
            (0.0, 2.0, "me, a trained\nspy:", "hook"),
            (2.0, 5.6, "stealth mode:\nactivated", "hook"),
            (5.6, 10.1, "attempt #2", "hook"),
            (10.1, 13.9, "attempt #37", "hook"),
        ],
        "sfx": [(3.6, "record_scratch", 0.8), (12.2, "sad_trombone")],
        "outro": 2.5,
        "title": "Me trying to be a stealthy spy 🕵️ #shorts",
        "blurb": "Sneaking straight into the light is NOT how stealth works. Can you do better?",
        "tags": BASE_TAGS + ["shorts", "fail", "funny", "gaming fails"],
    },
    {
        "id": "06-invisible-lasers", "orient": "portrait",
        "segments": [("p-reckless-08", 0.0, 2.85, 1.0), ("p-clean-08", 0.0, 6.6, 1.0)],
        "captions": [
            (0.0, 0.9, "empty hallway!", "hook"),
            (0.9, 2.85, "IT WAS NOT", "big"),
            (2.85, 5.45, "let's try that\nagain...", "hook"),
            (5.45, 9.45, "goggles ON.\noh. OH.", "hook"),
        ],
        "sfx": [(0.85, "record_scratch", 0.8)],
        "title": "The lasers were INVISIBLE the whole time 😳 #shorts",
        "blurb": "In this stealth game, the lasers only show up through your night vision goggles.",
        "tags": BASE_TAGS + ["shorts", "lasers", "night vision"],
    },
    {
        "id": "07-nap-time", "orient": "portrait",
        "segments": [("p-clean-06", 1.0, 7.5, 1.0)],
        "captions": [
            (0.0, 2.0, "POV: you're on\nnight shift", "hook"),
            (2.0, 3.5, "someone's\nbehind you", "hook"),
            (3.5, 6.0, "nap time", "hook"),
        ],
        "title": "POV: you're a security guard on night shift 😴 #shorts",
        "blurb": "Never turn your back in a stealth game. Takedowns only work from behind!",
        "tags": BASE_TAGS + ["shorts", "pov", "security guard"],
    },
    {
        "id": "08-cameras", "orient": "portrait",
        "segments": [("p-clean-07", 0.0, 12.0, 1.3)],
        "captions": [
            (0.0, 2.0, "Cameras can only\nsee in the LIGHT", "hook"),
            (2.0, 4.5, "so... lights out", "hook"),
            (4.5, 9.2, "work smarter,\nnot harder", "hook"),
        ],
        "title": "Security cameras can't see in the dark 📷 #shorts",
        "blurb": "Cameras need light. You have a pistol. Do the math.",
        "tags": BASE_TAGS + ["shorts", "security camera", "stealth"],
    },
    {
        "id": "09-doorway", "orient": "portrait",
        "segments": [("p-clean-01", 3.2, 8.5, 1.0)],
        "captions": [
            (0.0, 2.1, "he's walking\nRIGHT at me", "hook"),
            (2.1, 3.0, "don't. move.", "hook"),
            (3.0, 5.5, "...he walked\nright past", "hook"),
        ],
        "sfx": [(1.0, "tiptoe"), (2.1, "uh_oh", 0.7)],
        "title": "He walked RIGHT past me 😮‍💨 #shorts",
        "blurb": "Step back into a dark doorway and the guard walks right past. Just don't stand in the light.",
        "tags": BASE_TAGS + ["shorts", "close call", "stealth"],
    },
    {
        "id": "10-speedrun", "orient": "portrait",
        "segments": "auto-speedrun",
        "cut_whoosh": True,
        "captions": "auto-speedrun",
        "sfx": [],
        "title": "Every mission, never spotted once 👻 #shorts",
        "blurb": "All 10 missions back to back. Ghost rating on every one. Can you do it?",
        "tags": BASE_TAGS + ["shorts", "speedrun", "satisfying"],
    },
    {
        "id": "11-final-mission", "orient": "portrait",
        "segments": [("p-clean-10", 0.0, 19.5, 1.3)],
        "captions": [
            (0.0, 2.5, "Final mission:\nthey have\nFLASHLIGHTS", "hook"),
            (2.5, 4.5, "rude.", "hook"),
            (6.5, 8.5, "keycard: got it", "hook"),
        ],
        "title": "The final mission: the guards have FLASHLIGHTS 🔦 #shorts",
        "blurb": "Flashlights, cameras, lasers, a locked door. Everything at once.",
        "tags": BASE_TAGS + ["shorts", "final level", "boss level"],
    },
]


# --- Footage helpers ---------------------------------------------------------------

def clip_events(src):
    """[(time, name)] from the EVENT lines the game printed while recording."""
    path = os.path.join(FOOTAGE, src + ".events.txt")
    out = []
    if os.path.exists(path):
        for line in open(path):
            m = re.match(r"EVENT t=([\d.]+) (\w+)", line)
            if m:
                out.append((float(m.group(1)), m.group(2)))
    return out


def clip_end(src):
    """Time of the clip's complete/caught event (the end of the action)."""
    ev = [t for t, n in clip_events(src) if n in ("complete", "caught")]
    return ev[-1] if ev else duration(os.path.join(FOOTAGE, src + ".mp4"))


def expand(v):
    """Fill in generated segment/caption lists."""
    v = dict(v)
    if v["segments"] == "auto-speedrun":
        # The last ~2.6 s of each mission, sped up, ending on EXTRACTED.
        v["segments"] = [(f"p-clean-{n:02d}", max(0.0, clip_end(f"p-clean-{n:02d}") - 3.4),
                          clip_end(f"p-clean-{n:02d}") + 0.5, 1.5) for n in range(1, 11)]
    if v["captions"] == "auto-speedrun":
        seg = 3.9 / 1.5
        v["captions"] = [(0.0, 2.6, "10 missions.\n0 times spotted.", "hook")] + \
                        [(i * seg, (i + 1) * seg, f"{i + 1}/10", "counter") for i in range(10)]
    if v["captions"] == "auto-trailer":
        t, caps = 0.0, []
        lines = ["Light is how they see you", "So shoot out the lights", "Nobody checks the vents",
                 "Never turn your back", "Cameras need light too", "Night vision shows the lasers",
                 "10 missions. Flashlights. Rude."]
        for (src, a, b, sp), text in zip(v["segments"], lines):
            d = (b - a) / sp
            caps.append((t + 0.2, t + d - 0.2, text, "low"))
            t += d
        v["captions"] = caps
    return v


def frame_size(orient):
    return (1080, 1920) if orient == "portrait" else (1920, 1080)


def font(size):
    return ImageFont.truetype(FONT, size)


def draw_centered(draw, lines, y_center, size, fill, width, stroke=10, line_gap=1.12):
    f = font(size)
    y = y_center - size * line_gap * len(lines) / 2
    for line in lines:
        w = draw.textlength(line, font=f)
        draw.text(((width - w) / 2, y), line, font=f, fill=fill, stroke_width=stroke, stroke_fill=INK)
        y += size * line_gap


def caption_png(path, text, style, orient):
    W, H = frame_size(orient)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # The caption font has no emoji, so they'd render as boxes: keep them for
    # titles only.
    text = "".join(ch for ch in text if ord(ch) < 0x2000 or ch in "…’").strip()
    lines = [l.strip() for l in text.split("\n")] if text else []
    portrait = orient == "portrait"
    if style == "big":
        draw_centered(d, lines, H * (0.29 if portrait else 0.5), 140, AMBER, W, stroke=14)
    elif style == "counter":
        draw_centered(d, lines, H * 0.775, 110, GREEN, W, stroke=12)
    elif style == "cta":
        cy = H * (0.775 if portrait else 0.8)   # under the building, above the Shorts UI
        l1 = "FREE STEALTH GAME"
        l2 = PLAY_SHORT or "coming soon to your browser"
        f1, f2 = font(60), font(40)
        w = min(W - 60, max(d.textlength(l1, font=f1), d.textlength(l2, font=f2)) + 120)
        d.rounded_rectangle([(W - w) / 2, cy - 95, (W + w) / 2, cy + 95], 30, fill=(90, 255, 115, 240))
        d.text(((W - d.textlength(l1, font=f1)) / 2, cy - 72), l1, font=f1, fill=INK)
        d.text(((W - d.textlength(l2, font=f2)) / 2, cy + 18), l2, font=f2, fill=(10, 40, 20))
    elif style == "low":
        size = 72
        f = font(size)
        bw = max(d.textlength(l, font=f) for l in lines) + 80
        bh = len(lines) * size * 1.15 + 40
        y0 = H - bh - 110
        d.rounded_rectangle([(W - bw) / 2, y0, (W + bw) / 2, y0 + bh], 26, fill=(6, 8, 14, 200))
        draw_centered(d, lines, y0 + bh / 2, size, WHITE, W, stroke=0)
    else:  # hook: the top band of a Short, clear of the platform's UI
        size = 84 if max(len(l) for l in lines) <= 18 else 70
        f = font(size)
        bw = min(W - 40, max(d.textlength(l, font=f) for l in lines) + 70)
        bh = len(lines) * size * 1.15 + 44
        cy = H * 0.215
        d.rounded_rectangle([(W - bw) / 2, cy - bh / 2, (W + bw) / 2, cy + bh / 2], 34, fill=(255, 255, 255, 238))
        draw_centered(d, lines, cy, size, INK, W, stroke=0)
    img.save(path)


def draw_agent_head(img, cx, cy, s):
    """The hero's head in balaclava with the three glowing green lenses."""
    glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    lens = [(cx + s * 0.55, cy - s * 0.42), (cx + s * 0.55, cy - s * 0.02), (cx + s * 0.25, cy - s * 0.22)]
    for x, y in lens:
        r = s * 0.32
        g.ellipse([x - r, y - r, x + r, y + r], fill=(90, 255, 115, 120))
    glow = glow.filter(ImageFilter.GaussianBlur(s * 0.18))
    d = ImageDraw.Draw(img)
    d.ellipse([cx - s, cy - s, cx + s, cy + s], fill=(20, 22, 28), outline=(80, 95, 115), width=max(3, s // 20))
    d.rectangle([cx + s * 0.05, cy + s * 0.1, cx + s * 0.75, cy + s * 0.25], fill=(160, 120, 100))
    d.line([cx - s, cy - s * 0.35, cx + s * 0.4, cy - s * 0.35], fill=(70, 62, 50), width=max(3, s // 12))
    img.alpha_composite(glow) if img.mode == "RGBA" else img.paste(glow, (0, 0), glow)
    d = ImageDraw.Draw(img)
    for x, y in lens:
        r = s * 0.13
        d.ellipse([x - r, y - r, x + r, y + r], fill=(200, 255, 210))


def draw_lamp(d, cx, cy, s, W, H):
    d.polygon([(cx - s * 0.3, cy), (cx + s * 0.3, cy), (cx + s * 3.2, H), (cx - s * 3.2, H)], fill=(60, 52, 30))
    d.polygon([(cx - s * 0.3, cy), (cx + s * 0.3, cy), (cx + s * 2.0, H), (cx - s * 2.0, H)], fill=(84, 72, 40))
    d.polygon([(cx - s * 0.3, cy - s * 0.3), (cx + s * 0.3, cy - s * 0.3), (cx + s * 0.55, cy), (cx - s * 0.55, cy)], fill=(70, 74, 82))
    d.line([cx, 0, cx, cy - s * 0.3], fill=(70, 74, 82), width=4)
    d.ellipse([cx - s * 0.18, cy - s * 0.05, cx + s * 0.18, cy + s * 0.3], fill=(255, 245, 210))


def card_png(path, orient, title_lines, kind):
    W, H = frame_size(orient)
    img = Image.new("RGB", (W, H), NIGHT)
    d = ImageDraw.Draw(img)
    portrait = orient == "portrait"
    draw_lamp(d, W * 0.5, H * 0.12, 70 if portrait else 60, W, H)
    if kind == "intro":
        draw_agent_head(img, int(W * 0.5), int(H * (0.42 if portrait else 0.45)), 130 if portrait else 110)
        d = ImageDraw.Draw(img)
        draw_centered(d, title_lines, H * (0.66 if portrait else 0.78), 110 if portrait else 96, WHITE, W, stroke=12)
    else:
        draw_agent_head(img, int(W * 0.5), int(H * (0.33 if portrait else 0.34)), 110 if portrait else 90)
        d = ImageDraw.Draw(img)
        draw_centered(d, [NAME], H * (0.52 if portrait else 0.6), 120 if portrait else 120, GREEN, W, stroke=12)
        draw_centered(d, ["A FREE STEALTH GAME"], H * (0.61 if portrait else 0.72), 64 if portrait else 64, AMBER, W, stroke=8)
        draw_centered(d, [PLAY_SHORT or "coming soon to your browser"], H * (0.68 if portrait else 0.82),
                      46, WHITE, W, stroke=6)
    img.save(path)


def thumbnail_png(path):
    W, H = 1280, 720
    img = Image.new("RGBA", (W, H), NIGHT + (255,))
    d = ImageDraw.Draw(img)
    draw_lamp(d, 900, 90, 70, W, H)
    # a broken bulb on the left, glass flying
    d.polygon([(250, 60), (330, 60), (360, 110), (220, 110)], fill=(70, 74, 82))
    for x, y in [(240, 150), (300, 175), (350, 140), (275, 210), (330, 230)]:
        d.polygon([(x, y), (x + 14, y + 6), (x + 4, y + 18)], fill=(220, 235, 255))
    draw_agent_head(img, 360, 430, 150)
    d = ImageDraw.Draw(img)
    draw_centered(d, ["EVERY LAMP IS", "YOUR ENEMY"], 560, 92, WHITE, W + 560, stroke=12)
    img.convert("RGB").save(path)


# --- Assembly --------------------------------------------------------------------

def run(cmd):
    subprocess.run(cmd, check=True)


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                         capture_output=True, text=True, check=True).stdout
    return float(out.strip())


def cut(src, start, end, speed, path, W, H):
    vf = f"setpts=PTS/{speed},scale={W}:{H},fps=30"
    run(["ffmpeg", "-loglevel", "error", "-y", "-ss", f"{start:.3f}", "-to", f"{end:.3f}",
         "-i", os.path.join(FOOTAGE, src + ".mp4"), "-vf", vf, "-an",
         "-c:v", "libx264", "-preset", "fast", "-crf", "16", "-pix_fmt", "yuv420p", path])


def still(png, seconds, path):
    run(["ffmpeg", "-loglevel", "error", "-y", "-loop", "1", "-t", str(seconds), "-i", png,
         "-vf", "fps=30,format=yuv420p", "-c:v", "libx264", "-preset", "fast", "-crf", "16", path])


def build(v, tmp):
    v = expand(v)
    W, H = frame_size(v["orient"])
    parts = []
    if "intro" in v:
        text, secs = v["intro"]
        png = os.path.join(tmp, "intro.png")
        card_png(png, v["orient"], text.split("\n"), "intro")
        parts.append(os.path.join(tmp, "intro.mp4"))
        still(png, secs, parts[-1])
    offset = v["intro"][1] if "intro" in v else 0.0
    # Cut the segments and carry each clip's game events over to video time.
    cues, t = [], offset
    for i, (src, a, b, speed) in enumerate(v["segments"]):
        parts.append(os.path.join(tmp, f"seg{i}.mp4"))
        cut(src, a, b, speed, parts[-1], W, H)
        for et, name in clip_events(src):
            if a <= et < b:
                for snd, vol in EVENT_SOUNDS.get(name, []):
                    cues.append((t + (et - a) / speed, snd, vol))
        seg_len = (b - a) / speed
        if v.get("cut_whoosh") and i < len(v["segments"]) - 1:
            cues.append((t + seg_len - 0.15, "whoosh", 0.45))
        t += seg_len
    if v.get("outro"):
        png = os.path.join(tmp, "outro.png")
        card_png(png, v["orient"], [], "outro")
        parts.append(os.path.join(tmp, "outro.mp4"))
        still(png, v["outro"], parts[-1])
    listing = os.path.join(tmp, "list.txt")
    with open(listing, "w") as f:
        f.writelines(f"file '{p}'\n" for p in parts)
    joined = os.path.join(tmp, "joined.mp4")
    run(["ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", listing, "-c", "copy", joined])
    total = duration(joined)

    # Captions, plus the call to action at the end of videos without an outro card.
    gameplay_end = total - offset - (v.get("outro") or 0)
    captions = list(v["captions"])
    if not v.get("outro"):
        captions.append((max(0.0, gameplay_end - 2.0), gameplay_end, "cta", "cta"))
    inputs, filters, last = [], [], "[0:v]"
    for i, (t0, t1, text, style) in enumerate(captions):
        png = os.path.join(tmp, f"cap{i}.png")
        caption_png(png, text, style, v["orient"])
        inputs += ["-loop", "1", "-t", f"{total:.2f}", "-i", png]
        filters.append(f"{last}[{i + 1}:v]overlay=0:0:enable='between(t,{t0 + offset:.2f},{t1 + offset - 0.04:.2f})'[v{i}]")
        last = f"[v{i}]"

    cues += [(c[0] + offset, c[1], c[2] if len(c) > 2 else 1.0) for c in v.get("sfx", [])]
    if v.get("caption_pop", True):
        cues += [(c[0] + offset, "pop", 0.4) for c in v["captions"] if c[3] in ("hook", "big")]
    if "intro" in v:
        cues.append((0.05, "nv_on", 0.8))
    base = len(captions) + 1
    audio_inputs = ["-stream_loop", "-1", "-i", os.path.join(AUDIO, v.get("music", "thriller_theme") + ".wav")]
    mix = [f"[{base}:a]volume={v.get('music_volume', 0.8)},aresample=48000[m]"]
    labels = ["[m]"]
    for j, (ct, name, vol) in enumerate(cues):
        audio_inputs += ["-i", os.path.join(AUDIO, name + ".wav")]
        ms = max(0, int(ct * 1000))
        mix.append(f"[{base + 1 + j}:a]aresample=48000,adelay={ms}|{ms},volume={vol:.2f}[s{j}]")
        labels.append(f"[s{j}]")
    mix.append(f"{''.join(labels)}amix=inputs={len(labels)}:normalize=0:duration=first,atrim=0:{total:.2f},"
               f"loudnorm=I=-14:TP=-1.5:LRA=11,afade=t=in:d=0.2,afade=t=out:st={max(0, total - 0.8):.2f}:d=0.8,"
               f"aresample=48000[a]")
    graph = ";".join(filters + [";".join(mix)])
    out = os.path.join(OUT, v["id"] + ".mp4")
    run(["ffmpeg", "-loglevel", "error", "-y", "-i", joined, *inputs, *audio_inputs,
         "-filter_complex", graph, "-map", last, "-map", "[a]",
         "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p", "-r", "30",
         "-c:a", "aac", "-b:a", "192k", "-ac", "2", "-movflags", "+faststart", "-t", f"{total:.2f}", out])
    fix_loudness(out, tmp)
    fix_loudness(out, tmp)   # the limiter moves it a little; a second pass lands it
    print(f"{v['id']}: {total:.1f}s -> {os.path.relpath(out, ROOT)}")
    return total


def fix_loudness(path, tmp, target=-14.0):
    """Single-pass loudnorm undershoots on short clips; measure and nudge."""
    log = subprocess.run(["ffmpeg", "-i", path, "-af", "ebur128", "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    m = re.findall(r"I:\s+(-?[\d.]+) LUFS", log)
    if not m:
        return
    gain = target - float(m[-1])
    if abs(gain) < 0.5:
        return
    fixed = os.path.join(tmp, "loud.mp4")
    run(["ffmpeg", "-loglevel", "error", "-y", "-i", path, "-c:v", "copy",
         "-af", f"volume={gain:.2f}dB,alimiter=limit=0.84:level=false", "-c:a", "aac", "-b:a", "192k", fixed])
    os.replace(fixed, path)


def description(blurb, tags):
    play = f"▶ PLAY FREE: {PLAY}\n\n" if PLAY else ""
    return f"""{play}{blurb}

{NAME.title()} is a free side-view stealth game where light is the enemy: shoot out the lamps, crawl through air ducts, hide in dark doorways and sneak past guards, cameras and invisible lasers. 10 missions. Made with the Godot engine; every sound and pixel is made in code.

{" ".join("#" + t for t in tags)}"""


def write_metadata(lengths):
    path = os.path.join(ROOT, "docs", "marketing", "youtube.md")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tags = ["indiegame", "gamedev", "godot", "stealth"]
    lines = ["# YouTube uploads", "",
             "Generated by `tools/video/make_videos.py`. Audience: **No, it's not made for kids** (family-friendly, all ages).",
             "Upload as **Private** first, then publish after review. The name is a working title: re-render after renaming.", ""]
    for v in VIDEOS:
        lines += [f"## {v['id']} ({'Short' if v['orient'] == 'portrait' else 'video'}, {lengths.get(v['id'], 0):.0f}s)", "",
                  f"**Title:** {v['title']}", "", "**Description:**", "", "```", description(v["blurb"], tags), "```", "",
                  f"**Tags:** {', '.join(v['tags'])}", ""]
    with open(path, "w") as f:
        f.write("\n".join(lines))
    with open(os.path.join(OUT, "metadata.json"), "w") as f:
        json.dump([{"id": v["id"], "file": v["id"] + ".mp4", "title": v["title"],
                    "description": description(v["blurb"], tags), "tags": v["tags"],
                    "short": v["orient"] == "portrait"} for v in VIDEOS], f, indent=2, ensure_ascii=False)
    print("wrote", os.path.relpath(path, ROOT))


def main():
    os.makedirs(OUT, exist_ok=True)
    wanted = set(sys.argv[1:])
    lengths = {}
    for v in VIDEOS:
        if wanted and v["id"] not in wanted and v["id"].split("-")[0] not in wanted:
            continue
        with tempfile.TemporaryDirectory() as tmp:
            lengths[v["id"]] = build(v, tmp)
    thumbnail_png(os.path.join(OUT, "01-trailer-thumbnail.png"))
    if not wanted:
        write_metadata(lengths)


if __name__ == "__main__":
    main()
