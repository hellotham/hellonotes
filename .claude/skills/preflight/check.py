#!/usr/bin/env python3
"""
Mechanical pre-submission inventory.

Exists because "is anything else needed?" was answered from partial evidence —
the DMG was checked and the iPad screenshot tab was never opened, so a platform
shipped with one screenshot through two submissions. Judgement is exactly the
wrong instrument for a checklist; this is the checklist.

Fast checks only (a second or two). Test suites are named at the end rather
than run, because they take minutes and need the user's app closed.

    python3 .claude/skills/preflight/check.py [--json]

Exit 0 if every check passes, 1 if any FAIL. WARN never fails the run.
"""

import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
results = []


def add(status, name, detail=""):
    results.append({"status": status, "name": name, "detail": detail})


def sh(*args, **kw):
    return subprocess.run(args, capture_output=True, text=True, cwd=ROOT, timeout=60, **kw)


# ---------------------------------------------------------------- git
st = sh("git", "status", "--porcelain").stdout.strip()
add("PASS" if not st else "FAIL", "working tree clean",
    "" if not st else f"{len(st.splitlines())} uncommitted path(s)")

ahead = sh("git", "log", "--oneline", "origin/main..HEAD").stdout.strip()
add("PASS" if not ahead else "FAIL", "nothing unpushed",
    "" if not ahead else f"{len(ahead.splitlines())} commit(s) ahead of origin/main")

# ------------------------------------------------------- build numbers
pbx = (ROOT / "HelloNotes.xcodeproj/project.pbxproj").read_text()
builds = sorted(set(re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", pbx)))
mkts = sorted(set(re.findall(r"MARKETING_VERSION = ([^;]+);", pbx)))
add("PASS" if len(builds) == 1 else "FAIL", "one build number across targets",
    ", ".join(builds))
add("PASS" if len(mkts) == 1 else "FAIL", "one marketing version", ", ".join(mkts))

# ------------------------------------------------------------ archives
for arch in sorted((ROOT / "build").glob("*.xcarchive")):
    info = arch / "Info.plist"
    try:
        props = plistlib.loads(info.read_bytes()).get("ApplicationProperties", {})
        b, v = props.get("CFBundleVersion"), props.get("CFBundleShortVersionString")
        ok = b in builds and v in mkts
        add("PASS" if ok else "WARN", f"archive {arch.name}",
            f"{v} ({b})" + ("" if ok else " — does not match the project"))
    except Exception as e:
        add("WARN", f"archive {arch.name}", f"unreadable: {e.__class__.__name__}")

# --------------------------------------------------------- screenshots
GRID = {
    "dist/Screenshots-iOS":   (1284, 2778, "iPhone 6.5\""),
    "dist/Screenshots-iPad":  (2064, 2752, "iPad 13\""),
    "dist/Screenshots-macOS": (2560, 1600, "Mac"),
}
for rel, (w, h, label) in GRID.items():
    d = ROOT / rel
    pngs = sorted(d.glob("*.png")) if d.is_dir() else []
    if not pngs:
        add("WARN", f"screenshots · {label}", f"none staged in {rel}/")
        continue
    bad = []
    for p in pngs:
        out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(p)],
                             capture_output=True, text=True).stdout
        gw = re.search(r"pixelWidth: (\d+)", out)
        gh = re.search(r"pixelHeight: (\d+)", out)
        if not gw or not gh or (int(gw.group(1)), int(gh.group(1))) != (w, h):
            bad.append(p.name)
    status = "PASS" if not bad and 3 <= len(pngs) <= 10 else "FAIL" if bad else "WARN"
    detail = f"{len(pngs)} at {w}x{h}"
    if bad:
        detail += f" — WRONG SIZE: {', '.join(bad[:3])}"
    elif len(pngs) < 3:
        detail += " — the store wants at least 3"
    add(status, f"screenshots · {label}", detail)

raw = sorted((ROOT / "assets/screenshots-raw").glob("*.png"))
tracked = sh("git", "ls-files", "assets/screenshots-raw").stdout.strip().splitlines()
add("PASS" if raw and len(tracked) >= len(raw) else "WARN",
    "raw captures committed",
    f"{len(raw)} present, {len([t for t in tracked if t.endswith('.png')])} tracked")

# ------------------------------------------------- leftovers on the Mac
host = sh("pgrep", "-f", "-NSTreatUnknownArgumentsAsOpen").stdout.strip()
add("PASS" if not host else "FAIL", "no test hosts left running",
    "" if not host else f"pids {host.split()}")

app = sh("pgrep", "-f", r"HelloNotes\.app/Contents/MacOS/HelloNotes").stdout.strip()
add("PASS" if not app else "WARN", "Mac app not running",
    "" if not app else f"pids {app.split()} — a test run will refuse")

booted = subprocess.run(["xcrun", "simctl", "list", "devices", "booted"],
                        capture_output=True, text=True).stdout
n = len([l for l in booted.splitlines() if "HN-" in l])
add("PASS" if n == 0 else "WARN", "no simulators left booted", f"{n} booted")

# ----------------------------------------------------------- reporting
if "--json" in sys.argv:
    print(json.dumps(results, indent=1))
else:
    icon = {"PASS": "ok  ", "WARN": "warn", "FAIL": "FAIL"}
    for r in results:
        print(f"  {icon[r['status']]}  {r['name']}" + (f"  —  {r['detail']}" if r["detail"] else ""))
    fails = [r for r in results if r["status"] == "FAIL"]
    warns = [r for r in results if r["status"] == "WARN"]
    print(f"\n  {len(results) - len(fails) - len(warns)} passed, {len(warns)} warning(s), {len(fails)} failure(s)")
    print("\n  Not checked here (minutes, and needs the app closed):")
    print("    ./scripts/run-tests.sh                                    # 374 app tests")
    print("    swift test --package-path Packages/NotesEditor            # 401")
    print("    cd Packages/NotesEditor && xcodebuild test -scheme NotesEditor-Package \\")
    print("      -destination 'platform=iOS Simulator,name=HN-iPad'      # 381, THREE summaries")
    print("    scripts/check-download-page.sh                            # page vs artefact")
    print("    App Store Connect: open every screenshot tab, per platform")

sys.exit(1 if any(r["status"] == "FAIL" for r in results) else 0)
