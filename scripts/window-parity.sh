#!/bin/zsh
#
#  window-parity.sh — is the whole Mac window the same picture as the iPad's?
#
#  `chrome-parity.sh` compares the chrome's parts, rendered offscreen. This
#  compares the real window: the iPad app in the `HN-iPad` simulator in
#  landscape, and the Mac app in a window exactly the size of the iPad's safe
#  area, both launched with the same settings and the same sample collection,
#  captured empty and with one note open, and compared pixel by pixel. Only the
#  OS's own window chrome is masked: the Mac's traffic lights and its window's
#  rounded corners.
#
#  **The safe area is measured, not known.** The iPad half reports the status
#  bar's height as SpringBoard gives it, and the Mac's window and the cut of
#  the iPad's picture are sized from that. They were 1210×790 and 24pt, written
#  down — and the simulator's bar is 32pt now, so every row was 8pt out and an
#  empty window that matched failed by 3.5% (implemented.md §51.43).
#
#  **With a note open, the note is reported and not judged.** Its text is 17pt
#  on iOS and 16pt on the Mac on purpose (`AppearanceSettings.baseEditorFontSize`),
#  so the middle of that picture cannot match. The verdict there is the
#  chrome's — the sidebar, the bar, the status row.
#
#  **It never shows your vault, and never rewrites your preferences.** The Mac
#  app is launched with its open collections overridden to the sample
#  `DefaultCollection` alone, through the argument domain — all three lists,
#  the cloud collections' among them — with window restoration off and
#  `-HNCaptureSession YES`, under which it saves no collection list and no
#  recents. Before each picture the window is read through Accessibility for
#  the name of any other collection of yours or its top-level folders, and a
#  match takes no picture (`window-names.swift`; it prints a count, never a
#  name). Afterwards the list is *read* back and compared with a copy taken
#  first, and a difference is reported, not repaired — repairing it by
#  importing the copy once lost a race with the preferences daemon and left
#  the sample as the only open collection. Window state is restored from a
#  copy, as files. Your running HelloNotes is asked to quit first, gracefully,
#  because it may hold unsaved edits.
#
#  The iPad half needs no screen: an opt-in UI test rotates the simulator,
#  launches with the same settings and keeps the captures and the geometry
#  (`HelloNotesUITests.testWindowParityCapture`). The simulator gets a copy of
#  the Mac's sample collection, dates and all, so the rows say the same things.
#  `PARITY_REUSE_IPAD=1` keeps the last run's iPad half and takes the Mac's
#  again — for a change that is the Mac's alone.
#
#  **Its negative control**, to run after changing either script: one point of
#  padding above the shell on the Mac alone (`.padding(.top, 1)` under
#  `#if os(macOS)` at `AdaptiveShell.body`) must fail both states, by several
#  per cent of the chrome. Without it both pass.
#
set -u
here=${0:a:h}
cd "$here/.." || exit 1
work="${TMPDIR:-/tmp}/window-parity"
reuse_ipad=""
if [[ -n "${PARITY_REUSE_IPAD:-}" && -f "$work/ipad-empty.png" && -f "$work/ipad-note.png" && -f "$work/ipad-geometry.json" ]]; then
  reuse_ipad=1
  rm -f "$work"/mac-*.png "$work"/diff-*.png "$work"/side-*.png "$work"/prefs-*.plist
  rm -rf "$work/saved-backup"
else
  rm -rf "$work"; mkdir -p "$work"
fi

container=~/Library/Containers/com.hellotham.HelloNotes/Data
prefs="$container/Library/Preferences/com.hellotham.HelloNotes"
saved="$container/Library/Saved Application State/com.hellotham.HelloNotes.savedState"
sample="$container/Documents/DefaultCollection"
note_url="hellonotes://note?collection=DefaultCollection&title=Linking"
settings=(-hasSeenWelcome YES -appearanceMode light -accentChoice lavender -increaseContrast NO
          -textScale 1 -editorViewMode edit -sidePanel outline -sidebarWidth 280 -sidePanelWidth 360
          -bandContainerPaneWidth 260)

