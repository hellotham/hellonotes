# The product site (`website/`)

The public site at **<https://hellotham.com/hellonotes/>** — landing page, feature
tour, screenshots, download, an online user manual, and the about / privacy /
support pages Apple's reviewers look for. It lives in [`website/`](../website/) and is
built from source on every push; nothing generated is committed.

| Thing | Value |
|---|---|
| Live URL | <https://hellotham.com/hellonotes/> |
| Source | [`website/`](../website/) |
| Framework | **Astro 7** (static output) |
| CSS | **Tailwind 4** via `@tailwindcss/vite` |
| Deploy | [`.github/workflows/deploy-website.yml`](../.github/workflows/deploy-website.yml) → GitHub Pages |
| Pages mode | **GitHub Actions** (`build_type: workflow`) — *not* a `gh-pages` branch |
| Pages | 16 |
| Publisher | Hello Tham Pty. Ltd. — <https://hellotham.com> |
| DMG hosting | GitHub **Releases**, not the site (see [Distributing the DMG](#distributing-the-dmg)) |

---

## Local development

```bash
cd website
npm install
npm run dev      # http://localhost:4321/hellonotes/
npm run build    # static output → website/dist
npm run preview  # serve the built output
```

The dev server honours `base`, so browse **`/hellonotes/`**, not `/`.

---

## How it deploys

A push to `main` that touches `website/**` (or the workflow itself) triggers
`deploy-website.yml`, which builds with the official **`withastro/action`**
(`path: ./website`) and publishes with **`actions/deploy-pages`**. App-only commits
don't redeploy.

This replaced a legacy setup where the built HTML was committed to a **`gh-pages`
branch** and served directly (`build_type: legacy`). That branch was deleted once
its content was migrated. If Pages ever reverts to branch mode, the site will go
stale silently — check with:

```bash
gh api repos/hellotham/hellonotes/pages --jq '{build_type, html_url}'
# expect: {"build_type":"workflow","html_url":"https://hellotham.com/hellonotes/"}
```

> The API may still report a stale `source.branch: "gh-pages"`. It's inert —
> GitHub ignores `source` entirely when `build_type` is `workflow`.

---

## The two URL traps

Both bite silently — the build succeeds and only the *live* site is wrong.

### 1. `base` — internal links need the `/hellonotes` prefix

This is a **project page** served from a sub-path, so `astro.config.mjs` sets
`base: '/hellonotes'`. A bare `href="/privacy"` would resolve to
`hellotham.com/privacy` — a different site.

**Always build internal links and asset paths with the `href()` helper** in
[`src/lib/paths.ts`](../website/src/lib/paths.ts):

```astro
---
import { href } from '../lib/paths';
---
<a href={href('/privacy')}>Privacy</a>
<img src={href('assets/icon.png')} alt="" />
```

It derives the prefix from `import.meta.env.BASE_URL`, so renaming the repo — or
moving to a custom domain root with `base: '/'` — is a one-line config change
rather than a find-and-replace.

Verify after any build:

```bash
# every root-relative path must start with /hellonotes/
grep -ohE '(href|src)="/[^"]*"' dist/*.html | grep -v '"/hellonotes/'
# → no output
```

### 2. `site` — canonical URLs must use the custom domain

`site` is **`https://hellotham.com`**, not `hellotham.github.io`.

The apex domain is the CNAME of the *user-site* repo
(`hellotham/hellotham.github.io`), and GitHub serves this account's project pages
underneath it — so `hellotham.github.io/hellonotes/` **301s** to the custom
domain. This repo therefore needs **no `CNAME` file of its own**; it inherits.

Pointing `site` at `github.io` still builds and still works, but emits
`canonical`, `og:url` and `og:image` on the *redirecting* domain — bad for SEO
(a canonical should be the final URL) and for link unfurls.

---

## Legacy `.html` URLs — why `build.format: 'file'`

The old site used `privacy.html` / `support.html`, and those URLs are in the wild
— **App Store Connect's Privacy Policy and Support URL fields among them**.

`astro.config.mjs` sets **`build: { format: 'file' }`**, so Astro emits
`dist/privacy.html` as the *real page* rather than `dist/privacy/index.html`.
GitHub Pages resolves `<path>.html` **before** `<path>/index.html`, so a single
artefact answers both URL forms — no redirects at all:

```
/hellonotes/privacy       → privacy.html ✓   (extensionless, what we link/document)
/hellonotes/privacy.html  → privacy.html ✓   (the legacy URL)
```

**Two redirect approaches were tried first and both fail** — don't reintroduce
them:

1. **Astro's `redirects` config** honours this same `build.format`. With the
   default `'directory'`, a key of `'/privacy.html'` emits a `privacy.html/`
   *directory*: `/privacy.html/` works, `/privacy.html` 404s — and the URL in the
   wild has no trailing slash.
2. **Hand-written redirect files in `public/`** are worse: `public/privacy.html`
   *shadows* the real `/privacy` route by the resolution order above, so
   `/privacy` serves the redirect, which points back at `/privacy` — an infinite
   loop. This shipped briefly and broke both doc pages live.

The URLs registered with Apple are listed in
[production.md](production.md) §4/§5 and should stay in sync with the routes here.

---

## Site map

All 16 routes, and what each one is for. `NAV` and `MANUAL` in
[`src/lib/site.ts`](../website/src/lib/site.ts) are the single source of truth for
the nav bar and the manual's ordering, prev/next links and index cards — add a
manual page there and the navigation follows automatically.

| Route | Page | Purpose |
|---|---|---|
| `/` | `index.astro` | Landing page — hero, six-card feature grid, screenshot showcase, privacy pitch, download CTA |
| `/features` | `features.astro` | The long-form feature tour, grouped by task, alternating with screenshots |
| `/screenshots` | `screenshots.astro` | Full-width captioned gallery |
| `/download` | `download.astro` | Download button, requirements, install steps, checksum + `spctl` verification |
| `/manual` | `manual/index.astro` | Manual contents — one card per section |
| `/manual/getting-started` | | Opening a collection, the layout, first note, saving |
| `/manual/editor` | | Live Markdown, view modes, maths, diagrams, callouts, find, images, export |
| `/manual/links-and-graph` | | Wiki-links, aliases, backlinks, transclusion, graph, mind map |
| `/manual/organising` | | Search, Open Quickly, tags, bookmarks, daily notes, templates |
| `/manual/ai` | | Apple Intelligence, Ask Library, the Assistant, bring-your-own-model |
| `/manual/cloud` | | iCloud / Dropbox / Box / OneDrive / Google Drive, and the two ways to use them |
| `/manual/git` | | Init, identity, commits, history, remotes, current limits |
| `/manual/shortcuts` | | Keyboard reference |
| `/about` | `about.astro` | What the app is, who publishes it, how it's built — points at Hello Tham |
| `/privacy` | `privacy.astro` | Privacy policy — the URL registered with App Store Connect |
| `/support` | `support.astro` | Support / FAQ — the URL registered with App Store Connect |

> **Keyboard shortcuts must be copied from the app, never from memory.**
> `manual/shortcuts.astro` was built by reading the `.keyboardShortcut(…)`
> modifiers in `HelloNotes/App/AppCommands.swift`. Two plausible-sounding
> bindings were invented on a first pass and had to be removed — if you add a
> row, grep for it first.

---

## Distributing the DMG

The download button points at
`github.com/hellotham/hellonotes/releases/latest/download/HelloNotes.dmg`, so
**shipping a new build means publishing a GitHub Release** — the site itself is
never rebuilt for a release, and `latest` re-points automatically.

The disk image is deliberately **not** committed to `website/public/`: at ~35 MB
it would be added to the git history permanently and re-uploaded in every Pages
artefact.

After notarising (see [production.md](production.md)), publish and update the
site's metadata together:

```bash
shasum -a 256 dist/HelloNotes.dmg          # → paste into DOWNLOAD.sha256
gh release create v1.0 dist/HelloNotes.dmg --title "HelloNotes 1.0" --notes-file …
```

`APP.version`, `DOWNLOAD.size` and `DOWNLOAD.sha256` in `src/lib/site.ts` are
what the download page prints for people verifying the file by hand — they must
match the artefact actually attached to the release.

---

## Structure

```
website/
  astro.config.mjs      site + base + build.format + the Tailwind Vite plugin
  src/
    layouts/
      Layout.astro      <head>, canonical + OG/Twitter meta, <slot/>
      PageLayout.astro  Layout + Nav/Footer + the page header band
      ManualLayout.astro PageLayout + manual sidebar, prose and prev/next
    components/
      Nav.astro         sticky nav — inline links ≥md, a <details> menu below
      Footer.astro      publisher line, link columns, © year
      Prose.astro       the one place long-form typography is styled
    pages/
      index.astro       landing page
      features.astro    feature tour
      screenshots.astro gallery
      download.astro    download + install + verification
      about.astro       about / publisher
      privacy.astro     privacy policy
      support.astro     support + FAQ
      manual/           index + eight manual sections
    lib/
      paths.ts          href() — the base-aware URL builder
      site.ts           app, publisher, download and navigation metadata
    assets/screens/     screenshots, optimised at build time by astro:assets
    styles/global.css   @import "tailwindcss" + @theme tokens + @utility gradients
  public/assets/        app icon (served verbatim — it needs a stable URL)
```

### Images

Screenshots live in `src/assets/`, **not** `public/`, so `astro:assets`
processes them: the `<Image>` component emits sized, hashed WebP (a 3.1 MB PNG
becomes 10–84 KB) with intrinsic `width`/`height` so nothing shifts as the page
loads. Only the app icon stays in `public/` — the nav, footer and OG tags all
want one stable, unhashed URL for it.

### Styling notes

Tailwind 4 is **CSS-first**: there is **no `tailwind.config.js`**. The palette
ported from the original stylesheet lives in an `@theme` block in
`src/styles/global.css`, which makes the tokens available as ordinary utilities
(`bg-card`, `text-muted`, `border-line`, `rounded-card`). The brand gradient and
the gradient-filled text are `@utility` rules.

Two base rules in that file are load-bearing: headings get `line-height: 1.15`
(the `body` value of 1.6 leaves wrapped headings looking broken on a phone), and
the `<details>` mobile menu's marker is hidden. The menu needs no JavaScript —
it closes on its own because following a link reloads the page.

The old `@astrojs/tailwind` integration is **deprecated** — this project uses the
`@tailwindcss/vite` plugin, registered under `vite.plugins` in `astro.config.mjs`
(which is what `npx astro add tailwind` sets up).

---

## Checking a build before pushing

```bash
cd website && npm run build

# 1. every root-relative path carries the base
grep -ohE '(href|src)="/[^"]*"' dist/**/*.html dist/*.html | grep -v '"/hellonotes/'

# 2. canonicals are extensionless and on the custom domain
grep -h 'rel="canonical"' dist/*.html | head

# 3. no internal link 404s — resolve every href against the emitted files
```

Both URL traps above are invisible at build time; only the live site is wrong.
