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

## Sync the website — the step everyone forgets

The download page **prints** the version, size and SHA-256 for people verifying
by hand. They must match the artefact actually attached to the release, and
nothing enforces that except this step.

```bash
shasum -a 256 dist/HelloNotes.dmg
du -h dist/HelloNotes.dmg
```

Update in `website/src/lib/site.ts`:
- `APP.version` — the new version string
- `DOWNLOAD.size` — human-readable ("35.2 MB" style)
- `DOWNLOAD.sha256` — the fresh checksum

Commit and push (a `website/**` push auto-deploys via
`.github/workflows/deploy-website.yml`; app-only pushes do not).

## Publish

The site's download button points at `releases/latest/download/HelloNotes.dmg`,
so publishing the release IS the deploy — `latest` re-points automatically and
the site never rebuilds for it.

```bash
gh release create v<VERSION> dist/HelloNotes.dmg \
  --title "HelloNotes <VERSION>" --notes-file <notes.md>
```

Then prove the exact URL the button uses resolves:

```bash
curl -sIL -o /dev/null -w '%{http_code}\n' \
  https://github.com/hellotham/hellonotes/releases/latest/download/HelloNotes.dmg
# → 200
```

## Record it

Add the release to `docs/implemented.md` (shipped work goes there —
`unimplemented.md` is backlog only).
