#!/bin/zsh
# store-shots-mac.sh — the Mac's App Store screenshots: five scenes, light and
# dark, 2560×1600, into assets/screenshots-raw/macOS and dist/Screenshots-macOS.
#
# The iPhone and iPad sets are a test (`testStoreScreenshots`); the Mac's had
# been shot by hand each time, and once lost (assets/screenshots-raw/README.md).
# This is that procedure, written down — and it takes the screen while it runs,
# so it is the person's to start.
#
# **It captures the sample collection and nothing else.** A capture session
# (`-HNCaptureSession YES`) with all three lists in the argument domain — the
# sample's own bookmark, its path, and no cloud caches — so nothing the person
# has open comes back; before every picture the window is read through
# Accessibility for the names of their other collections and folders, and a
# match takes no picture (`window-names.swift`, which prints a count, never a
# name). The Assistant opens on the last conversation, which is the person's,
# so the chats folder is moved aside for the run; and the container's copy of
# the sample is replaced by the repository's, so the pictures show the manual
# as it ships. All of it is put back on exit, and the open collections are
# checked — read, never written — afterwards.
#
# The scenes are `SCENES` in make-screenshots.py and `screens.ts`:
#   01 Start Here, with Summary & Outline       02 Rich Content in Split
#   03 Linking, with its Graph                  04 the Mind Map, as a tab
#   05 the Assistant, answering from a note (asked once, on Local (Apple);
#      the dark picture opens on the same saved answer)
# Filed as the store's names in dist/Screenshots-macOS (01–05 dark, 06–10
# light) and as make-screenshots.py's (`dark_01.png` … `light_05.png`) in
# assets/screenshots-raw/macOS.
#
# **What it moves aside, it puts back — and only that.** Each run has its own
# folder, the trap that restores is set before anything is touched, and the
# restore undoes the steps that happened and no others. A run that is stopped
# before it can restore leaves the backups in its folder, and the next run
# refuses to start until they are put back: the first version moved the
# conversations aside before its trap existed, and began each run by deleting
# the folder an interrupted one had left them in.
#
# Needs the screen unlocked, and Accessibility for the terminal it runs in.
set -u
here=${0:a:h}
cd "$here/.." || exit 1
temporary=${TMPDIR:-/tmp}
for left in $temporary/store-shots-mac(N/) $temporary/store-shots-mac.*(N/); do
  if [[ -e $left/chats-backup || -e $left/sample-backup || -e $left/saved-backup ]]; then
    echo "An earlier run left the conversations, the sample or the window state in $left."
    echo "Put them back (or remove that folder once they are safe) before running again."
    exit 1
  fi
done
work=$(mktemp -d "$temporary/store-shots-mac.XXXXXX") || exit 1
container=~/Library/Containers/com.hellotham.HelloNotes/Data
prefs="$container/Library/Preferences/com.hellotham.HelloNotes"
saved="$container/Library/Saved Application State/com.hellotham.HelloNotes.savedState"
sample="$container/Documents/DefaultCollection"
chats="$container/Library/Application Support/HelloNotes/chats"
raw=assets/screenshots-raw/macOS
store=dist/Screenshots-macOS
width=1280; height=800
question="Summarise my Linking note in three bullet points."

[[ -d "$sample" ]] || { echo "No sample collection at $sample"; exit 1; }
if lsappinfo info -only name "$(lsappinfo front)" 2>/dev/null | grep -q loginwindow; then
  echo "The screen is locked; a window cannot be captured. Run again when it is unlocked."
  exit 1
fi

