---
status: PROPOSED (2026-09-24), for review. Nothing from §3 onward is built.
§2 is tabs as they work today, read from the code, with file, symbol and line
references. Overview: `ui.md` (decision L21). The bar the tabs live in:
`toolbars.md` §3. The menus: `menu.md`.
---

# Tabs

## 1. Why this document exists

Tabs in HelloNotes were never designed. They are a side effect: the window
keeps one editor per note it has opened, and the strip in the bar draws those
editors. Nothing in the app treats a tab as something you ask for. So there is
no **+**, no New Tab, no way back from a followed link except the tab you came
from, and a strip that fills up as you read.

The question that exposed it was "I don't see an obvious way to add a new tab."
There isn't one, because there has never been an answer to "what is a tab?".
This document gives one (§3–§4), says exactly how every route behaves (§5), and
lists what changes from today (§8).

---

## 2. Tabs today

### 2.1 What a tab is

A tab **is** an open note. `EditorTabs` (`State/EditorTabs.swift:16`) holds one
`EditorModel` per open note, in tab order. **The active tab is whichever editor
matches the window's selected note** (`EditorTabs.swift:11–13`): the selection
and the tabs are the same state seen twice. There is no empty tab and no tab
without a note.

### 2.2 How a tab appears

*`ContentView.swift` is cited by symbol, not line: it changes often.*

Every change of the selection opens the selected note: `ContentView`'s
`onChange(of: selectedNoteID)` calls `openSelectedNote`, which calls
`tabs.editor(for:)`. That returns the note's tab if it has one and **otherwise
appends a new tab** at the end (`EditorTabs.swift:62–95`).
The tab appears at once and fills in when the note has loaded, so a note still
downloading from the cloud shows its tab and a banner rather than nothing.

Every route that selects a note therefore shows it in its tab if it has one,
and otherwise in a new tab of its own:

- a click in the sidebar, the band or a compact list, a Recents or Bookmarks
  row, a search result;
- **the arrow keys in the sidebar, which open a tab for every row they pass
  that is not already open** (`NoteOutlineList.swift:179–192`);
- Open Quickly; a followed `[[link]]` (`ContentView.openWikiLink`); a reference
  in the panel or the status bar's Links popover;
- a graph node, a mind-map node, an Ask Library citation, and a
  `hellonotes://` link, a widget or the Open Note App Intent (a Shortcuts
  action) (all through `library.requestOpen`, which `ContentView` answers in
  its `onChange(of: library.pendingOpenNoteID)`);
- Quick Capture and Dictate to Daily Note, which append to today's note and
  then open it (`NavigationRouter.openDailyNote`);
- New Note, Today's Note, Duplicate and New Note from a Prompt, which select
  what they create; Services' New Note from Selection and the system-wide
  ⌃⌥⌘N, which create a note and so always get a new tab;
- Rename, which selects the renamed note, even one that was not the active
  one; and a move by dragging, which re-selects the moved note if it was the
  selected one.

There is no limit, and nothing ever closes a tab on its own except a note
disappearing (§2.3).

### 2.3 Switching and closing

- **Clicking a tab** selects its note (`ContentView.tabStrip`).
- **Closing:** the tab's ×; **File ▸ Close Tab**, enabled only while more than
  one tab is open and the selected note has an editor
  (`AppCommands.swift:513–514`; `canCloseTab` in `ContentView.appActions`); and
  **⌘W**, which the window claims only under the same two conditions, so that
  otherwise it falls through to the system's Close and closes the window (the
  hidden button at the end of `ContentView.presentations`). With several tabs
  open and nothing selected (§2.5, item 4), Close Tab is greyed out and ⌘W
  closes the window, tabs and all.
- Closing flushes the editor, removes the tab, and activates the tab that was to
  its right, or else the last one (`EditorTabs.swift:105–111`). Closing a
  background tab does not move the selection (`ContentView.closeTab`).
- A tab whose note disappears from the index is dropped, **unless it has unsaved
  changes**, which keep it (`EditorTabs.prune`, `EditorTabs.swift:136–142`).
  Trashing a note, closing a collection and renaming a note all reach tabs this
  way (§2.5).

### 2.4 Drawing and scope

