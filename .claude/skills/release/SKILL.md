---
name: release
description: Build, notarize, package and publish a HelloNotes release DMG, keeping the website's site.ts in sync with the shipped artefact
disable-model-invocation: true
---

# Release HelloNotes

Ship a signed, notarized DMG (arm64 from 1.3.3 — see docs/production.md A2) as a GitHub Release, and keep the
download page's printed metadata true.

The authoritative reference is [docs/production.md](../../../docs/production.md)
Appendix A2. This skill is the *sequence*; consult A2 when a step fails.

## Before anything: prove Release compiles

**Debug proves nothing about Release.** A Release-only SIL optimizer crash once
broke every archive while Debug stayed green for ~6,400 lines of work
(implemented.md §13). An archive is the slowest possible way to discover a
Release-only failure, so check first:

```bash
xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes -skipPackagePluginValidation \
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
# 0 · The app's entitlements without Private Cloud Compute, which Apple never
#     provisions for Developer ID (docs/production.md §1b-PCC). PlistBuddy, not
#     plutil: plutil reads the key's dots as a key path and removes nothing.
mkdir -p build
cp HelloNotes/HelloNotes.entitlements build/HelloNotes-DeveloperID.entitlements
/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.private-cloud-compute" \
  build/HelloNotes-DeveloperID.entitlements

# 1 · Archive (arm64 — 1.3.3's macOS 27 floor runs only on Apple silicon, and Xcode 27's
#     ARCHS_STANDARD is arm64 there; 1.3.2 and earlier were universal), signed with
#     those. Only the app target reads HN_APP_ENTITLEMENTS; the extensions keep
#     their own. Its own archive path: this archive must never be uploaded to the
#     App Store, whose build carries the entitlement.
xcodebuild archive -project HelloNotes.xcodeproj -scheme HelloNotes \
  -destination 'generic/platform=macOS' -skipPackagePluginValidation \
  -archivePath build/HelloNotes-DeveloperID.xcarchive -allowProvisioningUpdates \
  HN_APP_ENTITLEMENTS="$PWD/build/HelloNotes-DeveloperID.entitlements"

# 2 · Export with Developer ID — fails "not available for Developer ID provisioning
#     profiles" if the archive carries Private Cloud Compute
xcodebuild -exportArchive -archivePath build/HelloNotes-DeveloperID.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export-developer-id \
  -allowProvisioningUpdates

# 3 · Notarize + staple the .app (package-dmg.sh refuses an un-notarized app)
ditto -c -k --keepParent build/export-developer-id/HelloNotes.app build/HelloNotes.zip
xcrun notarytool submit build/HelloNotes.zip --keychain-profile "hellotham-notary" --wait
xcrun stapler staple build/export-developer-id/HelloNotes.app

# 4 · Build, sign, notarize, staple the DMG → dist/HelloNotes.dmg
#     (overwrites any existing dist/HelloNotes.dmg — move it aside to keep it)
scripts/package-dmg.sh build/export-developer-id/HelloNotes.app
```

## Verify what you are shipping — as a user's Mac would

Never trust the script's own output alone. Mount it:

```bash
spctl --assess -t open --context context:primary-signature -v dist/HelloNotes.dmg
#   → accepted / source=Notarized Developer ID
hdiutil attach dist/HelloNotes.dmg -nobrowse -mountpoint /tmp/hn
lipo -archs /tmp/hn/HelloNotes.app/Contents/MacOS/HelloNotes    # → arm64 (1.3.3+)
codesign -d --entitlements - /tmp/hn/HelloNotes.app | grep -c private-cloud-compute  # → 0
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
also checks the App Store's public version where there is one: **the page must
say what the App Store serves.** Until the app is publicly released the lookup
returns nothing, which is reported and not a failure.

### The App Store is usually a few days behind — say so

From 1.3.3 the download is published the day it is submitted, not held for
Apple's approval (the person's decision, 2026-10-12: "publish 1.3.3 on the web
as a release and say App Store approval pending"). `site.ts` carries both
facts: `APP_STORE.liveVersion` is what the store serves and `pendingVersion`
what is in review, and `StoreNotice.astro` says so beside every App Store link.
The check compares the store with `liveVersion`, and fails if the site is ahead
without saying a version is pending.

- **At submission:** `APP.version` is the new version, `liveVersion` the old,
  `pendingVersion` the new.
- **At approval:** `liveVersion` the new, `pendingVersion: null`, push. The
  check fails from the day the store changes until this is done, and says what
  to set. Then anything else that waited for the version to be live — China
  mainland's availability, for 1.3.3.

**Publish and deploy together.** `gh release create` moves `releases/latest`
at once, and the page's checksum is wrong from that second until the site
deploys. If the site is not ready to push, create the release with
`--prerelease --latest=false` and flip it (`gh release edit vX --prerelease=false
--latest`) in the same minute as the push: `latest` then never serves a file
the page does not describe.

**The push must move `main` — check `git branch --show-current` before the
commit.** On 2026-10-25 the `site.ts` commit landed on `release/1.3.3`, the
branch the shell was on; `git push origin main` said "Everything up-to-date",
the release was flipped anyway, and `latest` served 1.3.5 against a page
printing 1.3.3's checksum for a hundred seconds (implemented.md §51.60).
Then **read the live page, not the checkout**: `check-download-page.sh`
compares `releases/latest` with the `site.ts` of the checkout it runs in,
so it passes inside that window; `curl` the deployed `download.html` for the
new size and checksum, and watch the deploy run for *this* push's commit.

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

**Count them by asking, not by looking**: `scripts/asc-listing.py status
<version>` prints every set as Apple reports it — how many, how many finished
processing, and their pixel size — with the attached build and whether the text
matches `docs/app-store-listing.md`. The same script writes the text, attaches
the build, replaces the screenshots from `dist/Screenshots-*` and submits; it
refuses to submit unless `status` is clean (1.3.3 build 31 went in this way,
`docs/production.md` §10j).

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
