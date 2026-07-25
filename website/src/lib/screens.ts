import type { ImageMetadata } from 'astro';

import light01 from '../assets/screens/light_01.png';
import light02 from '../assets/screens/light_02.png';
import light03 from '../assets/screens/light_03.png';
import light04 from '../assets/screens/light_04.png';
import light05 from '../assets/screens/light_05.png';
import dark01 from '../assets/screens/dark_01.png';
import dark02 from '../assets/screens/dark_02.png';
import dark03 from '../assets/screens/dark_03.png';
import dark04 from '../assets/screens/dark_04.png';
import dark05 from '../assets/screens/dark_05.png';

/**
 * The product screenshots, each captured twice — once with the app's Appearance
 * set to Light and once to Dark, from the same SampleVault, same window size and
 * same note. Nothing but the app's own theme differs between the pair, which is
 * the point: it shows the setting rather than just decorating the page.
 *
 * Regenerate with scripts/make-screenshots.py; see docs/website.md.
 */
export interface Screen {
  id: string;
  light: ImageMetadata;
  dark: ImageMetadata;
  /** Describes what the app is doing — the same in either appearance. */
  alt: string;
  title: string;
  body: string;
}

export const SCREENS: Screen[] = [
  {
    id: 'files',
    light: light01,
    dark: dark01,
    alt: 'The HelloNotes window showing a collection sidebar, the note list and a note open in the editor',
    title: 'Your notes, your files',
    body: 'The sidebar is a view of a real folder on your Mac. Collections, folders, tags and bookmarks — over ordinary Markdown files you can open in any other app.',
  },
  {
    id: 'maths',
    light: light02,
    dark: dark02,
    alt: 'A note with LaTeX maths and a Mermaid flowchart rendered inline in the editor',
    title: 'Maths and diagrams, rendered inline',
    body: 'LaTeX maths and Mermaid diagrams are drawn natively in the editor as you type — no browser engine, no export step, no round trip.',
  },
  {
    id: 'callouts',
    light: light03,
    dark: dark03,
    alt: 'A note showing coloured callouts and a typed Properties panel above the text',
    title: 'Callouts, properties and rich Markdown',
    body: 'Collapsible callouts, hidden comments, and front matter presented as a typed, editable Properties panel rather than raw YAML.',
  },
  {
    id: 'graph',
    light: light04,
    dark: dark04,
    alt: 'The graph view showing notes as nodes joined by directional links',
    title: 'See how your thinking connects',
    body: 'The graph view maps links between notes, with arrows for direction and focus tracing to follow a thread through the collection.',
  },
  {
    id: 'ask',
    light: light05,
    dark: dark05,
    alt: 'Ask Library answering a question about the collection, with a list of source notes cited beneath the answer',
    title: 'Ask your library',
    body: 'Ask a question in plain language and get an answer grounded in your own notes, with citations back to the sources — running on-device.',
  },
];

export const byId = (id: string): Screen => {
  const found = SCREENS.find((s) => s.id === id);
  if (!found) throw new Error(`No screenshot with id "${id}"`);
  return found;
};
