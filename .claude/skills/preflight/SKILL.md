---
name: preflight
description: Full pre-submission inventory — git, build numbers, archives, screenshot counts and sizes per platform, leftover processes — then the slow gates to run by hand. Use before submitting to the App Store, cutting a release, or answering "is anything else needed?".
disable-model-invocation: true
---

# Preflight

```bash
python3 .claude/skills/preflight/check.py
```

Exit 0 when every check passes, 1 on any FAIL. Add `--json` for machine output.

## Why this exists

"Is anything else needed?" was answered from the DMG alone. The iPad screenshot
tab was never opened, and **a platform went to review with one stale screenshot
— twice.** The question is a request to re-inventory *every surface*, and that
is a checklist, not a judgement call. Anything a script can decide should not be
left to whoever is looking.

## What it checks, and why each one is there

| Check | The incident behind it |
|---|---|
| Working tree clean · nothing unpushed | Work committed but never pushed, twice |
| One build number, one marketing version | 16 targets; a partial bump ships a mismatched archive |
| Archives match the project | An archive built before the bump uploads the wrong build |
| **Screenshots per platform, at exact pixel sizes** | iPad shipped with 1; the 11-inch iPad's 1668×2420 is rejected outright |
| Raw captures present *and tracked* | The originals were lost to a scratchpad; composites are one-way |
| No test hosts left running | `xcodebuild test` injects into the app; hosts survive and look like the app |
| Mac app not running | `run-tests.sh` refuses rather than test on top of it |
| No simulators left booted | Leftovers confuse the next run and hold the app open |

The screenshot check reads **actual pixel dimensions** with `sips`, not
filenames — a file called `iphone-6.5.png` at the wrong size passes every check
that trusts its name.

## What it deliberately does not do

The slow gates are **named, not run** — they take minutes and one of them needs
the user's app closed:

```bash
./scripts/run-tests.sh                                     # 425 app tests, 56 suites
swift test --package-path Packages/NotesEditor             # 402
cd Packages/NotesEditor && xcodebuild test -scheme NotesEditor-Package \
  -destination 'platform=iOS Simulator,name=HN-iPad'       # 383 — THREE summaries, sum them
scripts/check-download-page.sh                             # live page vs what latest serves
```

And one thing no script here can do: **open every screenshot tab in App Store
Connect, per platform.** `0 of 10` and `1 of 10` read identically in a glance at
the page; only the count distinguishes them. Screenshots also cannot be edited
at all while a version is *Waiting for Review*, so a mistake there costs a
removal from review and a resubmission — inventory before submitting, not after.

## Extending it

Add checks to `check.py` via `add(status, name, detail)`. Use `FAIL` only for
things that must block a submission; `WARN` for things worth seeing that
legitimately vary (a staged screenshot set mid-work, an app you left open on
purpose). A check that cries wolf gets ignored, and an ignored check is worse
than no check — the same reason a guard needs a negative control before you
trust it.
