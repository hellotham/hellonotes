# Raw App Store / website captures

**Undecorated window and device captures. Commit them.**

`scripts/make-screenshots.py` composites the branded website frames *from* these
— gradient, caption, rounded corners, drop shadow — and every one of those steps
is one-way. There is no cropping a clean screenshot back out of a finished
frame.

They used to live in a session scratchpad and be discarded once the composites
existed. On 2026-08-29 the App Store needed undecorated macOS screenshots and
there were none anywhere: the scratchpad was long gone, git held only the
composited versions, App Store Connect's Media Manager held only the composited
versions, and the sole surviving copies were 1999px previews embedded in session
transcripts — too small for the 2560×1600 the store requires. Recovering them
meant launching the app on the author's Mac and opening a vault, which is the
one cost these files exist to avoid paying twice.

One folder per device, because the three are shot by different means and only
one of them costs anybody anything to redo.

| Folder | Source | How |
|---|---|---|
| `macOS/` | macOS | `screencapture -l<windowID>`, window sized 1280×800pt → 2560×1600px at 2× |
| `iPhone-6.5/` | iPhone 13 Pro Max | `xcrun simctl io <device> screenshot` — 1284×2778 |
| `iPad-13/` | iPad Pro 13-inch (M4) | `xcrun simctl io <device> screenshot` — 2064×2752 |

The two simulator sets are reshootable headlessly and cost nobody their screen;
the Mac set needs the author's machine, an unlocked screen and a loaded
collection, and is the one that has already been lost once.

**Shoot from `DefaultCollection`.** It ships *inside the binary* — it is the
tour and the user manual, copied into the app's container on first launch — so
it is public content by construction and it is what a reviewer opening the app
will actually see. `SampleVault` (the repo fixture) is still permitted; a real
vault never is. `.claude/hooks/guard-screencapture.py` enforces both, and on
macOS confirms which collection is loaded by **reading** `collectionPaths` from
the preferences plist rather than taking a screenshot to look.

`dist/Screenshots-{macOS,iOS,iPad}/` are the sets uploaded to App Store Connect.
`dist/` is git-ignored, so those copies are not a backup of anything — these
are.

## State, 2026-09-03

All three sets are complete and shot from `DefaultCollection`: 5 iPhone,
5 iPad, 10 macOS (five scenes × light and dark). The previous SampleVault set
is gone from the working tree — it is in git history if it is ever wanted, and
leaving it beside the new one is how six stale files and four fresh ones come
to look like ten.

Scenes are numbered to match `website/src/lib/screens.ts`: 01 files, 02 maths
and diagrams, 03 callouts and properties, 04 graph, 05 Ask Library. A caption is
composited into the website frame, so a capture must match its scene.

**A light/dark pair must differ only in the theme.** Same note, same tabs, same
scroll position, same caret — the website cross-fades between them, so anything
else that moves reads as a glitch. The caret matters more than it sounds:
it reveals the syntax it sits inside, so a click landing in the front matter
shows raw YAML, one landing in `$…$` shows the LaTeX source, and one landing in
a code span shows its backticks. Click a plain paragraph, and check the pair
against each other before filing them.
