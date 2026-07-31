#!/usr/bin/env python3
"""
Audit the built HelloNotes website (website/dist) for the silent failures this
project has actually shipped. Every check here corresponds to a real incident
recorded in docs/website.md or docs/implemented.md §14-16:

  1. base-prefix   — a bare href="/privacy" resolves to hellotham.com/privacy,
                     someone else's page. Every root-relative ref must carry
                     /hellonotes/.
  2. broken-refs   — internal href/src/srcset must resolve to an emitted file
                     (GitHub Pages resolves <path>.html before <path>/index.html,
                     so both forms count as existing).
  3. canonicals    — extensionless, on the custom domain. github.io merely 301s;
                     a canonical must name the final URL.
  4. sitemap       — sitemap.xml URLs must EQUAL the set of page canonicals.
                     (@astrojs/sitemap emitted a redirecting URL; the hand-rolled
                     endpoint exists so these can't diverge — verify anyway.)
  5. og-image      — present on every page and pointing at a file that exists.
                     Once 404'd on every page after the image moved out of
                     public/ (hashed asset names change on re-export).
  6. whitespace    — Astro applies JSX whitespace rules inside any element with
                     an expression, collapsing "published by\n<a>" to
                     "published byHello Tham". 28 of these shipped. Checked in
                     both directions (word<tag and tag>word).

Exit code 0 = clean, 1 = failures (each printed with file and detail).
Run from the repo root: python3 .claude/skills/site-audit/audit.py
"""

import re
import sys
from pathlib import Path

BASE = "/hellonotes/"
SITE = "https://hellotham.com"
DIST = Path("website/dist")

INLINE_TAGS = r"(?:a|span|code|strong|em|kbd)"


def fail_list():
    failures = []

    if not DIST.is_dir():
        return ["website/dist missing — run `npm run build` in website/ first"]

    pages = {p: p.read_text() for p in DIST.rglob("*.html")}

    # Everything that exists, addressed every way GitHub Pages will serve it.
    existing = set()
    for p in DIST.rglob("*"):
        if p.is_file():
            rel = BASE + str(p.relative_to(DIST))
            existing.add(rel)
            if rel.endswith("/index.html"):
                existing.add(rel[: -len("index.html")])
            if rel.endswith(".html"):
                existing.add(rel[: -len(".html")])

    canonicals = set()

    for page, html in sorted(pages.items()):
        name = str(page.relative_to(DIST))

        # -- 1 & 2: reference resolution ------------------------------------
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

        # -- 3: canonical ---------------------------------------------------
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

        # -- 5: og:image ----------------------------------------------------
        m = re.search(r'property="og:image" content="([^"]+)"', html)
        if not m:
            failures.append(f"{name}: no og:image")
        else:
            path = m.group(1).removeprefix(SITE)
            if path.split("#")[0] not in existing:
                failures.append(f"{name}: og:image does not resolve → {m.group(1)}")

        # -- 6: whitespace collapses ----------------------------------------
        body = html.split("<body", 1)[-1]
        for m in re.finditer(rf"([a-z]{{2,}})<{INLINE_TAGS}\b[^>]*>", body):
            failures.append(f"{name}: space collapsed before tag → …{m.group(0)[:40]}")
        for m in re.finditer(rf"[a-z]{{3,}}</{INLINE_TAGS}>([a-z]{{2,}})", body):
            failures.append(f"{name}: space collapsed after tag → …{m.group(0)[:40]}")

    # -- 4: sitemap == canonicals -------------------------------------------
    sitemap = DIST / "sitemap.xml"
    if not sitemap.exists():
        failures.append("sitemap.xml missing from dist")
    else:
        locs = set(re.findall(r"<loc>([^<]+)</loc>", sitemap.read_text()))
        for extra in sorted(locs - canonicals):
            failures.append(f"sitemap.xml: URL with no matching canonical → {extra}")
        for missing in sorted(canonicals - locs):
            failures.append(f"sitemap.xml: page canonical absent → {missing}")

    return failures


def main():
    failures = fail_list()
    if failures:
        print(f"✗ {len(failures)} failure(s):")
        for f in failures:
            print(f"  {f}")
        sys.exit(1)
    n_pages = len(list(DIST.rglob("*.html")))
    print(f"✓ site audit clean — {n_pages} pages checked (refs, canonicals, sitemap, og:image, whitespace)")


if __name__ == "__main__":
    main()
