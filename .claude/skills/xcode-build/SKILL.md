---
name: xcode-build
description: Build and test HelloNotes headlessly — the right invocation for each target, and the traps that make the wrong one look broken. Use when building, running tests, or when a build appears to hang.
---

# Building and testing

Six invocations, each with a trap that makes the wrong choice look like a
different problem.

## Build

```bash
# macOS, per-change gate
xcodebuild build -project HelloNotes.xcodeproj -scheme HelloNotes \
  -destination 'platform=macOS' -configuration Debug \
  -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/HelloNotes-SPM \
  2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -5

# iOS simulator
xcodebuild build -project HelloNotes.xcodeproj -scheme HelloNotes \
  -destination 'platform=iOS Simulator,name=HN-iPhone' -configuration Debug
```

- **A long `xcodebuild` is a cold build, not a hang.** 74 targets, 30–47 minutes
  from cold. Do not kill it and do not "diagnose" it.
- **Debug proves nothing about Release.** A Release-only SIL optimizer crash once
  broke every archive while Debug stayed green for ~6,400 lines of work. Check
  `-configuration Release` before archiving.
- **`Config/Secrets.xcconfig` is baked in at build time.** Building without it
  ships empty provider keys.

## Test

```bash
./scripts/run-tests.sh                                     # app suite: 425 tests, 56 suites
swift test --package-path Packages/NotesEditor             # editor, macOS: 401
cd Packages/NotesEditor && xcodebuild test -scheme NotesEditor-Package \
  -destination 'platform=iOS Simulator,name=HN-iPad'       # editor, iOS: 381
xcodebuild test -project HelloNotes.xcodeproj -scheme HelloNotes \
  -destination 'platform=macOS' \
  -only-testing:HelloNotesTests/ShellContractTests         # layout contract, ~2s
```

- **Never a bare `xcodebuild test` for the app suite.** The bundle is *hosted by
  the app*, so a raw run opens HelloNotes on the user's screen and leaves hosts
  behind. `run-tests.sh` quits their app first (gracefully — it may hold unsaved
  edits), runs, and kills any host afterwards whatever the result. A host's argv
  is the *app's*, so `pkill -f HelloNotesTests.xctest` matches nothing; its real
  signature is `-NSTreatUnknownArgumentsAsOpen`.
- **The iOS editor run prints THREE bundle summaries** — 169/12, 18/4, 194/13.
  The total is their sum. Reading only the last says "194 in 13" and looks
  exactly like two thirds of the suite having silently stopped.
- **`swift test` only ever builds for macOS**, so the UIKit half goes untested
  until the simulator command runs. That is how a `UITextView` showing a document
  it believed was empty, a zero-width keyboard bar and a link tap that ate the
  caret tap all shipped together.
- **A SIGSEGV in `objc_release` after adding a stored property** to a type shared
  across modules is a stale incremental build, not a logic bug:
  `rm -rf Packages/NotesEditor/.build/arm64-apple-macosx` and re-run.

## Visual gates

```bash
./scripts/render-parity.sh                                  # Edit ≡ Preview
swift run --package-path Tools/RenderParity RenderParity --docs --width 420
```

Run after touching `GFMBoxMetrics`, `StyleApplier`, `BlockBoxes`, `GFMLiveStyle`
or `GFMPage`. **Width is a dimension of coverage, not a configuration** — six of
nineteen defects found by the document gate were horizontal errors that only
become heights when something wraps. `Packages/NotesEditor/CLAUDE.md` holds the
rules for interpreting its output.

## Looking at it

- macOS: `./scripts/relaunch-debug.sh` — never `open`, which re-attaches to the
  running process and silently tests the **old binary**.
- iOS: `xcrun simctl install/launch` + `xcrun simctl io <dev> screenshot` —
  headless, costs nothing, does not touch the user's screen.
