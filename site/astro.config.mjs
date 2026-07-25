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

  // The old hand-written site used .html extensions. Those URLs are in the wild
  // — App Store Connect's Privacy Policy / Support URL fields among them — and
  // would otherwise 404 now that Astro serves extensionless routes. Astro emits
  // a small meta-refresh page for each in a static build.
  //
  // Keys are relative to `base` (they land at dist/, which *is* the base root),
  // but TARGETS are not base-prefixed automatically — a bare '/privacy' would
  // point at hellotham.com/privacy, i.e. the wrong site. Hence the explicit
  // ${BASE}. (No '/index.html' entry: it would create a dist/index.html
  // *directory* and clobber the real homepage.)
  redirects: {
    '/privacy.html': `${BASE}/privacy`,
    '/support.html': `${BASE}/support`,
  },
  vite: {
    plugins: [tailwindcss()]
  }
});