# Changelog

All notable changes to HelloNotes. Dates are release dates; the version is the
one shown in **HelloNotes ▸ About HelloNotes**.

---

## 1.3.2 — unreleased

*Dated 2026-08-20 when the first builds went to TestFlight. It has not shipped;
everything below landed in the same version while it was being tested, so it is
one release rather than several.*

### The iPad is a first-class place to write

**Typing keeps up.** On a 2,000-note vault in iCloud, every keystroke was doing
work that had nothing to do with the keystroke: two whole-document parses, a
pair of syscalls per sidebar row, spell checking that blocked on a cross-thread
lock, and a cache flush on every save that also threw away the document being
typed into. Worst-case cost per keystroke went from **11.90 ms to 0.68 ms** on a
120 KB note. Nothing of ours now runs between two keystrokes.

**Note text is sized for the platform it is on.** It was 16pt everywhere — a
macOS number, and a point *below* iOS's own body size, so notes read smaller
than the app's own labels. On iPhone and iPad it now follows the system Text
Size as well, which it never did before.

**Formatting moved into the system's own bar** above the keyboard: the floating
shortcuts row on iPad, an accessory bar on iPhone. It costs no screen space,
appears with a hardware keyboard, and shows whenever there is a cursor instead
of following the view mode.

**In portrait, the navigation band is two panes** — folders on the left, the
notes inside the selected one on the right, the way Finder does it. Rows carry
their date in a trailing column rather than on a second line, and are as tall as
what is in them: about a quarter more of your notes on screen, on both
platforms.

**Scroll past the end of a note**, so the last line is not stuck against the
bottom of the window. On the Mac too.

### Your notes, and the truth about them

**A note that cannot be read is no longer treated as an empty note.** Opening
one that had not finished downloading showed a blank editor — and typing into
that blank could overwrite the real note on the next autosave. The editor now
waits for the file, says which note it is waiting for, and refuses to save a
buffer it never loaded. Your edit is kept, not discarded.

**Opening a collection notices what changed while the app was closed.** It reads
its index for the first frame and then checks the folder, so the list is
immediate *and* right.

**Rescan Collection works on a collection that already has notes.** It did
nothing at all before — one folder the app could not read discarded the whole
pass in silence, and closing and re-adding the collection was the only repair.

**A folder that cannot be read now says which one, and why.** It used to report
"is being re-indexed", which was untrue — nothing was running — and never went
away.

**A vault reached through a symlink opens.** It came up empty, and reported
itself perfectly healthy while doing so.

### Backing HelloNotes

Every feature is included for everyone. Two voluntary products — **Champion**, a
repeatable one-off contribution, and **Commercial**, an annual licence for using
it at work — and the only thing either one adds is an **in-app support request**:
a way to reach the person who makes it. It composes the message and hands it to
your own mail app, so nothing is sent by HelloNotes and nothing about your notes
goes with it.

### A collection to start from

The app ships with one: a short tour and the user manual, in real Markdown files
you can edit, break or delete. Close it like any other collection; reopen it
from **File ▸ Open Default Collection**.

---

## 1.3.2 — 2026-08-20 · first TestFlight builds

HelloNotes runs on iPad properly rather than nominally, and one rendering fix
turns out to have affected the Mac just as much.

**Minimum is now macOS 26.5 and iOS/iPadOS 26.5.** The Intelligence features are
built on Foundation Models, which is 26-only, and the Quick Look extensions
already required 26.5 while the app claimed 15.0 — an app cannot promise an OS
its own embedded extensions refuse to run on.

### The iPad editor works

Four defects, each hidden behind the one in front of it.

- **Tapping in a note crashed the app.** A `UITextView` keeps two references to
  the document it shows and only one was being replaced, so the view reported an
  empty document while its layout engine laid out the whole note. AppKit
  tolerates that storage swap; UIKit does not.
- **There was no cursor.** The wiki-link tap recogniser had no delegate, so it
  competed with the text view's own caret tap and won — then did nothing,
  because most taps are not on a link. Scrolling worked throughout, which is
  what disguised it.
- **The format bar never rendered.** Built as a SwiftUI keyboard toolbar, which
  attaches only to views SwiftUI manages. Now a real keyboard accessory: a
  scrolling row of fourteen commands, with undo, redo and dismiss pinned.
