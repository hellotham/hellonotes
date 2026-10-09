---
status: CURRENT (2026-10-09; View's Graph and Mind Map from source, D13). The menu bar as built on macOS and iPadOS, the
command palette, every keyboard shortcut, and the gaps (§8). The macOS menus in
§3 were read from the running app through the accessibility API on 2026-09-24
(Debug build, no window key, which is why the collection submenus are absent
from that reading). The app's own items are from `UI/AppCommands.swift`.
Overview: `ui.md`.
---

# The menu bar

The menu bar is meant to be the app's **primary discoverability surface**:
every command the app has lives there with its shortcut, and every bar and
in-window menu is a shortcut to it (`ui.md` principle 5). The command palette is
generated from the same commands. Where that is not yet true, §8 says so.

---

## 1. How it works

- **One definition, both platforms.** `HelloNotesCommands` (`AppCommands.swift`)
  is ungated. iPadOS 26 and later build a menu bar from a scene's `.commands`
  exactly as macOS does; gating the file had once removed the iPad's whole menu
  bar and every keyboard shortcut. **Nothing in it is gated by platform** except
  the iPad's own Settings… item (the Mac gets that one from its `Settings`
  scene). A command that cannot run on a platform greys out because its action
  is missing, not because it was left out of the menu.
- **It acts on the frontmost main window.** Each main window publishes its
  commands as one value, `AppActions`, through a focused scene value. A command
  reads it from the key window and **greys out when it does not apply** there.
  A note window publishes nothing, so with a note window key, or no window at
  all, almost everything is disabled (§3 was read in that state).
- **Every command is meant to belong in `AppActions`**, including ones
  implemented as a notification or an `openWindow`, because the palette is
  generated from it and a command that reached the menu bar some other way is
  invisible there. A fact-check once found eight that had. Two still bypass it:
  HelloNotes Help and Dictate to Daily Note (§8).
- **While Open Quickly is up**, some commands dismiss it first and then run
  (`closingOpenQuickly`): New Note, Today's Note, Open…, Graph, Mind Map, Ask
  Library, Assistant, Close Tab (and ⌘W), New Note from a Prompt and Search All
  Collections. The note, format, AI, Review Links and Find commands grey out
  instead, so they cannot act on the note behind it. Everything else does
  neither (§8, item 4).

### Platforms

| | macOS | iPadOS | iPhone |
|---|---|---|---|
| Menu bar | always | built from the same commands; the system decides when to show it, so the app treats it as out of sight and keeps a touch route for almost everything (§8, item 1 lists the exceptions) | **none** |
| Settings | the `Settings` scene puts **Settings… ⌘,** in the app menu; the bar's ⚙ opens the same view as a sheet | the app adds **Settings… ⌘,**, which opens the Settings sheet; it greys out with no window. The bar's ⚙ opens it too | the Library place's More ⋯, and the AI place's AI Settings… |
| Mac-only | the system's Services, Hide, Quit and window-tab items; the menu-bar extra (§6); the Services provider; the global shortcut | — | — |

