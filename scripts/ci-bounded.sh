#!/bin/bash
#
#  ci-bounded.sh <seconds> <folder> -- <command…>
#
#  Run a command that is meant to finish, and when it has not, say what it was
#  doing before stopping it.
#
#  For the test step in CI (.github/workflows/build-and-test.yml). The first
#  run on `main` to get as far as running the Mac tests (2026-10-12, run
#  38179720226) started 775 of them within a fifth of a second and finished
#  none: the step printed nothing more for eighty minutes, the job ran into its
#  ninety, and GitHub reported it as *cancelled* — which read as someone having
#  stopped it. Nothing was kept that could say what the test host was waiting
#  for (implemented.md §51.44).
#
#  So the command's output is followed as it comes, and when it has said
#  nothing for CI_STALL_SILENCE seconds (300), or has run past <seconds>:
#
#    * the test host — and the command — are sampled, which is the stack the
#      main thread is stopped in;
#    * on a runner, the screen is pictured and the processes listed: a sheet
#      asking for permission, or for a keychain, is a thing on a screen;
#    * the number of tests that started and that finished is counted;
#    * and everything is left in <folder>, with the whole output, for the step
#      after this one to keep.
#
#  It exits 124 then; otherwise with the command's own status. The picture and
#  the process list are taken on a runner only (GITHUB_ACTIONS): run by hand,
#  the screen is a person's.
#
#  Try it: `CI_STALL_SILENCE=4 scripts/ci-bounded.sh 60 /tmp/x -- sleep 30`.
#
set -u

limit=${1:?seconds}
out=${2:?folder}
shift 2
[ "${1:-}" = "--" ] && shift
[ $# -gt 0 ] || { echo "ci-bounded.sh: no command" >&2; exit 2; }

silence=${CI_STALL_SILENCE:-300}
# A test host's argv is the app's, and `-NSTreatUnknownArgumentsAsOpen` is the
# one word in it that says it is a host (see run-tests.sh). **This app's**, as
# that script matches it: Xcode launches every app it debugs with the same
# argument, and the bare word would sample — and then stop — whatever else is
# being run from Xcode on a developer's Mac.
host_pattern=${CI_HOST_PATTERN:-HelloNotes\.app/Contents/MacOS/HelloNotes.*-NSTreatUnknownArgumentsAsOpen}

mkdir -p "$out"
log="$out/output.log"
: > "$log"

# Job control, so the command is a process group of its own and what it started
# goes with it when it is stopped.
set -m
"$@" > "$log" 2>&1 &
command_pid=$!
tail -n +1 -f "$log" &
tailer=$!

size_of() { wc -c < "$log" | tr -d ' '; }

sample_into() {  # <pid> <file>
  sample "$1" 10 -file "$2" > /dev/null 2>&1 \
    || sudo -n sample "$1" 10 -file "$2" > /dev/null 2>&1 \
    || echo "could not sample $1" >> "$out/summary.txt"
}

started=$SECONDS
last_size=$(size_of)
last_change=$SECONDS
why=""
while kill -0 "$command_pid" 2> /dev/null; do
  sleep 5
  now_size=$(size_of)
  if [ "$now_size" != "$last_size" ]; then
    last_size=$now_size
    last_change=$SECONDS
  fi
  if [ $((SECONDS - last_change)) -ge "$silence" ]; then
    why="said nothing for ${silence}s"
  elif [ $((SECONDS - started)) -ge "$limit" ]; then
    why="ran past ${limit}s"
  fi
  [ -n "$why" ] && break
done

if [ -z "$why" ]; then
  wait "$command_pid"
  status=$?
  sleep 1
  kill "$tailer" 2> /dev/null
  exit "$status"
fi

# Stalled. What it was doing, before anything is stopped.
tests_started=$(grep -c '^◇ Test .* started' "$log")
tests_finished=$(grep -cE '^(✔|✘) Test .* (passed|failed)' "$log")
{
  echo "The command $why."
  echo "Tests started: $tests_started. Tests finished: $tests_finished."
} | tee -a "$out/summary.txt"
echo "::error::The command $why — $tests_started tests started, $tests_finished finished. Samples are in the run's artifacts."

for pid in $(pgrep -f "$host_pattern"); do
  sample_into "$pid" "$out/sample-host-$pid.txt"
done
sample_into "$command_pid" "$out/sample-command.txt"
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  screencapture -x "$out/screen.png" 2> /dev/null || echo "no picture of the screen" >> "$out/summary.txt"
  ps -axo pid,ppid,state,etime,command > "$out/processes.txt" 2> /dev/null || true
fi

pkill -f "$host_pattern" 2> /dev/null
kill -- "-$command_pid" 2> /dev/null || kill "$command_pid" 2> /dev/null
sleep 2
kill -9 -- "-$command_pid" 2> /dev/null
kill "$tailer" 2> /dev/null
exit 124
