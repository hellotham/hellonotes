---
name: screenshots
description: Capture App Store and website screenshots for iPhone, iPad and Mac at the exact sizes each store requires, from DefaultCollection (or SampleVault) only, keeping the raw originals. Use when store screenshots are missing, stale, or wrong for any platform.
disable-model-invocation: true
---

# Screenshots — every platform, every required size

Three separate failures in one day produced this skill: **iPad shipped with a
single stale screenshot through two submissions**, macOS shipped branded frames
where the store wanted plain ones, and the raw originals for the Mac set had
been thrown away and were unrecoverable. None of that was a hard problem. All
of it was a missing checklist.

## The grid — check it before you shoot and again before you submit

| Platform | ASC tab | Required size | Device that produces it |
|---|---|---|---|
| iOS | iPhone | 1284 × 2778 (6.5") | iPhone 13 Pro Max |
| iOS | **iPad** | **2064 × 2752 (13")** | **iPad Pro 13-inch (M4)** |
| macOS | Mac | 2560 × 1600 | a **1280 × 800pt** window at 2× |

Three traps in that table, each paid for:

- **The iPad Pro 11-inch is the wrong device.** It gives 1668 × 2420, which ASC
  rejects, and its aspect ratio differs from the 13-inch — so it cannot be
  rescaled into a valid size. Create the right one once:
  `xcrun simctl create HN-iPad13 com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB com.apple.CoreSimulator.SimRuntime.iOS-26-5`
- **A 1280 × 800pt Mac window captures at exactly 2560 × 1600** on a 2× display.
  Size the window; never pad or rescale afterwards.
- **`0 of 10` and `1 of 10` look identical at a glance.** Read the count, per
  platform, per size. That is how iPad shipped with one.

## Before any Mac capture — read, never look

**Screenshotting to check *is* capturing.** Three shots of a private 2,019-note
vault were taken while checking whether the vault had switched. Confirm by
reading:

```bash
/usr/libexec/PlistBuddy -c "Print :collectionPaths" \
  ~/Library/Containers/com.hellotham.HelloNotes/Data/Library/Preferences/com.hellotham.HelloNotes.plist
```

Capture only once that names **DefaultCollection or SampleVault and nothing
else**. `DefaultCollection` is the one to shoot: it ships inside the binary, so
it is public content by construction and it is what a reviewer sees. A
`PreToolUse` hook (`.claude/hooks/guard-screencapture.py`) enforces this and
fails closed, so a forgotten check is a blocked command rather than a privacy
incident.

**Only ever `screencapture -l<windowID>`.** A region capture (`-R`) or a
full-screen one is a *screen* recording, and macOS raises a TCC dialog —
"Claude is requesting to bypass the system private window picker" — which is a
system security prompt you must not click through, and which **steals focus**,
so the keystrokes and menu clicks you send next land nowhere. A window capture
by id needs no such grant. It also already includes the window's **child**
windows: a SwiftUI `.popover` is its own `CGWindow` but composites into the
parent's capture, so there is nothing to stitch.

**A locked screen has no windows.** `CGWindowListCopyWindowInfo` returns
nothing and System Events counts zero windows while the session is locked, so a
perfectly healthy app looks like it launched without a window — which is
half an hour of hunting a regression that does not exist. Check first:

```bash
ioreg -n Root -d1 -a | grep -A 1 CGSSessionScreenIsLocked
```

`<true/>` means stop and ask the user to unlock; nothing on the Mac can be
captured or driven until they do.

**Back the plist up first and restore it after** — opening or closing a
collection changes the user's own state.

## iOS and iPadOS — simulators, costs nothing

```bash
xcodebuild build -destination 'platform=iOS Simulator,name=HN-iPhone'
xcrun simctl install HN-iPhone <app> && xcrun simctl launch HN-iPhone com.hellotham.HelloNotes
xcrun simctl status_bar HN-iPhone override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3
xcrun simctl io HN-iPhone screenshot shot.png
```

- Seed a vault: copy `SampleVault` into the container's `Documents/`, and into
  the Files app's *File Provider Storage* so the document picker can reach it.
  Opening the collection still needs the picker — see below.
- **Derive taps from the device's point size**, never the screenshot's pixels
  (iPhone 13 Pro Max is 1284 × 2778 px at 3× = **428 × 926 pt**).
- Match the appearance across a set: `xcrun simctl ui <dev> appearance dark`.
- **Orientation is sticky between runs.** A landscape iPhone is regular width
  and draws a different shell entirely.

## macOS — the app on a real screen

```bash
./scripts/relaunch-debug.sh                    # never `open`; that reuses a stale binary
swiftc -O scripts/winid.swift -o /tmp/winid && /tmp/winid
osascript -e 'tell application "System Events" to tell process "HelloNotes"
  set position of window 1 to {0, 33}
  set size of window 1 to {1280, 800}'
screencapture -l<id> -o -x raw/dark_1.png
```

**Driving the app**: use the computer-use MCP's *background* app tools
(`app_screenshot`, `app_click`, `app_batch`) rather than System Events. They
return an accessibility summary with an index per control, click by coordinate
**and** by element index, and do it all without fronting the app — where
System Events' `entire contents` returned 96 elements with no titles and its
`Open Quickly…` menu item opened nothing. Coordinates are window points
(a 0.5-scale screenshot's frame is still 1280×800).

Two things they cannot do, both of which have a workaround:

- **A menu-presenting control is refused** in the background (opening it would
  front the app). Use the menu bar: `View ▸ Graph View`, `View ▸ Ask Library`,
  `File ▸ New Window` all work through System Events' `click menu item`.
- **Scrolling is unreliable** — the scroll action sets the scrollbar's `AXValue`
  and lands on 0. Navigate instead: the editor's **Outline & statistics**
  popover lists every heading and clicking one scrolls to it exactly.

Two editor details that decide whether a capture looks right, both caused by the
same thing — **the caret reveals the syntax it is inside**:

- Front matter draws as raw YAML while the caret is in it and folds away when it
  is not. Click a body paragraph before shooting, or the flagship screenshot
  opens on a `---` block.
- Jumping via the outline *selects* the heading, so `## Diagrams` shows its
  hashes and a selection highlight. Click a plain paragraph afterwards.

`click <element>` (AXPress) through System Events also works if you need it —
`click (first button of toolbar 1 of window 1 whose description is "Outline")`
— but the background tools are faster and do not disturb the user's frontmost
app. Notes are reachable by clicking a sidebar row; views via the **View** menu
(Edit, Preview, Markdown, Split, Graph View, Ask Library).

**Capture with the app active, from inside the same AppleScript.** `activate`
from one shell command and `screencapture` from the next captures an
*inactive* window — grey traffic lights, which reads as a screenshot of a
background app. Put both in one script so focus never returns to the terminal:

```bash
osascript -e 'tell application "HelloNotes" to activate
delay 1.5
do shell script "screencapture -l<id> -o -x /path/out.png"'
```

**Opening a collection is the one step nothing exposes to scripting.** The
picker is a separate XPC process (`com.apple.appkit.xpc.openAndSavePanelService`),
and keystrokes meant for it land on the app instead — where `⌘⇧G` is *Graph
View*, so a mistimed "go to folder" silently opens a graph window over whatever
vault is loaded. **Ask the user to open SampleVault**; it takes them twenty
seconds and no amount of cleverness beats it.

`screencapture -l<windowID>` is the only truthful capture — it renders
materials, vibrancy and Liquid Glass as they actually appear. Never judge chrome
from `cacheDisplay`, which paints materials flat white.

## Keep the originals

```bash
cp raw/*.png assets/screenshots-raw/macOS/ && git add assets/screenshots-raw
```

One folder per device — `macOS/`, `iPhone-6.5/`, `iPad-13/` — and a set that is
**half replaced is worse than one that is not started**, because six stale
files beside four fresh ones look like ten. Move the old set to a
`superseded-…/` subfolder and record the count in that folder's README until
the new one is complete.

Compositing is one-way — gradient, caption, rounded corners, drop shadow — so a
finished website frame cannot be cropped back into a clean store screenshot.
When the store wanted undecorated Mac shots, every copy was gone: the scratchpad
was deleted, git and ASC held only composites, and the last surviving images
were **1999px previews inside session transcripts**, because a transcript
downscales. A transcript is a record, not a backup.
`scripts/make-screenshots.py` now copies its inputs here automatically; commit
what it leaves.

## Website frames

```bash
./venv/bin/python scripts/make-screenshots.py assets/screenshots-raw website/src/assets/screens
```

**Captions are composited into the image**, so a capture must match its scene's
caption in `website/src/lib/screens.ts` — scene 05 is "Ask your library", and
pointing it at anything else puts a false claim on a public page. The script
also writes `website/public/assets/og.png` *outside* its output directory, so
there is no such thing as a dry run into a scratch directory.

## Afterwards

- Restore the user's prefs plist and quit the app.
- Shut down and delete any simulator you created (`xcrun simctl shutdown|delete`)
  — two devices with the same name is its own confusion.
- Re-check the grid at the top. Every row, or the set is incomplete.