[[ -d "$sample" ]] || { echo "No sample collection at $sample"; exit 1; }

# MARK: - iPad

ipad_half() {
echo "iPad: a clean install with the Mac's sample collection…"
ios_app=$(xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes -skipPackagePluginValidation \
  -destination 'platform=iOS Simulator,name=HN-iPad' -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/HelloNotes.app
xcodebuild build -project HelloNotes.xcodeproj -scheme HelloNotes -skipPackagePluginValidation \
  -destination 'platform=iOS Simulator,name=HN-iPad' > "$work/ios-build.log" 2>&1 \
  || { echo "iOS build failed — see $work/ios-build.log"; exit 1; }
xcrun simctl terminate HN-iPad com.hellotham.HelloNotes 2>/dev/null
xcrun simctl uninstall HN-iPad com.hellotham.HelloNotes
xcrun simctl install HN-iPad "$ios_app"
xcrun simctl launch HN-iPad com.hellotham.HelloNotes -hasSeenWelcome YES > /dev/null
sleep 8   # seeds the sample collection on first launch
xcrun simctl terminate HN-iPad com.hellotham.HelloNotes
sim_docs="$(xcrun simctl get_app_container HN-iPad com.hellotham.HelloNotes data)/Documents"
rsync -a --delete "$sample/" "$sim_docs/DefaultCollection/"

echo "iPad: capturing in landscape…"
TEST_RUNNER_HN_WINDOW_PARITY=1 xcodebuild test -project HelloNotes.xcodeproj -scheme HelloNotes \
  -skipPackagePluginValidation -destination 'platform=iOS Simulator,name=HN-iPad' \
  -resultBundlePath "$work/ipad.xcresult" \
  "-only-testing:HelloNotesUITests/HelloNotesUITests/testWindowParityCapture" > "$work/ipad.log" 2>&1 \
  || { echo "iPad capture failed — see $work/ipad.log"; exit 1; }
xcrun xcresulttool export attachments --path "$work/ipad.xcresult" --output-path "$work/ipad" > /dev/null
python3 - "$work/ipad" <<'PY'
import json, shutil, sys, pathlib
folder = pathlib.Path(sys.argv[1])
for test in json.loads((folder / "manifest.json").read_text()):
    for attachment in test.get("attachments", []):
        name = attachment.get("suggestedHumanReadableName", "")
        for wanted in ("window-empty", "window-note"):
            if name.startswith(wanted):
                shutil.copy(folder / attachment["exportedFileName"], folder.parent / f"ipad-{wanted[7:]}.png")
        if name.startswith("window-geometry"):
            shutil.copy(folder / attachment["exportedFileName"], folder.parent / "ipad-geometry.json")
PY
}
if [[ -n "$reuse_ipad" ]]; then echo "iPad: the last run's half, kept."; else ipad_half; fi

# The screen, as the iPad half measured it: the Mac's window is its safe area.
read width height top bottom <<< "$(python3 -c 'import json,sys; g=json.load(open(sys.argv[1])); print(g["width"], g["height"], g["top"], g["bottom"])' "$work/ipad-geometry.json" 2>/dev/null)"
[[ -n "${bottom:-}" ]] || { echo "the iPad half kept no geometry — see $work/ipad.log"; exit 1; }
safe_height=$((height - top - bottom))
echo "iPad: ${width}×${height}pt, status bar ${top}pt, home indicator ${bottom}pt — a safe area of ${width}×${safe_height}pt."

# MARK: - Mac

# The Mac half needs a screen someone is signed in to. With the session locked
# `loginwindow` is frontmost, a new window never finishes appearing (it sits at
# 90% of its size) and `screencapture` cannot take it.
if lsappinfo info -only name "$(lsappinfo front)" 2>/dev/null | grep -q loginwindow; then
  echo "The Mac's screen is locked — the iPad half is in $work; run again when it is unlocked."
  exit 1
fi

mac_app=$(xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes -skipPackagePluginValidation \
  -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/HelloNotes.app
xcodebuild build -project HelloNotes.xcodeproj -scheme HelloNotes -skipPackagePluginValidation \
  -destination 'platform=macOS' > "$work/mac-build.log" 2>&1 \
  || { echo "macOS build failed — see $work/mac-build.log"; exit 1; }

# By what each process executes, not by a command line that mentions the app
# (`hellonotes-processes.sh`).
running() { "$here/hellonotes-processes.sh" all | tr '\n' ' '; }
if [[ -n "$(running)" ]]; then
  echo "Mac: quitting the running HelloNotes (it may hold unsaved edits)…"
  osascript -e 'tell application id "com.hellotham.HelloNotes" to quit' > /dev/null 2>&1
  for _ in {1..50}; do [[ -z "$(running)" ]] && break; sleep 0.2; done
  [[ -n "$(running)" ]] && { echo "HelloNotes would not quit; not capturing over it."; exit 1; }
fi

echo "Mac: backing up preferences (to check against) and window state…"
defaults export "$prefs" "$work/prefs-backup.plist" || { echo "could not read preferences"; exit 1; }
[[ -d "$saved" ]] && ditto "$saved" "$work/saved-backup"
restore() {
  osascript -e 'tell application id "com.hellotham.HelloNotes" to quit' > /dev/null 2>&1
  for _ in {1..100}; do [[ -z "$(running)" ]] && break; sleep 0.2; done
  rm -rf "$saved"; [[ -d "$work/saved-backup" ]] && ditto "$work/saved-backup" "$saved"
  # The window's frame is the one key written back: AppKit saves the capture's
  # 1210×790 as the main window's, and the person's next launch opened at it.
  # One key, through the preferences daemon, after the app has gone — not the
  # import of a whole backup that lost its race.
  python3 - "$work/prefs-backup.plist" "$prefs" <<'FRAME'
import plistlib, subprocess, sys
key = "NSWindow Frame main-AppWindow-1"
frame = plistlib.load(open(sys.argv[1], "rb")).get(key)
if isinstance(frame, str): subprocess.run(["defaults", "write", sys.argv[2], key, frame], check=False)
FRAME
  # **Checked, never written.** A capture session saves no collection list
  # (`CaptureSession`), so the list should be exactly as it was. An earlier
  # version imported the backup here instead, and lost the race with the
  # preferences daemon flushing the capture's own list afterwards — the open
  # collections came back as the sample alone.
  sleep 2
  defaults export "$prefs" "$work/prefs-after.plist"
  python3 - "$work/prefs-backup.plist" "$work/prefs-after.plist" <<'CHECK'
import plistlib, sys
before, after = (plistlib.load(open(p, "rb")) for p in sys.argv[1:3])
same = all(before.get(k) == after.get(k) for k in ("collectionPaths", "collectionBookmarks", "recentCollections", "remoteCollectionCaches"))
# A count, never the paths: they are the person's, and this is read in logs.
count = len(after.get("collectionPaths", [])) + len(after.get("remoteCollectionCaches") or [])
print(f"Mac: your {count} open collections are unchanged." if same
      else "WARNING — Mac: the open collections CHANGED during the capture.")
changed = sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k))
print("Mac: preference keys that changed: " + (", ".join(changed) or "none"))
sys.exit(0 if same else 3)
CHECK
  rm -f "$work/private-names.txt"
}
trap restore EXIT

