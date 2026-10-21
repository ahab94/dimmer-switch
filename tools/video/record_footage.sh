#!/bin/bash
# Records raw gameplay for the marketing videos into build/footage/:
#   p-clean-NN.mp4   portrait 1080x1920 autopilot runs (Shorts)
#   l-clean-NN.mp4   landscape 1920x1080 autopilot runs (trailer)
#   p-clumsy-NN.mp4  portrait runs where the agent sneaks straight into trouble
#   p-reckless-NN.mp4 portrait runs where he sprints straight in
# Each clip gets NAME.events.txt (EVENT t=... lines) for placing sounds.
# Usage: record_footage.sh [clip-name ...]   (default: everything)
set -euo pipefail
cd "$(dirname "$0")/../.."
GODOT=$(command -v godot || echo /Applications/Godot.app/Contents/MacOS/Godot)
out=build/footage
mkdir -p "$out"

# Movie Maker records at the window size and ignores --resolution, so each
# recording writes a temporary override.cfg (read at startup, it overrides
# project.godot) with the layout size and the real window size.
trap 'rm -f override.cfg' EXIT
window() {  # layout-w layout-h window-w window-h
	printf '[display]\nwindow/size/viewport_width=%s\nwindow/size/viewport_height=%s\nwindow/size/window_width_override=%s\nwindow/size/window_height_override=%s\n' "$@" > override.cfg
}

record() {  # name resolution level extra-flags...
	local name=$1 res=$2 level=$3; shift 3
	if [ -n "${ONLY:-}" ] && [[ " $ONLY " != *" $name "* ]]; then return; fi
	# SKIP_EXISTING=1 resumes an interrupted batch.
	if [ -n "${SKIP_EXISTING:-}" ] && [ -f "$out/$name.mp4" ]; then return; fi
	if [ "$res" = 1080x1920 ]; then window 720 1280 1080 1920; else window 1280 720 1920 1080; fi
	# --always-on-top: a covered window isn't redrawn on macOS, which would
	# record frozen frames.
	# Retry if the run gets killed from outside (no RESULT line).
	for attempt in 1 2 3 4; do
		"$GODOT" --path . --always-on-top --write-movie "$out/$name.avi" --fixed-fps 30 \
			-- --level="$level" --exit-on-end --end-hold=2 --clean --log-events "$@" > "$out/$name.log" 2>&1 || true
		grep -q RESULT "$out/$name.log" && [ -f "$out/$name.avi" ] && break
		echo "  $name: attempt $attempt interrupted, retrying"
		rm -f "$out/$name.avi"
		sleep 3
	done
	grep -E "^EVENT" "$out/$name.log" > "$out/$name.events.txt" || true
	echo "$name: $(grep RESULT "$out/$name.log" || echo 'no result')"
	rm -f override.cfg
	ffmpeg -loglevel error -y -i "$out/$name.avi" -c:v libx264 -preset fast -crf 16 -pix_fmt yuv420p -an "$out/$name.mp4"
	rm "$out/$name.avi"
	local size; size=$(ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0:s=x "$out/$name.mp4")
	[ "$size" = "$res" ] || { echo "$name recorded at $size, expected $res"; exit 1; }
	local frozen; frozen=$(ffmpeg -i "$out/$name.mp4" -vf freezedetect=n=0.0005:d=1.5 -map 0:v -f null - 2>&1 | grep -c freeze_start || true)
	[ "$frozen" = 0 ] || echo "  warning: $name has $frozen frozen stretch(es) (check it)"
}

ONLY="${*:-}"
for n in $(seq 1 10); do
	id=$(printf %02d "$n")
	extra=()
	[ "$n" = 8 ] && extra=(--nv-off-until=2.6)
	[ "$n" = 10 ] && extra=(--nv-off-until=16.9)   # lights die first, then the goggles flip on
	record "p-clean-$id" 1080x1920 $((n - 1)) --portrait --autopilot ${extra[@]+"${extra[@]}"} --timeout=150
	record "l-clean-$id" 1920x1080 $((n - 1)) --autopilot ${extra[@]+"${extra[@]}"} --timeout=150
done
for n in 1 2 3 5 7; do
	record "p-clumsy-$(printf %02d "$n")" 1080x1920 $((n - 1)) --portrait --clumsy --timeout=12
done
record "p-reckless-08" 1080x1920 7 --portrait --reckless --timeout=12
