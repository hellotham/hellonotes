#!/usr/bin/env python3
"""
PreToolUse guard: never capture the screen while a private vault is loaded.

Why this exists
---------------
On 2026-08-29 three `screencapture` shots were taken of the author's real
2,019-note Obsidian vault — personal folder names legible in the sidebar —
*while checking whether the vault had switched to SampleVault*. Saying "I
won't ship this one" is a different promise from "I won't take it", and only
the second is safe: the file exists the moment the shutter fires, whatever
was intended for it afterwards.

CLAUDE.md now carries the rule ("screenshotting to check IS capturing;
verify by reading collectionPaths"). A rule that must be remembered is
weaker than a gate that cannot be forgotten, which is what this is.

The rule
--------
If a Bash command runs `screencapture` **and** HelloNotes is running **and**
its loaded collections are anything other than SampleVault alone, block it.

Deliberately narrow, so it costs nothing in normal work:

  * HelloNotes not running        -> allow. Nothing of the vault is on screen.
  * SampleVault the only vault    -> allow. That is the marketing vault, and
                                     it ships in the repo.
  * plist unreadable / anything
    unexpected                    -> BLOCK. This guard exists for a privacy
                                     incident, so ambiguity resolves toward
                                     not taking the picture.

Checking which window a `-l<id>` targets is deliberately *not* attempted: a
full-screen or region capture catches the vault just as well, and a guard
that reasons about window ownership is a guard with a bypass.
"""

import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

# Overridable so the guard can be tested — including proving that it *blocks*,
# which a guard nobody has watched fail is not known to do.
PREFS = Path(
    os.environ.get("HN_GUARD_PREFS")
    or Path.home()
    / "Library/Containers/com.hellotham.HelloNotes/Data/Library"
    / "Preferences/com.hellotham.HelloNotes.plist"
)
FORCE_RUNNING = os.environ.get("HN_GUARD_ASSUME_RUNNING") == "1"
# Vaults whose contents are ours to publish. `SampleVault` is the repo's
# marketing fixture; `DefaultCollection` is the tour and user manual that ship
# *inside the binary* and are copied into the app's own container on first
# launch — so it is public content by construction, and strictly safer than a
# fixture anyone could have edited. The store screenshots are taken from it now,
# and a guard that refused it would have to be turned off to do the job, which
# is how a guard stops guarding.
SAFE_VAULTS = {"SampleVault", "DefaultCollection"}


def deny(reason: str) -> None:
    print(reason, file=sys.stderr)
    sys.exit(2)


try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)

if payload.get("tool_name") != "Bash":
    sys.exit(0)

command = payload.get("tool_input", {}).get("command", "") or ""
# Word-boundary match so `screencapture` is caught but a path or a comment
# mentioning it in passing is not the point — any real invocation matches.
if not re.search(r"\bscreencapture\b", command):
    sys.exit(0)

# Is the Mac app running? Match the macOS bundle layout only: a process in the
# iOS Simulator is also named HelloNotes, and its container holds only the
# seeded SampleVault, so it is not what this guard is about.
try:
    running = subprocess.run(
        ["pgrep", "-f", r"HelloNotes\.app/Contents/MacOS/HelloNotes"],
        capture_output=True,
        text=True,
        timeout=5,
    ).returncode == 0
except Exception:
    running = False

if not (running or FORCE_RUNNING):
    sys.exit(0)

try:
    with PREFS.open("rb") as fh:
        collections = plistlib.load(fh).get("collectionPaths") or []
except Exception as exc:
    deny(
        "screencapture blocked: HelloNotes is running and its preferences "
        f"could not be read ({exc.__class__.__name__}), so which vault is on "
        "screen is unknown.\n"
        "This guard fails closed on purpose — see .claude/hooks/"
        "guard-screencapture.py. Quit HelloNotes, or open SampleVault or "
        "DefaultCollection, then retry."
    )

others = [p for p in collections if Path(str(p)).name not in SAFE_VAULTS]
if others:
    listed = "\n  ".join(str(p) for p in others)
    deny(
        "screencapture blocked: HelloNotes has a collection open that is not "
        "SampleVault or DefaultCollection, so a capture may contain private "
        "notes.\n  " + listed + "\n\n"
        "Close it and leave only one of those open, then retry. Verify by "
        "READING, "
        "never by capturing to look:\n"
        '  /usr/libexec/PlistBuddy -c "Print :collectionPaths" \\\n'
        f"    {PREFS}\n\n"
        "Back the plist up first and restore it afterwards — opening or "
        "closing a collection changes the user's state."
    )

if not collections:
    deny(
        "screencapture blocked: HelloNotes is running but reports no open "
        "collection, so what is on screen cannot be confirmed. Open "
        "SampleVault or DefaultCollection, or quit the app, then retry."
    )

sys.exit(0)
