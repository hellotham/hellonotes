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
| Screenshots | 5 scenes × light + dark, built by [`scripts/make-screenshots.py`](../scripts/make-screenshots.py) |
| Appearance | Auto / Light / Dark, toggled in the nav — see [Theming](#theming) |
| Sitemap | hand-rolled [`src/pages/sitemap.xml.ts`](../website/src/pages/sitemap.xml.ts) — see [Sitemap](#sitemap) |

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

## Screenshots — light and dark

Every scene is shot **twice**, once with the app's Appearance set to Light and
once to Dark, from the same SampleVault, the same window geometry and the same
note. Only the app's own theme differs between a pair, which is what makes the
comparison worth showing at all.

[`src/lib/screens.ts`](../website/src/lib/screens.ts) is the registry: one entry
per scene, holding both variants plus the alt text and caption. Pages reference
scenes by id (`byId('graph')`) rather than importing files, so re-shooting a
scene never means touching a page.

Two presentations, deliberately different:

- **`screenshots.astro`** shows an explicit **Light / Dark switch**, because the
  point of that page is to show you both. It is two radio inputs styled as a
  segmented control, driving the figures through `:has()` — no JavaScript, and
  it defaults to whichever appearance the reader's own system uses.
- **`index.astro` and `features.astro`** use
  [`Shot.astro`](../website/src/components/Shot.astro), which emits a `<picture>`
  that follows `prefers-color-scheme` silently. `<Image>` cannot do this — art
  direction needs two sources behind a media query — so `Shot` builds the srcsets
  with `getImage()` and hand-writes the element. The `<img>` fallback is the dark
  variant, matching the page chrome.

### Re-shooting them

The capture is manual. **Screen Recording must be granted to the process running
the capture** (System Settings ▸ Privacy & Security ▸ Screen & System Audio
Recording), and the grant only applies to a *fresh* process — quit and reopen
after enabling it. Without it `screencapture` returns pure black full-screen,
`screencapture -l` fails with "could not create image from window", and
ScreenCaptureKit-based tools report "permission missing or SCContentFilter
failure". A black 107 KB PNG where a desktop should be is the tell.

Traps, each one paid for:

1. **Use SampleVault, never a real vault.** The first pass caught the author's
   own 2,000-note collection with personal folder names legible in the sidebar.
   Open SampleVault, close every other collection, and **put the library back
   afterwards** — closing a collection is a change to the user's state.
2. **Capture with `screencapture -l <windowID>`, never `-R`.** It takes the one
   window through the real compositor, so materials and vibrancy render
   truthfully and nothing can float over the frame. It also means the desktop
   *around* the window never appears — if you see wallpaper in a full-screen
   grab, that is outside the window and will not be in the plate.
3. **Synthetic `click at` events do not register in this SwiftUI app.** Drive it
   with real clicks. The ⊗ on a collection's group row ignores them too; its
   right-click menu ▸ Close Collection works.
4. **Raw files are `light_1.png` … `dark_5.png`** — single digit, no zero
   padding. The script skips anything else silently and still writes `og.png`,
   so a run that "succeeded" can have composited nothing.

**Shoot at 1470×852**, not 1470×923: 923 only fits with the Dock hidden, and the
compositor scales to fit, so any *consistent* size works.

**Scene 5 (Ask Library) needs no API keys.** Apple Intelligence is the default
intelligence provider, so the answer is generated on-device. Two things to know:

- The on-device model is **not deterministic and not always right**. Across four
  runs of the same question it produced a clean answer, a verbatim dump of
  README, and one that invented a "Backlinks button in the editor bar" that does
  not exist. **Read the answer before shipping it** — a hallucination in a
  marketing screenshot is a false claim about the product.
- Get one good answer, then **switch the app's theme with the answer still on
  screen** rather than re-asking. The text survives the appearance change, so
  the light/dark pair matches exactly — which is the whole premise of the pair.

The script composites the brand gradient, the caption and the window plate with
rounded corners and a drop shadow — and also writes `public/assets/og.png`. The
gradient follows the CSS convention (0° up, clockwise); getting the angle or the
gradient-line length wrong pushes the violet stop off-canvas, which is what the
first attempt did.

---

## SEO

| Tag | Where it comes from |
|---|---|
| `title`, `description` | Per page, via `PageLayout` |
| `rel=canonical` | Normalised in `Layout.astro` — extensionless, custom domain |
| `og:*`, `twitter:*` | `Layout.astro`, including `og:image:width/height/alt` |
| `og:image` | `public/assets/og.png` — 1200×630, generated by the screenshot script |
| JSON-LD `SoftwareApplication` | `Layout.astro`, on the home and download pages only |
| `sitemap.xml` | `src/pages/sitemap.xml.ts` |
| `robots.txt` | `public/robots.txt` |

**`og:image` must be a file in `public/`, never one processed by `astro:assets`.**
Asset filenames are content-hashed, so they change whenever the image is
re-exported, and social crawlers cache by URL. This was a live bug: the default
pointed at `assets/shot_02.png`, which had been moved into `src/assets/` — so
**every page's OG image 404'd** while still validating fine at build time.

### Sitemap

`@astrojs/sitemap` cannot emit the URLs this site needs, so the sitemap is a
hand-written endpoint. Under `build.format: 'file'` the integration hands
`serialize` a correct `…/hellonotes/` for the home page and then the underlying
`sitemap` package strips the trailing slash on the way out — and `…/hellonotes`
**301s** to `…/hellonotes/`. Advertising a redirecting URL is the same mistake as
pointing `rel=canonical` at one.

The endpoint enumerates routes with `import.meta.glob` and applies exactly the
rule `Layout.astro` uses for the canonical, so the two sets are identical:

`audit.py` (the `/site-audit` skill) asserts this equality on every run.

---

## Theming

The site follows the reader's system appearance and can be pinned to Light or
Dark from the control in the nav. Three moving parts:

**1. `light-dark()` carries the palette.** Every colour token in
`src/styles/global.css` is declared once as `light-dark(<light>, <dark>)`, which
resolves against the element's `color-scheme`. Switching appearance is therefore
one declaration, not a duplicated palette:

```css
:root                    { color-scheme: light dark; }  /* follow the system */
:root[data-theme=light]  { color-scheme: light; }
:root[data-theme=dark]   { color-scheme: dark; }
```

`color-scheme` also fixes form controls, scrollbars and the default canvas for
free. The `@theme` block above it declares the **dark** values as plain hex, so
a browser without `light-dark()` skips the `@supports` block and keeps the
site's original dark appearance rather than something broken.

> **`light-dark()` takes colours, not values.** Wrapping a whole
> `linear-gradient(...)` in it makes the declaration invalid, which silently
> turned the hero's gradient-filled text transparent. Put it on each *stop*.

**2. Tokens are semantic, and there are no colour literals outside `global.css`.**
`bg`, `bg2`, `card`, `ink`, `body`, `muted`, `line`, `edge`, `chip`, `link`,
`emphasis`, plus `shadow-plate|card|cta|menu`. The rewrite that introduced them
replaced `text-[#d7d3e6]` → `text-body`, `hover:text-white` →
`hover:text-emphasis`, `bg-white/5` → `bg-chip`, `border-[#4a4360]` →
`border-edge` and the four hard-coded shadows. **`text-white` survives only on
`.brand-gradient` buttons**, where the gradient is dark in both appearances.

**3. The choice is applied before first paint.**
[`ThemeScript.astro`](../website/src/components/ThemeScript.astro) is `is:inline`
in `<head>`; anything deferred or bundled runs after the browser has painted the
default, which is the flash of wrong theme. `localStorage.theme` holds `light` or
`dark`; **"Auto" is the absence of a value**, not a third one, so a reader who
never touches the control keeps tracking their system.

[`ThemeToggle.astro`](../website/src/components/ThemeToggle.astro) is a
radiogroup of three buttons (rendered twice — desktop bar and mobile menu — and
kept in sync), and it also rewrites the `theme-color` meta.

### Appearance-specific content

Screenshots exist in both appearances, so `.only-light` / `.only-dark` in
`global.css` reveal one. They are driven by the *same* conditions as the palette,
so the two can never disagree — which is why
[`Shot.astro`](../website/src/components/Shot.astro) is no longer a `<picture>`:
a `prefers-color-scheme` source only ever sees the **system** setting, so pinning
light on a dark Mac left dark screenshots on a light page. The hidden variant is
`display: none`, and a lazy `<img>` in a `display:none` subtree is never fetched.

Those rules are **unlayered**, so they beat Tailwind's utilities layer — don't
also put a `display` utility on the same element.

### Checking both appearances

Contrast, measured on the built site (AA needs 4.5:1 for body text, 3:1 for large):

| Token | Light | Dark |
|---|---|---|
| `ink` | 17.6:1 | 16.4:1 |
| `body` | 11.1:1 | 13.4:1 |
| `muted` | 6.0:1 | 7.3:1 |
| `link` | 5.9:1 | 10.3:1 |
| `emphasis` | 19.1:1 | 19.6:1 |
| gradient text (worst stop) | 4.4:1 | 3.4:1 |

The light gradient uses **deeper stops** than the button gradient: the amber end
`#f59e0b` is only 2.1:1 on a white page, below the 3:1 large-text floor.

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
      Shot.astro        screenshot pair; CSS reveals the one matching the theme
      ThemeScript.astro pre-paint appearance script (inline, in <head>)
      ThemeToggle.astro Auto / Light / Dark radiogroup
    pages/
      index.astro       landing page
      features.astro    feature tour
      screenshots.astro gallery
      download.astro    download + install + verification
      about.astro       about / publisher
      privacy.astro     privacy policy
      support.astro     support + FAQ
      manual/           index + eight manual sections
      sitemap.xml.ts    the sitemap endpoint (see SEO, above)
    lib/
      paths.ts          href() — the base-aware URL builder
      site.ts           app, publisher, download and navigation metadata
      screens.ts        the screenshot registry — one entry per scene, both variants
    assets/screens/     light_0N.png + dark_0N.png, optimised by astro:assets
    styles/global.css   @import "tailwindcss" + @theme tokens + @utility gradients
  public/
    assets/icon.png     app icon   ) served verbatim — both need stable,
    assets/og.png       OG card    ) unhashed URLs
    robots.txt
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
python3 .claude/skills/site-audit/audit.py   # from the repo root (any cwd works)
```

The audit covers base prefixes, internal ref resolution, canonicals,
sitemap/canonical agreement, og:image, and JSX whitespace collapse — every
check is an incident that shipped with a green build. The `/site-audit` skill
documents the incident behind each check; a PostToolUse hook also runs this
automatically after edits to website build inputs.

Both URL traps above are invisible at build time; only the live site is wrong.
