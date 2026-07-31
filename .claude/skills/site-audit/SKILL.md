---
name: site-audit
description: Audit the built website for the silent-failure classes this project has actually shipped — base-prefix drift, broken refs, canonical/sitemap divergence, og:image 404s, JSX whitespace collapse. Run before any push that touches website/.
---

# Website audit

Build the site, then run the bundled checker:

```bash
cd website && npm run build
cd .. && python3 .claude/skills/site-audit/audit.py
```

Exit 0 is clean; exit 1 prints one line per failure with the page and detail.

## Why these exact checks

Every check corresponds to an incident that **shipped or nearly shipped** from
this repository. None of them fail the Astro build — the build stays green and
only the live site is wrong, which is what makes them worth automating:

| Check | The incident |
|---|---|
| base prefix | Project page under `/hellonotes`; a bare `href="/privacy"` is someone else's page. Use `href()` from `src/lib/paths.ts`. |
| broken refs | the generalisation of the og:image incident below — any href/src/srcset naming a moved or renamed emitted file. |
| canonicals | First emitted on `github.io` (a redirecting domain), later with `.html` forms after `build.format: 'file'`. |
| sitemap == canonicals | `@astrojs/sitemap` stripped the home page's trailing slash, advertising a URL that 301s. |
| og:image resolves | Social crawlers cache by URL; the image must live in `public/` (stable name), never `src/assets/` (content-hashed). |
| whitespace collapse | "published byHello Tham" on all 16 pages — Astro applies JSX whitespace rules inside any element containing an expression. Fix with `{' '}`. |

Full background: [docs/website.md](../../../docs/website.md) ("The two URL
traps", "SEO", "Checking a build before pushing") and
[docs/implemented.md](../../../docs/implemented.md) §14–16.

## When a check fails

Fix the source, not the audit. The one legitimate reason to touch `audit.py`
is a deliberate structural change (e.g. the site moves off the `/hellonotes`
base) — in which case update `docs/website.md` in the same commit.
