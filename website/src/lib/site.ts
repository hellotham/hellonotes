/**
 * Site-wide facts. Kept in one place so a release only touches this file —
 * the version, download link and checksum appear on several pages.
 */

export const APP = {
  name: 'HelloNotes',
  tagline: 'Think in plain Markdown.',
  version: '1.3.2',
  minOS: 'macOS 26.5 or later',
  /** Universal binary — verified with `lipo -info` on the shipped DMG. */
  architectures: 'Apple silicon & Intel',
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
