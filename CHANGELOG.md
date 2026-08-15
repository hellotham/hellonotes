# Changelog

All notable changes to HelloNotes. Dates are release dates; the version is the
one shown in **HelloNotes ▸ About HelloNotes**.

---

## 1.2 — 2026-08-15

A collection points at a folder HelloNotes does not control. This release is
about what happens when that folder is large, slow, in the cloud, inside a Git
repository, or simply not there any more — and about the app saying so instead
of guessing.

### Cloud folders

- **Use the folder you already have.** If Box, Dropbox, OneDrive or Google Drive
  is installed on your Mac, **File ▸ Open Cloud Folder…** opens its folder
  directly. No sign-in, no token, no second copy of your files. Connecting over
  a provider's API moved to **File ▸ Connect Over the Web**, for accounts whose
  app you don't have.
- **Cloud collections open immediately.** Adding one used to download every note
  first; now the folder's structure appears straight away and each file's
  contents arrive the first time you open it. Every file comes across, not just
  Markdown — PDFs, images and documents preview as usual.
- **Cloud collections come back when you reopen the app**, from what is already
  on disk, and then check the provider for changes.
- **Refresh** in the collection's status bar asks the provider what has changed
  since it last looked, rather than re-reading the whole folder.
- **Edited in two places at once?** Both versions are kept. Yours stays where it
  is and the other is saved beside it as a conflicted copy — decided by the
  provider's own record of the file, not by comparing two devices' clocks.
- **Add as Collection now works on iPhone and iPad**, not just the Mac.

### Large folders

- **Adding a big folder tells you it is big**, and offers to open a subfolder
  instead. Adding it anyway is always allowed.
- **Scanning shows progress and can be stopped.** What has been found is kept,
  and scanning resumes from where it stopped rather than starting over — after a
  cancel, a quit, or iOS suspending the app.
- **Notes appear as they are found** instead of all at once at the end.
- **Non-note files can be hidden** per collection (**View ▸ Show Non-Note
  Files**), and the status bar says how many are hidden.

### Folders that move, vanish, or change behind your back

- **A folder that can't be read now says so** — moved, renamed, deleted, or on a
  disk that isn't connected — and keeps showing its notes as they were, rather
  than appearing empty. **Try Again** picks it back up; a folder that has moved
  is followed. Removing it is your decision, not the app's.
- **Editing continues while a folder is away.** Saving is refused rather than
  written into nowhere, and your changes are held until it returns.
- **Changes made by other apps are noticed more reliably.** When the system
  reports that it lost track of file changes, the collection re-scans instead of
  quietly serving a stale index — and says search results may be incomplete
  until it finishes.
- **iPad and iPhone notice changes at all now.** A vault edited on your Mac
  previously stayed stale until you relaunched.
- **Search says when it can't see everything**, and offers to download what it
  is skipping — for both online-only cloud files and folders connected over the web.

### Git

- **A folder inside a repository is recognised as one.** Opening
  `~/project/docs` as a collection previously offered no Git at all. It now has
  the full Git panel, and everything it does — commits, change counts, history —
  covers only that folder. Nothing outside your collection is ever committed.
- **The branch and change count keep up with the terminal.** A `git pull` or
  branch switch made outside the app is reflected instead of showing whatever
  was true when the collection opened.

### Fixed

- **"Add as Collection" appeared to do nothing.** Failures were discarded
  silently. It now shows progress, can be stopped, and reports what happened —
  including what it couldn't read.
- **A cloud browser opened with a saved sign-in showed an empty account.** It
  never actually asked the provider for anything.
- **An expired cloud sign-in now offers to sign in again** instead of looking
  like an empty folder.
- **Cancelling a scan no longer discards what it found.**
- **A collection whose saved permission had aged out silently disappeared** on
  the next launch. It is now kept, with an explanation.
- **Large attachments upload to OneDrive** instead of failing past 4 MB.

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