- **Switching notes kept the previous note's text** — and the stale document was
  still wired to the model, so typing would have saved the old note over the new
  file.

### Rendering

- **Tables, Mermaid diagrams, display maths and `![[Note]]` transclusions render
  on iPad.** They were parsed, styled and given a band to sit in; one step
  between the renderer and the page was macOS-only, so the adapter was never
  called.
- **Preview matches the editor, on both platforms.** Preview called a small
  hand-written stylesheet rather than the GitHub-identical renderer the app is
  built on — so the editor styled from GitHub's parse tree and the Preview did
  not. Export and Print were on the same wrong path. One renderer remains, so
  they cannot drift apart again.
- **Rendered text is no longer serif.** A malformed CSS property meant every
  preview, exported HTML file and printed page fell back to Times.
- **Markdown mode stopped rewriting your Markdown.** Typing `---` under a table
  header produced an em dash and the table quietly stopped being one.

### Reaching things on iPad

- **A menu bar**, and the shortcuts that come with it: ⌘B, ⌘F, Find, View.
- **File tabs**, sharing the Mac's tab model rather than a second one.
- **The inspector** over the note, with a button to open it. Previously
  unreachable — the control needed a screen wider than an iPad.
- **Rename, duplicate, bookmark, export and delete**, and a sidebar folder tree
  that remembers what you left open.

### Internal

- The editor package's tests had only ever run on macOS despite the package
  declaring iOS support. They run on both now — that gap is why four defects in
  the UIKit half went unnoticed.

---

## 1.3.1 — 2026-08-18

A bug-fix release. On a large vault kept in iCloud Drive the editor froze:
naming a note could lock the window for thirteen seconds, saving could set the
whole folder re-reading, and a note being edited could disappear from the
sidebar.

### The editor is never blocked

Work the code carefully sent to a background thread was running on the main one
anyway — a project setting made every unannotated type main-actor, so
`Task.detached` detached the work's priority and cancellation but not its
*thread*. Harmless on a local folder; on an iCloud one every directory listing
became a blocking call to the sync daemon, on the thread drawing the window.
Measured on a 2,000-note vault: naming a note 13.4 s → 0.003 s, scanning
0.24 s → 0.002 s of blocked editor, worst freeze 5.9 s → nothing above 0.5 s.

- **Naming a note is instant.** A rename rewrote `[[links]]` in every note in the
  vault before returning, and a new note opens with its title focused — so that
  was the cost of typing a name. It now rewrites only the notes that link to it,
  and does so after the rename rather than before.
- **Saving never re-reads the folder.** A save whose note had briefly left the
  list triggered a full rescan — which is what made notes leave the list.
- **Opening a note no longer waits for a scan**; creating, appending to and
  deleting one change a single entry.
- **Transclusions, link previews and the file viewer** read off the main thread.
- **Quitting can't hang.** A wedged sync daemon gets five seconds, then the app
  exits — rather than waiting forever and being force-quit, which discards the
  saves that wait exists to protect.

### Notes stay put

- **A partial scan can no longer remove notes.** A scan resuming mid-folder
  reports success having seen only the rest of the tree; publishing that as
  authoritative replaced the note list with its tail.
- **A cancelled scan leaves the collection alone** instead of emptying it.
- **Unsaved edits survive a background refresh** — closing an editor didn't flush
  it first.
- **A sidebar click always opens the note**; when it couldn't be resolved the
  click did nothing at all, silently.
- iPhone and iPad: switching collections no longer closes the open note, and a
  selection resolving to nothing leaves the editor alone.

### Blockquotes in the editor

- **Markdown reveals per line, not per block.** A blockquote is one block however
  many lines it spans, so a cursor inside one showed the raw `>` on every line
  and dropped every vertical bar. The line you are on now shows its markers
  while the rest keep their formatting, as in Bear and Obsidian. Applies to
  headings and emphasis too.
- **A paragraph turned into a blockquote gets its bar immediately**, rather than
  whenever that line next happened to be redrawn.

### Under the hood

The "never block the editor" rule is now enforced rather than remembered: work
that must stay off the main thread goes through a helper that makes touching
main-thread state a *compile error*, and a test fails the build if the folder
scanner regains main-actor isolation. The app can also catch a freeze while it
is happening and record what caused it.

---

## 1.3 — 2026-08-16

