---
status: CURRENT (2026-09-24). Every bar the app draws, as built, with its open
defects (§14). Decision record: `shell-chrome.md` D1, D3, D8, D9, D10, D11, D12;
the formatting decision is L20 in `ui.md` §11. Overview: `ui.md`.
---

# Toolbars

HelloNotes has **no system toolbar** on either platform. Every bar is a row (or
a status strip) that the app draws from `Chrome` tokens, so the Mac and the iPad
show the same pixels (D12). This document lists every one: what is in it, in
what order, at what size, and when it shows.

---

## 1. Rules every bar follows

1. **One row of chrome** (D1). In a column window the sidebar header, the bar
   over the editor and the panel header sit side by side at 40pt and make one
   row. In a tall window the band's header sits above the bar, because the band
   is above the editor. Nothing may add a row beneath them. Three panel views
   still do: Graph adds two rows, the Mind Map and the Assistant one each
   (§11, §14).
2. **A bar is a shortcut.** The rule is that every command in a bar is also in
   the menu bar ([menu.md](menu.md)), and the bar is the touch-reachable and
   one-click route. iPhone has no menu bar, so there the bars and places carry
   every route themselves. **The rule is not yet met**: Show/Hide Sidebar,
   Show/Hide Panel, New Folder…, Mind Map, Present as Slides, View Diagram,
   Download / Remove Download, the status bar's Properties, Links and Outline,
   Version History, the Git pane, the collection status bar's Stop, Try Again,
   Locate… and Remove, and the Assistant's New conversation have no menu item
   (§14, [menu.md](menu.md) §8).
3. **Buttons never move and never fold away.** When a bar runs short, the
   flexible content gives way: the search field (120–180pt) and the tabs share
   what the buttons leave, and the tabs scroll. There is no `»` overflow.
