#!/usr/bin/env python3
"""
PreToolUse guard for the three files that have already caused incidents here.

- `.env` (repo root)            → hard block, all tools. Standing rule: never
                                  read, print, or commit it.
- `Config/Secrets.xcconfig`     → hard block, all tools. Live provider
                                  credentials; a predecessor of this file had a
                                  secret purged from public git history. The
                                  committed template `Secrets.example.xcconfig`
                                  stays editable.
- `project.pbxproj`             → ask, Edit/Write only. Git is the source of
                                  truth (Xcode has twice regenerated it into
                                  the SwiftData template), but deliberate edits
                                  are occasionally legitimate — so require the
                                  user to confirm rather than forbid.

Exit 2 blocks the call and feeds stderr back to the model. A JSON
permissionDecision of "ask" defers to the user. Anything else: exit 0, silent.

This is a guardrail, not a security boundary — shell access can bypass it.
Its job is to stop the *routine* path, the same way the build gate does.
"""

import json
import sys
from pathlib import PurePosixPath

try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(0)

tool = payload.get("tool_name", "")
path = (payload.get("tool_input") or {}).get("file_path", "")
if not path:
    sys.exit(0)

name = PurePosixPath(path).name

if name == ".env":
    print(
        "Blocked: the repo-root .env is never read, edited, or committed by "
        "Claude (standing project rule). If its contents are needed, the user "
        "handles that file directly.",
        file=sys.stderr,
    )
    sys.exit(2)

if name == "Secrets.xcconfig":
    print(
        "Blocked: Config/Secrets.xcconfig holds live provider credentials and "
        "is git-ignored. Claude does not read or write it; edit "
        "Secrets.example.xcconfig for structure changes, and the user updates "
        "the real file. (A leaked secret from this file has been purged from "
        "public history once already.)",
        file=sys.stderr,
    )
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
    sys.exit(0)

sys.exit(0)
