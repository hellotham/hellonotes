#!/bin/zsh
# Does the download page tell the truth about the file the button serves?
#
# The page **prints** a version, a size and a SHA-256 so that someone can verify
# a download by hand. Those three come from `website/src/lib/site.ts`; the file
# comes from `releases/latest/download/HelloNotes.dmg`. Nothing connects them,
# and when they disagree the failure is not cosmetic — a checksum that does not
# match reads as a tampered download, which is the exact alarm the checksum
# exists to raise.
#
# They disagreed on the live site for about twenty minutes on 2026-08-29,
# because the release skill said to update `site.ts` and push *before*
# publishing the GitHub release. The push deploys; the release had not happened;
# so the page advertised 1.3.2's checksum while `latest` still served 1.3.1.
# The skill now publishes first. This script is the check that the order was
# actually followed.
#
# Usage:  scripts/check-download-page.sh            # against the live site
#         scripts/check-download-page.sh --local    # against site.ts + dist/
set -euo pipefail

ROOT=${0:A:h:h}
SITE_TS="$ROOT/website/src/lib/site.ts"
DMG_URL="https://github.com/hellotham/hellonotes/releases/latest/download/HelloNotes.dmg"

field() { grep -oE "$1: '[^']+'" "$SITE_TS" | head -1 | sed "s/.*'\(.*\)'/\1/"; }
want_version=$(field version)
want_size=$(field size)
want_sha=$(field sha256)

echo "site.ts advertises:  $want_version · $want_size · ${want_sha:0:16}…"

if [[ "${1:-}" == "--local" ]]; then
  tmp_dmg="$ROOT/dist/HelloNotes.dmg"
  [[ -f "$tmp_dmg" ]] || { echo "✗ dist/HelloNotes.dmg not built" >&2; exit 1; }
  got_sha=$(shasum -a 256 "$tmp_dmg" | cut -d' ' -f1)
  got_bytes=$(stat -f%z "$tmp_dmg")
  source_desc="dist/HelloNotes.dmg"
else
  # Download it. A HEAD gives the size but not the hash, and the hash is the
  # claim that actually matters.
  tmp_dmg=$(mktemp -t hn-dmg).dmg
  trap 'rm -f "$tmp_dmg"' EXIT
  curl -sL --max-time 300 -o "$tmp_dmg" "$DMG_URL"
  got_sha=$(shasum -a 256 "$tmp_dmg" | cut -d' ' -f1)
  got_bytes=$(stat -f%z "$tmp_dmg")
  source_desc="releases/latest"
fi

got_size=$(printf '%.1f MB' $((got_bytes / 1000000.0)))

# The version *inside* the disk image, not the one the page hopes is there.
# Size and hash alone do not catch the divergence that actually happened: the
# site announced 1.3.2 the moment the version was bumped in `site.ts`, while
# `latest` went on serving 1.3.1 for eleven days, because publishing the release
# is a separate act nobody had tied to the announcement.
mnt=$(mktemp -d -t hn-mnt)
hdiutil attach "$tmp_dmg" -nobrowse -mountpoint "$mnt" -quiet
got_version=$(defaults read "$mnt/HelloNotes.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
hdiutil detach "$mnt" -quiet
rmdir "$mnt" 2>/dev/null || true

echo "$source_desc serves:  $got_version · $got_size · ${got_sha:0:16}…"

fail=0
if [[ "$got_version" != "$want_version" ]]; then
  echo "✗ version mismatch — the page announces $want_version, the download is $got_version." >&2
  echo "   Bumping site.ts does not publish anything; the GitHub release does." >&2
  fail=1
fi
if [[ "$got_sha" != "$want_sha" ]]; then
  echo "✗ SHA-256 mismatch — the page's checksum does not match the download." >&2
  echo "   page:     $want_sha" >&2
  echo "   download: $got_sha" >&2
  fail=1
fi
if [[ "$got_size" != "$want_size" ]]; then
  echo "✗ size mismatch — page says $want_size, download is $got_size" >&2
  fail=1
fi

# The App Store copy, when there is one. Absent until the app is publicly
# released — a lookup returning nothing is not a failure, it is "not shipped
# yet". Once it is live the page must say what the App Store serves.
#
# That used to mean the two versions had to be equal, which holds a release's
# download back until Apple has approved it. From 1.3.3 the download goes out
# with the submission and the page *says* the App Store is behind:
# `APP_STORE.liveVersion` is what the store serves and `pendingVersion` what is
# in review. So the check is that the page's account of the store is true —
# and that it stops saying "pending" the day it is not.
store=$(curl -s --max-time 20 \
  "https://itunes.apple.com/lookup?bundleId=com.hellotham.HelloNotes&country=au" \
  | /usr/bin/python3 -c 'import json,sys; r=json.load(sys.stdin).get("results") or []; print(r[0]["version"] if r else "")' 2>/dev/null || true)
says_live=$(field liveVersion || true)
says_pending=$(field pendingVersion || true)
[[ -z "$says_live" ]] && says_live=$want_version
if [[ -n "$store" ]]; then
  echo "App Store serves:    $store   (the page says $says_live${says_pending:+, with $says_pending pending})"
  if [[ "$store" != "$says_live" ]]; then
    if [[ "$store" == "$want_version" && -n "$says_pending" ]]; then
      echo "✗ the App Store has $store now — set APP_STORE.liveVersion to it and pendingVersion to null" >&2
    else
      echo "✗ the page says the App Store has $says_live; it has $store" >&2
    fi
    fail=1
  elif [[ "$says_live" != "$want_version" && "$says_pending" != "$want_version" ]]; then
    echo "✗ the site advertises $want_version while the App Store has $store, and does not say $want_version is pending" >&2
    fail=1
  fi
else
  echo "App Store:           not publicly released (nothing to match yet)"
fi

(( fail )) && exit 1
echo "✓ the download page tells the truth about the artefact and the App Store"