- The strip sits in the middle of the bar over the editor (`toolbars.md` §3).
  Tabs are 28pt tall and up to 200pt wide; the active one is semibold on the
  accent at 30%; every tab has a ×. After the notes come the collection's
  tools that are open (D13) — the Mind Map, the Assistant, Ask Your Library,
  each with its symbol before its title (`ToolTabs`). A tool's tab in front
  puts the notes behind it; choosing a note, or a note's tab, puts the tool
  behind; closing the tool in front shows the note again. Tool tabs are not
  remembered across launches. When they do not fit, the strip scrolls
  sideways (`ContentView.shellBar`).
- **The strip is drawn while the selected note has an editor, or a tool is
  open.** With neither it is replaced by empty space, even if tabs are open.
- Tabs belong to one main window (`ContentView`'s `@State private var tabs`). A
  note window (Open in New Window) has none.
- **A relaunch restores only the active note** (`@SceneStorage`
  `restoredNotePath`, read in `ContentView`'s launch `task`); the other tabs are
  gone.

### 2.5 What is wrong with it

1. **Tabs pile up.** Opening *is* adding a tab, so reading five notes leaves five
   tabs, and walking the sidebar with the arrow keys leaves one for every row
   it passes.
2. **A tab cannot be asked for.** There is no +, no New Tab and no Open in New
   Tab, so the only way to get a tab is to open something.
3. **Tabs are doing history's job.** Following a link keeps the previous note
   because it adds a tab, not because there is a way back. There is no Back.
4. **The strip hides while tabs exist.** Clearing the selection hides the strip
   while the other tabs stay open behind it: tapping a collection on the phone,
   trashing the open note, closing its collection.
5. ✅ ~~**An attachment opens an editor.**~~ Selecting a PDF or an image falls through
   `openSelectedNote`'s "the file still exists" path, which makes a `Note` for it
   and opens an editor tab: the tab is titled with the file name without its
   extension, and Note Actions offers Rename, Duplicate and the rest for it,
   while the viewer draws the file. Read from the code; not yet reproduced in
   the app. *Fixed (implemented.md §51.36).*
6. ✅ ~~**Closing can discard text that could not be saved.**~~ Close flushes and then
   removes the tab whatever the flush did (`EditorTabs.swift:107–108`). When a
   save is refused (the collection is unavailable: "Your changes are kept here
   until it's back", `ContentView.wireTabs`), closing the tab throws those
   changes away. Read from the code; not yet reproduced. *Fixed (implemented.md §51.36).*
7. **A relaunch loses every tab but one.**
8. **The Mac has a second tab system.** macOS window tabbing was never turned
   off, so the View and Window menus offer Show Tab Bar, Show All Tabs (⇧⌘\),
   Show Previous Tab (⌃⇧⇥), Show Next Tab (⌃⇥), Move Tab to New Window and Merge
   All Windows (read from the running app, `menu.md` §3). Those are window tabs,
   unrelated to the note tabs, and the iPad has nothing like them.
9. **No floor.** In a narrow window with the sidebar and the panel open, the
   tabs get about 15pt, or nothing at all once the sidebar has been dragged
   wide (`toolbars.md` §3.1).
10. **A background tab cannot say something is wrong.** Download progress, a
    failed save and a conflict are banners in the editor, which only the active
    tab shows.
11. **Notes with the same title are indistinguishable.**
12. **Accessibility is a trade.** Each tab is one combined element, so its close
    button is reachable only as a named action in the rotor
    (`EditorTabBar.swift:95–122`).
13. ✅ ~~**Renaming a note moves its tab to the end, and switches to it.**~~ A note's
    identity is its file URL and a rename changes it. The rename selects the new
    URL, even when the note was not the active one; it has no tab, so a new one
    is appended and the old one is pruned; the editor reloads. Read from the
    code; not yet reproduced. *Fixed (implemented.md §51.36).*
14. ✅ ~~**Moving a note closes its background tab.**~~ Dragging a note into a folder
    re-selects it only if it was the selected note. If it was open in a
    background tab, the old URL disappears from the index and the tab is pruned
    without a word. Read from the code; not yet reproduced. *Fixed (implemented.md §51.36).*
15. ✅ ~~**Two routes close a collection without clearing the selection.**~~ **Remove**
    on the unavailable-collection status bar and the Cloud Collections manager
    call `library.close` directly. If the selected note's tab holds unsaved
    changes, it survives the prune and stays selected, pointing into a
    collection that is no longer open. Read from the code; not yet reproduced. *Fixed (implemented.md §51.36).*
16. **A capture navigates.** Quick Capture and Dictate to Daily Note open
    today's note after appending to it, so capturing from the menu-bar extra
    changes what the main window shows.

---

## 3. What a tab is (the model)

> **A tab is a place in the window where one thing is open.** It shows one
> item at a time: a note, an attachment, or the Start page. Opening something
> shows it in the active tab. A new tab exists only because someone asked for
> one.

| Term | Meaning |
|---|---|
| **Tab** | one slot in the strip. It has an identity of its own, independent of what it shows |
| **Item** | what a tab shows: a note, an attachment, or nothing (the **Start page**) |
| **Active tab** | the one on screen. **The sidebar's selection is the active tab's item**, and only that |
| **History** | the window's list of items it has shown, for Back and Forward |

**Invariants**

1. A main window always has at least one tab.
2. An item is in at most one tab of a window.
3. The sidebar's selection is always the active tab's item (none for a Start page).
4. Closing a tab never discards text that has not been written to disk.
5. Every open tab is reachable at every window size.

---

## 4. Decisions

Each decision gives the rule, the reason, and what was considered and rejected.

### T0 — One kind of tab

**Turn macOS window tabbing off** (`NSWindow.allowsAutomaticWindowTabbing =
false` at launch). All six window-tab items disappear: View ▸ Show Tab Bar and
Show All Tabs, and Window ▸ Show Previous Tab, Show Next Tab, Move Tab to New
Window and Merge All Windows. The app then puts **its own Show Previous Tab and
Show Next Tab** in the Window menu, where people look for them, acting on the
note tabs (T17).

*Why.* "Tab" should mean one thing. The iPad has no window tabs, so a Mac-only
second system breaks parity (`ui.md` principle 7), and a native tab bar would be
a second row of chrome (D1).
*Rejected:* using macOS window tabs as the app's tabs (TextEdit's and Pages'
model). The iPad cannot have them, and a window per note would bring back what
the app gave up to avoid it.

### T1 — A tab shows one item

A note, an attachment, or the Start page (T5). Its title in the strip is the
item's: the note's title, the attachment's file name with its extension, or
**New Tab**.

### T2 — Opening shows it in the active tab

Every route that opens something replaces what the active tab shows (the full
list is §5). The item left behind is recorded in the window's history (T6).
**Nothing opens a tab on its own.**

Three exceptions, each to protect something:

- **Opened from outside the window** (a `hellonotes://` link, a
  widget, an App Intent, Services, the system-wide ⌃⌥⌘N): **a new tab**. It did
  not come from what you are reading, so it must not replace it (a browser
  handles a link from another app the same way).
- **The active tab holds changes that could not be saved** (its collection is
  unavailable, a save failed, a conflict is unresolved): **a new tab**, so the
  unsaved note keeps its tab and its warning (T8).
- **The item is already in another tab: that tab is activated** (T3).

**Some things that select a note today are not opens**, and change nothing in
the strip:

- **A capture.** Quick Capture and Dictate to Daily Note append to today's
  note and leave the window as it was. Today they open the daily note
  afterwards, which contradicts what they are for: jotting a line "without
  leaving what you are doing". The Quick Capture window already says "Added to
  today's note."; Today's Note (⇧⌘T) is the way to go and look.
- **A rename or a move.** The note keeps its tab: the tab follows the file to
  its new name or folder, and its history entries follow too. Renaming a note
  that is not the active one does not switch to it. Today a rename moves the
  tab to the end of the strip and switches to it, and a move closes a
  background tab (§2.5).

*Why.* Tabs stay under the user's control: reading ten notes in a row uses one
tab. This is the model of Finder, Safari and Obsidian, and Finder is the closest
Apple app to this one: a sidebar of places, contents, and tabs you ask for. It
also makes the arrow keys a way to *browse* the sidebar instead of a way to make
tabs.
*Rejected:* **every open is a new tab** (today): tabs become history and fill
up. **Preview tabs** (VS Code: a click opens a temporary tab that the next click
replaces until you edit it): a mode drawn in italics that people have to learn,
and in an autosaving editor there is no clear moment at which a tab "becomes
permanent". **A cap that closes the oldest tab**: something disappears that you
did not close.

### T3 — One tab per item per window

Opening an item that is already in a tab of this window **activates that tab**
and leaves the active tab as it was.

*Why.* The sidebar's selection names one tab, never two. One note has one
editor buffer per window. "Where is that note?": there it is, in its tab.
*Rejected:* duplicates, Safari-style. Two tabs showing one buffer make it
ambiguous which one the sidebar is pointing at.

### T4 — A new tab is asked for

| Route | Result |
|---|---|
| **+** at the end of the strip | a new Start tab at the end, active, with the caret in its field |
| **⌘T**, **File ▸ New Tab** | the same |
| **⌘-click** on a note or attachment row (sidebar, band, compact lists, Recents, Bookmarks, search results), a reference, a link in the editor, a graph or mind-map node, an Ask Library citation | the item in a new tab **right after the active one**, activated |
| **⌘Return** in Open Quickly, or on the Start page | the same |
| **Open in New Tab** in every note and attachment row menu, and **Open Link in New Tab** in the editor's link menu | the same |
| any of these, when the item is already in a tab | that tab is activated (T3) |

**The touch route** on an iPad without a keyboard, and on a phone, is **+ and
then choose**. ⌘-click and the row menus are shortcuts to it
(`ui.md` principle 5).

### T5 — The Start page

What a tab shows when it shows nothing. It **replaces today's "Select a Note"
screen**.

```
┌──────────────────────────────────────────────────────────┐
│                                                          │
│          [🔍 Open a note…                           ]    │  28pt field, ≤ 480pt wide
│                                                          │
│          [New Note]  [Today's Note]  [From a Prompt…]    │
│                                                          │
│          RECENT                                          │
│          Meeting notes                        12:40 pm   │  the sidebar's own rows
│          Trip plan                              Monday   │
│          …                                               │
│          BOOKMARKS                                       │
│          Reading list                            2 Sep   │
│                                                          │
├──────────────────────────────────────────────────────────┤
│ the collection status bar (toolbars.md §5.2)             │
└──────────────────────────────────────────────────────────┘
```

- **Open a note…** searches notes and headings as you type, with Open Quickly's
  engine (`quickOpenResults`). ↑/↓ move through the results; **Return opens here**;
  **⌘Return opens in a new tab** (this tab stays); Escape clears the field.
- With the field empty: **New Note** (⌘N), **Today's Note** (⇧⌘T) and **New
  Note from a Prompt…** (⌃⌘N), then **RECENT** (the eight most recently modified
  notes) and **BOOKMARKS**. Clicking a row opens it here.
- With no collection open: the **No Collections** state, with Open
  Collection… and Open Recent….
- **The field takes the caret only when the tab was just created** by + or ⌘T.
  A Start page that appears because the last tab was closed does not take
  focus (`ui.md` principle 10).
- The Start page is not recorded in history (T6).

*Why a page, and not a new note or the Open Quickly sheet.* ⌘N already makes a
note. A + that made one would give two commands one meaning. A sheet is not a
tab: cancelling it would leave nothing, and + must visibly add a tab. The page
also gives the empty editor a purpose, which "Select a Note" never had.

### T6 — Back and Forward belong to the window

The window keeps **one history**: the items the active tab has shown, in order.

- **Recorded:** whenever the active tab's item changes by opening something
  (T2) or by activating another tab, the item being left is appended, unless it
  is already the last entry. A new navigation discards the entries ahead of the
  current position, as a browser does.
- **Not recorded:** the Start page; closing a tab (Reopen Closed Tab is the way
  back from that, T7).
- **Back** (⌘[) goes to the previous entry: **if it is in a tab, that tab is
  activated; otherwise it is shown in the active tab.** **Forward** (⌘]) is the
  mirror. Entries whose file is gone are skipped and removed. A rename or a move
  updates the entries that name it.
- **At most 50 entries** per window. History is not restored after a relaunch.
- **In the bar:** ‹ (`chevron.left`) and › (`chevron.right`), 28pt bar buttons,
  **immediately before the strip**, each disabled when there is nowhere to go.
  The tooltip names the destination ("Back to Meeting notes").
- **In the menus:** **Go ▸ Back** and **Go ▸ Forward**. Go is a new menu, after
  View (`menu.md`).

*Why the window and not each tab.* With T3 a note lives in exactly one tab, so
"where was I?" is answered by a note, not by a tab. A window-wide history
answers it even when you were in another tab (VS Code's Go Back works this way).
T2 makes Back necessary: following a link now replaces the note you were
reading, and there has to be a way to return that is not the sidebar.
*Rejected:* per-tab history (Safari, Finder). With one tab per item it makes
Back stop at a tab's edge, which is exactly where you often want to go next.

### T7 — Closing

| Route | Effect |
|---|---|
| the tab's **×** | closes that tab |
| **⌘W** | closes the active tab **while there are several**; with one tab the window does not claim ⌘W, and it is the platform's own Close (the window closes on the Mac) |
| **File ▸ Close Tab** | closes the active tab. Enabled whenever the active tab shows an item or there are several tabs |
| **File ▸ Close Other Tabs**, and the tab menu (T15) | closes every tab but the active one |
| **Close Tabs to the Right** (tab menu) | as it says |
| **File ▸ Reopen Closed Tab** | reopens the most recently closed tab, with its item, where it was; up to ten per window |

- **The last tab never disappears.** Closing it with × or Close Tab turns it
  into a Start tab (invariant 1).
- After closing the active tab, **the tab to its right becomes active, or else
  the one to its left** (today's rule, kept).
- **Closing saves first.** If the note has changes that **could not be written**
  (the collection is unavailable, a save failed, a conflict is unresolved),
  closing asks instead of discarding them: *"Close “Trip plan”? Its latest
  changes couldn't be saved: <reason>."* **Cancel** · **Close and Discard
  Changes**. Nothing else asks: autosave means an ordinary close has nothing to
  confirm (invariant 4).
- **Move to Trash** on a note closes its tab. **Close Collection** closes the
  tabs of its notes. Both ask first if one of those notes has changes that could
  not be saved.
- A note that disappears **outside** the app keeps today's rule: its tab closes
  unless it has unsaved changes, in which case it stays and shows ⚠︎ (T8).
- **No shortcut for Close Other Tabs or Reopen Closed Tab.** ⌥⌘W is the system's
  Close All, which SwiftUI will not reliably reassign (the same reason ⌘W is not
  attached to Close Tab), and ⇧⌘T is Today's Note.

### T8 — The strip

```
 ‹ ›  │ ⟳ Draft   × │ Trip plan — Projects × │ Trip plan — Archive × │ ⚠︎ Budget × │  +
      └─ downloading   └─ same title: the folder follows it ──────────  └─ couldn't save
```

- **Where:** in the bar, between ‹ › (T6) and Note Actions (`toolbars.md` §3).
- **Always drawn**, including a single tab, and a Start tab. The strip is where
  + lives, and a strip that hides with one tab hides the concept.
- **A tab:** 28pt tall, 10pt padding; the title at 13pt, semibold in the label
  colour when active and regular in the secondary colour when not; the × a 9pt
  semibold glyph in a 16pt square, tertiary. Width is the title plus the ×,
  **at least 88pt** (room for a short title and a target) and **at most 200pt**
  (`Chrome.Metric.tabMaxWidth`); titles truncate at the tail. 4pt between tabs.
  The active tab is filled with the accent at 30% (radius 6); an inactive one
  gets the hover fill under a pointer.
- **The × is always drawn.** A control that appears only on hover does not exist
  on touch.
- **Same titles:** when two tabs' titles are equal, each adds " — *folder*" (its
  parent folder) in the secondary colour.
- **Status glyph**, before the title, on any tab: a small spinner while the
  note downloads; `exclamationmark.triangle.fill` in `Chrome.Colour.orange` when
  its changes could not be saved, its collection is unavailable, or a conflict
  is unresolved. Nothing when all is well: autosave means "unsaved" is not news.
- **Tooltip** (pointer): where the note lives, "My Vault › Projects › Trip plan".
- **+** (`plus`, "New Tab"): a 28pt bar button directly after the last tab,
  **outside the scrolling area**, so it never scrolls away.

### T9 — When the strip does not fit

The bar's buttons never move (`toolbars.md` §1). The strip takes what they
leave, and `ViewThatFits` picks the first of these that fits:

1. **All the tabs**, at their natural widths.
2. **The tabs scrolling** sideways, without a scroll bar, when there is room for
   at least one tab at its 88pt minimum beside the +. The active tab is scrolled
   into view whenever it changes.
3. **A tab menu**: a 28pt button (`square.on.square` and the tab count) that
   opens a menu of every tab (the active one ticked, each with its status
   glyph), then New Tab, Close Tab and Reopen Closed Tab.

**Switching is never removed** (`ui.md` §4.6): Show Previous/Next Tab work at
every width, and the palette lists every open tab (T17).

### T10 — Order

- **New Tab** (+, ⌘T) goes at the end. **Open in New Tab** goes right after the
  active tab, so related tabs stay together. Restored tabs keep their order.
- **Drag a tab to reorder it**, with a pointer, or by holding and dragging on
  touch. The order has no command of its own, as in Safari: it is direct
  manipulation, not a command.
- Dragging a tab out of the strip does nothing (T18).

### T11 — Restoration

- Each window saves its tabs: the items in order and which one is active
  (`@SceneStorage`, replacing `restoredNotePath`). A relaunch restores them.
  Items that no longer exist are dropped; if none are left, the window opens
  with one Start tab.
- History (T6) and closed tabs (T7) are not restored.
- **New Window** (⌥⌘N) opens with one Start tab.

### T12 — Windows

- Tabs belong to a main window. **A note window** (Open in New Window) has no
  tabs, and a link followed in it opens another note window (today's behaviour,
  kept).
- **Open in New Window** from a tab's menu opens its note in a note window and
  leaves the tab where it is.
- The same note may be open in two windows, one buffer each (today's
  behaviour). T3 applies within a window.

### T13 — Attachments

An attachment opens in a tab like a note: the file viewer (`FileViewerView`)
instead of the editor, the tab titled with the file name, and **Note Actions ⌄
replaced by the attachment's own menu**: Open in Default App (Open in Files on
iOS) and Reveal. **No editor is created for an attachment**, which removes
§2.5 item 5.

### T14 — Compact (phone, and any window under 600pt)

The same model, fitted to the compact shell:

- **One bar for the expanded note**: Collapse (`chevron.down`, "Back to
  *place*") · the strip · + · Note Actions ⌄ · Panel. The separate title row goes;
  the active tab carries the title (`toolbars.md` §14, item 1).
- **Back and Forward are the first group in Note Actions ⌄** on compact. At
  375pt the bar has no room for two more buttons, and the strip's width matters
  more.
- **The mini strip** shows the active tab's title, and "· *n* tabs" when there
  are several. With a Start tab active it is hidden, as it is today with no note.
- **Tapping a note in a place** shows it in the active tab (T2). It does not
  expand the note (today's behaviour, kept: the Apple Music model).
- **Tapping a collection** in the Notes place changes the scope and **leaves the
  active tab alone** (today it clears the selection, §2.5 item 4).

### T15 — The tab's menu

Right-click or long-press a tab: **Close Tab · Close Other Tabs · Close Tabs to
the Right** · — · **Open in New Window · Copy Wiki Link · Reveal in Finder /
Files** · — · **Reopen Closed Tab**.

Every item is also in the menu bar, or in Note Actions for the active tab, so
this menu is a shortcut. The one exception is a *background* tab's note
commands: activate the tab first. That is the same rule that puts a note's
commands in the open note's menu.

### T16 — Accessibility

- **A tab** is one element: a button, with `.isSelected` when active, labelled
  with its title plus its state (", downloading", ", changes not saved").
  Activating it switches to it. Named actions: **Close *title*** and **Close
  Other Tabs**. Today's trade (the × is reachable only as a named action) is
  kept, and gets a VoiceOver check on both platforms before shipping.
- **+** is "New Tab"; **‹** and **›** are "Back" and "Forward", with the
  destination's title as their value.
- **The tab menu** (T9 fallback) is "Tabs, *n* open".
- The keyboard reaches everything: ⌃⇥ and ⌃⇧⇥ (or ⇧⌘] and ⇧⌘[) cycle tabs, ⌘[
  and ⌘] walk history, and ⌘T, ⌘W open and close.

### T17 — Commands

| Command | Shortcut | Menu | Palette |
|---|---|---|---|
| New Tab | ⌘T | File, after New Note | yes |
| Close Tab | ⌘W while several tabs are open | File | yes |
| Close Other Tabs | — | File; tab menu | yes |
| Reopen Closed Tab | — | File | yes |
| Back | ⌘[ | **Go** (new) | yes |
| Forward | ⌘] | **Go** | yes |
| Show Previous Tab | ⇧⌘[, and ⌃⇧⇥ | Window | yes |
| Show Next Tab | ⇧⌘], and ⌃⇥ | Window | yes |
| Open in New Tab | ⌘-click, ⌘Return | row menus; the editor's link menu | — |
| Switch to Tab: *title* | — | — | one row per open tab |

**Conflicts checked against every existing shortcut** (`menu.md` §7): ⌘T is
free (this app has no Show Fonts); ⌘[ and ⌘] are free (the editor binds
neither); ⇧⌘[ and ⇧⌘] are free; ⌃⇥ and ⌃⇧⇥ belong to the OS's window tabs today
and are freed by T0 (the editor already leaves ⌃⇥ alone,
`MarkdownEditorView.swift:721`).

### T18 — Not in this design

| Not included | Why |
|---|---|
| Pinned tabs | T2's exceptions and T3 already stop the cases pinning exists for: a note with unsaved problems keeps its tab, and an open note is never duplicated. Revisit if people ask |
| Preview (temporary) tabs | rejected in T2 |
| Per-tab history | rejected in T6 |
| Tab groups; a tab overview (Show All Tabs) | nothing yet needs them, and T9's menu covers finding a tab |
| Dragging tabs between windows, or out into a new window | SwiftUI has no native tab drag between windows. Open in New Window covers the need |
| A limit on the number of tabs | T2 removes the pile-up; a cap would close something you did not close |
| **Split panes** (`maxPanes`, decision L2) | a separate design. When it comes, each pane gets its own strip and active tab, and T3 becomes "one tab per item per pane" |

---

## 5. Behaviour reference

What each action does today, and what it does under this design.

| You… | Today | Designed |
|---|---|---|
| click a note in the sidebar, band or a compact list | its tab if it has one, else **a new tab** | **shown in the active tab**; its tab if it has one (T2, T3) |
| ⌘-click a note | as a click | a new tab after the active one (T4) |
| press ↑ / ↓ in the sidebar | **a new tab for every row not already open** | the active tab follows the selection |
| click a search result, a Recents or a Bookmarks row | its tab if it has one, else a new tab | the active tab |
| choose in Open Quickly (Return) | its tab if it has one, else a new tab | the active tab; ⌘Return: a new tab |
| click a `[[link]]` in the editor | its tab if it has one, else a new tab | **the active tab**; Back returns (T6); ⌘-click: a new tab |
| click a reference in the panel or the Links popover | its tab if it has one, else a new tab | the active tab; ⌘-click: a new tab |
| click a graph or mind-map node, or an Ask Library citation | its tab if it has one, else a new tab | the active tab |
| open a `hellonotes://` link, a widget, or an App Intent such as Open Note | its tab if it has one, else a new tab | **a new tab** (T2) |
| Services' New Note from Selection, or the system-wide ⌃⌥⌘N | always a new tab (they create the note) | a new tab (T2) |
| Quick Capture… or Dictate to Daily Note | today's note opens: its tab if it has one, else a new tab | **nothing moves**; the text is appended (T2) |
| New Note, Today's Note, New Note from a Prompt | a new tab (Today's Note: its tab if it is open) | the active tab (the previous note is one Back away) |
| Duplicate | a new tab with the copy | the active tab shows the copy |
| Rename | switches to the renamed note, in **a new tab at the end**; the old one is pruned and the editor reloads (§2.5) | the same tab, retitled; the active tab does not change; history updated |
| move a note by dragging it into a folder | the selected note: as Rename; a note in a background tab: **its tab closes** | the tab follows the file (T2) |
| click an attachment | **an editor tab** behind the viewer | the viewer in the active tab; no editor (T13) |
| + or ⌘T | — | a new Start tab (T4, T5) |
| × or Close Tab on the last tab | × leaves no tab; Close Tab is disabled | the tab becomes a Start tab (T7) |
| ⌘W with one tab, or with no note selected | closes the window (with any tabs still open) | closes the window when there is one tab; with several, closes the active one (there is always one) |
| close a tab whose changes could not be saved | **the changes are discarded** | asked first (T7) |
| Move to Trash on the open note | its tab closes (unless it holds unsaved text); the selection clears, so the strip hides while the other tabs stay open | its tab closes (T7); the neighbour becomes active |
| Close Collection | its notes' tabs close (unless they hold unsaved text); the selection clears if it was in it, so the strip hides over the remaining tabs | its notes' tabs close (T7) |
| tap a collection in the compact Notes place | the selection clears and the strip hides | the active tab is left alone (T14) |
| Back / Forward | — | ⌘[ / ⌘], ‹ ›, Go menu (T6) |
| relaunch | the active note returns | **every tab returns** (T11) |
| View ▸ Show Tab Bar (Mac) | macOS window tabs | gone (T0) |

---

## 6. State model

How the design maps onto the code. The shape, not the implementation.

```swift
@MainActor @Observable
final class WindowTabs {                  // replaces EditorTabs, one per main window
    private(set) var tabs: [Tab]          // strip order; never empty
    private(set) var activeID: Tab.ID
    private(set) var editors: [URL: EditorModel]   // one per note shown in any tab
    private(set) var history: [Item]      // T6, capped at 50
    private(set) var position: Int
    private(set) var closed: [Tab]        // T7, up to 10

    func open(_ item: Item, in: Placement)  // .active or .newTab: T2, T3, T4
    func newTab()                            // a Start tab: T4, T5
    func close(_ id: Tab.ID) async -> CloseOutcome   // flush; .needsConfirmation if unsaved (T7)
    func back(); func forward()              // T6
}

struct Tab: Identifiable { let id: UUID; var item: Item? }   // nil is the Start page
enum Item: Hashable { case note(URL), file(URL) }
```

- **The window's selection becomes a projection.** Reading `selectedNoteID`
  gives the active tab's item. Writing it means "open this in the active tab".
  So every route in §5 that sets the selection today keeps working and gets T2
  and T3 for free. Only the routes that open a new tab (T4, and T2's outside-the-
  window rule) call `open(_:in: .newTab)`.
- **Editors are keyed by file URL**, created when an item enters a tab and
  released when no tab shows it, after a flush. An editor whose flush failed is
  kept, which is what T2's and T7's protections rest on.
- **Persistence:** `@SceneStorage("openTabs")` holds `{items: [path or null],
  active: index}`. `restoredNotePath` is retired.
- **Window tabbing:** `NSWindow.allowsAutomaticWindowTabbing = false`, set once
  at launch on the Mac (T0).
- **Attachments** never reach `EditorModel` (T13), which removes
  `openSelectedNote`'s "treat any existing file as a note" path for them.

---

## 7. What this changes in the other documents

| Document | Change |
|---|---|
| `toolbars.md` §3 | the bar gains ‹ › before the strip and + after it; the strip is always drawn; §3.1's sliver is replaced by T9's fallback; the compact bar becomes one row (T14) |
| `menu.md` | File gains New Tab, Close Other Tabs and Reopen Closed Tab; a Go menu (Back, Forward); Window's Show Previous/Next Tab act on note tabs; the OS's window-tab items go (T0) |
| `primary.md` | a click shows the note in the active tab; ⌘-click and Open in New Tab; row menus gain Open in New Tab |
| `ui.md` | the empty editor is the Start page; L21 becomes built |

---

## 8. Changes from today, in one list

1. Opening replaces the active tab's item instead of adding a tab (T2).
2. An item is never in two tabs of a window (T3; mostly true today).
3. New Tab, +, ⌘-click, ⌘Return and Open in New Tab exist (T4).
4. The Start page replaces "Select a Note" (T5).
5. Back and Forward, and a Go menu (T6).
6. Closing asks before it discards unsaved changes; Close Other Tabs, Close Tabs
   to the Right and Reopen Closed Tab exist; the last tab becomes a Start tab
   (T7).
7. The strip is always drawn, has a floor and a menu fallback, disambiguates
   equal titles, shows status, and can be reordered (T8–T10).
8. Every tab is restored after a relaunch (T11).
9. Attachments open in tabs without an editor (T13).
10. The phone's expanded note has one bar (T14).
11. macOS window tabbing is off (T0).
12. A capture no longer navigates, and a rename or a move keeps the note's tab
    where it is (T2).
13. Closing a collection by any route closes its notes' tabs, asking first about
    unsaved changes (T7).

---

## 9. How it will be verified

- **Unit (`WindowTabsTests`)**: one test per row of §5; history (Back activates a
  tab, reopens into the active tab, skips a deleted note, follows a rename);
  T3's dedup; the Start page is never in history; T7's guard, **with a negative
  control** (closing a tab whose save failed, without the guard, loses the text
  — the test must fail that way first); restoration round-trip, including a
  missing file; the ⌘W rule.
- **`ShellComplianceTests`**: nothing creates an `EditorModel` for the main window
  except `WindowTabs`; every open route goes through `open(_:in:)`; no attachment
  reaches an editor.
- **Chrome parity** (`scripts/chrome-parity.sh`): the bar scene gains ‹ ›, +, a
  status glyph, a disambiguated title and the tab-menu fallback, compared
  pixel for pixel on both platforms.
- **UI tests** (`HelloNotesUITests`, iPhone and iPad): + makes a Start tab; a
  note chosen from it lands in that tab; closing the last tab leaves a Start
  tab; tabs survive a relaunch.
- **The menus**, read from the running Mac app through the accessibility API
  (as `menu.md` §3 was): the window-tab items are gone, and the new items and
  shortcuts are there.
- **VoiceOver** on both platforms (T16).
