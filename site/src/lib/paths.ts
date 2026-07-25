/**
 * Build a site-absolute URL that respects Astro's configured `base`.
 *
 * The site deploys to a project page (https://hellotham.github.io/hellonotes/),
 * so every internal link and asset must be prefixed with the base — a bare
 * "/privacy" would 404 against the domain root. Deriving it from
 * `import.meta.env.BASE_URL` (rather than hard-coding "/hellonotes/") means
 * renaming the repo, or moving to a custom domain with `base: '/'`, needs only
 * an astro.config change.
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