mac_app=$(xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes -skipPackagePluginValidation \
  -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/HelloNotes.app
echo "Building the Debug app…"
xcodebuild build -project HelloNotes.xcodeproj -scheme HelloNotes -skipPackagePluginValidation \
  -destination 'platform=macOS' > "$work/build.log" 2>&1 \
  || { echo "macOS build failed — see $work/build.log"; exit 1; }
for tool in window-names winid ax-press; do
  swiftc -O "scripts/$tool.swift" -o "$work/$tool" 2> "$work/$tool.log" \
    || { echo "could not build $tool — see $work/$tool.log"; exit 1; }
done

running() { "$here/hellonotes-processes.sh" all | tr '\n' ' '; }
# Asked only of an app that is running: told to quit or come forward when it is
# not, AppleScript can launch it — and which HelloNotes it launches is not this
# script's to choose.
quit_app() {
  [[ -z "$(running)" ]] && return 0
  osascript -e 'tell application id "com.hellotham.HelloNotes" to quit' > /dev/null 2>&1
  for _ in {1..100}; do [[ -z "$(running)" ]] && return 0; sleep 0.2; done
  return 1
}
if [[ -n "$(running)" ]]; then
  echo "Quitting the running HelloNotes (it may hold unsaved edits)…"
  quit_app || { echo "HelloNotes would not quit; not capturing over it."; exit 1; }
fi

# What has been done, so the restore undoes exactly that.
backed_saved=0; had_chats=0; moved_chats=0; backed_sample=0; replaced_sample=0
restore() {
  quit_app || echo "WARNING — HelloNotes would not quit; restoring anyway."
  if (( backed_saved )); then rm -rf "$saved"; ditto "$work/saved-backup" "$saved" && rm -rf "$work/saved-backup"; fi
  # The capture's conversations go only when the person's are back, or when
  # there were none to begin with.
  if (( moved_chats )); then
    rm -rf "$chats"; mv "$work/chats-backup" "$chats"
  elif (( ! had_chats )); then
    rm -rf "$chats"
  fi
  if (( replaced_sample )); then
    rsync -a --delete "$work/sample-backup/" "$sample/" && rm -rf "$work/sample-backup"
  elif (( backed_sample )); then
    rm -rf "$work/sample-backup"
  fi
  [[ -f "$work/prefs-backup.plist" ]] || return
  # The keys a capture can write are written back as they were, one at a time
  # through the preferences daemon, after the app has gone: the window's frame
  # (AppKit saves the capture's as the main window's), and any setting the
  # scenes passed in the argument domain that the app then saved as the
  # person's own — the first run left `editorViewMode` as the last scene's.
  defaults export "$prefs" "$work/prefs-captured.plist"
  python3 - "$work/prefs-backup.plist" "$work/prefs-captured.plist" "$prefs" <<'KEYS'
import plistlib, subprocess, sys
before, captured = (plistlib.load(open(p, "rb")) for p in sys.argv[1:3])
domain = sys.argv[3]
keys = ["NSWindow Frame main-AppWindow-1", "hasSeenWelcome", "appearanceMode", "accentChoice",
        "increaseContrast", "textScale", "editorViewMode", "sidePanel", "sidebarWidth",
        "sidePanelWidth", "aiModel"]
flags = {str: "-string", bool: "-bool", int: "-int", float: "-float"}
for key in keys:
    old = before.get(key)
    if old == captured.get(key):
        continue
    if old is None:
        subprocess.run(["defaults", "delete", domain, key], check=False)
    elif type(old) in flags:
        value = ("true" if old else "false") if isinstance(old, bool) else str(old)
        subprocess.run(["defaults", "write", domain, key, flags[type(old)], value], check=False)
    else:
        print(f"WARNING — {key} changed and is not a kind this script writes back.")
KEYS
  sleep 2
  defaults export "$prefs" "$work/prefs-after.plist"
  python3 - "$work/prefs-backup.plist" "$work/prefs-after.plist" <<'CHECK'
import plistlib, sys
before, after = (plistlib.load(open(p, "rb")) for p in sys.argv[1:3])
keys = ("collectionPaths", "collectionBookmarks", "recentCollections", "remoteCollectionCaches", "aiModel")
same = all(before.get(k) == after.get(k) for k in keys)
count = len(after.get("collectionPaths", [])) + len(after.get("remoteCollectionCaches") or [])
print(f"Your {count} open collections and your default model are unchanged." if same
      else "WARNING — the open collections or the default model CHANGED during the capture.")
changed = sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k))
print("Preference keys that changed: " + (", ".join(changed) or "none"))
CHECK
  rm -f "$work/private-names.txt"
}
trap restore EXIT
trap 'exit 130' INT TERM HUP

