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
verify by reading collectionPaths — and remoteCollectionCaches"). A rule
that must be remembered is weaker than a gate that cannot be forgotten, which
is what this is.

The rule
--------
If a Bash command runs `screencapture` **and** HelloNotes is running **and**
its loaded collections are anything other than SampleVault and
DefaultCollection, block it.

What is loaded is asked of every list `Library.restore()` reopens a
collection from, never of collectionPaths alone:

  collectionPaths         The local collections' last-known paths: the only
                          names here, and the only list SAFE_VAULTS judges.
  remoteCollectionCaches  The cloud collections' cache folders. A cloud
                          collection is in this list and no other: on
                          2026-09-24 collectionPaths said DefaultCollection
                          alone, and a capture showed a OneDrive collection's
                          folders. A cache folder is named after the
                          provider's folder, so no name makes one safe.
  collectionBookmarks     What restore() opens; collectionPaths only names it,
                          index for index. persist() writes the two together,
                          but restore() opens a bookmark that has no path at
                          its index too — a plist from before collectionPaths
                          (2026-08-15), or one written by hand — and a
                          bookmark is opaque here, so the two are counted.
  vaultBookmark           The first versions' one bookmark, which restore()
                          opens, with no path, when collectionBookmarks is
                          empty.

Deliberately narrow, so it costs nothing in normal work:

  * HelloNotes not running        -> allow. Nothing of the vault is on screen.
  * SampleVault, DefaultCollection
    or both, and nothing else in
    any list                      -> allow. One is the marketing vault in the
                                     repo; the other ships inside the binary.
  * remoteCollectionCaches lists
    anything                      -> BLOCK, whatever it is called: no cloud
                                     collection is ours to publish.
  * collectionPaths names any
    other collection              -> BLOCK.
  * a bookmark with no path       -> BLOCK. It opens a collection this guard
                                     cannot name.
  * nothing open                  -> BLOCK. What is on screen cannot be
                                     confirmed.
  * plist unreadable, a list that
    is not an array of what
    restore() reads, the guard
    itself failing, anything
    unexpected                    -> BLOCK. This guard exists for a privacy
                                     incident, so ambiguity resolves toward
                                     not taking the picture.

Each list is read as restore() reads it (`as? [String]`, `as? [Data]`), and
from two places: the plist file, and cfprefsd, which has what the app has set
before the file does — ten seconds before, for a running sandboxed process
whose plist exists, and over a minute where the plist did not exist yet
(measured). Either one can block.

What it found is said in key names and counts, never values: a path names a
private folder, and a cache folder a provider's.