4. **Every control has a name**, not just a picture: a tooltip (`.help`) and an
   accessibility label on each glyph button, and a `Label` behind each menu
   button so the system can title it wherever it reads one
   (`ShellComplianceTests`: "Every control that can fold into a toolbar's
   overflow has a name").
5. **Fixed metrics** (`Chrome.Metric`): a 40pt row, 28pt bar buttons (14pt
   glyphs in 28pt squares, radius 6) with an invisible 44pt hit area, 10pt
   padding, 4pt spacing, the chrome grey (`Chrome.Colour.chrome`), and a 1pt
   separator on the edge that faces the content.
6. **A button that is on** is drawn in the accent over the accent at 30%. A
   hovered button gets a faint fill. A disabled one is dimmed to 35%.

---

## 2. Inventory

| Bar | Where | Height | Shells | Code |
|---|---|---|---|---|
| **Shell bar** | over the editor | 40 | all (reduced on compact) | `ContentView.shellBar` |
| **Sidebar header** | top of the primary sidebar or band | 40 | column, tall | `ContentView.sidebarHeader` |
| **Panel header** | top of the right panel | 40 | all | `SidePanelHeader` |
| **Graph controls** | under the panel header, in Graph: two rows | ≥ 36, then a counts-and-zoom row | all | `GraphPane.controls`, `GraphView` |
| **Mind Map header** | under the panel header, in Mind Map | content | all | `MindMapView.header` |
| **Assistant header** | under the panel header, in the Assistant | content | all | `AssistantView.header` |
| **Editor status bar** | under an open note | 44 | all, and note windows | `NoteEditorView.bottomBar` |
| **Collection status bar** | under the empty editor | 44 | column, tall | `ContentView.noNoteStatusBar` |
| **Find & Replace bar** | over the note, when open | 2 rows | all, and note windows | `FindReplaceBar` |
| **Condition strips and banners** | over the tree or the note | content | all | `CollectionStatusStrips`, `EditorBanners` |
| **Compact tab bar** | bottom of the screen | 49 + safe area | compact | `CompactTabBar` |
| **Place bar** | top of each compact place | 40 | compact | `CompactPlaceBar` |
| **Mini strip** | above the compact tab bar | 56 | compact | `CompactShell.miniStrip` |
| **Expanded note bar** | top of a full-screen note | 40 | compact | `CompactShell.expandedNote` |
| **Note window bar** | top of a note window | 40 | note windows | `NoteWindowView.windowBar` |
| **Sheet bar** | top of a sheet | 40 | eight sheets | `ChromeSheetBar` |
| **Sheet tops of their own** | top of seven more sheets | content | sheets | §10 |
| **Settings tab strip** | top of Settings | 58 | Settings | `SettingsTabStrip` |
| **Formatting** | the OS's keyboard bar | the OS's | iPad, iPhone | `EditorCommands.installFormattingAssistant` |

---

## 3. The shell bar

The bar over the editor, and the only bar that carries the window's commands.
Its order is the iPad's layout at the Mac's scale, the same on both platforms:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ [🔍 Search      ] [⊟] [✎] [⋯] │ Note A × │ Note B × │…            [⌄] [◨]    │
└──────────────────────────────────────────────────────────────────────────────┘
  field 120–180     28   28   28   tabs: the flexible middle          28   28
```

**Search · Sidebar · New Note · More ⋯ | the open notes' tabs | Note Actions ⌄
· Panel.** 40pt tall, 10pt padding, 4pt between items, the chrome grey, a 1pt
rule below, and the window drags by its background (Mac). With the sidebar
hidden the bar is the window's top-left corner, so on the Mac it pads its
leading end by 78pt for the traffic lights (`WindowControls.leadingInset`; 0 on
iOS).

| # | Item | Glyph | What it does | Shown |
|---|---|---|---|---|
| 1 | **Search** field | `magnifyingglass` | searches every open collection; the results replace the tree in the primary sidebar ([primary.md](primary.md) §3.2). The placeholder "Search" is drawn by the app; a clear button (`xmark.circle.fill`) appears with text; Return leaves the field. ⌥⌘F puts the caret here and shows a hidden sidebar. VoiceOver: "Search all collections" | not on compact |
| 2 | **Show Sidebar / Hide Sidebar** | `sidebar.leading` | hides or shows the primary sidebar, or the band on a tall shell | not on compact |
| 3 | **New Note** | `square.and.pencil` | creates a note in the sidebar's scope collection, or in the band's chosen container ([primary.md](primary.md) §9); disabled with no collection | not on compact |
| 4 | **More** ⋯ | `ellipsis.circle` | a menu (§3.2). VoiceOver: "More actions" | not on compact |
| 5 | **Tabs** | — | the open notes; flexible; scrolls when it does not fit ([tabs.md](tabs.md)) | only while a note is open; otherwise empty space |
| 6 | **Note Actions** ⌄ | `chevron.down.circle` | a menu (§3.3) | only while a note is open |
| 7 | **Show Panel / Hide Panel** | `sidebar.trailing` | shows or hides the right panel; drawn on while the panel shows | always |

### 3.1 Narrow widths

The five buttons are fixed. The search field (120–180pt) and the tabs share
whatever is left. SwiftUI sizes the field first and offers it a share, so the
two shrink together and the tabs can start scrolling before the field reaches
its 120pt minimum. **There is no floor under the tabs.** The bar's fixed part
(padding, five buttons, six gaps and the field at its minimum) is 304pt.

- **At the Mac's minimum window (860pt)** with a 280pt sidebar and the panel
  open, the panel is clamped to 259pt and the editor is 319pt. That leaves the
  tabs about 15pt, a sliver.
- **With the sidebar dragged to 340pt**, the panel sits at its 220pt floor and
  the editor gets 298pt. The tabs get nothing, and the bar's fixed part
  overflows the editor by 6pt.

[tabs.md](tabs.md) T9 designs the fallback. The overflow itself is the shared
width budget in `ui.md` §12, item 2.

### 3.2 More ⋯

| Item | Glyph | Enabled when |
|---|---|---|
| Today's Note | `calendar` | a collection is open |
| Quick Capture… | `square.and.pencil.circle` | a collection is open |
| Open Quickly… | `arrow.forward.square` | the scope collection has notes |
| — | | |
| Assistant | `sparkles` | a collection is open |
| Ask Your Library | `sparkles.rectangle.stack` | there are notes |
| New Note from a Prompt… | `sparkles.square.filled.on.square` | a collection is open |
| Graph View | `point.3.connected.trianglepath.dotted` | the scope collection has notes |
| — | | |
| Settings… | `gearshape` | always |
| — | | |
| New Folder… | `folder.badge.plus` | a collection is open |
| New Collection ▸ | Empty Folder… · Git Repository… | |
| Open Collection ▸ | from Folder… · from iCloud Drive… · from Obsidian Vault… · from Cloud… · from Repository… | |
| — | | |
| Open Recent… | `clock.arrow.circlepath` | |
| Open Default Collection | `books.vertical` | |

Settings sits above the folder and collection commands on purpose: a menu from a
bar in the middle of a portrait iPad is capped at about 520pt and scrolls, and
Settings fell below the fold when it came last (`implemented.md` §51.4). The
folder and collection commands have visible homes of their own (the sidebar's
`+` and each row's `…`).

### 3.3 Note Actions ⌄

Everything that acts on the open note, in one menu, so the tabs keep the width.
It is the touch route to the note's commands. Most are also in the menu bar;
Show/Hide Panel, Mind Map, Present as Slides, View Diagram and Download /
Remove Download are not (§14).

| Group | Items |
|---|---|
| View | an inline picker: **Edit · Preview · Markdown · Split** |
| — | **Show Panel / Hide Panel** |
| — | **Mind Map** · **Present as Slides** (a Marp deck only) · **View Diagram** (only if the note has one) |
| — "Using *model*" | **Summarise Note** · **Suggest Tags** · **Suggest Links** · **Rewrite or Expand…** (only when a model can answer) |
| — | the note's row menu from the sidebar ([primary.md](primary.md) §6): Rename…, Duplicate, Add/Remove Bookmark · — · Copy Wiki Link, Open in New Window, Reveal in Finder/Files · — Download or Remove Download (cloud notes) · — Review Links… · — Export ▸ (Export as HTML…, Export as PDF…, Print…) · — **Move to Trash**, last |

### 3.4 Per shell

| Shell | Bar |
|---|---|
| Column, tall | all seven items |
| Compact, note expanded | **tabs · Note Actions · Panel** only (`showsShellCommands: false`): the Search place has the field, and the places carry the rest. It sits **under** the expanded note's own bar (§8.4) |

---

## 4. The headers in the columns

Both are 40pt rows in the chrome grey with a rule below.

- **Sidebar header**: empty at the leading end (the traffic lights sit there on
  the Mac) and **Add Collection** (`+`, a menu) at the trailing end. →
  [primary.md](primary.md) §7.
- **Panel header**: the strip of nine views (or a pull-down when it cannot fit)
  and **Close panel**. → [secondary.md](secondary.md) §3.

---

## 5. Status bars

Both status bars use the same drawing: 12pt text and glyphs in the secondary
label colour, a 34pt row with 5pt above and below (44pt in all), the chrome grey,
and a rule on top. The collection bar's rule is 1pt. The editor bar draws two
(§14). Their buttons are `ChromeStatusButton`: a 12pt glyph in a 22 × 18 frame
with a larger invisible target.

### 5.1 The editor status bar (a note is open)

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│ ⚠︎ Save failed │ ✎ 3 changed               [✎|👁|‹›|◫] │ 🔍 ☰ 🔗 ≡ 🧠 ▭ ⌁ ✦ ↺ ⇪ ⧉ │
└──────────────────────────────────────────────────────────────────────────────────┘
  status (left)                              mode          actions (right)
```

| Side | Item | Shown |
|---|---|---|
| left | **Save failed** (red, with the reason as its tooltip). Successful saves are never announced: a status that changes width twice a sentence moves the bar while you type | only after a failed save |
| left | **Clean** or **n changed** (orange) — a button opening the Git pane as a popover | the collection is a Git repository |
| right | **Mode**: a four-segment control, Edit · Preview · Markdown · Split (`ChromeSegmented`, 30 × 20 segments) | always |
| right | **Find & replace (⌘F)** | enabled in Edit only |
| right | **Edit front-matter properties**: a popover with the properties editor | always |
| right | **Links to and from this note**: a popover with the note's outgoing links, linked mentions and unlinked mentions | always |
| right | **Outline & statistics**: a popover | always |
| right | **Mind map of this note's ideas**: opens the panel on Mind Map | always |
| right | **Present as slides (Marp)** | a Marp deck |
| right | **View diagram**: the diagram zoom — in Edit, on the diagram the caret is in or else the nearest; in Markdown, Split and Preview, whose caret the zoom cannot read, on the first (each diagram's own button — in its corner in Edit and Preview, at the right-hand end of its first line in Markdown and Split — opens that one) | the note has a Mermaid block — asked when it loads and after each save, as the note menu asks |
| right | ✦ **Summarise, suggest and rewrite with *model***: a menu, Summarise Note, Suggest Tags, Suggest Links, —, Rewrite or Expand Note…, —, "via *model*" | a model can answer |
| right | **Version history (Git)**: a sheet | Git repository |
| right | **Export**: a menu, Export as HTML…, Export as PDF… | always |
| right | **Open this note in a new window** | always |

- **When it runs short, the row scrolls sideways** instead of truncating. Its
  controls are fixed-size, so the row cannot shrink. The switch to scrolling is
  decided from the offered width, not with `ViewThatFits`, so typing never
  re-decides the bar's shape. The threshold is 533pt measured *inside* the
  bar's 10pt padding, so the bar scrolls below 553pt: the padding was meant to be
  counted once and is counted twice. The 512.67pt minimum it was derived from
  was measured with one set of items. The Git, AI, Marp, Mermaid and
  Save-failed items change the real minimum.
- It sits in the **bottom safe-area inset**, so the system's keyboard bar and
  the software keyboard push it up instead of drawing over it. On iPad it also
  clears the floating shortcuts pill, which SwiftUI does not report with a
  hardware keyboard (`AssistantBarInset`).
- Every popover here states its compact adaptation, so on a phone it stays a
  popover instead of becoming a sheet with a 360pt island floating in it.
- **Note windows draw the same bar, but four items do not work there**: the
  ✦ AI menu never appears, Mind map does nothing, Links always says "No
  References", and the Git button (**Clean** / ***n* changed**) opens an empty
  popover. The note window passes no model, no mind-map action, no references
  and no collection. A selection in a note window also offers none of the
  vault actions (Link to, Find Related, Ask Your Library), because it passes
  none (§14).

### 5.2 The collection status bar (no note open)

Under the empty editor, while a collection is focused:

| Side | Item |
|---|---|
| left | the collection (`folder`) · *n* notes · *n* tags (when there are any) |
| left | where it lives: *Provider* (direct) with **Refresh**, or the cloud provider's name |
| left | *n* online-only (when there are any) |
| left | a scan long enough to mention: a progress bar or spinner, "Scanning *n* items…", **Stop** |
| left | **Unavailable** (orange) with **Try Again**, **Locate…**, **Remove**; or *n* files hidden (when Show Non-Note Files is off); or why the index is stale |
| right | the Git branch and a dirty dot, as a button opening the Git pane (not for a direct-API collection) |
| right | **New note** · **Today's note** · **Graph view** (with a tip) · **Ask your library** · **Assistant** |

---

## 6. The Find & Replace bar

Toggled by Edit ▸ Find… (⌘F) or the status bar's magnifier. It works in Edit:
⌘F from another mode switches to Edit first, and the magnifier is enabled in
Edit only. It sits above the note pane at full width.

```
┌───────────────────────────────────────────────────────────────────┐
│ 🔍 [Find                         ]   2 of 7   [⌃] [⌄]   [Done]    │
│ ⇄  [Replace                      ]          [Replace] [Replace All]│
└───────────────────────────────────────────────────────────────────┘
```

Return in the Find field goes to the next match; the chevrons go back and
forward (wrapping); **Done** (Escape) closes it and clears the highlights. It
closes itself when the editor switches to another note. The previous-match
button's tooltip promises Shift-Return, which nothing binds (§14).

---

## 7. Condition strips and banners

These are not command bars. They are rows that appear when the app has
something to say about the collection or the note: usually that something is
wrong, sometimes that a wait is under way or has finished. Each has a symbol, a
sentence and, where there is something to do, a button.

| Strip | Where | Says | Offers |
|---|---|---|---|
| Scan in progress | over the editor | three lines: how far the scan has got, and where | **Stop** |
| The last scan's summary | over the editor | "Scanned *name* — *n* notes…", or that it was stopped; clears itself after 6 seconds | — |
| Collection unavailable | over the note | "*name* is unavailable — *why*" | **Try Again**, **Locate…** |
| Index behind the folder | over the note | "*name*: *why*" | **Rescan**, when the cause is permanent |
| Search may be incomplete | over the sidebar tree, while searching | "These results may be incomplete — *collections*…" | — |
| Items not downloaded | over the sidebar tree, while searching | "*n* items aren't downloaded…" | **Download and Search** |
| Conflict | over the note | "This note changed on disk while you were editing." | **Reload**, **Keep Mine** |
| Save error | over the note | "This note couldn't be saved." | **Retry** |
| Downloading | over the note | the note is still downloading (a wait, not a fault) | — |
| Unloaded | over the note | the note could not be loaded | **Try Again** |

---

## 8. The compact bars

### 8.1 The tab bar

Four places, Notes (`folder`), Search (`magnifyingglass`), Tags (`number`) and AI
(`sparkles`): a 17pt glyph over a 10pt name. The chosen place's glyph is drawn
in the accent and its name in the label colour. 49pt tall, the chrome grey
running into the home-indicator area, a rule on top.

### 8.2 The place bar

Each place's own 40pt bar: its title centred (13pt semibold), its commands at the
trailing end. Library has **More ⋯**, Search has **New Note**, Tags and AI have
none ([primary.md](primary.md) §10).

### 8.3 The mini strip

56pt, directly above the tab bar, while a note is open: a document glyph, the
note's title at 12pt medium, and `chevron.up`. Tapping it shows the note full
screen. VoiceOver: "Open *title*".

### 8.4 The expanded note

A 40pt bar with **Back** (`chevron.down` and "Back", returning to the place and
closing the panel if it is open) and the note's title centred. **Under it, the
shell bar in its compact form (§3.4) is a second 40pt bar**, with the tabs,
Note Actions and the panel toggle. That is two rows of chrome, which D1 forbids
(§14).

---

## 9. Formatting: the bar the app does not draw

There is **no format bar** in the app (L20). A pane-level bar was designed (L3),
built twice, and removed: it spent 36–44pt of every editing screen
re-implementing a control the system already provides, and a hand-rolled
keyboard accessory drew over the status bar on an iPad with a hardware keyboard.

| Platform | Where formatting lives |
|---|---|
| **macOS** | the **Format** menu, with shortcuts: Bold ⌘B, Italic ⌘I, Heading 1–3 ⌥⌘1–3, Bulleted List ⇧⌘7, Numbered List ⇧⌘9, and Strikethrough, Highlight, Inline Code and Blockquote without shortcuts |
| **iPad** | the system's **shortcuts bar** (`inputAssistantItem`), the floating pill that carries the language selector and dictation, including with a hardware keyboard. Leading: **Text Style** (Bold, Italic, Strikethrough, Highlight, Code) and **Lists** (Blockquote, Bulleted List, Numbered List); trailing: **Headings** (1–3). A group collapses to its representative button when the pill is short |
| **iPhone** | an **`inputAccessoryView`**: a 44pt `UIToolbar` above the keyboard with all eleven commands in a row, since iPhone has no shortcuts bar |

Both editors install it: the live editor (Edit) and `SourceEditor` (Markdown and
Split). `EditorToolbarContractTests` checks the arrangement's outline in five
tests: that the shortcuts bar is used on iPad and an accessory on iPhone (and
that `NoteEditorView` does not contain the string `EditorFormatBar`); that both
editors install them; that `SourceEditor` answers the formatting, undo, redo and
end-editing notifications; that every formatting button and group is named; and
that every popover in `NoteEditorView` and `ContentView` states its compact
adaptation. It does not check which buttons are in each group, their order, the
count or the heights; those are described here from `EditorCommands.swift`.

**Selection actions** are menu items, not a bar. On a selection, the editor's
context menu on the Mac and the system edit menu on iOS offer **Rewrite with
AI…** first, then **Link to "*title*"** (only when a note of that name exists),
**Find Related** and **Ask Your Library**, beside the system's own Writing Tools.

---

## 10. Sheets and Settings

**Sheet bar** (`ChromeSheetBar`): 40pt, the title centred (13pt semibold),
actions at either end (Cancel, Done, Clone…), a rule below. Eight sheets use it:
Git, Clone Repository, New Repository, Acknowledgements, Manage Cloud
Collections, Version History, the cloud folder picker and the diagram zoom —
"Diagram", or "Diagram *n* of *m*" when the note has several, with **Done** at
the right as the cancel action.

**Seven sheets draw a top of their own** instead:

| Sheet | Its top |
|---|---|
| Open… (the launcher) | "Open" and **Done** |
| Slides | "Slides — *title*" and **Done**, and a row of slide controls at the bottom |
| New Note from a Prompt | "New Note from a Prompt" and **Cancel** |
| Review Links | "Review Links", "*n* of *m*" and **Close** |
| Rewrite | "Rewrite Note" or "Rewrite Selection", the model's name, and **Close** (Replace Note or Replace Selection, and Insert Below, are its commits) |
| Quick Capture | a leading "Quick Capture" title and a caption. No dismiss control: **Append** (⌘↩) is its only button |
| Welcome | a centred header (the app icon, "Welcome to HelloNotes") and **Explore first** at the bottom, which has no shortcut |

The two palettes (Command Palette, Open Quickly) open on their search field,
and Settings on its tab strip.

**Settings tab strip**: 58pt; five tabs of 72 × 46pt (a glyph over an 11pt
name): **General**, **Appearance**, **Git**, **AI**, **Support**. The chosen
tab's glyph is in the accent on a rounded wash and its name in the label colour.
The strip is centred with 60pt reserved at each end, so **Done** never overlaps
a tab. On a phone the tabs share the width Done leaves. It is the same view in
the Mac's Settings window and in the iPad's sheet.

---

## 11. Rows inside the panel's views

Three of the panel's views add rows of their own under the panel's header:

- **Graph**, two rows. First its controls: **Scope** (Whole Collection, or
  around the focused note, named "Around "*note*"" in the widest layout and
  "Around Focused Note" otherwise) and, around a note, **Link distance** (1–3
  links), as unlabelled pop-ups. When the graph is capped, a line under them
  says how many notes are hidden. The pop-ups fall back to one line, a shorter
  line, or two rows as the panel narrows. At least 36pt, the chrome grey, a rule
  below. Then the graph's own row: "*n* notes · *m* links" and zoom controls.
- **Mind Map**: a "Mind Map" title in `Chrome.Style.headline`, zoom controls, and
  **Open "*note*"**, with 16pt of padding.
- **Assistant**: agent mode (a toggle, `wrench.and.screwdriver.fill` or
  `bubble.left`), the model (a pull-down), **New conversation**
  (`square.and.pencil`) and **AI settings** (`gearshape`), right-aligned.

That is four extra rows, drawn four different ways (§14).

---

## 12. The note window's bar

A note window (Open in New Window) has a 40pt bar carrying **only its title**,
centred on the window and kept clear of the traffic lights on both sides. The
note's commands are in its editor status bar (§5.1), as in the main window. The
window drags by the bar.

---

## 13. What the OS draws

The traffic lights (Mac); iPadOS's window controls and resize grabber; the iOS
status bar; the software keyboard and its shortcuts bar; and any menu, popover
or alert once open. The buttons that open menus are the app's.

---

## 14. Open defects and gaps

1. **The phone's expanded note has two bars** (§8.4): Back and the title, then
   the tabs, Note Actions and Panel. **Fix:** one 40pt row, Collapse (⌄) ·
   tabs · Note Actions · Panel, with the title carried by the active tab. See
   [tabs.md](tabs.md) T14.
2. **The tabs have no floor, and the bar can overflow** (§3.1). With the
   sidebar and the panel open in a narrow window the tabs get a sliver or
   nothing, and the fixed part of the bar overflows by 6pt. [tabs.md](tabs.md)
   T9, `ui.md` §12.
3. **Three panel views add rows of their own** (§11): Graph two, the Mind Map
   and the Assistant one each, four rows drawn four ways. They should use the
   panel's header, or one shared strip under it.
4. **Bar commands with no menu item** (§1, rule 2): Show/Hide Sidebar, Show/Hide
   Panel, New Folder…, Mind Map, Present as Slides, View Diagram, Download /
   Remove Download, the status bar's Properties, Links and Outline, Version
   History, the Git pane, the collection status bar's Stop, Try Again, Locate…
   and Remove, and the Assistant's New conversation.
5. ✅ ~~**Note windows' status bar has four dead items**~~ (§5.1): no AI menu, a Mind
   map button that does nothing, a Links popover that always says "No
   References", and a Git button that opens an empty popover. A selection there
   offers none of the vault actions. *Fixed (implemented.md §51.36).*
6. **The editor status bar's scroll threshold counts its padding twice**
   (§5.1), and its minimum was measured for one set of items.
7. ✅ ~~**The editor status bar draws a 2pt rule**~~: a `ChromeDivider` above it and a
   rule of its own. *Fixed (implemented.md §51.36).*
8. ✅ ~~**A system colour in the collection status bar.**~~ A permanent stale reason
   is drawn in `.orange`, which is a different orange on each platform, beside
   `Chrome.Colour.orange` everywhere else (D12). *Fixed (implemented.md §51.36).*
9. ✅ ~~**`ShellMetrics.statusBar` says 28pt; both status bars are 44pt.**~~ The
   constant is read by nothing. *Fixed (implemented.md §51.36).*
10. ✅ ~~**Sheets have five kinds of top**~~ (§10). Quick Capture and Welcome have no
    cancel action at all, and every other sheet's dismissal is the cancel
    action. (The Mermaid Diagrams sheet, whose Done was the *default* action,
    was replaced by the diagram zoom on 2026-09-24, which uses the sheet bar.) *Fixed (implemented.md §51.36).*
11. ✅ ~~**Escape has several owners.**~~ The panel's Close, the find bar's Done,
    Settings' Done and the Assistant approval card's Deny are all
    `.cancelAction`. *Fixed (implemented.md §51.36).*
12. ✅ ~~**A tooltip promises a shortcut that does not exist**~~: "Previous match
    (Shift-Return)" on the find bar. *Fixed (implemented.md §51.36).*
13. **The Mac's Settings window shows Done** beside its own close button,
    because the strip is the sheet's. Harmless, but it is a sheet's control in a
    window.
