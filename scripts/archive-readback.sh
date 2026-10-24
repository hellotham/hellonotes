#!/bin/zsh
#
# archive-readback.sh — what an archive is, read from the archive.
#
#   scripts/archive-readback.sh build/HelloNotes.xcarchive
#   scripts/archive-readback.sh build/HelloNotes-iOS.xcarchive
#
# The checks the TestFlight record makes of every build, done the same way
# each time instead of by hand (docs/production.md §10, "Read back from each
# archive"): the version and build of the app and of every extension; the
# architectures and the minimum OS; the Private Cloud Compute entitlement
# present and no temporary-exception entitlement; the five cloud-provider
# keys present — by length, never by value — and ITSAppUsesNonExemptEncryption.
# Prints facts only; exits 1 when one of them is not what a store build needs.
#
set -euo pipefail
(( $# == 1 )) || { sed -n 2,14p "$0"; exit 64; }
archive=$1
app=$(ls -d "$archive"/Products/Applications/*.app 2>/dev/null | head -1)
[[ -n $app ]] || { echo "no app in $archive" >&2; exit 1; }
if [[ -d $app/Contents ]]; then plist=$app/Contents/Info.plist; binary=$app/Contents/MacOS/${${app:t}%.app}; plugins=$app/Contents/PlugIns
else plist=$app/Info.plist; binary=$app/${${app:t}%.app}; plugins=$app/PlugIns; fi
read_key() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || echo "(absent)" }
bad=0

echo "app        $(read_key "$plist" CFBundleShortVersionString) ($(read_key "$plist" CFBundleVersion))  ${app:t}"
for appex in "$plugins"/*.appex(N) "$app"/Contents/Extensions/*.appex(N) "$app"/Extensions/*.appex(N); do
    p=$appex/Contents/Info.plist; [[ -f $p ]] || p=$appex/Info.plist
    echo "extension  $(read_key "$p" CFBundleShortVersionString) ($(read_key "$p" CFBundleVersion))  ${appex:t}"
done
echo "archs      $(lipo -archs "$binary")"
echo "build      $(vtool -show-build "$binary" 2>/dev/null | grep -E 'platform|minos|sdk' | awk '{printf "%s %s  ", $1, $2}')"

ents=$(codesign -d --entitlements :- "$app" 2>/dev/null || true)
if [[ $ents == *"com.apple.developer.private-cloud-compute"* ]]; then echo "entitlement  Private Cloud Compute: present"; else echo "entitlement  Private Cloud Compute: ABSENT"; fi
if [[ $ents == *"temporary-exception"* ]]; then echo "entitlement  temporary-exception: PRESENT"; bad=1; else echo "entitlement  temporary-exception: none"; fi

for key in DropboxAppKey BoxClientID BoxClientSecret GoogleClientID OneDriveClientID; do
    value=$(read_key "$plist" "$key")
    if [[ $value == "(absent)" || -z $value || $value == *'$('* ]]; then echo "provider   $key: MISSING"; bad=1
    else echo "provider   $key: ${#value} characters"; fi
done
enc=$(read_key "$plist" ITSAppUsesNonExemptEncryption)
echo "encryption ITSAppUsesNonExemptEncryption = $enc"
[[ $enc == false ]] || bad=1
exit $bad
