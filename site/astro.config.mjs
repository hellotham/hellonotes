// @ts-check
import { defineConfig } from 'astro/config';

import tailwindcss from '@tailwindcss/vite';

// https://astro.build/config
export default defineConfig({
  // Project page: https://hellotham.github.io/hellonotes/
  // `site` + `base` make canonical URLs and asset paths resolve under the
  // sub-path. Never hard-code "/hellonotes/" in a template — use the `href()`
  // helper in src/lib/paths.ts, which is built from `import.meta.env.BASE_URL`,
  // so the site still works if the repo (and therefore the base) is renamed.
  site: 'https://hellotham.github.io',
  base: '/hellonotes',
  vite: {
    plugins: [tailwindcss()]
  }
});