Checking which window a `-l<id>` targets is deliberately *not* attempted: a
full-screen or region capture catches the vault just as well, and a guard
that reasons about window ownership is a guard with a bypass.
"""

import json
import os
import plistlib
import re
import shlex
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


def crashed(kind, exc, tb) -> None:
    # The class and the line only: an exception's message can carry a value.
    while tb is not None and tb.tb_next is not None:
        tb = tb.tb_next
    where = f" at {Path(tb.tb_frame.f_code.co_filename).name}:{tb.tb_lineno}" if tb else ""
    print(
        f"screencapture blocked: this guard failed ({kind.__name__}{where}) "
        "before it could decide, and a guard that has not decided does not "
        "allow. See .claude/hooks/guard-screencapture.py.",
        file=sys.stderr,
        flush=True,
    )
    os._exit(2)


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

# From here on the command takes a picture and HelloNotes may be running,
# and a guard that crashes has not decided. Claude Code reads every exit but
# 2 as "go ahead", so an uncaught exception — exit 1 — let the picture be
# taken: a collectionPaths that held a number did exactly that. Whatever
# fails from here on blocks.
sys.excepthook = crashed

# Each list is what `restore()` reads — `as? [String]`, `as? [Data]` — or
# absent, which is a list nothing has written yet. A list with one entry of
# another kind is no list at all to the app, which then does what it does
# with none — it opens the first versions' vaultBookmark in its place — and
# this guard cannot follow that, so it is unreadable, and blocks. So is
# anything that is not an array.
class Unreadable(Exception):
    pass


KINDS = {str: "a string", bytes: "data"}


def listed(prefs: dict, key: str, kind: type) -> list:
    value = prefs.get(key, [])
    if not isinstance(value, list):
        raise Unreadable(f"{key} holds {type(value).__name__}, not an array")
    if not all(isinstance(item, kind) for item in value):
        raise Unreadable(f"{key} holds an entry that is not {KINDS[kind]}")
    return value


def counted(n: int, noun: str) -> str:
    return f"{n} {noun}" + ("" if n == 1 else "s")


def counting(*keys: str) -> str:
    # How to read a list's size without printing what is in it, as cfprefsd
    # has it. `-expect array` is what makes it a count: without it, `raw`
    # prints the value of a key that holds a string.
    plist = shlex.quote(str(PREFS))
    return "".join(
        f"  defaults export {plist} - |\n"
        f"    plutil -extract {key} raw -expect array -o - -\n"
        for key in keys
    )


def judge(prefs) -> "str | None":
    """Why this view of the preferences rules a capture out, or None."""
    if not isinstance(prefs, dict):
        raise Unreadable(f"it holds {type(prefs).__name__}, not a dictionary")
    collections = listed(prefs, "collectionPaths", str)
    remotes = listed(prefs, "remoteCollectionCaches", str)
    bookmarks = listed(prefs, "collectionBookmarks", bytes)

    if remotes:
        n = len(remotes)
        return (
            f"screencapture blocked: HelloNotes has {counted(n, 'cloud collection')} "
            f"open — remoteCollectionCaches lists {n} — so a capture may contain "
            "private notes. A cloud collection comes back from that list alone "
            "and is never in collectionPaths, so collectionPaths cannot vouch for "
            "it.\n\n"
            f"Close {'it' if n == 1 else 'them'}, or quit HelloNotes, then retry. "
            "Verify by READING, never by capturing to look — and count, never "
            "print: an entry names a provider's folder. This prints how many "
            'there are; 0, or "No value at that key path", means none:\n'
            + counting("remoteCollectionCaches")
        )

    private = [p for p in collections if Path(p).name not in SAFE_VAULTS]
    if private:
        n = len(private)
        return (
            f"screencapture blocked: collectionPaths names "
            f"{counted(len(collections), 'collection')}, and {n} "
            f"{'is' if n == 1 else 'are'} not SampleVault or DefaultCollection, "
            "so a capture may contain private notes.\n\n"
            f"Close {'it' if n == 1 else 'them'}, leaving SampleVault or "
            "DefaultCollection, then retry: this guard reads the names again on "
            "every capture. Verify by READING, never by capturing to look — and "
            "count, never print: a path names a private folder.\n"
            + counting("collectionPaths")
            + "\nBack the plist up first and restore it afterwards — opening or "
            "closing a collection changes the user's state."
        )

    # restore() pairs bookmark i with path i, and opens a bookmark that
    # resolves whether or not a path is there to name it — so one past the
    # end of collectionPaths is a collection nothing here can name. The first
    # versions' one `vaultBookmark` is opened that way whenever
    # collectionBookmarks is empty.
    legacy = not bookmarks and "vaultBookmark" in prefs
    unnamed = 1 if legacy else len(bookmarks) - len(collections)
    if unnamed > 0:
        found = (
            "vaultBookmark is set and collectionBookmarks is empty"
            if legacy
            else f"collectionBookmarks lists {len(bookmarks)} and collectionPaths "
            f"names {len(collections)}"
        )
        return (
            f"screencapture blocked: {found}. HelloNotes opens a bookmark with no "
            "path beside it, and this guard cannot name what that opens: a "
            "bookmark is opaque to it.\n\n"
            "Quit HelloNotes, or open or close any collection (the app then "
            "writes both lists again), and retry. Count by reading, never print:\n"
            + counting("collectionBookmarks", "collectionPaths")
        )

    if not collections:
        return (
            "screencapture blocked: HelloNotes is running but reports no open "
            "collection, so what is on screen cannot be confirmed. Open "
            "SampleVault or DefaultCollection, or quit the app, then retry."
        )
    return None


# Two views of the same preferences. The app's changes reach cfprefsd at once
# and the file when cfprefsd writes it: ten seconds later for a running
# sandboxed process whose plist exists, over a minute later where the plist
# did not exist yet (implemented.md §51.53). So the file alone says a cloud
# collection opened a moment ago is not open, and cfprefsd alone says nothing
# of a file it cannot read — it answers an empty dictionary. Each view is
# judged, and either one blocks.
def from_file(path: Path) -> dict:
    with path.open("rb") as fh:
        return plistlib.load(fh)


def from_cfprefsd(path: Path) -> dict:
    # Exported as XML, which plistlib cannot always parse — a string may hold
    # a control character — so plutil makes it binary first. Short timeouts
    # (the two take about 10 ms): the hook is given 15 seconds in all, the
    # process check above has a timeout of its own, and a hook that runs out
    # of time is taken as "go ahead".
    exported = subprocess.run(
        ["/usr/bin/defaults", "export", str(path), "-"],
        capture_output=True,
        timeout=1,
        check=True,
    ).stdout
    return plistlib.loads(
        subprocess.run(
            ["/usr/bin/plutil", "-convert", "binary1", "-o", "-", "-"],
            input=exported,
            capture_output=True,
            timeout=1,
            check=True,
        ).stdout
    )


VIEWS = (
    ("the plist file", from_file),
    ("cfprefsd, which has what the app has set before the file does", from_cfprefsd),
)

for view, read in VIEWS:
    try:
        reason = judge(read(PREFS))
    except Exception as exc:
        detail = str(exc) if isinstance(exc, Unreadable) else exc.__class__.__name__
        deny(
            "screencapture blocked: HelloNotes is running and its preferences "
            f"could not be read ({detail}, in {view}), so which vault is on "
            "screen is unknown.\n"
            "This guard fails closed on purpose — see .claude/hooks/"
            "guard-screencapture.py. Quit HelloNotes, or open SampleVault or "
            "DefaultCollection, then retry."
        )
    if reason:
        deny(reason + f"\n(Read from {view}.)")

sys.exit(0)
