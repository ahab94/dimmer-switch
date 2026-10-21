#!/bin/bash
# Done when: the project loads, every mechanic test passes, and the
# autopilot beats all ten missions without ever being noticed.
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT=$(command -v godot || true)
[ -z "$GODOT" ] && [ -x /Applications/Godot.app/Contents/MacOS/Godot ] && GODOT=/Applications/Godot.app/Contents/MacOS/Godot
[ -n "$GODOT" ] || { echo "Godot is not installed"; exit 1; }
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true
out=$("$GODOT" --headless --path . --script res://tests/smoke_test.gd 2>&1) || { echo "$out"; exit 1; }
echo "$out" | grep -q "SMOKE OK" || { echo "$out"; echo "smoke test failed"; exit 1; }
out=$("$GODOT" --headless --path . --script res://tests/game_test.gd 2>&1) || { echo "$out"; exit 1; }
if echo "$out" | grep -qE "SCRIPT ERROR|FAIL:" || ! echo "$out" | grep -q "GAME OK"; then echo "$out"; echo "gameplay test failed"; exit 1; fi
bash checks/autoplay.sh | tail -1
# The real game loop must agree with the headless replay.
line=$("$GODOT" --headless --path . --fixed-fps 60 -- --level=0 --autopilot --exit-on-end --timeout=60 2>&1 | grep RESULT || true)
[[ "$line" == *"complete"*"alerts=0"* ]] || { echo "game loop autopilot failed: $line"; exit 1; }
echo "dimmer-switch: all good"
