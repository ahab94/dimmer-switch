#!/usr/bin/env python3
"""Contact sheet of a footage clip: one frame per `step` seconds, labelled
with its time, plus the clip's logged events. For picking cut points.

    /usr/bin/python3 tools/video/contact_sheet.py p-clean-05 [step] [out.png]
"""
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
name = sys.argv[1]
step = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
out = sys.argv[3] if len(sys.argv) > 3 else os.path.join(ROOT, "build", name + "-sheet.png")
src = os.path.join(ROOT, "build", "footage", name + ".mp4")
dur = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", src],
                           capture_output=True, text=True).stdout)
font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf", 22)
portrait = name.startswith("p-")
tw = 200 if portrait else 384
frames = []
with tempfile.TemporaryDirectory() as tmp:
    t = 0.0
    while t < dur:
        p = os.path.join(tmp, f"{t:.1f}.png")
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-ss", f"{t:.2f}", "-i", src, "-frames:v", "1",
                        "-vf", f"scale={tw}:-1", p], check=True)
        if os.path.exists(p):
            frames.append((t, Image.open(p).copy()))
        t += step
cols = 8 if portrait else 5
th = frames[0][1].height
if portrait:   # crop to the building band, where the action is
    th = int(th * 0.4)
rows = (len(frames) + cols - 1) // cols
sheet = Image.new("RGB", (cols * tw, rows * (th + 26) + 60), (0, 0, 0))
d = ImageDraw.Draw(sheet)
for i, (t, im) in enumerate(frames):
    if portrait:
        im = im.crop((0, int(im.height * 0.33), tw, int(im.height * 0.33) + th))
    x, y = (i % cols) * tw, (i // cols) * (th + 26)
    sheet.paste(im, (x, y + 26))
    d.text((x + 4, y + 2), f"{t:.1f}s", font=font, fill=(90, 255, 115))
ev_path = src.replace(".mp4", ".events.txt")
events = open(ev_path).read().replace("EVENT ", "").replace("\n", "  ") if os.path.exists(ev_path) else ""
d.text((6, sheet.height - 50), events[:160], font=font, fill=(255, 214, 120))
sheet.save(out)
print(out)