On **iPhone** every command's route is in the compact shell: the places' bars
(the Notes place's `+` and More ⋯), the AI place, the open note's Note Actions,
and the row menus
([primary.md](primary.md) §10, [toolbars.md](toolbars.md) §3.3). The exceptions,
which an iPhone cannot reach at all, are listed in §8, item 1.

---

## 2. Order

**HelloNotes · File · Edit · View · Note · Format · Window · Help** (macOS, as
read). SwiftUI places the two custom menus, Note and Format, after View.

---

## 3. The menus

*(system)* marks an item the OS supplies. "A window" means a main window is key.

### 3.1 HelloNotes (the app menu)

| Item | Shortcut | Enabled when | Notes |
|---|---|---|---|
| About HelloNotes | | always | shows the splash over the key main window until it is tapped or Escape is pressed. With no main window key (none open, or a note window in front), it opens a new main window and shows no splash, because the launch splash appears once per launch |
| Acknowledgements… | | a window | licences and credits, beside About rather than in Settings |
| — | | | |
| Settings… | ⌘, | macOS: always *(system, from the `Settings` scene)*; iPad: a window (the app's own item, opening the Settings sheet) | |
| — Services ▸ | | | *(system, macOS)* |
| — Hide HelloNotes · Hide Others · Show All | ⌘H · ⌥⌘H | | *(system, macOS)* |
| — Quit HelloNotes | ⌘Q | | *(system, macOS)*. Pending autosaves are drained first (`TerminationGuard`), for up to 5 seconds |

### 3.2 File

| Item | Shortcut | Enabled when |
|---|---|---|
| New Note | ⌘N | a collection is in scope |
| New Window | ⌥⌘N | a window |
| Today's Note | ⇧⌘T | a collection is in scope |
| New Note from a Prompt… | ⌃⌘N | a collection is in scope |
| — | | |
| Open… | ⌘O | a window. Opens the launcher: recent collections, saved libraries, and every way to add a collection |
| Open Default Collection | | a window. Restores the bundled collection if its files were deleted |
| Quick Capture… | ⌃⌘K | a collection is open |
| Open Quickly… | ⇧⌘O | the scope collection has notes |
| — | | |
| Rescan Collection | ⌥⌘R | a collection is in scope |
| — | | |
| Close Tab | *(⌘W, not shown)* | more than one tab is open, and the selected note has its editor |
| — Close · Close All | ⌘W · ⌥⌘W | *(system, macOS)* |
| — | | |
| Export as HTML… | | a note is open |
| Export as PDF… | | a note is open |
| — | | |
| Command Palette… | ⇧⌘P | a window |
| — | | |
| Refresh Cloud Collection | | the scope collection is a direct-API cloud collection |
| — | | |
| New Collection ▸ Empty Folder… · Git Repository… | | present only with a window |
| Open Collection ▸ from Folder… · from iCloud Drive… · from Obsidian Vault… · from Cloud… · from Repository… | | present only with a window |
| Print… | ⌘P | a note is open |

**⌘W** is not attached to Close Tab: SwiftUI will not reliably give a menu item
a key equivalent that the system's Close already owns. Instead the main window
claims ⌘W itself while it has more than one tab, so ⌘W closes the tab then and
the window otherwise, as Safari does ([tabs.md](tabs.md) §2). Close Tab is the
visible, clickable twin.

### 3.3 Edit

| Item | Shortcut | Enabled when |
|---|---|---|
| Undo · Redo | ⌘Z · ⇧⌘Z | *(system)* |
| Cut · Copy · Paste · Delete · Select All | ⌘X · ⌘C · ⌘V · · ⌘A | *(system)* |
| — | | |
| Find… | ⌘F | a note is open. Shows or hides the note's Find & Replace bar, switching to Edit first if needed |
| Search All Collections | ⌥⌘F | a window. Puts the caret in the bar's search field and shows a hidden sidebar |
| — Writing Tools ▸ · AutoFill ▸ · Start Dictation… · Emoji & Symbols | | *(system)* |

### 3.4 View

| Item | Shortcut | Enabled when |
|---|---|---|
| Show Tab Bar · Show All Tabs | · ⇧⌘\ | *(system, macOS window tabs; see §8)* |
| — | | |
| Edit · Preview · Markdown · Split | ⌘1 · ⌘2 · ⌘3 · ⌘4 | a window; the current mode is ticked |
| — | | |
| Graph | ⇧⌘G | a note is open. Opens the panel on the note's Graph — its links in and out (it was "Graph View", the whole collection's, until D13) |
| Mind Map | ⇧⌘M | the scope collection has notes. Opens the Mind Map — the links across the collection — as a tab |
| Ask Your Library | ⇧⌘J | there are notes. Opens it as a tab |
| Assistant | ⇧⌘A | a window. Opens the Assistant as a tab |
| — | | |
| Show Non-Note Files | | a collection is in scope; a toggle |
| — Enter Full Screen | | *(system)* |

### 3.5 Note

| Item | Shortcut | Enabled when |
|---|---|---|
| Rename… | ⇧⌘R | a note is open |
| Duplicate | ⌘D | a note is open |
| Add Bookmark / Remove Bookmark | ⇧⌘D | a note is open |
| — | | |
| Summarise Note | | a note is open and a model can answer. The summary appears in the panel's Outline (but see `secondary.md` §9, item 1) |
| Suggest Tags | | the same. In the panel's Tags |
| Suggest Links | | the same. In the panel's References |
| Rewrite or Expand Note… | | the same. A sheet that shows the result before replacing anything |
| Review Links… | ⇧⌘L | a note is open. An exact text scan, so it needs no model |
| — | | |
| Insert Template ▸ *each template* | | the scope collection has templates and a note is open |
| — | | |
| Copy Wiki Link | | a note is open |
| Open in New Window | | a note is open |
| Reveal in Finder (Reveal in Files on iPad) | | the note's file can be revealed |
| — | | |
| Move to Trash | ⌘⌫ | a note is open |
| — | | |
| Dictate to Daily Note / Stop Dictation | ⌃⌘D | dictation is supported, whether or not a window is open |

The AI actions are here, in the menu that owns the note, rather than in an
"Intelligence" menu: someone looking for a way to summarise is thinking about
the note, not about which subsystem answers.

### 3.6 Format

| Item | Shortcut |
|---|---|
| Bold | ⌘B |
| Italic | ⌘I |
| Strikethrough · Highlight · Inline Code | |
| — | |
| Heading 1 · Heading 2 · Heading 3 | ⌥⌘1 · ⌥⌘2 · ⌥⌘3 |
| — | |
| Blockquote | |
| Bulleted List | ⇧⌘7 |
| Numbered List | ⇧⌘9 |

Enabled when a note is open **in Edit mode**: the formatting bus is installed by
the live editor, which is mounted only in Edit. The same commands are also on
the iPad's system shortcuts bar and in the iPhone's accessory toolbar above the
keyboard ([toolbars.md](toolbars.md) §9).

### 3.7 Window *(system)*

macOS: Minimize (⌘M), Minimize All, Zoom, Zoom All, Fill, Center, Move & Resize ▸,
Full Screen Tile, Bring All to Front, Arrange in Front, Remove Window from Set;
**Show Previous Tab (⌃⇧⇥), Show Next Tab (⌃⇥), Move Tab to New Window, Merge All
Windows** (window tabs, §8); then the open windows. The app adds nothing to
this menu.

### 3.8 Help

| Item | Notes |
|---|---|
| HelloNotes Help | opens the project page (`https://github.com/hellotham/hellonotes`) |

---

## 4. The command palette

**File ▸ Command Palette… (⇧⌘P)**: the app's commands, found by name
(`CommandPaletteView`, built by `AppActions.paletteCommands`).

- **Disabled commands are omitted, not greyed.** A menu shows what exists in a
  fixed place you can learn; a search result you cannot act on is a dead end.
- **What it lists:** the menus' commands, plus one row per template ("Insert
  Template: *name*") and one per way of adding a collection. The editor modes
  appear only as the three you are not in. It has no row for itself, and none
  for **About**, **Settings…**, **Open Default Collection** or **HelloNotes
  Help**.
- **Each row shows its group** (File, Edit, View, Assistant, Note, Format or
  Help) as a caption. With the query empty the rows are in the order they were
  added, not in sections; once you type they are ranked by how well they match.
- **Only thirteen rows show a shortcut.** None is shown for Today's Note,
  Rescan, Rename, Duplicate, Bookmark, Move to Trash, the modes, the launcher
  (⌘O in the menu), or the Format commands that have one in the menu (Bold,
  Italic, the headings and the lists).
- The Format rows appear only in Edit mode, like the menu.
- **It has no touch route.** It opens from ⇧⌘P or File ▸ Command Palette…, so
  it needs a keyboard or the menu bar. Nothing in the bar or the compact places
  opens it (§8).

---

## 5. Menus inside the window

The app draws these buttons; the OS draws the menus they open.

| Menu | Where | Document |
|---|---|---|
| **New Note +** | the bar | [toolbars.md](toolbars.md) §3.2 |
| **Search 🔍** | the bar | [toolbars.md](toolbars.md) §3.2 |
| **Note Actions ⌄** | the bar, with a note open | [toolbars.md](toolbars.md) §3.3 |
| **Add Folder or Collection +** | the sidebar's header, and the phone's Notes place | [primary.md](primary.md) §7, §10 |
| **Row menus** (`…` and context menus) | sidebar, band and compact rows | [primary.md](primary.md) §6 |
| **✦ AI** and **Export** | the editor's status bar | [toolbars.md](toolbars.md) §5.1 |
| **The panel's pull-down** | the panel's header, when narrow | [secondary.md](secondary.md) §3 |
| **The editor's selection menu** | a right-click (Mac) or the edit menu (iOS) over a selection | Rewrite with AI…, Link to "*title*", Find Related, Ask Your Library, beside the system's items ([toolbars.md](toolbars.md) §9) |
| **The Library place's More ⋯** | the compact shell | [primary.md](primary.md) §10 |

---

## 6. Beyond the window (macOS)

| Entry point | What it does |
|---|---|
| **Menu-bar extra** (`note.text`, "HelloNotes") | Quick Capture in a small window from the menu bar, into today's daily note, without switching apps. The same capture is File ▸ Quick Capture… (⌃⌘K) on both platforms |
| **Services ▸ New HelloNotes Note from Selection** | in other apps' Services menus, when text is selected: a new note from it |
| **⌃⌥⌘N, system-wide** | brings HelloNotes forward and starts a new note (`GlobalHotKey`). Three modifiers, so it shadows neither ⌥⌘N (New Window) nor ⌃⌘N (New Note from a Prompt) |

iOS has none of these: a background app cannot register a system-wide shortcut
or extend another app's menus.

---

## 7. Every keyboard shortcut

**Menu commands**

| Shortcut | Command | Where it lives |
|---|---|---|
| ⌘, | Settings… | app menu |
| ⌘1 · ⌘2 · ⌘3 · ⌘4 | Edit · Preview · Markdown · Split | View |
| ⌥⌘1 · ⌥⌘2 · ⌥⌘3 | Heading 1 · 2 · 3 | Format |
| ⇧⌘7 · ⇧⌘9 | Bulleted List · Numbered List | Format |
| ⇧⌘A | Assistant | View |
| ⌘B · ⌘I | Bold · Italic | Format |
| ⌘D · ⇧⌘D | Duplicate · Add/Remove Bookmark | Note |
| ⌃⌘D | Dictate to Daily Note | Note |
| ⌘F | Find… | Edit |
| ⌥⌘F | Search All Collections | Edit |
| ⇧⌘G | Graph | View |
| ⇧⌘J | Ask Your Library | View |
| ⇧⌘M | Mind Map | View |
| ⌃⌘K | Quick Capture… | File |
| ⇧⌘L | Review Links… | Note |
| ⌘N | New Note | File |
| ⌥⌘N | New Window | File |
| ⌃⌘N | New Note from a Prompt… | File |
| ⌃⌥⌘N | a new note, from any app (macOS) | system-wide |
| ⌘O · ⇧⌘O | Open… · Open Quickly… | File |
| ⌘P · ⇧⌘P | Print… · Command Palette… | File |
| ⇧⌘R · ⌥⌘R | Rename… · Rescan Collection | Note · File |
| ⇧⌘T | Today's Note | File |
| ⌘W | Close Tab while several are open; otherwise the window's Close | the window |
| ⌘⌫ | Move to Trash | Note |

**Keys inside views**

| Key | Does | Where |
|---|---|---|
| Esc | closes the panel, the find bar, or a sheet (their cancel actions); dismisses Open Quickly, the palette and the splash; clears an inline suggestion; **denies** an Assistant edit awaiting approval | wherever it applies |
| Return | presses a sheet's default button; opens or runs the selected row in Open Quickly and the palette; sends in the Assistant; **approves** an Assistant edit awaiting approval; asks the question in Ask Library; goes to the next match in the find bar | wherever it applies |
| ↑ · ↓ | moves the selection: through notes and attachments in the sidebar column (when focused), notes and headings in Open Quickly, commands in the palette, revisions in the History list | those lists |
| ↑ or ← at the top of a note | moves the caret into the note's title | the editor |
| ↓, Return or Tab in the title | moves the caret into the note's body | the note's title |
| ⌥⇥ | accepts an inline completion (also → at the end of a line, on the Mac) | the editor |
| ⌥Esc or F5 | asks for a completion (macOS) | the editor |
| ⌘Return | saves a Quick Capture | Quick Capture |
| ← · → | previous / next slide | the slides view |
| ← · → | previous / next diagram, when the note has more than one | the diagram zoom |

---

## 8. Open defects and gaps

1. **Commands with no menu item.** Principle 5 says every command has one.
   These have none:
   - **Show / Hide Sidebar.** Proposed: View ▸ Show Sidebar / Hide Sidebar, ⌃⌘S
     (the macOS convention).
   - **Show / Hide Panel**, and the panel's **Summary & Outline, Tags, Links,
     Properties** and **History**. Proposed: View ▸ Show Panel / Hide Panel
     (⌥⌘I), and View ▸ Panel ▸ with all six views, the Graph keeping ⇧⌘G.
   - **Present as Slides** and **View Diagram** (Note Actions and the status
     bar only — and, for the diagram zoom, the View diagram button on each
     diagram).
   - The collection commands: **New Folder…**, **Focus Collection**, **Close
     Collection** and a collection's **Reveal**; a folder's **New Note Here**,
     **New Folder Here…**, **Reveal** and **Move to Trash**; an attachment's
     **Open in Default App**; and a note's **Download / Remove Download**. They
     are in row menus and the sidebar's `+` only.
   - **Git**: Initialize Repository, Commit, Push, Fetch and Connect Remote live
     only in the Git pane — the sidebar's Git row, or a note window's bottom
     bar.
   - The reverse gap, menu items with **no touch route**: the **Command
     Palette**, **Insert Template**, **About**, **Acknowledgements…**,
     **HelloNotes Help** and **New Window**. A keyboard-less iPad reaches them
     only through the menu bar, and an iPhone not at all. **Dictate to Daily
     Note** has had one on a wide iPad since D14, the bar's `+`.
   - **On iPhone** (and in a narrow iPad window, the compact shell), the bar's
     `+` and 🔍 are not drawn, so **Today's Note**, **Open Quickly** and
     **Dictate to Daily Note** have no touch route there; the Search place
     searches, and its bar has **New Note**.
2. **Two tab systems on the Mac.** View ▸ Show Tab Bar and Show All Tabs, and
   Window ▸ Show Previous/Next Tab, Move Tab to New Window and Merge All
   Windows, are macOS's **window** tabs. They appear because the app never
   turned window tabbing off. They have nothing to do with the note tabs in the
   bar, and the iPad has neither. [tabs.md](tabs.md) T0 turns them off and gives
   Show Previous/Next Tab to the note tabs.
3. ✅ ~~**The palette disagrees with the menus.**~~
   - *Shortcuts:* it labels Open Quickly with ⌘O (the menu, correctly, says
     ⇧⌘O), and writes modifiers as ⌘⇧ where the menu shows ⇧⌘.
   - *Names:* "Find in Note", "Rename Note", "Duplicate Note", "Bookmark Note",
     "Ask Your Library", "Edit Mode" and the other modes, and "Open Quickly" and
     "Acknowledgements" without their "…".
   - *One name, two things:* the palette's "Open Collection" is the launcher
     (the menu's Open… ⌘O), while the menu's Open Collection ▸ is the
     add-a-collection submenu.
   - *Groups:* Dictation is under Edit, Export and Print under Note,
     Acknowledgements under Help (the menu has it in the app menu), and Ask Your
     Library and Assistant under "Assistant" (the menu has them in View).

   One vocabulary and one notation, derived from the menu, would stop the drift.
4. ✅ ~~**Some commands ignore Open Quickly.**~~ Insert Template stays enabled while
   Open Quickly is up and inserts into the note behind it. New Window, Open
   Default Collection, Rescan Collection, Refresh Cloud Collection, the editor
   modes, Show Non-Note Files, About, Acknowledgements, Settings, Quick Capture,
   the palette, Dictation, Help and every New/Open Collection ▸ item neither
   grey out nor dismiss it. From Open Collection ▸ from Cloud… and from
   Repository…, and New Collection ▸ Git Repository…, their sheets open on top
   of Open Quickly (§1). *Fixed (implemented.md §51.36).*
5. ✅ ~~**Open Quickly is enabled for one collection and searches another.**~~ It is
   enabled when the sidebar's scope collection has notes, but it searches the
   focused collection. *Fixed (implemented.md §51.36).*
6. **Two commands bypass `AppActions`**: HelloNotes Help and Dictate to Daily
   Note, so neither follows the key window.
7. **Close Tab shows no shortcut**, so ⌘W's tab behaviour cannot be learned from
   the menu.
8. **Doubled separators in File**: after Close Tab, and before Print whenever
   the collection submenus are absent. *The divider before Print is fixed (implemented.md §51.36); the one after Close Tab was not reproduced.*
9. ✅ ~~**Inconsistent labels.**~~ "Summarise" in the menus, palette and panel;
   "Summarize" in the compact AI place and the Welcome screen. Rewrite is
   "Rewrite or Expand Note…" in the Note menu, "Rewrite or Expand…" in Note
   Actions and "Rewrite Note…" in the AI place. The launcher has three names:
   Open… (File), Open Collection (the palette) and Open Recent… (the `+` menu,
   More ⋯ and the Library place). The palette says "Hide Non-Note Files" where
   the menu shows a ticked "Show Non-Note Files". *Fixed (implemented.md §51.36).*
10. ✅ ~~**Review Links is greyed out with no model**~~ in the compact AI place,
    although it needs no model (the Note menu gets this right). *Fixed (implemented.md §51.36).*
11. ✅ ~~**Acknowledgements greys out with no window**~~, although it concerns the app,
    not a window. About does not grey out. *Fixed (implemented.md §51.36).* *Fixed (implemented.md §51.36).*
