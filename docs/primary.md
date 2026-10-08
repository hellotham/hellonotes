---
status: CURRENT (2026-09-24). Describes the primary sidebar as built, the rules
it follows and its open defects (§12). Decision record: `shell-chrome.md` D2,
D2a, D3, D4, D5, D8, D11. Overview: `ui.md`.
---

# The primary sidebar

The left of the window (or the top, in a tall one): the **collections**, their
folders and notes, and the two places pinned above them. It answers one question,
**"where is it?"**, and nothing else.

---

## 1. Its job, and what it may not hold

- **Places only.** Collections, folders, notes, attachments, and the two pinned
  places, Recents and Bookmarks. Nothing about *what a note is* lives here:
  tags, outline, links and properties are the right panel's
  ([secondary.md](secondary.md), decision L1).
- **No commands** (`shell-chrome.md` D8, the P2 corollary). People collapse the
  sidebar while they work, so anything inside it vanishes exactly when it is
  wanted. New Note, search, Open Quickly and the rest are in the bar over the
  editor and in the menu bar.
- **The exceptions are actions whose whole subject is the sidebar's own
  content**, which Apple's apps put at the sidebar's edge or on its rows: the
  **Add Collection** menu in the sidebar's header; each row's own menu (its `…`
  button and its context menu); the menu on the empty space below the rows;
  the buttons in the sidebar's empty states (§3.5); and **Download and Search**
  in the search strip (§3.2).

---

## 2. Three forms, one tree

The shell decides the form from the window's shape (`ui.md` §4). The content is
the same tree in every form (§3).

| Shell | Form | Drawn by |
|---|---|---|
| Column (`.two`, `.wide`, `.wideInspector`) | **Sidebar column**: one tree, 220–340pt wide | `NoteOutlineList` |
| Tall (`.tall`) | **Band**: the tree across the top in two panes, containers on the left and their contents on the right | `BandTwoPane` |
| Compact (`.compact`) | **Places**: Notes, Search, Tags and AI behind a bottom tab bar | `ContentView` `collectionsList`, `noteList`, `tagList`, `aiPlace` |

`SidebarLayout` picks between the column and the band. It has to be a view of
its own: `@Environment(\.shell)` read in `ContentView` resolves *above*
`AdaptiveShell` and is always `.wide` there, so a branch taken in `ContentView`
would never see the tall shell (`BandTwoPane.swift`).

---

## 3. What is in it

`SidebarTree.roots(_:)` builds the tree once for every form, from one value of
inputs (`SidebarTree.Inputs`). It has three modes.

### 3.1 Browsing (no search, no tag filter)

```
▸ Recents          ← pinned place: the 8 most recently modified notes, every collection
▸ Bookmarks        ← pinned place: every bookmarked note, every collection
▾ My Vault         ← one root per open collection, in library order
  ▸ Daily          ←   subfolders first, A→Z (Finder's order)
  ▸ Projects
    Meeting notes  ←   then notes, by Settings ▸ Appearance ▸ Sort notes by
    12:40 pm            (Date Modified, newest first, by default; or Name)
  diagram.pdf      ←   then attachments, A→Z (only with Show Non-Note Files)
▸ Obsidian Vault
```

- **A pinned place with nothing in it is omitted**, not shown empty. An
  always-present Bookmarks that never opens teaches people to ignore it.
- **Recents means recently *modified*** (`LibraryPlace.mostRecent`), across
  every open collection. It is not a history of what you opened.
- Notes saved in the same second keep one order everywhere (`Note.newestFirst`).
- Attachments (PDFs, images, CSV and other files) appear only when the
  collection's **Show Non-Note Files** is on (View menu, or the collection's row
  menu). The collection status bar says how many are hidden.

### 3.2 Searching

