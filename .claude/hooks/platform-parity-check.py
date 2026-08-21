#!/usr/bin/env python3
"""
PostToolUse check: a platform gate must supply *both* platforms.

The rule, and why it is this rule
--------------------------------
There are two kinds of `#if os(...)` and they are not alike:

    // one API, two implementations — this is how parity is built
    #if os(macOS)
    throw error            // the Mac has a Trash for every location
    #else
    try FileManager.default.removeItem(at: url)
    #endif

    // a feature that exists on one platform — this is how parity is lost
    #if os(macOS)
    Button("Reveal in Finder") { ... }
    #endif

The first gives both platforms the same behaviour through different calls. The
second gives one platform a capability the other does not have. Every divergence
this audit found is the second kind, and every shared type it built —
`AccentContrast`, `Trash`, `PointerPresence` — is the first.

The distinction is mechanical: **the second kind has no `#else`.** So that is the
check. A gate that covers both branches passes; a gate that covers one is
refused. No exemption list, no registry, nothing to sign off — because an
exemption is a judgement call, and the record of judgement calls in this
codebase is four for four wrong, each defended in a comment by whoever made it.

Also refused: a newly created file named `iOS*` or `Mac*`, which is the same
divergence spelled as a filename. And a whole-file gate is caught by the same
rule — `#if os(macOS)` at the top of a 739-line view with `#endif` at the bottom
has no `#else`, which is exactly what makes it a one-platform feature.

Scope: `HelloNotes/**.swift`. The editor package's AppKit/UIKit split *is* the
platform boundary and both halves exist there by construction; the parity test
suites cover the tests.

Exit 2 feeds the message back so the next action is the fix.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

GATE = re.compile(r'^\s*#if\s+.*\b(?:os\(macOS\)|os\(iOS\)|os\(visionOS\)|'
                  r'canImport\(AppKit\)|canImport\(UIKit\)|targetEnvironment\()')
ELSE = re.compile(r'^\s*#(?:else|elseif)\b')
ENDIF = re.compile(r'^\s*#endif\b')
ANY_IF = re.compile(r'^\s*#if\b')

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

if not relative.parts or relative.parts[0] != "HelloNotes" or path.suffix != ".swift":
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


IMPORT = re.compile(r'^\s*(?:@_\w+\s+)?import\s')


def one_sided_gates(lines: list[str]) -> list[tuple[int, str]]:
    """Gates whose block contains no `#else` / `#elseif` at their own depth.

    A gate whose body is nothing but `import` lines is not one of them. The rule
    is about *behaviour* — a capability one platform has and the other does not
    — and naming a framework that exists on one platform grants nothing by
    itself. The code that uses it is what gets checked, and it is checked. This
    is the rule being precise rather than an exemption: there is nothing to
    argue and nothing to record, because an import-only gate cannot make the two
    platforms behave differently.
    """
    found: list[tuple[int, str]] = []
    stack: list[tuple[int, str, bool]] = []   # (line index, text, saw_else)
    for index, line in enumerate(lines):
        if ANY_IF.match(line):
            stack.append((index, line.strip(), False))
        elif ELSE.match(line) and stack:
            start, text, _ = stack[-1]
            stack[-1] = (start, text, True)
        elif ENDIF.match(line) and stack:
            start, text, saw_else = stack.pop()
            if not GATE.match(lines[start]) or saw_else:
                continue
            body = [l for l in lines[start + 1:index]
                    if l.strip() and not l.strip().startswith("//")]
            if body and all(IMPORT.match(l) for l in body):
                continue
            found.append((start, text))
    return found


before = {text for _, text in one_sided_gates(committed(relative))}
problems: list[str] = []

if not committed(relative) and re.match(r'^(iOS|Mac)[A-Z]', path.name):
    problems.append(
        f"`{path.name}` is a new platform-specific file — the same divergence "
        f"spelled as a filename. Put the decision in a shared type and keep only "
        f"the presentation per platform."
    )

remaining = dict()
for text in before:
    remaining[text] = remaining.get(text, 0) + 1

for index, text in one_sided_gates(current):
    if remaining.get(text):
        remaining[text] -= 1
        continue
    problems.append(
        f"{relative}:{index + 1} — `{text}` has no `#else`, so it gives one "
        f"platform something the other does not have. A gate that supplies both "
        f"branches is how this codebase shares behaviour (`Trash`, "
        f"`PointerPresence`, `AccentContrast` all do); a gate that supplies one "
        f"is how it loses it. Ask what fact the gate is about — every divergence "
        f"found in this project turned out to be a platform standing in for "
        f"window width, whether a pointer is attached, or whether a Trash "
        f"exists — then answer that fact on both sides."
    )

if problems:
    print("Platform parity check\n", file=sys.stderr)
    for problem in problems:
        print(f"  • {problem}\n", file=sys.stderr)
    print("A Mac window and an iPad of the same size must behave the same. There "
          "is no exemption path: give the gate an `#else`, or share the "
          "implementation.", file=sys.stderr)
    sys.exit(2)

sys.exit(0)
