# The marketing site (`site/`)

The public site at **<https://hellotham.com/hellonotes/>** — home, privacy and
support pages. It lives in [`site/`](../site/) and is built from source on every
push; nothing generated is committed.

| Thing | Value |
|---|---|
| Live URL | <https://hellotham.com/hellonotes/> |
| Source | [`site/`](../site/) |
| Framework | **Astro 7** (static output) |
| CSS | **Tailwind 4** via `@tailwindcss/vite` |
| Deploy | [`.github/workflows/deploy-site.yml`](../.github/workflows/deploy-site.yml) → GitHub Pages |
| Pages mode | **GitHub Actions** (`build_type: workflow`) — *not* a `gh-pages` branch |

---

## Local development

```bash
cd site
npm install
npm run dev      # http://localhost:4321/hellonotes/
npm run build    # static output → site/dist
npm run preview  # serve the built output
```

The dev server honours `base`, so browse **`/hellonotes/`**, not `/`.

---

## How it deploys

A push to `main` that touches `site/**` (or the workflow itself) triggers
`deploy-site.yml`, which builds with the official **`withastro/action`**
(`path: ./site`) and publishes with **`actions/deploy-pages`**. App-only commits
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
[`src/lib/paths.ts`](../site/src/lib/paths.ts):

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
grep -ohE '(href|src)="/[^"]*"' dist/index.html dist/*/index.html | grep -v '"/hellonotes/'
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

## Legacy `.html` redirects

The old site used `privacy.html` / `support.html`. Those URLs are in the wild —
**App Store Connect's Privacy Policy and Support URL fields among them** — and
Astro serves extensionless routes, so they'd 404. `astro.config.mjs` maps them:

```js
redirects: {
  '/privacy.html': `${BASE}/privacy`,
  '/support.html': `${BASE}/support`,
}
```

Two gotchas encoded there:
- Redirect **targets are not base-prefixed automatically** (keys are, since they
  land at the base root) — hence the explicit `${BASE}`.
- **Never add `'/index.html'`** — it creates a `dist/index.html` *directory* and
  clobbers the real homepage.

The URLs registered with Apple are listed in
[production.md](production.md) §4/§5 and should stay in sync with the routes here.

---

## Structure

```
site/
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
