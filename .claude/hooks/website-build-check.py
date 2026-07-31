#!/usr/bin/env python3
"""
PostToolUse check: after any edit under website/, rebuild the site and run the
bundled audit (.claude/skills/site-audit/audit.py).

Rationale: every website failure this project has shipped — base-prefix drift,
og:image 404s, canonical/.html forms, sitemap divergence, JSX whitespace
collapse — left the Astro build green. The build alone proves almost nothing;
the audit is what catches the incident classes. Both are cheap (~300 ms build
for 16 pages, sub-second audit), so they run on every edit.

PostToolUse cannot un-do the edit; exit 2 feeds the failure output straight
back to the model so the very next action is the fix, not a push. Mid-refactor
noise (e.g. a link whose target page is the next edit) is acceptable — the
report is informational, and a clean state is always one audit away.
"""

import json
import subprocess
import sys
from pathlib import Path

try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(0)

path = (payload.get("tool_input") or {}).get("file_path", "")
if "/website/" not in path and not path.startswith("website/"):
    sys.exit(0)
# Generated output is not a source edit.
if "/dist/" in path or "/node_modules/" in path or "/.astro/" in path:
    sys.exit(0)

root = Path(__file__).resolve().parents[2]

build = subprocess.run(
    ["npm", "run", "build"],
    cwd=root / "website",
    capture_output=True,
    text=True,
)
if build.returncode != 0:
    tail = (build.stdout + build.stderr).strip().splitlines()[-15:]
    print("website build FAILED after this edit:\n" + "\n".join(tail), file=sys.stderr)
    sys.exit(2)

audit = subprocess.run(
    [sys.executable, str(root / ".claude/skills/site-audit/audit.py")],
    cwd=root,
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

sys.exit(0)
