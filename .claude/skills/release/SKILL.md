---
name: release
description: Build, notarize, package and publish a HelloNotes release DMG, keeping the website's site.ts in sync with the shipped artefact
disable-model-invocation: true
---

# Release HelloNotes

Ship a signed, notarized, universal DMG as a GitHub Release, and keep the
download page's printed metadata true.

The authoritative reference is [docs/production.md](../../../docs/production.md)
Appendix A2. This skill is the *sequence*; consult A2 when a step fails.

## Before anything: prove Release compiles

**Debug proves nothing about Release.** A Release-only SIL optimizer crash once
broke every archive while Debug stayed green for ~6,400 lines of work
(implemented.md §13). An archive is the slowest possible way to discover a
Release-only failure, so check first:

```bash
xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes \
  -configuration Release -destination 'generic/platform=macOS' build 2>&1 | tail -5
```

If `swift-frontend` segfaults with no `error:` line, read the FULL log for
`While running pass` — the crashing SILFunction names the file. Do not filter
the tail. Known past cause: generic-class deinit inlining (`OnceResumer`);
the non-generic constraint comments in `Core/VisionAlt.swift` must stay.

Also confirm `Config/Secrets.xcconfig` exists — **the DMG bakes in whatever it
held at build time**. Building without it ships empty cloud-provider keys.

## The pipeline

```bash
# 1 · Archive (universal: arm64 + x86_64)
xcodebuild archive -project HelloNotes.xcodeproj -scheme HelloNotes \
  -destination 'generic/platform=macOS' \
  -archivePath build/HelloNotes.xcarchive -allowProvisioningUpdates

# 2 · Export with Developer ID
xcodebuild -exportArchive -archivePath build/HelloNotes.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export \
  -allowProvisioningUpdates

# 3 · Notarize + staple the .app (package-dmg.sh refuses an un-notarized app)
ditto -c -k --keepParent build/export/HelloNotes.app build/HelloNotes.zip
xcrun notarytool submit build/HelloNotes.zip --keychain-profile "hellotham-notary" --wait
xcrun stapler staple build/export/HelloNotes.app

# 4 · Build, sign, notarize, staple the DMG → dist/HelloNotes.dmg
#     (overwrites any existing dist/HelloNotes.dmg — move it aside to keep it)
scripts/package-dmg.sh build/export/HelloNotes.app
```

## Verify what you are shipping — as a user's Mac would

Never trust the script's own output alone. Mount it:

```bash
spctl --assess -t open --context context:primary-signature -v dist/HelloNotes.dmg
#   → accepted / source=Notarized Developer ID
hdiutil attach dist/HelloNotes.dmg -nobrowse -mountpoint /tmp/hn
lipo -archs /tmp/hn/HelloNotes.app/Contents/MacOS/HelloNotes    # → x86_64 arm64
spctl --assess --type execute -v /tmp/hn/HelloNotes.app
xcrun stapler validate /tmp/hn/HelloNotes.app                   # works offline
defaults read /tmp/hn/HelloNotes.app/Contents/Info CFBundleShortVersionString
hdiutil detach /tmp/hn
```

## Publish first — the order matters

**Publishing comes before the website, not after.** The site's download button
points at `releases/latest/download/HelloNotes.dmg`, so `latest` is what people
actually get; `site.ts` is only what the page *says* they will get. Update the
page first and there is a window in which it advertises a version and a checksum
for a file nobody can download yet — and a checksum that does not match reads as
a **tampered download**, which is precisely the alarm the checksum exists to
raise. That window was live for twenty minutes on 2026-08-29.

Worse, the same gap can stay open indefinitely: `site.ts`'s version was bumped
to 1.3.2 on the day the work landed and `latest` served 1.3.1 for eleven days
after, because bumping a constant announces a release and publishing one is a
separate act that nothing tied to it.

```bash
gh release create v<VERSION> dist/HelloNotes.dmg \
  --title "HelloNotes <VERSION>" --notes-file <notes.md>
```