# The sample collection's own bookmark, from the backup, as the only one.
only_sample=$(python3 - "$work/prefs-backup.plist" "$sample" <<'PY'
import plistlib, sys
prefs = plistlib.load(open(sys.argv[1], "rb"))
paths = prefs.get("collectionPaths", [])
index = next(i for i, p in enumerate(paths) if p.rstrip("/") == sys.argv[2].rstrip("/"))
print(prefs["collectionBookmarks"][index].hex())
PY
) || { echo "the sample collection is not among the Mac's open collections"; exit 1; }

# What must not be in a picture: the names of every other collection and of
# their top-level folders. Written to a file, counted, never printed.
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
print(f"Mac: watching the window for {len(lines)} names of {len(roots)} other collections.")
PY
swiftc -O scripts/window-names.swift -o "$work/window-names" 2> "$work/window-names.log" \
  || { echo "could not build the name check — see $work/window-names.log"; exit 1; }

echo "Mac: launching with the sample collection only, at ${width}×${safe_height}…"
# All three lists, or a collection comes back: a cloud collection is restored
# from `remoteCollectionCaches` alone, which this left as the person had it —
# so with one connected, the sidebar in the capture was not the sample's only.
#
# The frame AppKit saved for the main window outranks the scene's default
# size, so it is overridden too — in the argument domain, like the rest.
open -n -F -a "$mac_app" --args "${settings[@]}" -ApplePersistenceIgnoreState YES -HNCaptureSession YES \
  -HNWindowWidth $width -HNWindowHeight $safe_height "-NSWindow Frame main-AppWindow-1" "100 60 $width $safe_height 0 0 1512 949 " \
  -collectionBookmarks "(<$only_sample>)" -collectionPaths "(\"$sample\")" -remoteCollectionCaches "()" -HNHideTips
