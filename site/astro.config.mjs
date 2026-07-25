// @ts-check
import { defineConfig } from 'astro/config';

import tailwindcss from '@tailwindcss/vite';

/** Sub-path this project page is served from. Single source of truth for the
 *  `base` and for redirect targets (which Astro does not base-prefix). */
const BASE = '/hellonotes';

// https://astro.build/config
export default defineConfig({
  // Public URL: https://hellotham.com/hellonotes/
  //
  // `site` is the CUSTOM domain, not hellotham.github.io. The apex domain is the
  // CNAME of the *user-site* repo (hellotham/hellotham.github.io), and GitHub
  // serves project pages of the same account underneath it — so github.io URLs
  // 301 here. Pointing `site` at github.io would emit canonical/og:url/og:image
  // on the redirecting domain, which is wrong for SEO and link unfurls.
  // (This repo needs no CNAME file of its own; it inherits the domain.)
  //
  // `site` + `base` make canonical URLs and asset paths resolve under the
  // sub-path. Never hard-code "/hellonotes/" in a template — use the `href()`
  // helper in src/lib/paths.ts, which is built from `import.meta.env.BASE_URL`,
  // so the site still works if the repo (and therefore the base) is renamed.
  site: 'https://hellotham.com',
  base: BASE,

  // Emit dist/privacy.html rather than dist/privacy/index.html.
  //
  // This is what keeps the OLD urls working. The previous site used
  // /privacy.html and /support.html, and those are in the wild — App Store
  // Connect's Privacy Policy and Support URL fields among them. GitHub Pages
  // resolves `<path>.html` BEFORE `<path>/index.html`, so with 'file' format a
  // single artefact answers both forms:
  //     /hellonotes/privacy       → privacy.html ✓
  //     /hellonotes/privacy.html  → privacy.html ✓
  //
  // Redirects were tried first and are a trap here. Astro's `redirects` honours
  // this same format setting, so with the default 'directory' a key of
  // '/privacy.html' emits a privacy.html/ *directory* (serves /privacy.html/,
  // 404s /privacy.html). Hand-written redirect files in public/ are worse still:
  // public/privacy.html SHADOWS the real /privacy route by the resolution order
  // above, producing a redirect loop.
  build: { format: 'file' },
  vite: {
    plugins: [tailwindcss()]
  }
});