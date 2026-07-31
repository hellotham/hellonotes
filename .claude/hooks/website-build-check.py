#!/usr/bin/env python3
"""
PostToolUse check: after any edit to a website BUILD INPUT, rebuild the site
and run the bundled audit (.claude/skills/site-audit/audit.py).

Build inputs are website/src/**, website/public/**, astro.config.mjs and
package.json — an allowlist, because the directory also holds docs
(AGENTS.md/CLAUDE.md), lockfiles and tsconfig that cannot change a byte of
dist, and paying a build per docs edit is pure waste.

Rationale for running at all: every website failure this project has shipped —
base-prefix drift, og:image 404s, canonical/.html forms, sitemap divergence,
JSX whitespace collapse — left the Astro build green. The audit is what
catches the incident classes; both together cost well under a second.

PostToolUse cannot un-do the edit; exit 2 feeds the failure output straight
back to the model so the very next action is the fix, not a push. Mid-refactor
noise (a link whose target page is the next edit) is acceptable — the report
is informational, and a clean state is always one audit away.
"""

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WEBSITE = ROOT / "website"

try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(0)

path = (payload.get("tool_input") or {}).get("file_path", "")
if not path:
    sys.exit(0)

edited = Path(path)
if not edited.is_absolute():
    edited = ROOT / edited
edited = edited.resolve()

build_inputs = (
    WEBSITE / "src",
    WEBSITE / "public",
    WEBSITE / "astro.config.mjs",
    WEBSITE / "package.json",
)
if not any(edited == p or p in edited.parents for p in build_inputs):
    sys.exit(0)

# Prefer the astro binary directly — `npm run build` adds a whole extra node
# startup (~70 ms) just to read package.json and spawn the same thing.
astro = WEBSITE / "node_modules" / ".bin" / "astro"
cmd = [str(astro), "build"] if astro.exists() else ["npm", "run", "build"]

build = subprocess.run(cmd, cwd=WEBSITE, capture_output=True, text=True)
if build.returncode != 0:
    tail = (build.stdout + build.stderr).strip().splitlines()[-15:]
    print("website build FAILED after this edit:\n" + "\n".join(tail), file=sys.stderr)
    sys.exit(2)

audit = subprocess.run(
    [sys.executable, str(ROOT / ".claude/skills/site-audit/audit.py")],
    capture_output=True,
    text=True,
)
if audit.returncode != 0:
    print(
        "website builds, but the site audit found regressions:\n"
        + audit.stdout.strip(),
        file=sys.stderr,
    )
    sys.exit(2)