HelloNotes already had most of this. It was just filed under "AI" — in a panel and a
window organised around the fact that a model was involved, which is the one thing
you are least likely to be thinking about when you want a summary. So this release is
mostly about putting each of these next to the thing it acts on, and then adding the
two that were genuinely missing: finding the links you meant to make, and letting
research arrive as a note instead of as a chat reply.

### Where the AI lives now

- **The Note menu.** Summarise Note, Suggest Tags, Suggest Links and Rewrite or
  Expand Note… sit beside Rename and Duplicate. Each answer lands in the inspector
  tab that already holds that kind of information — the summary at the top of
  **Outline**, tags in **Tags**, suggested links in **References**, beside the
  backlinks they are about to join.
- **A command palette**, <kbd>⇧⌘P</kbd>. Type a command's name to run it — including
  the ones with no shortcut worth memorising. It is built from the same set of
  actions the menu bar is, rather than a hand-kept list of its own, and a command
  that is unavailable right now is left out rather than shown greyed: everything you
  can find in it, you can run.
- **Select text and act on it.** The things the system's own Writing Tools cannot do,
  because they need your notes: link the phrase, find related notes, explain it using
  what you have written. On the Mac these appear in a small floating bar; on iPhone
  and iPad they join the standard selection menu. Ordinary rewriting is left to
  Writing Tools, which is already in every text view.
- **The AI features now work on iPhone and iPad**, where previously none of them did —
  the note actions, rewriting, Ask Library, the Assistant, Review Links and New Note
  from a Prompt. The command palette remains Mac-only.

### Review Links

- **Review Links…** (<kbd>⇧⌘L</kbd>) walks a note phrase by phrase, the way a spell
  check does: **Link**, **Skip**, or **Never**. You see the phrase in its own
  sentence and the opening lines of the note it would point at, because the same
  phrase can deserve a link in one paragraph and not the next.
- **"Never" is remembered** for that collection, so a phrase you have already
  rejected stops coming back. It is stored on your device, not in your notes — a
  decision you made is not something to commit to a shared repository.
- **Nothing is written until you finish**, and the whole set applies as one change
  you can undo in one step.
- Every phrase that **names** another note is a candidate. When a note turns up more
  than ten, the ten whose targets are most related to what you have written are the
  ones you are shown — which on a real collection cut the list by more than half
  while keeping almost every link people had genuinely made.

### New Note from a Prompt

- <kbd>⌃⌘N</kbd>, or **File ▸ New Note from a Prompt…**, in two modes.
- **Write** composes a note from a description.
- **Research** investigates a question on the web across several angles and lands the
  answer *as a note* — with its sources gathered at the bottom and a record of the
  question it came from, so a note you did not write can still be recognised as one
  later.
- **Both connect to what you already have.** Notes you own on the topic are offered
  to the model as links, and every link that comes back is checked against your
  collection: anything naming a note that does not exist is turned back into ordinary
  text, and the draft tells you it happened. Research arrives joined up instead of
  as an island.
- **You read the whole draft before it exists.** Title and body are editable, and no
  file is created until you press **Create Note**.

### Suggest as I type *(Mac only, off by default)*

- Grey text appears after the cursor when you pause at the end of a line.
  <kbd>⌥⇥</kbd> or <kbd>→</kbd> accepts it, <kbd>Esc</kbd> dismisses it.
- **The suggestion is never part of your note until you accept it.** It is drawn on
  screen and nothing more — it cannot reach a save, a search result, your links, or a
  Git diff.
- Runs **on your device only**. A suggestion that has to cross the network arrives
  after you have already typed past it, so this is offered only where the model is
  local. Turn it on in **Assistant Settings ▸ Inline completion**.

### Smaller things

- **Related notes are found by the whole text, not just the title** — by the
  distinctive words two notes share, so an unusual name or term that appears in both
  counts for far more than a common one. It reads your notes the first time something
  needs it rather than at launch, and keeps up as you save. It matches wording rather
  than meaning: two notes on the same subject that share no vocabulary will not find
  each other.
- **Assistant Settings now says what your chosen model can and cannot do** — whether
  it runs on your device or in the cloud, roughly how much of a note it reads, and
  which features would work better on a larger one.
- Deep research now declines up front on a provider that cannot drive its tools,
  instead of failing part-way through and looking like broken research.

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
