#!/usr/bin/env python3
"""
PostToolUse check: refuse a *new* platform divergence in HelloNotes/.

Why a hook and not a test. This repo already has two parity tests
(PlatformParityTests, ShellComplianceTests) and they are tripwires: they fire
after somebody has written the second implementation, which means the second
implementation gets written. Three shipped divergences were found by hand in one
audit — the iPad's inspector column pinned to `.constant(false)`, `prefersTouch`
hard-coded per platform, and a sidebar whose two versions had drifted five rows
apart — and each one had been *defended in a comment* by whoever added it. A
check that runs at the moment the gate is typed is the only one that can refuse
the gate.

What it refuses, in files under HelloNotes/ (not tests, not the editor package):

  1. A newly added `#if os(macOS)` / `#if os(iOS)` / `#if canImport(AppKit)`
     style gate.
  2. A newly created file whose name starts with `iOS` or `Mac`.

Both are refusable rather than forbidden, but **not by the author**. The escape
is

    // PARITY-EXEMPT: <id>

where `<id>` names an entry in docs/parity-exemptions.md that carries an
`Approved:` line from the project owner. A reason written by whoever wants the
gate is not a control — it is the same self-granted permission that produced
every divergence this audit found, each of which arrived with a comment
defending it, each of which was wrong. So the reason lives in a file the model
is refused write access to (see protect-files.py), and an entry without
`Approved:` is a request rather than an exemption.

Exit 2 feeds the message back to the model so the next action is the fix.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

GATE = re.compile(r'^\s*#(?:if|elseif)\s+.*\b(?:os\(macOS\)|os\(iOS\)|os\(visionOS\)|'
                  r'canImport\(AppKit\)|canImport\(UIKit\)|targetEnvironment\()')
EXEMPT = re.compile(r'PARITY-EXEMPT\s*:\s*([A-Za-z0-9][A-Za-z0-9_-]*)')
REGISTRY = ROOT / "docs" / "parity-exemptions.md"


def approved_ids() -> set[str]:
    """Exemption ids the owner has signed off, from the registry.

    An entry is `### \\`id\\`` followed, before the next entry, by a line
    beginning `- **Approved:**` whose text is not the pending marker. Anything
    else — missing, blank, "pending" — is not in force.
    """
    try:
        text = REGISTRY.read_text(encoding="utf-8")
    except Exception:
        return set()
    approved: set[str] = set()
    current: str | None = None
    for line in text.splitlines():
        heading = re.match(r'^###\s+`([^`]+)`', line)
        if heading:
            current = heading.group(1)
            continue
        if current and re.match(r'^\s*-\s*\*\*Approved:\*\*', line):
            body = line.split("**Approved:**", 1)[1].strip()
            if body and "pending" not in body.lower():
                approved.add(current)
            current = None
    return approved


def exemption_is_in_force(context: str) -> tuple[bool, str]:
    """Whether `context` carries an approved exemption, and why not if not."""
    match = EXEMPT.search(context)
    if not match:
        return False, ("no `// PARITY-EXEMPT: <id>` naming an approved entry in "
                       "docs/parity-exemptions.md")
    identifier = match.group(1)
    if identifier not in approved_ids():
        return False, (f"`PARITY-EXEMPT: {identifier}` names an entry that is not "
                       f"approved in docs/parity-exemptions.md. Add the argument "
                       f"there and ask the owner to sign it off — the model "
                       f"cannot approve its own exemption.")
    return True, ""

try:
    event = json.load(sys.stdin)
except Exception:
    sys.exit(0)

path_text = (event.get("tool_input") or {}).get("file_path") or ""
if not path_text:
    sys.exit(0)
path = Path(path_text)

try:
    relative = path.resolve().relative_to(ROOT)
except ValueError:
    sys.exit(0)

parts = relative.parts
# App sources only. The editor package's AppKit/UIKit split is the platform
# boundary itself and is expected; tests are checked by the parity suites.
if not parts or parts[0] != "HelloNotes":
    sys.exit(0)
if path.suffix != ".swift":
    sys.exit(0)


def committed(rel: Path) -> list[str]:
    """The file as HEAD has it — empty for a new file."""
    try:
        out = subprocess.run(["git", "show", f"HEAD:{rel.as_posix()}"],
                             cwd=ROOT, capture_output=True, text=True, timeout=10)
        return out.stdout.splitlines() if out.returncode == 0 else []
    except Exception:
        return []


try:
    current = path.read_text(encoding="utf-8").splitlines()
except Exception:
    sys.exit(0)

before = committed(relative)
problems: list[str] = []

# 1 — a new platform-named file.
if not before and re.match(r'^(iOS|Mac)[A-Z]', path.name):
    head = "\n".join(current[:40])
    ok, why = exemption_is_in_force(head)
    if not ok:
        problems.append(
            f"`{path.name}` is a new platform-specific file. A view that exists "
            f"once per platform is how the two shells drift — put the decision in "
            f"a shared type and keep only the presentation per platform. ({why})"
        )

# 2 — gates that are in the file now and were not before.
def gate_lines(lines: list[str]) -> list[str]:
    return [line.strip() for line in lines if GATE.match(line)]

added = gate_lines(current)
for gate in gate_lines(before):
    if gate in added:
        added.remove(gate)

for index, line in enumerate(current):
    if not GATE.match(line):
        continue
    stripped = line.strip()
    if stripped not in added:
        continue
    added.remove(stripped)
    context = "\n".join(current[max(0, index - 3):index + 1])
    ok, why = exemption_is_in_force(context)
    if ok:
        continue
    problems.append(
        f"{relative}:{index + 1} adds `{stripped}`. Ask what fact the gate is "
        f"really about — three divergences in this codebase turned out to be a "
        f"platform standing in for something else (window width, whether a "
        f"pointer is attached, whether a Trash exists). ({why})"
    )

if problems:
    print("Platform parity check\n", file=sys.stderr)
    for problem in problems:
        print(f"  • {problem}\n", file=sys.stderr)
    print("The contract is that a Mac window and an iPad of the same size behave "
          "the same. Share the implementation, or put the argument in "
          "docs/parity-exemptions.md and ask the owner to approve it — an "
          "exemption you granted yourself is not one.", file=sys.stderr)
    sys.exit(2)

sys.exit(0)
