## Development

When starting the dev server, use background mode:

```
astro dev --background
```

Manage the background server with `astro dev stop`, `astro dev status`, and `astro dev logs`.

## Before pushing

```bash
npm run build && python3 ../.claude/skills/site-audit/audit.py
```

Every check in the audit is an incident that shipped with a green build. Deep
reference: `../docs/website.md`.

## Project rules (each learned the hard way)

- Project page under `base: '/hellonotes'` — build every internal link/asset path
  with `href()` from `src/lib/paths.ts`; a bare `href="/x"` is someone else's page.
- Canonicals/OG URLs use the custom domain (`hellotham.com`), never `github.io` (it 301s).
- `build.format: 'file'` keeps legacy `/privacy.html` URLs working — do not add
  redirects (both known approaches loop or 404; see docs/website.md).
- `og:image` lives in `public/` only — `src/assets/` names are content-hashed and
  social crawlers cache by URL (this 404'd on every page once).
- No colour literals outside `src/styles/global.css` — the palette is `light-dark()`
  tokens; `light-dark()` takes colours, not gradients (an invalid value renders
  gradient text invisible).
- Astro applies JSX whitespace rules in any element with an expression: a newline
  before an inline tag eats the space — use `{' '}` (28 of these shipped once).
- Screenshots pair via `src/lib/screens.ts` + `Shot.astro`; app metadata and the
  download checksum live in `src/lib/site.ts` and must match the shipped DMG.
  **Captions are composited into the image**, so a capture must match its scene's
  caption — scene 05 is "Ask your library", and pointing it at anything else puts
  a false claim on a public page rather than a cosmetic mismatch. The raw
  captures live in `../assets/screenshots-raw/` and are committed; compositing is
  one-way. `make-screenshots.py` also writes `public/assets/og.png` *outside* its
  output directory, so there is no such thing as a dry run into a scratch dir.

## Documentation

Full documentation: https://docs.astro.build

Consult these guides before working on related tasks:

- [Adding pages, dynamic routes, or middleware](https://docs.astro.build/en/guides/routing/)
- [Working with Astro components](https://docs.astro.build/en/basics/astro-components/)
- [Using React, Vue, Svelte, or other framework components](https://docs.astro.build/en/guides/framework-components/)
- [Adding or managing content](https://docs.astro.build/en/guides/content-collections/)
- [Adding styles or using Tailwind](https://docs.astro.build/en/guides/styling/)
- [Supporting multiple languages](https://docs.astro.build/en/guides/internationalization/)
