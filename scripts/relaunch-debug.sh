#!/bin/zsh
# Relaunch the freshly built Debug HelloNotes.app for live testing.
#
# A HelloNotes process launched before a rebuild keeps running the OLD binary
# (osascript quit / plain `open` reuse it), so UI verification silently tests
# stale code. Force-kill every instance, then launch a NEW instance (-n) of
# the most recently built Debug app from DerivedData.
#
# Every step is verified rather than assumed: killing waits for the processes
# to actually go, and the launched process is checked to be running the binary
# we just built. A relaunch that quietly left the old app up is worse than one
# that fails loudly, because you then test the wrong code and trust the result.
set -euo pipefail

app=$(ls -td "$HOME"/Library/Developer/Xcode/DerivedData/HelloNotes-*/Build/Products/Debug/HelloNotes.app 2>/dev/null | head -1)
if [[ -z "$app" ]]; then
  echo "No Debug build found in DerivedData — run xcodebuild first." >&2
  exit 1
fi
binary="$app/Contents/MacOS/HelloNotes"

# Every live instance, however it was started. `pgrep -x` alone misses an app
# whose process name differs from the bundle (a test host, an Xcode run), so
# match the executable path too and merge the two lists.
running_pids() {
  { pgrep -x HelloNotes || true; pgrep -f "HelloNotes.app/Contents/MacOS/HelloNotes" || true; } \
    | sort -u | tr '\n' ' ' | sed 's/ $//'
}

pids=$(running_pids)
if [[ -n "$pids" ]]; then
  echo "Killing running HelloNotes instance(s): $pids"
  # SIGKILL: a graceful quit can be refused by a modal sheet or a save panel,
  # and this script's whole promise is that nothing old survives it.
  kill -9 ${=pids} 2>/dev/null || true

  # Wait for them to actually go rather than hoping a fixed sleep was enough.
  for _ in {1..25}; do
    [[ -z "$(running_pids)" ]] && break
    sleep 0.2
  done
  survivors=$(running_pids)
  if [[ -n "$survivors" ]]; then
    echo "Refusing to launch: these instances would not die: $survivors" >&2
    echo "Investigate before testing — a surviving instance is the old binary." >&2
    exit 1
  fi
  echo "All previous instances gone."
else
  echo "No running instance to kill."
fi

built=$(date -r "$binary" "+%Y-%m-%d %H:%M:%S")
echo "Launching $app"
echo "  built: $built"
open -n "$app"

# Wait for it to appear, then confirm it is *this* build.
for _ in {1..25}; do
  pid=$(running_pids)
  [[ -n "$pid" ]] && break
  sleep 0.2
done
if [[ -z "${pid:-}" ]]; then
  echo "HelloNotes failed to launch." >&2
  exit 1
fi

count=$(echo "$pid" | wc -w | tr -d ' ')
if [[ "$count" != "1" ]]; then
  echo "Warning: $count instances are running ($pid) — expected exactly one." >&2
fi

first=${pid%% *}
actual=$(ps -o comm= -p "$first" | sed 's/ *$//')
echo "Running: PID $first ($(ps -o lstart= -p "$first"))"
if [[ "$actual" != "$binary" ]]; then
  echo "Warning: running executable is not the freshly built one:" >&2
  echo "  running: $actual" >&2
  echo "  built:   $binary" >&2
  exit 1
fi
echo "Verified: running the build at $built"
