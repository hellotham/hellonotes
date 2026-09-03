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

| Set | Shot from | Status |
|---|---|---|
| `iPhone-6.5/` | DefaultCollection | **complete** — 5 of 5 |
| `iPad-13/` | DefaultCollection | **complete** — 5 of 5 |
| `macOS/` | DefaultCollection | **4 of 10** — `light_01`…`light_04`; `light_05` (Ask Library) and all five dark still to shoot |
| `macOS/superseded-samplevault/` | SampleVault, pre-1.3.3 | the previous complete set, kept only until the ten above exist. **Do not upload these** — they predate DefaultCollection, the two-column note row, wiki-link alias concealment and the link-graph path fix. |

Scenes are numbered to match `website/src/lib/screens.ts`: 01 files, 02 maths
and diagrams, 03 callouts and properties, 04 graph, 05 Ask Library. A caption is
composited into the website frame, so a capture must match its scene.