sleep 5
# In front, or not captured: a window of an app that is not frontmost is drawn
# at 90% — Stage Manager's set — and `screencapture -l` cannot take it. Every
# size the first runs read was exactly 0.9 of the real one.
osascript -e 'tell application id "com.hellotham.HelloNotes" to activate' > /dev/null 2>&1
sleep 3
swiftc -O scripts/winid.swift -o "$work/winid" 2> /dev/null
window() { "$work/winid" | awk -v size="^${width}(\\.0)?x${safe_height}(\\.0)?$" '$2 ~ size {print $1; exit}'; }
id=$(window)
mac_pid=$("$here/hellonotes-processes.sh" at "$mac_app/Contents/MacOS/HelloNotes" | head -1)
# Read, not looked at: no picture while a name that is not the sample's shows.
only_the_sample() {
  local seen=$("$work/window-names" "$mac_pid" "$work/private-names.txt")
  [[ "$seen" == windows=[1-9]*" matches=0" ]] && return 0
  echo "Mac: NOT captured — the window was read and is not the sample's alone ($seen)."
  return 1
}
only_the_sample || exit 1
# Every other window the app has open is kept too — anything drawn over the
# main window is part of what someone sees.
"$work/winid" | while read -r other size _; do
  [[ "$other" == "$id" ]] || screencapture -l"$other" -o -x "$work/mac-other-$other-$size.png"
done
[[ -n "$id" ]] || { echo "no ${width}×${safe_height} HelloNotes window — windows are:"; "$work/winid" | awk '{print "  " $2}'; exit 1; }
screencapture -l"$id" -o -x "$work/mac-empty.png"
open -a "$mac_app" "$note_url"
sleep 3
osascript -e 'tell application id "com.hellotham.HelloNotes" to activate' > /dev/null 2>&1
sleep 1
only_the_sample || exit 1
screencapture -l"$id" -o -x "$work/mac-note.png"

# MARK: - Compare

result=0   # not `status`, which zsh reserves
swift "$here/window-parity-compare.swift" "$work/mac-empty.png" "$work/ipad-empty.png" \
  "$work/diff-empty.png" "$work/side-empty.png" $top $bottom || result=1
swift "$here/window-parity-compare.swift" "$work/mac-note.png" "$work/ipad-note.png" \
  "$work/diff-note.png" "$work/side-note.png" $top $bottom note || result=1
echo "Pictures in $work (side-*.png: Mac | iPad; diff-*.png: differences in red)."
exit $result