echo "Backing up preferences (to check against), window state, conversations and the sample…"
defaults export "$prefs" "$work/prefs-backup.plist" || { echo "could not read preferences"; exit 1; }
if [[ -d "$saved" ]]; then
  ditto "$saved" "$work/saved-backup" || { echo "could not back up the window state"; exit 1; }
  backed_saved=1
fi
if [[ -d "$chats" ]]; then
  had_chats=1
  mv "$chats" "$work/chats-backup" || { echo "could not move the conversations aside"; exit 1; }
  moved_chats=1
fi
ditto "$sample" "$work/sample-backup" || { echo "could not back up the sample"; exit 1; }
backed_sample=1
replaced_sample=1
rsync -a --delete DefaultCollection/ "$sample/" || { echo "could not put the shipping sample in place"; exit 1; }

only_sample=$(python3 - "$work/prefs-backup.plist" "$sample" <<'PY'
import plistlib, sys
prefs = plistlib.load(open(sys.argv[1], "rb"))
paths = prefs.get("collectionPaths", [])
index = next(i for i, p in enumerate(paths) if p.rstrip("/") == sys.argv[2].rstrip("/"))
print(prefs["collectionBookmarks"][index].hex())
PY
) || { echo "the sample collection is not among the open collections"; exit 1; }

# The names that must not be in a picture, as window-parity.sh builds them.
python3 - "$work/prefs-backup.plist" "$sample" "$work/private-names.txt" <<'PY'
import json, os, plistlib, sys
prefs = plistlib.load(open(sys.argv[1], "rb")); sample = sys.argv[2].rstrip("/")
roots = [p for p in prefs.get("collectionPaths", []) if p.rstrip("/") != sample]
roots += [p for p in (prefs.get("remoteCollectionCaches") or []) if isinstance(p, str)]
names = set()
for root in roots:
    names.add(os.path.basename(root.rstrip("/")))
    try:
        for entry in os.listdir(root):
            full = os.path.join(root, entry)
            if os.path.isdir(full) and not entry.startswith("."): names.add(entry)
            if entry.endswith(".json") and os.path.getsize(full) < 5_000_000:
                try:
                    shown = json.load(open(full)).get("displayName")
                    if isinstance(shown, str): names.add(shown)
                except Exception: pass
    except Exception: pass
in_sample = {"defaultcollection"}
for _, folders, files in os.walk(sample):
    in_sample |= {f.lower() for f in folders} | {os.path.splitext(f)[0].lower() for f in files}
lines = ["=" + n for n in sorted(names) if len(n) >= 2 and n.lower() not in in_sample]
lines += ["~" + os.path.basename(r.rstrip("/")) for r in roots
          if len(os.path.basename(r.rstrip("/"))) >= 4 and os.path.basename(r.rstrip("/")).lower() not in in_sample]
open(sys.argv[3], "w").write("\n".join(lines))
print(f"Watching the window for {len(lines)} names of {len(roots)} other collections.")
PY

activate() {
  [[ -n "$(running)" ]] && osascript -e 'tell application id "com.hellotham.HelloNotes" to activate' > /dev/null 2>&1
}
menu() {
  osascript -e "tell application \"System Events\" to tell process \"HelloNotes\" to click menu item \"$1\" of menu 1 of menu bar item \"View\" of menu bar 1" > /dev/null \
    || { echo "no View ▸ $1"; return 1; }
}
window() { "$work/winid" | awk -v size="^${width}(\\.0)?x${height}(\\.0)?$" '$2 ~ size {print $1; exit}'; }

# One scene, in its own launch, which ends with it whatever happened — a scene
# that failed left its instance running, and the next one's window could be
# taken from it.
shoot() {
  scene "$@"
  local result=$?
  quit_app || { echo "$1: HelloNotes would not quit"; return 1; }
  return $result
}

