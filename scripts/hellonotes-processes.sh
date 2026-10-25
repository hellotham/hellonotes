#!/bin/zsh
# Which processes on this Mac are HelloNotes — found by what each one
# *executes*, never by what its command line happens to mention.
#
#   scripts/hellonotes-processes.sh app              the app as a person runs it
#   scripts/hellonotes-processes.sh hosts            test hosts: the app, launched to host a test bundle
#   scripts/hellonotes-processes.sh all              both
#   scripts/hellonotes-processes.sh at <executable>  any of them started as exactly that executable
#
# One pid a line, and nothing when there are none — exit 0 either way, so a
# caller under `set -e` is not stopped by "found nothing", which is the usual
# answer. Asked for anything else, it says so and exits 2: a misspelt mode
# that quietly found nothing would read as "nothing running".
#
# **Why not `pgrep -f` on the path**, which every script here used: `-f`
# matches the *whole command line* of every process, so anything that merely
# names the app was the app — a shell running a command that mentions the
# path, an editor open on it, `sample`, `codesign`. On 2026-10-12
# `run-tests.sh` took the shell that had started it for "the running Mac app"
# and refused to run, twice; and the same kind of match chose what `kill -9`
# and `pkill` were sent to in three scripts (docs/implemented.md §51.50).
#
# What a process executes is two things `ps` reports, and neither is a
# command line:
#   - `ucomm`, the name of the file the kernel executed (its first sixteen
#     characters). A shell is `zsh` whatever its command says, and `exec -a`
#     does not change it.
#   - `comm`, the path it was started as — the full path, spaces and all, for
#     anything LaunchServices or Xcode launches.
# A HelloNotes process is one named `HelloNotes` whose path ends in the Mac
# bundle's layout, `HelloNotes.app/Contents/MacOS/HelloNotes`. The app in the
# iOS Simulator is named HelloNotes too, and its bundle is flat
# (`HelloNotes.app/HelloNotes`): none of these scripts' business.
#
# A test host *is* the app — the test bundle is injected into it, so nothing
# about the process says "xctest" — launched by Xcode with
# `-NSTreatUnknownArgumentsAsOpen`, which a person's launch never has. That is
# asked of the process's own arguments, which, the process being the app, are
# the app's.
set -u

which=${1:-all}
wanted=${2:-}
case $which in
  app|hosts|all) ;;
  at) [[ -n "$wanted" ]] || { echo "hellonotes-processes.sh at: which executable?" >&2; exit 2; } ;;
  *) echo "usage: hellonotes-processes.sh app | hosts | all | at <executable>  (got: $which)" >&2; exit 2 ;;
esac

for pid in $(pgrep -x HelloNotes 2> /dev/null); do
  # Asked again of the pid, not taken from pgrep: the process may have gone,
  # and its number been given to something else, in between.
  name=$(ps -o ucomm= -p "$pid" 2> /dev/null | sed 's/[[:space:]]*$//')
  [[ "$name" == HelloNotes ]] || continue
  # Not `path`, which in zsh *is* `$PATH`: assigned, every command after it
  # stops being found.
  exe=$(ps -o comm= -p "$pid" 2> /dev/null | sed 's/[[:space:]]*$//')
  [[ "$exe" == */HelloNotes.app/Contents/MacOS/HelloNotes ]] || continue
  args=$(ps -o args= -p "$pid" 2> /dev/null)
  if [[ "$args" == *" -NSTreatUnknownArgumentsAsOpen"* ]]; then host=yes; else host=no; fi
  case $which in
    app)   [[ $host == no ]] && echo "$pid" ;;
    hosts) [[ $host == yes ]] && echo "$pid" ;;
    all)   echo "$pid" ;;
    at)    [[ "$exe" == "$wanted" ]] && echo "$pid" ;;
  esac
done
exit 0
