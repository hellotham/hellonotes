#!/bin/zsh
# Run the app's test suite without leaving anything running.
#
# `HelloNotesTests` is a *hosted* bundle: `xcodebuild test` launches HelloNotes
# and injects the tests into it. Two consequences, both of which bit repeatedly
# until this script existed:
#
#   1. **Kill the app first.** A test host launching while the user's own app is
#      up puts a second HelloNotes on screen — indistinguishable from "it
#      launched over itself".
#   2. **Kill the host afterwards.** Because the bundle is injected rather than
#      exec'd, the host's argv is the *app's* — nothing on its command line says
#      "xctest". `pkill -f HelloNotesTests.xctest` therefore matches nothing,
#      which is exactly the no-op that kept leaving hosts running while looking
#      like cleanup.
#
# The host does have a signature: Xcode launches it with
# `-NSTreatUnknownArgumentsAsOpen`, which a normally-launched app never has. That
# is what this matches, so cleanup can never hit the user's own instance.
#
# Usage:  ./scripts/run-tests.sh [extra xcodebuild args]
#   e.g.  ./scripts/run-tests.sh -only-testing:HelloNotesTests/ShellContractTests
set -uo pipefail

here=${0:a:h}
cd "$here/.."

# A test host, and never the user's app.
test_hosts() {
  pgrep -f "HelloNotes.app/Contents/MacOS/HelloNotes.*-NSTreatUnknownArgumentsAsOpen" \
    | tr '\n' ' ' | sed 's/ $//'
}

cleanup_hosts() {
  local hosts=$(test_hosts)
  if [[ -n "$hosts" ]]; then
    echo "Cleaning up test host(s): $hosts"
    kill -9 ${=hosts} 2>/dev/null || true
    for _ in {1..25}; do
      [[ -z "$(test_hosts)" ]] && break
      sleep 0.2
    done
  fi
  local left=$(test_hosts)
  if [[ -n "$left" ]]; then
    echo "WARNING: test host(s) still running: $left" >&2
  else
    echo "No test hosts left."
  fi
}

# Testing injects the bundle via a debug dylib, which leaves unsigned
# `__preview.dylib` stubs behind; see scripts/clean-preview-stubs.sh for why the
# next ordinary build then dies in CodeSign.
cleanup_preview_dylibs() { "$here/clean-preview-stubs.sh" }

# Whatever happens — pass, fail, interrupt — do not leave a host behind.
trap 'echo; cleanup_hosts; cleanup_preview_dylibs; exit 130' INT TERM

# 1. The user's own app first, gracefully: it may hold unsaved edits, and a
#    hard kill would skip the autosave flush (see relaunch-debug.sh).
if pgrep -x HelloNotes > /dev/null 2>&1; then
  echo "Quitting the running app before testing (it may hold unsaved edits)…"
  osascript -e 'tell application "HelloNotes" to quit' >/dev/null 2>&1 || true
  for _ in {1..50}; do
    pgrep -x HelloNotes > /dev/null 2>&1 || break
    sleep 0.2
  done
  if pgrep -x HelloNotes > /dev/null 2>&1; then
    echo "App would not quit; leaving it alone and refusing to test on top of it." >&2
    echo "Close it (or its modal sheet) and re-run." >&2
    exit 1
  fi
  echo "App quit."
fi

# 2. Run — after clearing any stubs a *previous* run left behind. Cleaning only
#    afterwards is not enough: this run's own build may re-sign the app, and it
#    would then trip over the last run's leftovers before reaching the tests.
cleanup_preview_dylibs

xcodebuild test \
  -project HelloNotes.xcodeproj -scheme HelloNotes \
  -destination 'platform=macOS' \
  -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/HelloNotes-SPM \
  "${@:--only-testing:HelloNotesTests}"
# NOT `status=$?`: in zsh `status` is a read-only alias for `$?`, so the
# assignment fails and the later `exit $status` reports whatever *cleanup* did.
# A failing suite would have exited 0 — the script would have lied.
result=$?

# 3. Clean up regardless of the result.
cleanup_hosts
cleanup_preview_dylibs
exit $result
