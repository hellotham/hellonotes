# The marketing site (`website/`)

The public site at **<https://hellotham.com/hellonotes/>** — home, privacy and
support pages. It lives in [`website/`](../website/) and is built from source on every
push; nothing generated is committed.

| Thing | Value |
|---|---|
| Live URL | <https://hellotham.com/hellonotes/> |
| Source | [`website/`](../website/) |
| Framework | **Astro 7** (static output) |
| CSS | **Tailwind 4** via `@tailwindcss/vite` |
| Deploy | [`.github/workflows/deploy-website.yml`](../.github/workflows/deploy-website.yml) → GitHub Pages |
| Pages mode | **GitHub Actions** (`build_type: workflow`) — *not* a `gh-pages` branch |

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

## Structure

```
website/
  astro.config.mjs      site + base + redirects + the Tailwind Vite plugin
  src/
    layouts/
      Layout.astro      <head>, canonical + OG/Twitter meta, <slot/>
      DocLayout.astro   Layout + Nav/Footer + prose styling (privacy, support)
    components/
      Nav.astro         sticky nav; links resolved through href()
      Footer.astro      badge + links + © year
    pages/
      index.astro       home — feature grid and screenshots are data arrays
      privacy.astro     privacy policy
      support.astro     support / FAQ
    lib/paths.ts        href() — the base-aware URL builder
    styles/global.css   @import "tailwindcss" + @theme tokens + @utility gradients
  public/assets/        app icon + five screenshots (served verbatim)
```

### Styling notes

Tailwind 4 is **CSS-first**: there is **no `tailwind.config.js`**. The palette
ported from the original stylesheet lives in an `@theme` block in
`src/styles/global.css`, which makes the tokens available as ordinary utilities
(`bg-card`, `text-muted`, `border-line`, `rounded-card`). The brand gradient and
the gradient-filled text are `@utility` rules.

The old `@astrojs/tailwind` integration is **deprecated** — this project uses the
`@tailwindcss/vite` plugin, registered under `vite.plugins` in `astro.config.mjs`
(which is what `npx astro add tailwind` sets up).
