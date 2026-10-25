#!/bin/zsh
#
# duo-pose.sh — pose the iPhone Duo simulator from a shell.
#
#   scripts/duo-pose.sh [device] <Closed|"Partially Open"|Open|"Rotate Right"|list>
#
# The device is HN-iPhoneDuo unless named. Device Hub (Xcode 27.1's simulator
# app) is launched or its window brought back if it has none, the device's
# row is selected, Start is pressed if the pose buttons are not showing yet,
# and then the pose. `list` prints the buttons instead. All of it through the
# Accessibility API (`duo-pose.swift`), because the controls are SwiftUI's.
#
# A pose change backgrounds the running app: relaunch it before shooting.
#   xcrun simctl io HN-iPhoneDuo screenshot --display=primary   out.png   # outer
#   xcrun simctl io HN-iPhoneDuo screenshot --display=primary-1 in.png    # inner — black while closed
#
set -euo pipefail
HERE=${0:a:h}
if (( $# == 2 )); then DEVICE=$1; POSE=$2
elif (( $# == 1 )); then DEVICE=HN-iPhoneDuo; POSE=$1
else sed -n 2,16p "$0"; exit 64; fi

UDID=$(xcrun simctl list devices -j | python3 -c '
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d["name"] == name and d.get("isAvailable", True):
            print(d["udid"]); sys.exit(0)
sys.exit(1)' "$DEVICE") || { echo "no simulator named $DEVICE" >&2; exit 1; }

# The tool, built once per change to its source.
SRC=$HERE/duo-pose.swift
BIN=${TMPDIR:-/tmp}/hellonotes-duo-pose/duo-pose
if [[ ! -x $BIN || $SRC -nt $BIN ]]; then
    mkdir -p "${BIN:h}"
    swiftc -O -o "$BIN" "$SRC"
fi

HUB=$(cd "$(xcode-select -p)/../Applications" && pwd)/DeviceHub.app
hub_pid() { pgrep -x DeviceHub 2>/dev/null | head -1 || true }
PID=$(hub_pid)
if [[ -z $PID ]]; then open -a "$HUB" || exit 1; sleep 4; PID=$(hub_pid); fi
[[ -n $PID ]] || { echo "Device Hub did not start ($HUB)" >&2; exit 1; }

# A listing selects the row and prints the buttons; "no window" means the
# window was closed (a test run on the device closes it, and the app keeps
# running) — reopening the app brings it back, in a few seconds.
listing() { "$BIN" "$PID" "$UDID" 2>&1 || true }
OUT=$(listing)
if [[ $OUT == *"no window"* ]]; then
    open -a "$HUB" || exit 1
    for _ in {1..20}; do sleep 1; OUT=$(listing); [[ $OUT == *"no window"* ]] || break; done
fi
[[ $OUT == *"no window"* ]] && { echo "Device Hub has no window to drive" >&2; exit 2; }
[[ $OUT == *"row not found"* ]] && { echo "$DEVICE is not listed in Device Hub" >&2; echo "$OUT"; exit 1; }

if [[ $POSE == list ]]; then echo "$OUT" | grep -E "^AX" | sed -E 's/ id="[^"]*"//'; exit 0; fi

has_button() { echo "$1" | grep -qE "desc=\"$2\"|title=\"$2\"" }
if ! has_button "$OUT" "$POSE"; then
    if has_button "$OUT" Start; then
        "$BIN" "$PID" "$UDID" Start | tail -1
        sleep 3
        OUT=$(listing)
    fi
fi
has_button "$OUT" "$POSE" || { echo "no button \"$POSE\" for $DEVICE; the buttons are:" >&2; echo "$OUT" | grep -E "^AX" >&2; exit 1; }
"$BIN" "$PID" "$UDID" "$POSE" | tail -1
