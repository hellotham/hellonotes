import type { ImageMetadata } from 'astro';

import iphoneRichContent from '../assets/devices/iphone-rich-content.png';
import iphoneAI from '../assets/devices/iphone-ai.png';
import ipadSplitView from '../assets/devices/ipad-split-view.png';

/**
 * iPhone and iPad captures, for the parts of the site that would otherwise
 * describe a Mac-only app.
 *
 * These are deliberately **not** `screens.ts`. That set is the composited
 * marketing frames — brand gradient, a caption burnt into the pixels, rounded
 * corners and a drop shadow, produced by `scripts/make-screenshots.py` at a
 * fixed 2560x1600 Mac canvas. These are the raw device captures from
 * `assets/screenshots-raw/`, shown as they came off the simulator and framed by
 * CSS instead, because:
 *
 *   - the compositor has one canvas size and five hard-coded Mac scenes, so an
 *     iPhone frame would mean a second layout engine in a script whose output
 *     is one-way and cannot be dry-run (it writes `public/assets/og.png`
 *     outside its output directory); and
 *   - a caption burnt into an image is a caption no reviewer can correct. Here
 *     the caption is text below the picture, so it can be fixed without a
 *     re-shoot.
 *
 * Every `alt`/`caption` below was written after opening the file. A caption
 * that does not match its capture is a false claim on a public page, not a
 * cosmetic mismatch — the same rule `website/CLAUDE.md` states for the Mac set.
 *
 * All three are shot from `DefaultCollection`, which ships inside the binary,
 * so nothing here is anyone's private vault.
 */
export interface DeviceShot {
  id: string;
  image: ImageMetadata;
  device: 'iPhone' | 'iPad';
  alt: string;
  caption: string;
}

export const DEVICE_SHOTS: DeviceShot[] = [
  {
    id: 'iphone-rich-content',
    image: iphoneRichContent,
    device: 'iPhone',
    alt: 'HelloNotes on iPhone showing a note in Preview with two callouts, inline and block LaTeX maths, and a Mermaid flowchart',
    caption: 'Callouts, LaTeX maths and Mermaid diagrams, on the phone.',
  },
  {
    id: 'iphone-ai',
    image: iphoneAI,
    device: 'iPhone',
    alt: 'The AI tab on iPhone listing Ask Your Library and New Note from a Prompt, then for this note Summarise, Suggest Tags, Suggest Links, Rewrite or Expand and Review Links, then Assistant and AI Settings',
    caption: 'The AI tab: ask your library, or act on the note in front of you.',
  },
  {
    id: 'ipad-split-view',
    image: ipadSplitView,
    device: 'iPad',
    alt: 'HelloNotes on iPad held upright: the collection and its note list in a band across the top, a row of open tabs, and the note in Split with its Markdown source beside the rendered page',
    caption: 'On iPad: the collection across the top, your tabs, and source beside the page.',
  },
];
