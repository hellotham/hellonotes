# Changelog

All notable changes to HelloNotes. Dates are release dates; the version is the
one shown in **HelloNotes ▸ About HelloNotes**.

---

## 1.1 — 2026-08-11

The window got simpler, the editor got several long-standing rendering faults
fixed, and a handful of silent failures learned to speak up.

### The window

- **One sidebar instead of two columns of chrome.** Collections and folders are
  now a single tree in one collapsible sidebar: the collection is the root, its
  folders hang beneath it, and opening another collection adds another root. The
  separate 64pt collection rail is gone.
- **Library, bookmarks and recents** live as pinned places at the top of that
  tree rather than beside it.
- **The toolbar was rebuilt.** Search sits at the leading edge, next to the
  sidebar it searches. New Note and Open Quickly sit in the middle. The five
  inspector panels — outline, tags, references, properties, history — are
  toggles at the trailing edge; pressing the active one closes the panel.
- **The note's title is shown above its body** and can be renamed in place, with
  the caret moving between title and body as one flow.

### Editor

- **Display maths, Mermaid diagrams and tables no longer leave dead space.** A
  rendered block reserved its image band once per line of source, so a one-line
  `$$…$$` formula pushed roughly 90pt of emptiness beneath itself.
- **No more stray marks under a rendered block.** The block's trailing newline
  kept full body size (a blank line under every formula), and a Mermaid fence's
  syntax colours were repainted over the concealed source after it collapsed,
  leaving coloured specks under the diagram.
- **Front matter folds to nothing.** It used to leave one blank line above the
  note's first real content.
- **Rendered blocks follow the theme.** Maths, diagrams and tables re-render when
  you switch between light and dark instead of keeping their original ink.
- **Windows line endings parse correctly.** In a CRLF file, setext headings,
  thematic breaks and front matter were all read as ordinary paragraphs.
- **The editor stays responsive while another app edits the same vault.**
- **Link anchors are no longer mistaken for tags.**

### Accessibility

- **The VoiceOver headings rotor honours its search field.** Typing to narrow the
  heading list previously did nothing.
- **Graph and mind-map labels scale with the system text size** instead of canvas
  zoom alone. Mind-map chips grow with their labels rather than clipping them.

### Git

- **Create Repository can be stopped.** Creating with a remote ends in a push,
  and a push to an unreachable host used to leave the sheet spinning with no way
  out. Stopping removes the half-made repository.
- **Fixed a deadlock** in the git operation queue.

### Reliability & performance

- **Launch opens saved collections in parallel** rather than waiting for each
  folder scan in turn.
- **Superseded folder scans stop.** A bulk `git checkout` could put several full
  vault walks on the disk at once.
- **Chat transcript save failures are reported** instead of silently losing the
  conversation until the next launch.
- **The references panel shows an empty state** rather than disappearing when a
  note has no links.

### iPhone & iPad

- The adaptive shell now drives iOS too, with a compact tab-bar model of its own,
  and a live editor with full block chrome.

### Project

- Continuous integration builds both platforms, compiles the test targets and
  runs the suites on every push.

---

## 1.0 — 2026-07-25

First public release. A local-first, native macOS Markdown knowledge base:
your notes are ordinary `.md` files in an ordinary folder.

- Live Markdown editing on a purpose-built TextKit 2 engine
- Wiki-links, aliases, backlinks, unlinked mentions, transclusion
- Graph and mind-map views
- LaTeX maths, Mermaid diagrams, callouts, typed front-matter properties
- GitHub-identical preview, HTML/PDF export, Marp slides
- Full-text and title search, Open Quickly, tags, bookmarks, daily notes
- Version history with Git: init, commit, push, fetch, clone, browse and restore
- Cloud storage through iCloud, Dropbox, Box, OneDrive and Google Drive
- On-device Apple Intelligence, plus optional cloud AI providers
