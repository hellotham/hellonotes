import type { APIRoute } from 'astro';

/**
 * The sitemap, generated from the pages that actually exist.
 *
 * Hand-rolled rather than using @astrojs/sitemap, which cannot emit the URLs
 * this site needs. Under `build.format: 'file'` the integration hands `serialize`
 * a correct `…/hellonotes/` for the home page and then the underlying `sitemap`
 * package strips the trailing slash on the way out — and `…/hellonotes` **301s**
 * to `…/hellonotes/`. Advertising a redirecting URL is the same mistake as
 * pointing `rel=canonical` at one (see docs/website.md), so every entry here is
 * built with exactly the rule Layout.astro uses for the canonical. The two are
 * verified equal at build time; see the check in docs/website.md.
 */

const BASE = import.meta.env.BASE_URL.replace(/\/$/, '');

/** Every routable page, as a site-root-relative path. */
const routes = Object.keys(import.meta.glob('./**/*.astro'))
  .map((file) =>
    file
      .replace(/^\.\//, '')
      .replace(/\.astro$/, '')
      .replace(/(^|\/)index$/, '')
  )
  .map((path) => (path === '' ? `${BASE}/` : `${BASE}/${path}`))
  .sort();

export const GET: APIRoute = ({ site }) => {
  const urls = routes
    .map((path) => `<url><loc>${new URL(path, site).href}</loc></url>`)
    .join('');

  return new Response(
    `<?xml version="1.0" encoding="UTF-8"?>` +
      `<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${urls}</urlset>`,
    { headers: { 'Content-Type': 'application/xml; charset=utf-8' } }
  );
};
