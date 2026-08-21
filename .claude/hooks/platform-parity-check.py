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

Both are refusable rather than forbidden: adding

    // PARITY-EXEMPT: <reason>

on the line above the gate (or in the first 40 lines of a new file) lets it
through and puts the reason in the diff, where review can see it. The point is
not that divergence is impossible — `revealInFinder` has no iOS meaning — it is
that divergence has to be argued for once, in writing, instead of appearing.

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
EXEMPT = re.compile(r'PARITY-EXEMPT\s*:\s*\S')

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
    if not EXEMPT.search(head):
        problems.append(
            f"`{path.name}` is a new platform-specific file. A view that exists "
            f"once per platform is how the two shells drift — put the decision in "
            f"a shared type and keep only the presentation per platform."
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
    if EXEMPT.search(context):
        continue
    problems.append(
        f"{relative}:{index + 1} adds `{stripped}`. Ask what fact the gate is "
        f"really about — three divergences in this codebase turned out to be a "
        f"platform standing in for something else (window width, whether a "
        f"pointer is attached, whether a Trash exists). If it is genuinely "
        f"platform-specific, say so with `// PARITY-EXEMPT: <reason>` above it."
    )

if problems:
    print("Platform parity check\n", file=sys.stderr)
    for problem in problems:
        print(f"  • {problem}\n", file=sys.stderr)
    print("The contract is that a Mac window and an iPad of the same size behave "
          "the same. Exempt it in writing, or share the implementation.",
          file=sys.stderr)
    sys.exit(2)

sys.exit(0)