# The mode and the panel in the argument domain, so nothing is written to the
# person's settings.
scene() {   # name appearance mode panel note action
  local name=$1 appearance=$2 mode=$3 panel=$4 note=$5 action=$6
  open -n -F -a "$mac_app" --args -hasSeenWelcome YES -appearanceMode "$appearance" -accentChoice lavender \
    -increaseContrast NO -textScale 1 -editorViewMode "$mode" -sidePanel "$panel" -sidebarWidth 280 \
    -sidePanelWidth 360 -aiModel onDevice -ApplePersistenceIgnoreState YES -HNCaptureSession YES \
    -HNWindowWidth $width -HNWindowHeight $height "-NSWindow Frame main-AppWindow-1" "100 60 $width $height 0 0 1512 949 " \
    -collectionBookmarks "(<$only_sample>)" -collectionPaths "(\"$sample\")" -remoteCollectionCaches "()"
  sleep 6; activate; sleep 2
  local pid=$("$here/hellonotes-processes.sh" at "$mac_app/Contents/MacOS/HelloNotes" | head -1)
  [[ -n "$pid" ]] || { echo "$name: the app did not start"; return 1; }
  open -a "$mac_app" "hellonotes://note?collection=DefaultCollection&title=${note// /%20}"
  sleep 3; activate; sleep 1
  case "$action" in
    panel) "$work/ax-press" "$pid" "Show Panel" > /dev/null || { echo "$name: no Show Panel"; return 1; } ;;
    graph) menu "Graph" || return 1 ;;
    mindmap) menu "Mind Map" || return 1 ;;
    ask)
      menu "Assistant" || return 1
      sleep 3; activate
      # Into the message field by name, or not at all: typed into whatever
      # had the keyboard, the question would land in the note beside it.
      "$work/ax-press" "$pid" "Message" focus > /dev/null || { echo "$name: no message field"; return 1; }
      osascript -e "tell application \"System Events\" to keystroke \"$question\"" \
                -e 'tell application "System Events" to key code 36' > /dev/null
      echo "$name: asked; waiting for the answer…"
      sleep 40 ;;
    assistant) menu "Assistant" || return 1 ;;
  esac
  sleep 4; activate; sleep 1
  local seen=$("$work/window-names" "$pid" "$work/private-names.txt")
  if [[ "$seen" != windows=[1-9]*" matches=0" ]]; then
    echo "$name: NOT captured — the window is not the sample's alone ($seen)."
    return 1
  fi
  local id=$(window)
  [[ -n "$id" ]] || { echo "$name: no ${width}×${height} window"; "$work/winid" | awk '{print "  " $2}'; return 1; }
  screencapture -l"$id" -o -x "$work/$name.png" && [[ -s "$work/$name.png" ]] \
    || { echo "$name: the window could not be captured"; return 1; }
  echo "$name: $(sips -g pixelWidth -g pixelHeight "$work/$name.png" | awk '/pixel/{printf "%s ", $2}')"
}

failed=0
shoot 06-light-start-here light edit outline "Start Here" panel || failed=1
shoot 07-light-split-view light split outline "Rich Content" none || failed=1
shoot 08-light-graph light edit graph "Linking" graph || failed=1
shoot 09-light-mind-map light edit outline "Start Here" mindmap || failed=1
shoot 10-light-assistant light edit outline "Intelligence" ask || failed=1
shoot 01-dark-start-here dark edit outline "Start Here" panel || failed=1
shoot 02-dark-split-view dark split outline "Rich Content" none || failed=1
shoot 03-dark-graph dark edit graph "Linking" graph || failed=1
shoot 04-dark-mind-map dark edit outline "Start Here" mindmap || failed=1
shoot 05-dark-assistant dark edit outline "Intelligence" assistant || failed=1

if (( failed )); then
  echo "Not every scene was captured; nothing was filed. The pictures taken are in $work."
  exit 1
fi
mkdir -p "$raw" "$store"
for f in "$work"/[01]*.png; do
  base=${f:t:r}                                # 07-light-split-view
  number=${base%%-*}; look=${${base#*-}%%-*}   # 07, light
  cp "$f" "$store/"
  cp "$f" "$raw/${look}_0$(( (10#$number - 1) % 5 + 1 )).png"   # light_02.png
done
echo "Filed ten pictures into $raw and $store — look at every one before uploading."
