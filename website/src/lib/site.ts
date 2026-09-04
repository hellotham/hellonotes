/**
 * Site-wide facts. Kept in one place so a release only touches this file —
 * the version, download link and checksum appear on several pages.
 */

export const APP = {
  name: 'HelloNotes',
  tagline: 'Think in plain Markdown.',
  version: '1.3.2',
  /** The Mac floor. Also the DMG's requirement — that channel is Mac-only. */
  minMacOS: 'macOS 26.5 or later',
  minIOS: 'iOS & iPadOS 26.5 or later',
  /**
   * Both floors in one phrase, for the places that name the requirement once.
   * `minOS` used to be the single Mac string and is deliberately gone rather
   * than kept as an alias: every remaining reader had to be looked at, because
   * a Mac-only sentence on a page that now also sells an iPhone app is wrong in
   * a way no build catches.
   */
  platforms: 'macOS, iOS & iPadOS 26.5 or later',
  /** Universal binary — verified with `lipo -info` on the shipped DMG. */
  architectures: 'Apple silicon & Intel',
} as const;

/**
 * The App Store listing. One App Store Connect record ships both platforms, so
 * both links carry the same id — `mt=12` is what selects the Mac App Store.
 *
 * These 404 until App Review approves the version, which is why this whole
 * change is staged rather than deployed: pushing anything under `website/**`
 * publishes the site (see .github/workflows/deploy-website.yml), and a dead
 * store link on the front page is worse than no link at all.
 */
export const APP_STORE = {
  id: '6803259848',
  ios: 'https://apps.apple.com/app/id6803259848',
  mac: 'https://apps.apple.com/app/id6803259848?mt=12',
} as const;

export const PUBLISHER = {
  name: 'Hello Tham',
  legalName: 'Hello Tham Pty. Ltd.',
  site: 'https://hellotham.com',
  email: 'info@hellotham.com',
} as const;

export const REPO = 'https://github.com/hellotham/hellonotes';

export const DOWNLOAD = {
  /** Release assets live on GitHub Releases — a 35 MB binary does not belong in
   *  the site repo, where it would bloat every clone forever. */
  url: `${REPO}/releases/latest/download/HelloNotes.dmg`,
  releasesPage: `${REPO}/releases/latest`,
  fileName: 'HelloNotes.dmg',
  size: '40.0 MB',
  sha256: '0c70b7b06f5b048406c670ab4cc53d237291f4b4a6c14aa9ce3a50ccec6900e4',
} as const;

/** Primary nav. Secondary/legal links live in the footer. */
export const NAV = [
  { label: 'Features', href: '/features' },
  { label: 'Screenshots', href: '/screenshots' },
  { label: 'Manual', href: '/manual' },
  { label: 'Download', href: '/download' },
  { label: 'Support', href: '/support' },
] as const;

/** Manual sections — drives the manual index, the in-page sidebar, and prev/next. */
export const MANUAL = [
  { slug: 'getting-started', title: 'Getting started', blurb: 'Open a collection, create your first note, and learn the layout.' },
  { slug: 'editor', title: 'The editor', blurb: 'Live Markdown, view modes, maths, diagrams, callouts and properties.' },
  { slug: 'links-and-graph', title: 'Links & the graph', blurb: 'Wiki-links, aliases, backlinks, transclusion, graph and mind map.' },
  { slug: 'organising', title: 'Organising notes', blurb: 'Search, Open Quickly, tags, bookmarks, daily notes and templates.' },
  { slug: 'ai', title: 'AI & intelligence', blurb: 'Where each AI action lives, Review Links, New Note from a Prompt, typing suggestions, Ask Library and providers.' },
  { slug: 'cloud', title: 'Cloud storage', blurb: 'Use iCloud, Dropbox, Box, OneDrive or Google Drive — two ways.' },
  { slug: 'git', title: 'Version history with Git', blurb: 'Initialise a repo, commit, sync to a remote, browse and restore.' },
  { slug: 'shortcuts', title: 'Keyboard shortcuts', blurb: 'The full shortcut reference.' },
] as const;
