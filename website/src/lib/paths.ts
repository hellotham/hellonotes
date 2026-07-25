/**
 * Build a site-absolute URL that respects Astro's configured `base`.
 *
 * The site is a project page served from a sub-path
 * (https://hellotham.com/hellonotes/), so every internal link and asset must be
 * prefixed with the base — a bare "/privacy" would resolve against the domain
 * root, which is a different site. Deriving the prefix from
 * `import.meta.env.BASE_URL` (rather than hard-coding "/hellonotes/") means
 * renaming the repo, or moving to a domain root with `base: '/'`, needs only an
 * astro.config change.
 *
 *   href('/')            → '/hellonotes/'
 *   href('/privacy')     → '/hellonotes/privacy'
 *   href('assets/x.png') → '/hellonotes/assets/x.png'
 */
export function href(path = '/'): string {
  const base = import.meta.env.BASE_URL; // '/hellonotes/' (Astro guarantees a trailing slash)
  const clean = path.replace(/^\/+/, '');
  return base.endsWith('/') ? base + clean : `${base}/${clean}`;
}
