#!/usr/bin/env python3
"""
PreToolUse guard for the files that have already caused incidents here.
Matching is by BASENAME, so the rules apply to these names anywhere in the
tree, not just the repo-root copies — deliberate, since a stray `.env` in a
subdirectory is just as sensitive.

- `.env`               → hard block, all tools. Standing rule: never read,
                         print, or commit it.
- `Secrets.xcconfig`   → hard block, all tools. Live provider credentials; a
                         secret from this file was once purged from public git
                         history. The committed `Secrets.example.xcconfig`
                         template stays editable (different basename).
- `project.pbxproj`    → ask, Edit/Write only. Git is the source of truth
                         (Xcode has twice regenerated it into the SwiftData
                         template), but deliberate edits are occasionally
                         legitimate — require confirmation, don't forbid.

Exit 2 blocks the call and feeds stderr back to the model. A JSON
permissionDecision of "ask" defers to the user. Anything else passes.

This is a guardrail, not a security boundary — shell access can bypass it.
Its job is to stop the *routine* path, the same way the build gate does.
"""

import json
import sys
from pathlib import PurePosixPath

BLOCKED = {
    ".env": (
        "Blocked: .env files are never read, edited, or committed by Claude "
        "(standing project rule). If the contents are needed, the user handles "
        "the file directly."
    ),
    "parity-exemptions.md": (
        "Blocked: docs/parity-exemptions.md records which platform divergences "
        "the owner has approved, and Claude does not write to it. An exemption "
        "authored by the party that wants it is not a control — that is exactly "
        "how every divergence in this codebase arrived, each with a comment "
        "defending it. Put the argument in the response for the user to paste "
        "in and sign off; until an entry carries `Approved:`, the gate it covers "
        "stays refused."
    ),
    "Secrets.xcconfig": (
        "Blocked: Secrets.xcconfig holds live provider credentials and is "
        "git-ignored. Claude does not read or write it; edit "
        "Secrets.example.xcconfig for structure changes, and the user updates "
        "the real file. (A leaked secret from this file has been purged from "
        "public history once already.)"
    ),
}

try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(0)

tool = payload.get("tool_name", "")
path = (payload.get("tool_input") or {}).get("file_path", "")
if not path:
    sys.exit(0)

name = PurePosixPath(path).name

if name in BLOCKED:
    print(BLOCKED[name], file=sys.stderr)
    sys.exit(2)

if name == "project.pbxproj" and tool in ("Edit", "Write"):
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "ask",
                    "permissionDecisionReason": (
                        "project.pbxproj edit — git is the source of truth for "
                        "this file (Xcode has twice regenerated it into a "
                        "template; recovery is `git checkout`). Confirm this "
                        "edit is deliberate."
                    ),
                }
            }
        )
    )
