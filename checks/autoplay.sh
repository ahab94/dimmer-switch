#!/bin/bash
# Done when: the autopilot beats every mission without ever being noticed.
# Proves each level is winnable. Plans in-process and replays the plan
# through the real simulation (tests/autoplay_test.gd).
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT=$(command -v godot || echo /Applications/Godot.app/Contents/MacOS/Godot)
out=$("$GODOT" --headless --path . --script res://tests/autoplay_test.gd "$@" 2>&1) || true
echo "$out" | grep -E "RESULT|SCRIPT ERROR|FAIL|AUTOPLAY"
echo "$out" | grep -q "AUTOPLAY OK" || { echo "autoplay: some missions failed"; exit 1; }
