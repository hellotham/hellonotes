#!/bin/zsh
#
#  chrome-parity.sh — do the Mac and the iPad draw the same chrome?
#
#  Renders the chrome scenes (`ChromeParityTests`: the bar, rows, status bar,
#  panel header, a settings form, a sheet bar and empty state) on macOS and in
#  the `HN-iPad` simulator, then compares the two sets pixel for pixel
#  (`chrome-parity-compare.swift`). The requirement is that the two platforms
#  draw the **same picture**; a source check can prove a view uses `Chrome`
#  tokens and cannot prove the tokens render alike, so this looks at both
#  pictures.
#
#  The macOS half goes through `run-tests.sh` (the bundle is app-hosted: it
#  quits your running HelloNotes first, gracefully, and cleans up after). The
#  iOS half is headless. Diff maps land in $TMPDIR/chrome-parity/diff.
#
set -u
here=${0:a:h}
cd "$here/.." || exit 1
work="${TMPDIR:-/tmp}/chrome-parity"
rm -rf "$work"; mkdir -p "$work"

echo "Rendering on macOS…"
"$here/run-tests.sh" "-only-testing:HelloNotesTests/ChromeParityTests/renderChrome()" > "$work/mac.log" 2>&1
mac=$(grep -o 'CHROME_PARITY_OUTPUT=.*' "$work/mac.log" | tail -1 | cut -d= -f2-)
[[ -n "$mac" && -d "$mac" ]] || { echo "macOS render failed — see $work/mac.log"; exit 1; }

echo "Rendering on the HN-iPad simulator…"
xcodebuild test -project HelloNotes.xcodeproj -scheme HelloNotes \
  -destination 'platform=iOS Simulator,name=HN-iPad' -skipPackagePluginValidation \
  "-only-testing:HelloNotesTests/ChromeParityTests/renderChrome()" > "$work/ios.log" 2>&1
ios=$(grep -o 'CHROME_PARITY_OUTPUT=.*' "$work/ios.log" | tail -1 | cut -d= -f2-)
[[ -n "$ios" && -d "$ios" ]] || { echo "iOS render failed — see $work/ios.log"; exit 1; }

# Copied out: the simulator's container is renamed on every reinstall.
cp -R "$mac" "$work/macos"; cp -R "$ios" "$work/ios"
swift "$here/chrome-parity-compare.swift" "$work/macos" "$work/ios" "$work/diff"
