---
name: relaunch-app
description: Rebuild and relaunch the HelloNotes macOS Debug app for live testing — force-kills any running instance so you never test a stale binary. Use whenever you need to see a code change running in the real app.
---

# Relaunch HelloNotes (Debug, live testing)

macOS keeps a launched app's **original** Mach-O mapped even after you rebuild on
disk: `open` and AppleScript quit/relaunch both re-attach to the running process,
so UI verification silently tests **stale code**. The only reliable relaunch is a
hard `killall -9` + `open -n` of the freshly built app. `scripts/relaunch-debug.sh`
does exactly that.

## Steps

1. **Build the change first** (incremental; DerivedData stays warm, so this is
   usually 1–2 min, not a cold 30–47 min build):

   ```bash
   xcodebuild build -project HelloNotes.xcodeproj -scheme HelloNotes \
     -destination 'platform=macOS' -configuration Debug \
     -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/HelloNotes-SPM \
     2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -5
   ```

   Do not relaunch unless you see `** BUILD SUCCEEDED **`.

2. **Force-kill + launch the fresh build:**

   ```bash
   ./scripts/relaunch-debug.sh
   ```

   It prints the new PID and its start time. If it says
   `No Debug build found`, run step 1 first.

## Rules

- **Relaunch only when the user asks.** The app runs on the machine they are
  working on; an unrequested relaunch takes their window away mid-task. Build,
  verify headlessly (below), then hand it over.
- **Never** `open` the app or relaunch via AppleScript to test a change — you'll
  test the old binary. Always go through `scripts/relaunch-debug.sh`.
- **Respect the user's screen.** Never drive the app with computer-use or
  screenshots. Prefer telemetry you can read from the terminal.
- Confirm it's the new binary: `pgrep -x HelloNotes` and check the start time is
  now.

## Observe without touching the screen

### Headless harnesses — prefer these; they need no relaunch at all

- `scratchpad/LayoutRef/` — the shell layout contract across every device size.
- `scratchpad/RealProbe/` — drives the **real** `MarkdownEditor` package in an
  `NSWindow` that is never ordered front, and asserts the sizing contract
  (`docs/layout-architecture.md` Part 5). `swift run RealProbe` — exits non-zero
  on failure.

### The running app's own geometry probe

Debug builds only, and **off unless asked for**, so an ordinary run pays nothing:

```bash
HN_GEOM_LOG=1 ./scripts/relaunch-debug.sh
```

```bash
tail -30 ~/Library/Containers/com.hellotham.HelloNotes/Data/Library/Caches/hn-geom.log
```

Each entry prints the editor's scroll geometry plus its full ancestor chain with
heights — **any ancestor taller than the window is a live S1/S2 violation**, which
is how the unreachable top-of-file bug was finally located. Prefer adding
file-based telemetry over screenshots; `log show` is unreliable for this app.

## Cross-references

- Stale-binary trap and the script: `scripts/relaunch-debug.sh`.
- Full/Release verification and DMG: the `release` skill (never use this one to
  ship — Debug proves nothing about Release).
