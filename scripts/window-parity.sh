#!/bin/zsh
#
#  window-parity.sh — is the whole Mac window the same picture as the iPad's?
#
#  `chrome-parity.sh` compares the chrome's parts, rendered offscreen. This
#  compares the real window: the iPad app in the `HN-iPad` simulator in
#  landscape, and the Mac app in a window exactly the size of the iPad's safe
#  area (1210×790pt), both launched with the same settings and the same sample
#  collection, captured empty and with one note open, and compared pixel by
#  pixel. Only the OS's own window chrome is masked: the Mac's traffic lights
#  and its window's rounded corners.
#
#  **It never shows your vault, and never rewrites your preferences.** The Mac
#  app is launched with its open collections overridden to the sample
#  `DefaultCollection` alone, through the argument domain, with window
#  restoration off and `-HNCaptureSession YES`, under which it saves no
#  collection list and no recents. Afterwards the list is *read* back and
#  compared with a copy taken first, and a difference is reported, not
#  repaired — repairing it by importing the copy once lost a race with the
#  preferences daemon and left the sample as the only open collection. Window
#  state is restored from a copy, as files. Your running HelloNotes is asked to
#  quit first, gracefully, because it may hold unsaved edits.
#
#  The iPad half needs no screen: an opt-in UI test rotates the simulator,
#  launches with the same settings and keeps the captures
#  (`HelloNotesUITests.testWindowParityCapture`). The simulator gets a copy of
#  the Mac's sample collection, dates and all, so the rows say the same things.
#
set -u
here=${0:a:h}
cd "$here/.." || exit 1
work="${TMPDIR:-/tmp}/window-parity"
rm -rf "$work"; mkdir -p "$work"

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
PY

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

running() { pgrep -f 'HelloNotes\.app/Contents/MacOS/HelloNotes' | tr '\n' ' '; }
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
same = all(before.get(k) == after.get(k) for k in ("collectionPaths", "collectionBookmarks", "recentCollections"))
print("Mac: open collections unchanged:" if same else "WARNING — Mac: the open collections CHANGED during the capture:")
for path in after.get("collectionPaths", []): print("    " + path)
sys.exit(0 if same else 3)
CHECK
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

echo "Mac: launching with the sample collection only, at 1210×790…"
# The frame AppKit saved for the main window outranks the scene's default
# size, so it is overridden too — in the argument domain, like the rest.
open -n -F -a "$mac_app" --args "${settings[@]}" -ApplePersistenceIgnoreState YES -HNCaptureSession YES \
  -HNWindowWidth 1210 -HNWindowHeight 790 "-NSWindow Frame main-AppWindow-1" "100 60 1210 790 0 0 1512 949 " \
  -collectionBookmarks "(<$only_sample>)" -collectionPaths "(\"$sample\")" -HNHideTips
sleep 5
# In front, or not captured: a window of an app that is not frontmost is drawn
# at 90% — Stage Manager's set — and `screencapture -l` cannot take it. Every
# size the first runs read was exactly 0.9 of the real one.
osascript -e 'tell application id "com.hellotham.HelloNotes" to activate' > /dev/null 2>&1
sleep 3
swiftc -O scripts/winid.swift -o "$work/winid" 2> /dev/null
window() { "$work/winid" | awk '$2 ~ /^1210(\.0)?x790(\.0)?$/ {print $1; exit}'; }
id=$(window)
# Every other window the app has open is kept too — anything drawn over the
# main window is part of what someone sees.
"$work/winid" | while read -r other size _; do
  [[ "$other" == "$id" ]] || screencapture -l"$other" -o -x "$work/mac-other-$other-$size.png"
done
[[ -n "$id" ]] || { echo "no 1210×790 HelloNotes window — windows are:"; "$work/winid"; exit 1; }
screencapture -l"$id" -o -x "$work/mac-empty.png"
open -a "$mac_app" "$note_url"
sleep 3
osascript -e 'tell application id "com.hellotham.HelloNotes" to activate' > /dev/null 2>&1
sleep 1
screencapture -l"$id" -o -x "$work/mac-note.png"

# MARK: - Compare

result=0   # not `status`, which zsh reserves
for state in empty note; do
  swift "$here/window-parity-compare.swift" "$work/mac-$state.png" "$work/ipad-$state.png" \
    "$work/diff-$state.png" "$work/side-$state.png" || result=1
done
echo "Pictures in $work (side-*.png: Mac | iPad; diff-*.png: differences in red)."
exit $result
