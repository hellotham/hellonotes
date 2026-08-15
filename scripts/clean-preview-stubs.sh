#!/bin/zsh
# Remove the unsigned `__preview.dylib` stubs that a *test* build injects into
# the app and every app extension.
#
# They make the next plain `xcodebuild build` die in CodeSign with
#
#     <appex>: code object is not signed at all
#     In subcomponent: .../Contents/MacOS/__preview.dylib
#
# — a failure with no connection to the code just written, and an intermittent
# one, since it only fires when something forces a re-sign. They regenerate on
# demand, so removing them costs nothing and disarms the trap.
#
# Every configuration, not just Debug: an iOS build writes to Debug-iphoneos,
# and cleaning one while leaving the other is how this bit twice.
set -uo pipefail

products=(~/Library/Developer/Xcode/DerivedData/HelloNotes-*/Build/Products/*(N/))
(( ${#products} )) || exit 0

count=$(find "${products[@]}" -name "__preview.dylib" -delete -print 2>/dev/null | wc -l | tr -d ' ')
[[ "$count" != "0" ]] && echo "Removed $count stale __preview.dylib stub(s)."
exit 0
