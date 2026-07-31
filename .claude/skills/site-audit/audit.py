#!/usr/bin/env python3
"""
Audit the built HelloNotes website (website/dist) for silent failures: base
prefixes, internal ref resolution, canonicals, sitemap/canonical agreement,
og:image resolution, and JSX whitespace collapse.

Each check corresponds to a shipped incident — the catalogue with the incident
behind every check lives in SKILL.md next to this file; deep background in
docs/website.md and docs/implemented.md §14-16.

Runs from any cwd (paths are anchored to this file's repo). Exit 0 = clean,
exit 1 = failures, one line each.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DIST = ROOT / "website" / "dist"
BASE = "/hellonotes/"
# Deliberately hard-coded rather than read from astro.config.mjs: an audit that
# derives its expectation from the config would validate a misconfigured base.
SITE = "https://hellotham.com"

INLINE_TAGS = r"(?:a|span|code|strong|em|kbd)"


def run_audit():
    """Return (failures, pages_checked)."""
    failures = []

    if not DIST.is_dir():
        return ["website/dist missing — run `npm run build` in website/ first"], 0

    # One traversal: collect page paths and every servable address. GitHub
    # Pages resolves <path>.html before <path>/index.html, so both forms exist.
    pages = []
    existing = set()
    for p in DIST.rglob("*"):
        if not p.is_file():
            continue
        rel = BASE + str(p.relative_to(DIST))
        existing.add(rel)
        if rel.endswith("/index.html"):
            existing.add(rel[: -len("index.html")])
        if rel.endswith(".html"):
            existing.add(rel[: -len(".html")])
            pages.append(p)

    canonicals = set()

    for page in sorted(pages):
        html = page.read_text()
        name = str(page.relative_to(DIST))

        # Base prefix + internal ref resolution.
        refs = re.findall(r'(?:href|src)="([^"]+)"', html)
        for srcset in re.findall(r'srcset="([^"]+)"', html):
            refs += [c.strip().split(" ")[0] for c in srcset.split(",")]
        for u in refs:
            if not u or u.startswith(("http://", "https://", "mailto:", "#", "data:")):
                continue
            if not u.startswith(BASE):
                failures.append(f"{name}: missing base prefix → {u}")
            elif u.split("#")[0] not in existing:
                failures.append(f"{name}: broken internal ref → {u}")

        # Canonical: extensionless, on the custom domain.
        m = re.search(r'<link rel="canonical" href="([^"]+)"', html)
        if not m:
            failures.append(f"{name}: no rel=canonical")
        else:
            c = m.group(1)
            canonicals.add(c)
            if not c.startswith(SITE):
                failures.append(f"{name}: canonical not on custom domain → {c}")
            if c.endswith(".html"):
                failures.append(f"{name}: canonical carries .html → {c}")

        # og:image present and resolving.
        m = re.search(r'property="og:image" content="([^"]+)"', html)
        if not m:
            failures.append(f"{name}: no og:image")
        elif m.group(1).removeprefix(SITE) not in existing:
            failures.append(f"{name}: og:image does not resolve → {m.group(1)}")

        # JSX whitespace collapse, both directions.
        body = html.split("<body", 1)[-1]
        for m in re.finditer(rf"[a-z]{{2,}}<{INLINE_TAGS}\b[^>]*>", body):
            failures.append(f"{name}: space collapsed before tag → …{m.group(0)[:40]}")
        for m in re.finditer(rf"[a-z]{{3,}}</{INLINE_TAGS}>[a-z]{{2,}}", body):
            failures.append(f"{name}: space collapsed after tag → …{m.group(0)[:40]}")

    # Sitemap URLs must equal the set of page canonicals.
    sitemap = DIST / "sitemap.xml"
    if not sitemap.exists():
        failures.append("sitemap.xml missing from dist")
    else:
        locs = set(re.findall(r"<loc>([^<]+)</loc>", sitemap.read_text()))
        for extra in sorted(locs - canonicals):
            failures.append(f"sitemap.xml: URL with no matching canonical → {extra}")
        for missing in sorted(canonicals - locs):
            failures.append(f"sitemap.xml: page canonical absent → {missing}")

    return failures, len(pages)


def main():
    failures, n_pages = run_audit()
    if failures:
        print(f"✗ {len(failures)} failure(s):")
        for f in failures:
            print(f"  {f}")
        sys.exit(1)
    print(f"✓ site audit clean — {n_pages} pages checked (refs, canonicals, sitemap, og:image, whitespace)")


if __name__ == "__main__":
    main()
