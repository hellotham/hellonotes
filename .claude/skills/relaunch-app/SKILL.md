---
name: relaunch-app
description: Rebuild and relaunch the HelloNotes macOS Debug app for live testing — force-kills any running instance so you never test a stale binary. Use whenever you need to see a code change running in the real app.
---

# Relaunch HelloNotes (Debug, live testing)

macOS keeps a launched app's **original** Mach-O mapped even after you rebuild on
disk: plain `open` re-attaches to the running process, so UI verification silently
tests **stale code**. The instance has to end, and a new one has to start with
`open -n`. `scripts/relaunch-debug.sh` does that.

**It quits gracefully first, and so must you.** HelloNotes autosaves on a
debounce and `TerminationGuard` drains those pending writes during the quit
handshake. `kill -9` skips it, so a hard kill can silently discard whatever was
typed in the last debounce window — data loss on a notes app, caused by a
convenience. The script asks the app to quit, waits 10s, escalates to SIGTERM,
and only reaches SIGKILL if the app refuses both — printing a loud warning when
it does. Never reach for `killall -9` or `pkill -9` on HelloNotes yourself.

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

   To test the **Release** build instead — the only configuration that proves
   anything about the sandbox, since Xcode injects a
   `temporary-exception.files.absolute-path.read-only = /` entitlement into
   Debug builds:

   ```bash
   HN_CONFIG=Release ./scripts/relaunch-debug.sh
   ```

   The configuration is an environment variable rather than an argument
   deliberately: the script still refuses arguments, because `--help` once
   relaunched the app.

   The script verifies rather than assumes, and exits non-zero if it can't:

   - finds every live instance by process name **and** by executable path, so a
     test host or an Xcode-launched run is caught too;
   - **quits them gracefully**, so debounced autosaves are flushed, escalating to
     SIGTERM and only then SIGKILL, and **waits until they're actually gone** at
     each stage rather than hoping a fixed `sleep` was enough;
   - waits for **LaunchServices** to forget them too, not just the process table
     — the Dock icon and the window are what a person actually sees, and they
     outlive the process by a moment;
   - refuses to launch if anything survived, because a survivor *is* the old
     binary and testing against it produces a confident wrong answer;
   - confirms the process that came up is running the executable just built, and
     prints that build's timestamp.

   Read its output. `Verified: running the build at <time>` is the only line
   that means the relaunch worked. If it says `No Debug build found`, run step 1.
   Never report the app relaunched without that line.

## Rules

- **Relaunch only when the user asks _for that relaunch_.** The app runs on the
  machine they are working on; an unrequested relaunch takes their window away
  mid-task. "Launch when you're finished" is permission for **one** launch at
  the end, not a standing licence — three relaunches inside two minutes is the
  same interruption three times. Build, verify headlessly (below), then hand it
  over once.
- **Never run the script speculatively.** Not to read its usage, not to check
  what it does — read the file. It takes no arguments and now refuses them,
  because `relaunch-debug.sh --help` used to just relaunch the app.
- **Print its whole output.** Do not `tail` it. The line that says
  `Killing running HelloNotes instance(s): <pids>` is the evidence that the old
  instance died; hiding it makes a correct relaunch look like a careless one,
  and there is no way to tell the two apart afterwards.
- **Do not run `xcodebuild test` while you are still working.** A macOS test
  bundle needs a test *host*, so every run launches HelloNotes on the user's
  screen — and a run that hangs or that you start twice leaves **several copies
  of the app open**, which the user then has to clean up. Treat it exactly like
  a relaunch: it is a thing you do at the *end*, on the finished change, not a
  gate you tap between edits. See "Running the app tests" below.
- **Never** `open` the app or relaunch via AppleScript to test a change — you'll
  test the old binary. Always go through `scripts/relaunch-debug.sh`.
- **Respect the user's screen.** Never drive the app with computer-use or
  screenshots. Prefer telemetry you can read from the terminal.
- Confirm it's the new binary: `pgrep -x HelloNotes` and check the start time is
  now.

## Running the app tests

`HelloNotesTests` is hosted by the app, so there is no flag that stops it
launching. Work around it rather than paying for it repeatedly:

- **During the change**, use only what runs headless — `xcodebuild build` for
  both platforms, `swift test --package-path Packages/NotesEditor`, and the
  scratchpad harnesses below. None of these open a window.
- **At the end**, run it through the script, never `xcodebuild test` by hand:

  ```bash
  ./scripts/run-tests.sh
  ```

  It quits the user's app first (gracefully — it may hold unsaved edits), runs
  the suite, and kills any test host afterwards whatever the result. The whole
  suite is ~2s and 119 tests; scope it with `-only-testing:` only if you have a
  reason.

- **Why by hand goes wrong.** The bundle is *injected* into the app, so the test
  host's argv is the **app's** — nothing on its command line says `xctest`.
  `pkill -f "HelloNotesTests.xctest"` therefore matches nothing: it looks like
  cleanup and does nothing, which is how hosts kept surviving and appearing as
  "the app launched over itself". The host's actual signature is
  `-NSTreatUnknownArgumentsAsOpen`, which a normally-launched app never carries,
  and that is what the script matches — so it can never hit the user's own app.
- **Kill before, kill after. Don't leave anything you created.** A host running
  while the user's app is up is a second HelloNotes on their screen.

- **Never leave a test run in the background** across turns. If it hasn't
  finished, kill it and say so — an unattended run keeps a window open on
  someone else's machine.

## Look at the app — properly

`screencapture -l <windowID>` captures **one window** through the real
compositor. It needs no Screen Recording permission for a window you can
enumerate, and it is the only rendering path that draws materials, vibrancy and
Liquid Glass as they actually appear.

```bash
# the window id (compile once; CoreGraphics, no permissions)
swiftc -O scripts/winid.swift -o /tmp/winid && /tmp/winid
screencapture -l<id> -o -x /tmp/hn-app.png
```

**Never judge chrome from `cacheDisplay`/`bitmapImageRepForCachingDisplay`.**
It cannot render materials, so it paints them as flat white. An entire session
was lost to a "white capsule" that existed only in such a snapshot: eight
attempted fixes, two reverts and a shipped regression, all aimed at an artefact
of the instrument. The same trap caught the design bench, which rendered its
candidates the same way.

**Validate an instrument before trusting it.** One capture of any app with a
normal sidebar would have exposed the flaw in seconds. If a measurement
disagrees with what the user can see, the measurement is the suspect.

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
