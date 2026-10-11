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
 * set to Light and once to Dark, from the same DefaultCollection, same window
 * size and same note. (DefaultCollection ships inside the binary, so every shot
 * is content a reader can open for themselves rather than a private vault.)
 * Nothing but the app's own theme differs between the pair, which is the point:
 * it shows the setting rather than just decorating the page.
 *
 * **The caption is burnt into each image** (`SCENES` in
 * scripts/make-screenshots.py), so an entry here has to describe the same scene
 * its picture does. The five were re-shot for 1.3.3, whose window is three
 * regions — the collection on the left, the note in the middle, what the note
 * is on the right — and every `alt` below was written with the capture open.
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
    id: 'window',
    light: light01,
    dark: dark01,
    alt: 'The HelloNotes window in three parts: a sidebar with Mind Map, Assistant, Ask Your Library and Git above the tree of the collection’s folders and notes; the note “Start Here” open in the editor; and a right panel showing Summary & Outline — the note’s word count and its headings',
    title: 'The collection, the note, and what the note is',
    body: 'One window, three parts. On the left the collection — a real folder on your device, shown as it is on disk. In the middle the note. On the right what that note is: its outline, tags, links, properties, history and graph.',
  },
  {
    id: 'split',
    light: light02,
    dark: dark02,
    alt: 'The note “Rich Content” in Split view: its Markdown source on the left, and on the right the same note rendered, with three coloured callouts and inline and block LaTeX maths',
    title: 'Markdown source beside the rendered page',
    body: 'Split puts the Markdown you type next to the page it makes. Callouts, LaTeX maths, Mermaid diagrams, tables and highlighted code are all plain text in the file.',
  },
  {
    id: 'graph',
    light: light03,
    dark: dark03,
    alt: 'The note “Linking” open in the editor, with the right panel showing its Graph: the note ringed among four others, joined by arrows for the links into it and out of it, set to Direct links',
    title: 'A graph of each note’s links',
    body: 'The Graph is in the panel beside the note it is about: what links to this note and what it links to, as nodes and arrows — and a link or two further on, if you ask.',
  },
  {
    id: 'mind-map',
    light: light04,
    dark: dark04,
    alt: 'The Mind Map open as a tab beside a note: the collection at the centre, two coloured branches of notes headed by “Start Here” and “Index”, and faint dashed lines for the links the branches leave out',
    title: 'A mind map of the whole collection',
    body: 'The Mind Map draws the links across a collection as a mind map, in a tab of its own beside your notes: the collection at the centre, its best-connected notes heading the branches, and the links the branches leave out as dashed lines.',
  },
  {
    id: 'assistant',
    light: light05,
    dark: dark05,
    alt: 'The Assistant open as a tab, running on the System model: asked to summarise the Linking note in three bullet points, it shows a search_notes call and a read_note call and then a three-point answer',
    title: 'An Assistant that reads your notes first',
    body: 'Ask the Assistant about your collection and it searches and reads your notes before it answers, showing each step — here on Apple’s model, on the device. A change to a note waits for your approval.',
  },
];

export const byId = (id: string): Screen => {
  const found = SCREENS.find((s) => s.id === id);
  if (!found) throw new Error(`No screenshot with id "${id}"`);
  return found;
};
