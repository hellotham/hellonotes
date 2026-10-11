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

## State, 2026-10-12 (1.3.3)

All three sets were shot again for 1.3.3, from `DefaultCollection` as the
repository has it: the window was rearranged in builds 27–29 (the collection on
the left, the note in the middle, what the note is on the right), so every
1.3.2 picture showed an app that no longer exists, and the iPad's AI picture
named services 1.3.3 does not have.

| Set | Files | Scenes, in the order they are uploaded |
|---|---|---|
| `iPhone-6.5/` | 6 | rich content (maths, a diagram) · the Mind Map · a note's Graph · the AI place · transclusion · the note list |
| `iPad-13/` | 5 | rich content · Split (source beside the page) · the Mind Map · a note's Graph · transclusion |
| `macOS/` | 10 | `light_`/`dark_` 01 a note with Summary & Outline · 02 Split · 03 a note's Graph · 04 the Mind Map · 05 the Assistant answering from a note |

**The iPhone and iPad sets are a test now**, not a walk by hand:
`HelloNotesUITests.testStoreScreenshots`, opt-in, on `HN-iPhone` and
`HN-iPad13` —

    xcrun simctl status_bar HN-iPad13 override --time 9:41 --batteryState charged --batteryLevel 100
    xcrun simctl ui HN-iPad13 appearance dark
    xcrun simctl uninstall HN-iPad13 com.hellotham.HelloNotes   # the sample as shipped
    TEST_RUNNER_HN_STORE_SHOTS=1 xcodebuild test -project HelloNotes.xcodeproj -scheme HelloNotes \
      -skipPackagePluginValidation -destination 'platform=iOS Simulator,name=HN-iPad13' \
      -resultBundlePath shots.xcresult -only-testing:HelloNotesUITests/HelloNotesUITests/testStoreScreenshots
    xcrun xcresulttool export attachments --path shots.xcresult --output-path shots

It fails if a button it means to press is not there. Its first version carried
on regardless, and returned seven pictures of one screen with a green tick.

**The Mac set** is the Debug build launched as a capture session with the
sample collection alone — `collectionBookmarks`, `collectionPaths` **and**
`remoteCollectionCaches "()"` named in the argument domain, since a cloud
collection comes back from the third alone — in a 1280×800pt window, each scene
its own launch with the mode and the panel as arguments (nothing is then
written to the person's settings), notes opened by `hellonotes://` link, the
panel and the tabs by Accessibility and the View menu. Before every capture the
window is read through Accessibility for the name of any other collection or
its folders; a match takes no picture. For the run the container's copy of the
sample is replaced by the repository's and the Assistant's saved conversations
are moved aside — the Assistant opens on the last one, which is the person's —
and both are put back after. Scene 05 asks the on-device model one question
about a sample note; the dark scene opens on the same saved answer, so the pair
differs only in the theme.

Scenes are numbered to match `website/src/lib/screens.ts`. A caption is
composited into the website frame, so a capture must match its scene.

**A light/dark pair must differ only in the theme.** Same note, same tabs, same
scroll position, same caret — the website cross-fades between them, so anything
else that moves reads as a glitch. The caret matters more than it sounds:
it reveals the syntax it sits inside, so a click landing in the front matter
shows raw YAML, one landing in `$…$` shows the LaTeX source, and one landing in
a code span shows its backticks. Click a plain paragraph, and check the pair
against each other before filing them.