Publishing IS the deploy for the download itself — `latest` re-points
automatically and the site does not rebuild for it. Prove the exact URL the
button uses resolves:

```bash
curl -sIL -o /dev/null -w '%{http_code}\n' \
  https://github.com/hellotham/hellonotes/releases/latest/download/HelloNotes.dmg
# → 200
```

## Then sync the website — the step everyone forgets

The download page **prints** the version, size and SHA-256 for people verifying
by hand. They must match the artefact `latest` now serves.

```bash
shasum -a 256 dist/HelloNotes.dmg
du -h dist/HelloNotes.dmg
```

Update in `website/src/lib/site.ts`:
- `APP.version` — the new version string
- `DOWNLOAD.size` — human-readable ("35.2 MB" style, decimal MB)
- `DOWNLOAD.sha256` — the fresh checksum

Commit and push (a `website/**` push auto-deploys via
`.github/workflows/deploy-website.yml`; app-only pushes do not).

## Prove the page tells the truth

Nothing connects `site.ts` to the artefact except this check. Run it against the
live site once the deploy lands:

```bash
scripts/check-download-page.sh          # live site vs releases/latest
scripts/check-download-page.sh --local  # site.ts vs dist/ before publishing
```

It downloads the DMG the button serves, mounts it, and compares the **version
inside the image**, its size and its SHA-256 against what the page claims —
size and hash alone would not have caught the eleven-day version divergence. It
also checks the App Store's public version where there is one: **the site must
never advertise a version newer than the App Store's.** Until the app is
publicly released the lookup returns nothing, which is reported and not a
failure.

## App Store screenshots — inventory every surface, every time

**A platform is not "done" because one of its tabs has images in it.** Build 13
went to review twice with iPad holding a *single* stale light-mode screenshot,
because the check was "does the iPhone tab look right" and the iPad tab was
never opened. Screenshots are per-platform *and* per-display-size, and ASC shows
one size at a time.

Before submitting, walk the whole grid and count:

| Platform | Tab | Required size | Expect |
|---|---|---|---|
| iOS | iPhone | 6.5" — 1284×2778 (or 1242×2688) | 3–10 |
| iOS | **iPad** | 13" — 2064×2752 | 3–10 |
| macOS | Mac | 2560×1600 (or 1280×800 / 1440×900 / 2880×1800) | 3–10 |

Every row, or the submission is incomplete. `0 of 10 Screenshots` and `1 of 10`
both read as "there is something there" in a glance at the page; only the count
distinguishes them.

**Screenshots cannot be edited while a version is *Waiting for Review*** — the
file input and Delete All simply are not in the DOM. Getting one wrong therefore
costs a removal from review and a resubmission, so inventory *before* submitting,
not after.

**Never `Delete All` before the replacements are staged and verified at the right
pixel size.** Deletion is per display size and immediate.

### Shooting them

- **iOS/iPadOS**: simulators, headless, no cost to anyone —
  `xcrun simctl io <device> screenshot`. Device must match the store size
  exactly: iPhone 13 Pro Max → 1284×2778; **iPad Pro 13-inch (M4) → 2064×2752**
  (the 11-inch gives 1668×2420, which ASC will not take, and the aspect ratio
  differs so it cannot be rescaled). Seed a vault and use
  `xcrun simctl status_bar <device> override --time 9:41 …`.
- **macOS**: the app on a real screen, so it costs the user their session.
  `screencapture -l <windowID>` — and a **1280×800 pt window captures at exactly
  2560×1600** on a 2× display, so size the window rather than padding afterwards.
  Read `collectionPaths` from the preferences plist to confirm SampleVault is the
  only collection loaded **before** capturing anything (CLAUDE.md: screenshotting
  to check is capturing). Back up that plist and restore it after.
- **Keep the raw captures.** `make-screenshots.py` now copies them into
  `assets/screenshots-raw/`; commit them. The branded website frames are one-way
  derivatives and the store wants the undecorated originals.

## Record it

Add the release to `docs/implemented.md` (shipped work goes there —
`unimplemented.md` is backlog only).