When the bar's search field holds text, **the results replace the whole tree**.
They are grouped under one row per collection, each result a note row with its
snippet, followed by any attachments whose *content* matched (found through the
system's Spotlight index). The search runs across every open collection and is
debounced (`LibrarySearch`). Two strips above the tree say when the answer may
be short (`SearchCompletenessNotice`), because a false negative is the most
damaging thing a knowledge tool can produce: nobody notices the note that did
not come back.

- "These results may be incomplete — *collections* are not fully indexed."
  when a collection's index is behind its folder or the folder cannot be read.
- "*n* items aren't downloaded, so their contents aren't searched." with
  **Download and Search**, when a cloud collection holds items that are not on
  the device. Search skips them by default so that a query never pulls a whole
  account down.

With no match, the sidebar says **No Results** ("No results for "*query*".
Check the spelling or try a new search.").

### 3.3 Filtering by a tag

Choosing a tag in the right panel's Tags view flattens the tree to that tag's
notes, as bare note rows with no group row above them: the filter is already
scoped to one collection. Choosing a tag clears the search field, because a
filter and a search would fight. **The band cannot show a filtered list**
(§12).

### 3.4 Cached, and keyed on everything

`SidebarTreeModel` rebuilds the tree only when its key changes. **The key names
every input**: sort order, text scale, the bookmark count, the focused
collection, the mode (search revision, tag and scope), and each collection's id,
revision, state, scan progress and Show Non-Note Files. A cache key that missed
one input once made "Show Non-Note Files" do nothing on the Mac, and a filtered
tree that ignored revisions kept drawing notes that had gone.

### 3.5 When there is nothing to show

`SidebarEmptyState` draws one of three states over the sidebar:

| When | Title | Says | Offers |
|---|---|---|---|
| no collection is open | **No Collections** | "Open a folder of Markdown notes, or an Obsidian vault, to get started." | **Open Collection…** (prominent), **Open Recent…** (disabled when there is nothing to reopen) |
| a search found nothing | **No Results** | "No results for "*query*". Check the spelling or try a new search." | — |
| the only open collection is empty | **No Notes** | ""*name*" is empty. Create your first note to get started." | **New Note** |

Closing the last collection must not be a dead end, which is why the first
state offers both ways back in.

---

## 4. Rows

The column and the band draw these rows, at the Mac's metrics, from
`ChromeRows.swift`. The compact places draw their collection rows their own way
(§10).

| Row | Height | Content |
|---|---|---|
| **Collection** | 24pt | `books.vertical` 12pt (orange `exclamationmark.triangle` when unavailable), the name at 11pt (**semibold when it is the focused collection**; tertiary when unavailable), a mini spinner while scanning, a 6pt Git dot (grey when clean, orange with changes; only for a repository), then `…` |
| **Place** (Recents, Bookmarks) | 22pt | a 12pt symbol (`clock`, `bookmark`) and the name at 11pt, secondary colour |
| **Folder** | 22pt | `folder` 12pt and the name at 12pt, then `…` |
| **Note** | 32pt | the title at 13pt semibold, a `icloud.and.arrow.down` badge when it is online only, and an 11pt second line: the search snippet, or the date |
| **Attachment** | 22pt | the file kind's symbol and the file name at 12pt |

- **Dates are compact** (`NoteRowContent.compactDate`): the time today,
  "Yesterday", the weekday within a week, day and month this year, a short
  numeric date before that.
- **Wide note rows.** Where the list is at least 420pt wide
  (`ShellMetrics.noteRowTwoColumn`), the date moves up into a trailing column
  beside the title and only a snippet takes a second line. A sidebar column
  (220–340pt) is always below that and stays stacked; the band's right pane
  always uses the wide layout. The width is measured once for the whole list,
  never per row, so neighbouring rows cannot disagree.
- **Indent** 14pt per level after an 8pt leading inset. The **disclosure
  triangle** is a 9pt chevron in a 14pt slot, reserved on every row so leaves
  line up with their siblings.
- **Selection** is the accent at 30% in a rounded rectangle (radius 6) inset
  5 × 1pt. **Hover** is a faint fill. A glyph inside a selected row is never
  drawn in the accent (accent on accent draws nothing).
- **Text Size** scales row fonts and heights together (`chromeScale`), on both
  platforms, **in the column only**. The band and the compact lists ignore it
  (§12).
- The sidebar's background is the chrome grey (`Chrome.Colour.chrome`), not the
  editor's white.

---

## 5. What a row does

| Gesture | On | Result |
|---|---|---|
| Click / tap | a note or attachment | **selects it**, which opens it in the window's editor (see [tabs.md](tabs.md) for which tab) |
| Click / tap | a collection, place or folder | opens or closes it: **the whole row**, not just its triangle |
| Click / tap | the triangle | opens or closes it |
| ↑ / ↓ | the column sidebar, focused | moves the selection to the previous or next note or attachment row and scrolls it into view. A note that also appears under an open Recents or Bookmarks is found at its first row, so the step starts from the pinned copy |
| Drag | a note or attachment | carries its file URL: to a folder in the tree, or out to another app |
| Drop | onto a folder or collection row | **moves** the files there, only within the same collection and never onto the folder they are already in. The row highlights for any drag and filters on the drop, so a drag from another collection, or into the folder it came from, highlights and then does nothing (§12) |
| Drop | onto a note, an attachment, Recents or Bookmarks | refused before the row highlights |
| Right-click / long-press | any row | the row's menu (§6) |
| Click / tap `…` | a collection or folder row | the same menu, visibly |
| Right-click / long-press | the empty space below the rows | New Note and New Folder… in the sidebar's scope collection (§11) |

Open folders and places are remembered per window (`expandedFolders`, restored
on relaunch). **Folded collections are not** (`collapsedCollections` is
`@State`): collections start open after every launch, and places and folders
start closed. In the column, a collection added from a cloud account is
scrolled into view and opened (`revealID`); the other ways of adding a
collection do not reveal it. The empty-space menu and the reveal exist in the
column only.

A note row has **no `…`**. Its commands' visible home is the open note's own
menu, **Note Actions ⌄** in the bar ([toolbars.md](toolbars.md) §3.3), the
arrangement Mail uses for a message.

---

## 6. Row menus

One list per kind of row (`SidebarMenu.items(for:actions:)`). Every form
(column, band, compact lists) and every renderer (context menu, `…`, Note
Actions) draws the same list.

**Note**

| Item | Notes |
|---|---|
| Rename… | an alert; wiki links to the note are updated across the collection |
| Duplicate | selects the copy |
| Add Bookmark / Remove Bookmark | |
| — | |
| Copy Wiki Link | `[[Title]]` |
| Open in New Window | a note window (`ui.md` §9.1) |
| Reveal in Finder / Reveal in Files | |
| — Download, or Remove Download | only for a note in a cloud folder: Download while it is online only, Remove Download once it is on the device |
| — Review Links… | only for the note open in the editor |
| — Export ▸ Export as HTML…, Export as PDF…, Print… | exports the editor's buffer when the note is open, downloads a cloud note first, and reports when there is nothing to export |
| — Move to Trash | destructive |

**Attachment:** Open in Default App (macOS) or Open in Files (iOS), then Reveal
in Finder / Files.

**Collection:** New Note · New Folder… · — · Show Non-Note Files (or Hide) ·
Rescan Collection · Refresh Cloud Collection (direct-API collections only) · — ·
Focus Collection · Reveal in Finder / Files · Close Collection.

**Folder:** New Note Here · New Folder Here… · — · Reveal in Finder / Files · — ·
Move to Trash (confirmed first, because it trashes the folder's contents). Both
"Here" items open the folder first, so the new item is not created somewhere
you cannot see.

**Place:** no menu. A pinned place owns nothing on disk.

---

## 7. The header row

```
┌──────────────────────────────┐
│ ●●●                        + │  40pt · chrome grey · 1pt rule below
└──────────────────────────────┘
```

- 40pt, the height of the bar over the editor, so the columns share one top
  edge (D11). The window drags by its background.
- On the Mac the **traffic lights** sit over its leading end, as in Apple
  Notes. On iPad the leading end is empty.
- At the trailing end is **Add Collection** (`+`), a menu:
  - **New Collection ▸** Empty Folder… · Git Repository…
  - **Open Collection ▸** from Folder… · from iCloud Drive… · from Obsidian
    Vault… · from Cloud… · from Repository…
  - —
  - **Open Recent…** (the launcher: recent collections and saved libraries)
  - **Open Default Collection** (the tour and manual that ship with the app,
    restored if deleted)

  The same set (`AddCollectionActions.options`) is drawn by the File menu, the
  bar's More ⋯ menu, the compact Library's More ⋯, the command palette and the
  Welcome and launcher screens.

---

## 8. Showing, hiding and sizing it

- **One toggle**, the bar's second button, **Show Sidebar / Hide Sidebar**
  (`sidebar.leading`), hides whichever left region the shell has: the column or
  the band (D3, as amended). It is at the same place, size and drawing on both
  platforms.
- With the sidebar hidden, the bar is the window's top-left corner and pads its
  leading end by 78pt on the Mac for the traffic lights.
- **Search reopens it.** Edit ▸ Search All Collections (⌥⌘F) shows a hidden
  sidebar and puts the caret in the search field. Find Related on a selection
  shows it with the results, without taking the caret. Results that land in a
  hidden panel are a dead end.
- **Width:** 280pt to start; drag the divider between 220 and 340, and never so
  wide that the editor drops below 320. That limit ignores the right panel, so
  with the panel open in a narrow window the editor can end up at about 298pt
  (`ui.md` §12). The width is stored app-wide
  (`sidebarWidth`) and clamped at use, so narrowing the window borrows width
  back without forgetting it. The divider's 1pt line has a 10pt grab area, a
  resize cursor on the Mac, and an adjustable accessibility value (±20pt).
- There is **no menu command and no shortcut** for the toggle (§12).

---

## 9. The band (tall shell)

```
┌───────────────────────────────────────────────────────────────┐
│                                                             + │ header, 40pt
├─────────────────────┬─────────────────────────────────────────┤
│ ▸ Recents           │ Meeting notes                  12:40 pm │
│ ▾ My Vault        … │   Agenda for Tuesday…                   │
│   ▸ Daily         … │ Reading list                    Monday  │
│   ▾ Projects      … │ Trip plan                        2 Sep  │
│     ▸ Archive     … │ budget.csv                              │
├─────────────────────┴─────────────────────────────────────────┤
 ← 260pt (180 … width − 260) →  ← what is directly inside it →
```

Why two panes: a band on an iPad in portrait is 834pt wide and 320pt tall. One
tree there spends its width on nothing and runs out of height in about eight
rows; two panes scroll independently and show the folders *and* the notes
(D2a).

- **Left (containers):** the same tree with every leaf removed: places,
  collections and folders (`SidebarTree.containers`). Tapping a row **selects it
  as the container**; the triangle opens it. Collection and folder rows carry
  `…` and take drops. It is on the chrome grey.
- **Right (contents):** what is **directly inside** the chosen container, its
  notes and attachments but not its subfolders' (`SidebarTree.leaves(of:)`),
  in wide rows on the content white. Recursing would make it a second copy of
  the tree. Empty, it says **Nothing Selected** ("Choose a collection or folder
  on the left.") or **No Notes Here** ("This folder has no notes of its own.").
- **A container is chosen before one is clicked:** the first that holds
  something (`firstNonEmptyContainer`), which is often Recents, so that the band
  does not open onto an empty right pane. Under a tag filter it cannot find one
  (§12).
- **New Note goes where you are looking.** The bar's New Note creates the note
  in the band's chosen container, opening that folder first, the same target
  as the folder row's New Note Here (`ShellComplianceTests`). With a collection
  chosen, the note goes to that collection's root. With a place (Recents,
  Bookmarks) chosen, it goes to the root of the sidebar's scope collection.
- The band is **320pt tall, fixed**, header included. The divider between the
  panes drags; the band's own height does not (§12).
- The arrow keys do nothing in the band.

---

## 10. The compact places

On a phone (or any window under 600pt) there is no sidebar. Its job is split
across the bottom tab bar's four places (`CompactPlace`), each with its own 40pt
bar (`CompactPlaceBar`: the title centred, commands at the trailing end). The
place is remembered per window.

| Place | Bar | Content |
|---|---|---|
| **Notes** (`folder`) | "Library" · **More ⋯** | a "Collections" heading, then one row per open collection: 32pt, `books.vertical`, the name at 13pt (semibold and ✓ when focused), the note count, `…`. Then **All Notes** (clears a tag filter, ✓ when none is active). With no collection open: **Open Folder…** |
| **Search** (`magnifyingglass`) | the collection's name, "#tag" under a tag filter, or "Library" · **New Note** | a full-width search field ("Search *collection*"), then the collection's notes: its search results, its tagged notes under a filter, or all of them. One collection, unlike the sidebar's search, which covers every open collection |
| **Tags** (`number`) | "Tags" | **All Notes**, then every tag of the collection; choosing one filters the notes and switches to Search. Empty: **No Tags** ("Tags you write as #tag in a note appear here.") |
| **AI** (`sparkles`) | "AI" | the AI commands ([secondary.md](secondary.md) §7) |

- **Tapping a collection** makes it the scope of every place and focuses it. It
  clears the search, the tag filter and the selected note.
- **Tapping a note** selects it. It shows in the mini strip above the tab bar,
  and tapping the strip shows the note full screen.
- **The Notes place's More ⋯**: New Note (when a collection is open), the Add
  Collection set (§7), —, Settings…. On iPhone, with no menu bar, it is the one
  route to adding a collection that is always there.
- Note rows are the sidebar's own note rows, with the tree's menu on a
  long-press. **Collection rows are drawn separately** from the sidebar's: they
  show no unavailable warning, scanning spinner or Git dot (§12).
- The **Library place** (quick actions, recent notes and bookmarks across every
  collection, `LibraryPlace`) takes the Search place's list when no collection
  is open, or when the sidebar's scope is the whole library (§11) and the search
  field is empty and no tag filter is on.

---

## 11. Which collection the window is in

Three pieces of state answer "which collection?" and it helps to name them:

| Name | What it is | Set by |
|---|---|---|
| **Focused collection** (`library.focusedID`) | the collection the window's commands act on; semibold in the tree | opening a note (its collection), **Focus Collection**, tapping a collection in the compact Notes place, adding a collection |
| **Sidebar scope** (`railPlaceID`, per window) | "the sidebar's selection" in `AGENTS.md`'s rule: what New Note, Today's Note, Rescan, a tag filter and New Note from a Prompt act on, and what enables Open Quickly and Graph (which then work on the focused collection) | follows the focused collection. It stands on the whole library ("Library") when no collection was focused the first time the window opened, or when the collection it named is closed. It then **stays** on Library through focus changes, and leaves only when the library goes from empty to non-empty, when a collection from a cloud account is added, or when a collection is tapped in the compact Notes place (§12) |
| **Band container** (`bandContainerID`) | the folder New Note lands in | the band's left pane. It is `@State` and never cleared, so a column window that was once tall keeps using it (§12) |

The scope a command uses is `railCollection ?? focused`: the sidebar scope,
falling back to the focused collection. The window's title (for the Window menu
and Mission Control) is the scope collection's name, and **empty** on Library.
(An open attachment's viewer sets a title of its own; which one the system shows
then has not been checked.)

---

## 12. Open defects and gaps

1. ✅ ~~**Hidden-sidebar state is stored twice and restores inconsistently.**~~ The
   toggle writes `bandHidden` (per window, remembered) and `columnVisibility`
   (`@State`, forgotten). After a relaunch with the sidebar hidden, a column
   window shows the sidebar while the bar reads **Show Sidebar** and keeps the
   78pt traffic-light inset. The first click on the toggle only drops the inset,
   so the bar's controls jump left while the sidebar stays. **Fix:** one stored
   value, "left region hidden", per window. *Fixed (implemented.md §51.36).*
2. **No menu item and no shortcut for Show/Hide Sidebar.** This breaks
   principle 5 (`ui.md` §2) on the Mac and on an iPad with a keyboard. **Fix:**
   View ▸ Show Sidebar / Hide Sidebar, ⌃⌘S, the macOS convention
   ([menu.md](menu.md) §8).
3. **The band's height is fixed at 320pt.** Every other region can be dragged.
   A portrait reader who wants eight more lines of note has to hide the band
   completely.
4. **Keyboard navigation exists only in the column tree.** The band's panes and
   the compact lists do not take the arrow keys.
5. **The arrow keys open a tab per row today**, because selecting a note opens
   it in a new tab. [tabs.md](tabs.md) replaces that.
6. **"Recents" suggests recently opened.** It lists recently *modified* notes.
   Either the name changes (Recently Edited) or the content does. Opening
   history belongs to Back and Forward ([tabs.md](tabs.md) T6).
7. ✅ ~~**The empty-space menu is offered whenever there is a scope collection.**~~
   `SidebarMenu.emptySpace`'s comment says it is offered only when the whole
   outline belongs to one collection. With several collections open, New Note
   there lands in the scope collection, which the click does not name. *Fixed (implemented.md §51.36).*
8. ✅ ~~**Two system colours in the rows.**~~ `ChromeCollectionRow` draws the
   unavailable symbol and the Git dot in `Color.orange`, which is a different
   orange on each platform. It should be `Chrome.Colour.orange` (D12). *Fixed (implemented.md §51.36).*
9. ✅ ~~**Every divider is announced as "Panel width".**~~ `ResizableDivider`'s
   accessibility label is fixed, so VoiceOver calls the sidebar's divider and
   the band's divider "Panel width" as well. *Fixed (implemented.md §51.36).*
10. **The band cannot show a tag filter.** A filter makes the tree bare note
    rows. The band's left pane keeps containers only, so it goes empty. Its
    first-container rule then picks a note, and the right pane says **No Notes
    Here**. The tall shell has no way to see a tag's notes.
11. **Text Size reaches the column only.** The band's panes and the compact
    lists do not read `chromeScale`.
12. ✅ ~~**On a phone an unreadable collection looks healthy.**~~ The compact
    collection rows are not `ChromeCollectionRow`, so they drop the unavailable
    warning, the scanning spinner and the Git dot. *Fixed (implemented.md §51.36).*
13. **Drops highlight and then do nothing.** Folder and collection rows accept
    any drag and filter it after the drop, so a drag from another collection,
    or back into its own folder, lights the row and then silently does
    nothing. The band enables every row that is not a place.
14. ✅ ~~**The band's container outlives the band.**~~ `bandContainerID` is never
    cleared, so New Note in a column window that was once tall (an iPad
    rotated, a Mac window resized) still lands in the folder last chosen in the
    band. With Recents chosen, `expand` also writes Recents into the open
    folders, so New Note opens Recents in the tree. *Fixed (implemented.md §51.36).*
15. ✅ ~~**The scope can get stuck on Library.**~~ Closing the collection the sidebar's
    scope names leaves it on Library. Focus changes do not move it off, and
    neither does opening another local collection while one is open. The
    window's title goes empty, and the compact Search place shows the Library
    place, until the library empties and refills, a cloud-account collection is
    added, or a collection is tapped in the compact Notes place. *Fixed (implemented.md §51.36).*
16. **Stale source comments** about the sidebar are listed in `ui.md` §12,
    item 7.
