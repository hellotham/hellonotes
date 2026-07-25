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

  // NOTE: legacy /privacy.html and /support.html redirects are NOT declared here.
  // Astro's `redirects` honours build.format ('directory' by default), so a key
  // of '/privacy.html' emits dist/privacy.html/index.html — a *directory*. That
  // serves /privacy.html/ but 404s on /privacy.html, which is the URL actually in
  // the wild. They're plain files in public/ instead (public/privacy.html), which
  // is copied verbatim and therefore lands as a real file.
  vite: {
    plugins: [tailwindcss()]
  }
});