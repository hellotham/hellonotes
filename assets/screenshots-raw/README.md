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

| Source | How |
|---|---|
| macOS | `screencapture -l <windowID>`, window sized 1280×800pt → 2560×1600px at 2× |
| iPhone | `xcrun simctl io <device> screenshot` — 1284×2778 |
| iPad | `xcrun simctl io <device> screenshot` — 2064×2752 (iPad Pro **13-inch**) |

Shoot from SampleVault only, never a real vault — and on macOS confirm which
collection is loaded by reading `collectionPaths` from the preferences plist,
not by taking a screenshot to look.
