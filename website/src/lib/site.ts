/**
 * Site-wide facts. Kept in one place so a release only touches this file —
 * the version, download link and checksum appear on several pages.
 */

export const APP = {
  name: 'HelloNotes',
  tagline: 'Think in plain Markdown.',
  /**
   * The current release — what the direct download for Mac is. The App Store
   * can be a version behind while Apple reviews it: see `APP_STORE` below.
   */
  version: '1.3.3',
  /** The Mac floor. Also the DMG's requirement — that channel is Mac-only. */
  minMacOS: 'macOS 27 or later',
  minIOS: 'iOS & iPadOS 27 or later',
  /**
   * Both floors in one phrase, for the places that name the requirement once.
   * `minOS` used to be the single Mac string and is deliberately gone rather
   * than kept as an alias: every remaining reader had to be looked at, because
   * a Mac-only sentence on a page that now also sells an iPhone app is wrong in
   * a way no build catches.
   */
  platforms: 'macOS, iOS & iPadOS 27 or later',
  /**
   * 1.3.3 is arm64 only — `lipo -archs` on the shipped app says `arm64`.
   * Versions up to 1.3.2 were universal, so any sentence that reads this must
   * not go on to mention Intel.
   */
  architectures: 'Apple silicon',
} as const;

/**
 * The App Store listing — **one** page for all three platforms.
 *
 * Both platforms ship from a single App Store Connect record, and Apple serves
 * them as one unified product page: `?mt=12` (the legacy "Mac App Store"
 * selector) is *dropped on redirect*, so a separate Mac link resolves to
 * exactly the same URL as the iPhone one. Two buttons here would be two ways to
 * reach the same place, which reads as a mistake rather than a choice — hence
 * one link, and copy that names the devices instead.
 *
 * Verified live 2026-09-15: both forms 200 and both land on
 * apps.apple.com/…/app/hellonotes/id6803259848, whose page lists Mac, iPhone
 * and iPad.
 */
export const APP_STORE = {
  id: '6803259848',
  url: 'https://apps.apple.com/app/id6803259848',
  /**
   * What the App Store serves today, and the version waiting with App Review.
   *
   * The two channels do not move together: the DMG is published the day it is
   * notarised, and the App Store — the only route to iPhone and iPad — changes
   * when Apple approves the build. While `pendingVersion` is set and differs
   * from `liveVersion`, `StoreNotice.astro` says so beside every App Store
   * link, and the pages name `liveVersion` wherever they say what the store
   * has.
   *
   * **When Apple approves 1.3.3:** set `liveVersion` to '1.3.3' and
   * `pendingVersion` to null. The notice disappears by itself, and so does
   * the line on the screenshots page saying the iPhone and iPad pictures are
   * of a version still in review. `scripts/check-download-page.sh` fails from
   * the day the store has the new version until this is done.
   */
  liveVersion: '1.3.2',
  pendingVersion: '1.3.3' as string | null,
} as const;

/** Whether the App Store is a version behind the direct download. */
export const STORE_IS_PENDING =
  APP_STORE.pendingVersion !== null && APP_STORE.pendingVersion !== APP_STORE.liveVersion;

export const PUBLISHER = {
  name: 'Hello Tham',
  legalName: 'Hello Tham Pty. Ltd.',
  site: 'https://hellotham.com',
  email: 'info@hellotham.com',
} as const;

export const REPO = 'https://github.com/hellotham/hellonotes';

export const DOWNLOAD = {
  /** Release assets live on GitHub Releases — a disk image does not belong in
   *  the site repo, where it would bloat every clone forever. */
  url: `${REPO}/releases/latest/download/HelloNotes.dmg`,
  releasesPage: `${REPO}/releases/latest`,
  fileName: 'HelloNotes.dmg',
  size: '29.1 MB',
  sha256: '665bc36b8e375f174bb4be93a5bfa58a0138f2514c33eb425281a4702ace4629',
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
  { slug: 'editor', title: 'The editor', blurb: 'Live Markdown, view modes, lists, find and replace, maths, diagrams, callouts and properties.' },
  { slug: 'links-and-graph', title: 'Links & the graph', blurb: 'Wiki-links, aliases, backlinks, transclusion, graph and mind map.' },
  { slug: 'organising', title: 'Organising notes', blurb: 'Search, Open Quickly, tags, bookmarks, daily notes and templates.' },
  { slug: 'ai', title: 'AI & intelligence', blurb: 'Where each AI action lives, Review Links, New Note from a Prompt, typing suggestions, Ask Your Library, the Assistant, and choosing the System model or an MLX model.' },
  { slug: 'cloud', title: 'Cloud storage', blurb: 'Use iCloud, Dropbox, Box, OneDrive or Google Drive — two ways.' },
  { slug: 'git', title: 'Version history with Git', blurb: 'Initialise a repo, commit, sync to a remote, browse and restore.' },
  { slug: 'shortcuts', title: 'Keyboard shortcuts', blurb: 'The full shortcut reference.' },
] as const;
