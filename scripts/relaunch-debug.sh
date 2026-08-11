#!/bin/zsh
# Relaunch the freshly built Debug HelloNotes.app for live testing.
#
# A HelloNotes process launched before a rebuild keeps running the OLD binary
# (plain `open` re-attaches to it), so UI verification silently tests stale
# code. End every instance, then launch a NEW one (-n) of the most recently
# built Debug app from DerivedData.
#
# **Quit gracefully first.** HelloNotes autosaves on a debounce, and its
# `TerminationGuard` drains those pending writes during the quit handshake
# (`applicationShouldTerminate` → `terminateLater`). `kill -9` skips that
# entirely, so a hard kill can silently discard whatever the user typed in the
# last debounce window. On a notes app that is data loss, and no amount of
# convenience justifies it. So: ask it to quit, give it time, and escalate only
# if it refuses — saying so loudly when we do.
#
# Every step is verified rather than assumed: each stage waits for the process
# to actually go, and the launched process is checked to be running the binary
# we just built. A relaunch that quietly left the old app up is worse than one
# that fails loudly, because you then test the wrong code and trust the result.
set -euo pipefail

# Launching takes over the user's screen, so this script must never do it by
# accident. It takes no arguments; anything passed is a misunderstanding of what
# it does, and a misunderstanding must not cost someone their window. (Asking it
# for `--help` relaunched the app, which is exactly the failure this prevents.)
if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help)
      echo "usage: relaunch-debug.sh    (no arguments)"
      echo
      echo "Force-kills every running HelloNotes instance, then launches the"
      echo "freshly built Debug app. Build first; this does not build."
      exit 0
      ;;
    *)
      echo "relaunch-debug.sh takes no arguments (got: $*)." >&2
      echo "Refusing to launch — run it bare, or --help." >&2
      exit 2
      ;;
  esac
fi

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

# What a *person* sees is not the process table — it is the Dock, ⌘-Tab and the
# window list, all of which come from LaunchServices. LaunchServices reaps a
# killed app a moment after the process dies, so a relaunch that only waits on
# `pgrep` can put the new app up while the old one is still listed and its
# window still on screen. That looks exactly like launching on top of the old
# app, and from the user's side it *is*.
registered_asns() {
  lsappinfo list 2>/dev/null \
    | awk '/bundleID="com.hellotham.HelloNotes"/ {found=1} /pid = / && found {print $3; found=0}' \
    | tr '\n' ' ' | sed 's/ $//'
}

# Wait up to $2 tenths of a second for every instance to exit. Returns 0 once
# they are all gone, 1 if any survived.
wait_for_exit() {
  for _ in {1..$1}; do
    [[ -z "$(running_pids)" ]] && return 0
    sleep 0.2
  done
  [[ -z "$(running_pids)" ]]
}

pids=$(running_pids)
if [[ -n "$pids" ]]; then
  # 1. Ask it to quit. This is the only path that runs the app's termination
  #    handshake, which is what flushes debounced autosaves. Give it a real
  #    budget (10s): draining a large note and its index is not instant.
  echo "Quitting HelloNotes ($pids) — waiting for autosaves to flush…"
  osascript -e 'tell application "HelloNotes" to quit' >/dev/null 2>&1 || true
  if wait_for_exit 50; then
    echo "Quit cleanly."
  else
    # 2. It did not go. A modal sheet or a save panel can refuse the quit
    #    event. SIGTERM next — still ordinary termination, not a kill.
    echo "Did not quit in 10s; sending SIGTERM to $(running_pids)." >&2
    kill -TERM ${=$(running_pids)} 2>/dev/null || true
    if wait_for_exit 25; then
      echo "Terminated."
    else
      # 3. Last resort, and it is not free: this skips the autosave drain, so
      #    unsaved edits in the debounce window are lost. Say so — an unnoticed
      #    hard kill on a notes app is how someone loses a paragraph.
      echo "WARNING: HelloNotes ignored quit and SIGTERM. Sending SIGKILL." >&2
      echo "WARNING: a hard kill skips the autosave flush — unsaved edits in the" >&2
      echo "         last debounce window may be lost. Check the note if it matters." >&2
      kill -9 ${=$(running_pids)} 2>/dev/null || true
      wait_for_exit 25 || true
    fi
  fi

  survivors=$(running_pids)
  if [[ -n "$survivors" ]]; then
    echo "Refusing to launch: these instances would not die: $survivors" >&2
    echo "Investigate before testing — a surviving instance is the old binary." >&2
    exit 1
  fi

  # ...and wait for LaunchServices to forget them too, so the Dock icon and the
  # window are actually gone before a new one appears.
  for _ in {1..40}; do
    [[ -z "$(registered_asns)" ]] && break
    sleep 0.2
  done
  lingering=$(registered_asns)
  if [[ -n "$lingering" ]]; then
    echo "Refusing to launch: LaunchServices still lists HelloNotes (pids: $lingering)." >&2
    echo "Launching now would put the new app on top of the old one." >&2
    exit 1
  fi
  echo "All previous instances gone (process table and LaunchServices)."
else
  echo "No running instance to kill."
fi

built=$(date -r "$binary" "+%Y-%m-%d %H:%M:%S")
echo "Launching $app"
echo "  built: $built"
# `-ApplePersistenceIgnoreState YES`: never resurrect the killed instance's
# windows. `kill -9` gives the app no chance to clear its saved state, so
# without this a relaunch can reopen the dead instance's window set — which
# again looks like the old app never went away.
open -n "$app" --args -ApplePersistenceIgnoreState YES

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
