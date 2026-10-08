---
status: CURRENT (2026-09-24). The top-level UI design. It incorporates
`layout-architecture.md` (2026-08-11), whose sizing contract, personas and
decisions live here now, renumbered only where noted, and corrected to what is
built. The component documents below carry the detail. `shell-chrome.md` stays
the decision record for the chrome (D1–D12).
---

# HelloNotes UI: the responsive design

One shell for the Mac, the iPad and the iPhone, chosen by the shape of the
window and never by the device, drawn by the app so that a Mac window and an
iPad of the same size are the same pixels.

This document says how the whole thing fits together: the rules, the shells,
the sizes and the contract every view obeys. Each part of the window has its own
document:

| Document | What it covers |
|---|---|
| **ui.md** (this) | Principles, personas, the shells and how one is chosen, sizes, the text column, the chrome, the sizing contract, windows and presentations, validation, the layout decisions |
| [primary.md](primary.md) | The primary sidebar (left, or the band on top) that shows the collections, and the compact shell's places |
| [secondary.md](secondary.md) | The secondary sidebar (right), the panel that shows what belongs to a note or a collection |
| [toolbars.md](toolbars.md) | Every bar the app draws: the shell bar, headers, status bars, the find bar, the compact bars, sheet bars, and the formatting bar the app deliberately does not draw |
| [tabs.md](tabs.md) | Tabs: how they work today, and the design that replaces it (**proposed**) |
| [menu.md](menu.md) | The menu bar on macOS and iPadOS, the command palette, and every shortcut |
| [shell-chrome.md](shell-chrome.md) | The decision record for the chrome (D1–D12) and the survey behind it |
| [wireframes.html](wireframes.html) | The original wireframes of 2026-08-11. **Historical**: they show the rail and inspector shapes that D2 and D6 replaced |
| [implemented.md](implemented.md) §17, §18, §51.4, §51.5 | How the layout, the chrome and the parity work was built, and what it found |

---

## 1. Why the shell is designed this way

It started with one defect. A note's first lines could not be reached: no
amount of scrolling brought them into view. Six speculative fixes failed because
each treated it as a scrolling bug. Printing the running app's own view
hierarchy found it with one measurement. Inside a **923pt** window:

```
AppKitWindowHostingView                       h=923.0    y=0       ← the window
  NavigationSplitRepresentable                h=1477.5   y=-251    ← 554pt too tall
    NSSplitView                               h=1477.5
      column hosting view                     h=1477.5
        MarkdownEditorView host               h=1390.5   y=52
          NSScrollView                        h=1390.5
```

The scroll offset was always correct. **The view was taller than its window**,
so its top 251pt sat above the frame, drawn nowhere and reachable by nothing.
`NSScrollView`, `NSOutlineView`, `UITextView`, `WKWebView`, `PDFView` and
`QLPreviewView` all report their **content** size as their fitting size, and a
representable with no `sizeThatFits` hands that to SwiftUI as an ideal size. A
2,000-note outline could inflate the shell on its own. The sizing contract (§8)
exists because of this, and every shell decision since has been expressed as
numbers first.

A second defect class drove the later work: the Mac and the iPad drifted apart.
They drifted in which buttons existed, where the buttons sat, and the size and
colour everything was drawn at, because two shells, two toolbars and the OS's
own controls each gave a different answer. §7 is the result: one shell, drawn by
the app.

---

## 2. Principles

Everything in the component documents derives from these. When a proposed
change contradicts one, the change is wrong or the principle has to be revised
here first.

1. **The shape of the window decides the layout, never the device** (the *axis
   of abundance*). A Mac window and an iPad of the same size get the same shell.
   Stage Manager makes device identity meaningless, so it is never consulted.
2. **Three regions.** The collections are on the left, the editor is in the
   middle, and everything else is on the right (`shell-chrome.md` D6). A phone,
   which has room for one of them, shows the editor as the screen and the rest
   as places.
3. **One row of chrome, ever** (D1). No panel adds a row beneath the bar.
4. **No command lives in the collapsible sidebar** (D8). People collapse it
   *while working*, so a command inside it disappears exactly when it is wanted.
   Commands live in the bar and in the menu bar. The exceptions are actions
   whose subject *is* the sidebar's content: Add Collection, and a row's own
   `…` menu.
5. **Every command has a menu-bar item and a visible touch route.** The bar is
   a shortcut and never the only way. Nothing is reachable only through a
   long-press, right-click or swipe (HIG, Context menus). iPhone has no menu
   bar, so the compact shell carries its own routes.
6. **An editor never blocks editing** (D6a). The right panel is a column
   wherever the editor keeps its floor beside it, and never a modal over a note
   that could be typed in.
7. **The Mac and the iPad draw the same pixels** (D12). The app draws its chrome
   from `Chrome` tokens at the Mac's metrics, in the iPad's layout. The OS keeps
   only its window controls and whatever it presents once open: a menu, a
   popover, an alert.
8. **A viewport reports the size it is offered, never the size it contains**
   (S1, §8).
9. **The app opens no window of its own accord.** A window exists because
   someone asked for one: New Window, Open in New Window, a link followed inside
   a note window (which opens the linked note in another), or About when no main
   window is in front. Everything else is a view in a region of the window you
   are in.
10. **Nothing takes focus that the user did not give it.** A rebuild, a scan or
    a save may not move the caret, the selection or the note on screen.

**Priority under pressure** is the same for every persona (§3):

> **text > switching > list > library > references > properties**

Navigation yields first. The editor is the last thing to shrink and the last to
disappear.

---

## 3. Who uses this, and where

| Persona | Context | Job | Cannot show |
|---|---|---|---|
| **P1 Desk researcher** | macOS, 1470–3840pt | cross-reference sources, write a synthesis, commit | — |
| **P2 Laptop writer** | macOS 860–1280, often half-screen ~660 | write beside a browser or a PDF | three columns and references at 660pt |
| **P3 iPad reader** | 11–13", Stage Manager = any width | read, follow a link, fix a sentence | three permanent columns in portrait |
| **P4 Split capturer** | iPad ⅓ (320pt) beside Safari | paste a quote, jot two lines | any second column, a status bar |
| **P5 Phone capturer** | iPhone 375–430pt | capture, look up, read one note | anything beside the note |

What each persona needs from the *chrome*, as opposed to the arrangement, is in
`shell-chrome.md` Part 1. The P2 corollary (principle 4) decides more of the
chrome than anything else.

---

## 4. The shells

### 4.1 Choosing one

`shellKind(width:height:)` (`UI/Shell/ShellContract.swift`) is the one rule. It
reads the window's size and nothing else:

| Condition | `ShellKind` | Arrangement drawn |
|---|---|---|
| `width < 600` | `.compact` | **Compact**: places behind a bottom tab bar, the open note above it as a mini strip |
| `width ≥ 600` and `height > width` | `.tall` | **Tall**: the primary sidebar as a band across the top, the editor beneath, the panel as a column when it fits |
| `600 ≤ width < 960`, landscape | `.two` | **Column**: sidebar · editor · panel |
| `960 ≤ width < 1400`, landscape | `.wide` | **Column** |
| `width ≥ 1400`, landscape | `.wideInspector` | **Column** |

There are five kinds and **three arrangements**. `.two`, `.wide` and
`.wideInspector` are drawn by the same `columnShell`. `.two` and `.wide` are
identical in every respect; `.wideInspector` differs only in the pane-width
estimate that seeds the environment (`estimatedPaneWidth` also subtracts the
panel's ideal width), and `EditorPaneContainer` replaces that estimate with the
measured width immediately. Whether the panel can be a column is decided by
`ShellMetrics.hasPanelColumn`, not by the kind (§4.4).

The scenes the contract is tested against (`ShellContractTests`):

| Scene | Size (pt) | Shell |
|---|---|---|
| Stage Manager tiny | 250 × 800 | compact |
| iPad ⅓ | 320 × 1024 | compact |
| iPhone SE | 375 × 667 | compact |
| iPhone 17 Pro | 402 × 874 | compact |
| iPad ½ | 507 × 1024 | compact |
| Mac half-screen | 660 × 900 | tall |
| iPad portrait | 834 × 1194 | tall |
| Tall Mac window | 900 × 1400 | tall |
| Mac minimum | 860 × 480 | two |
| Mac default | 1100 × 720 | wide |
| iPad landscape | 1194 × 834 | wide |
| Mac typical | 1470 × 923 | wideInspector |
| Mac ultrawide | 2560 × 1440 | wideInspector |
| Mac large | 3840 × 2160 | wideInspector |

> **Why "tall" exists.** An iPad in portrait is 834pt wide. By width alone that
> buys a second column and a 554pt measure. Banding the navigation across the
> top gives the editor the full width and spends the height that portrait has
> spare.

### 4.2 Column shell (`.two`, `.wide`, `.wideInspector`)

```
 Mac, 1470 × 923, sidebar and panel showing
┌────────────────────┬──────────────────────────────────────────────┬────────────────────────┐
│ ●●●              + │ Search… ⊟ ✎ ⋯ │ Note A │ Note B │      ⌄ ◨ │ ▤ # ⇄ ◇ ↺ ◈ │ ⋈ ✧ ✦  ⊗ │ ← one 40pt row
├────────────────────┼──────────────────────────────────────────────┼────────────────────────┤
│ ▸ Recents          │ (condition strip, only when needed)          │                        │
│ ▸ Bookmarks        │                                              │  what the panel        │
│ ▾ My Vault       … │  Note title                                  │  is showing            │
│   ▸ Daily        … │  The text of the note…                       │                        │
│   ▸ Projects     … │                                              │                        │
│   A note           │                                              │                        │
│     12:40 pm       │                                              │                        │
│ ▸ Obsidian Vault … ├──────────────────────────────────────────────┤                        │
│                    │ 3 changed   [✎ 👁 ‹› ◫] │ 🔍 ☰ 🔗 ▤ 🧠 ✦ ↺ ⇪ ⧉ │                        │ ← 44pt status bar
└────────────────────┴──────────────────────────────────────────────┴────────────────────────┘
   280 (220–340)                  flexible, floor 320                    360 (220 and up)
```

- The **sidebar** is column one: an `HStack` sibling with a
  `ResizableDivider`, not a `NavigationSplitView` (D3, as amended).
  → [primary.md](primary.md)
- The **editor pane** carries the shell bar over it (the 40pt row of commands and
  tabs) and, with a note open, the editor's status bar under it.
  → [toolbars.md](toolbars.md), [tabs.md](tabs.md)
- The **panel** is a sibling of the editor with its own divider, never
  `.inspector()` (D7). → [secondary.md](secondary.md)
- The sidebar header, the shell bar and the panel header are three 40pt bars
  side by side. Together they are the one row of chrome: the columns share one
  top edge.
- On the Mac the traffic lights sit over the sidebar's header (D11). With the
  sidebar hidden the shell bar is the window's top-left corner and pads its
  leading edge by `WindowControls.leadingInset` (78pt on the Mac, 0 on iOS). That
  is the one number in the chrome that differs by platform.

### 4.3 Tall shell (`.tall`)

```
 iPad portrait, 834 × 1194
┌──────────────────────────────────────────────────────────────┐
│                                                            + │ ← sidebar header, 40pt
├───────────────────────┬──────────────────────────────────────┤
│ ▸ Recents             │ Meeting notes              12:40 pm  │
│ ▾ My Vault          … │ Reading list                Mon      │  band: 320pt in all,
│   ▸ Daily           … │ Trip plan                   2 Sep    │  including the header
│   ▸ Projects        … │                                      │
├───────────────────────┴──────────────────────────────────────┤
│ Search… ⊟ ✎ ⋯ │ Trip plan │ Reading list │               ⌄ ◨ │ ← shell bar, 40pt
├──────────────────────────────────────────────────────────────┤
│  Trip plan                                                   │
│  …                                                           │
├──────────────────────────────────────────────────────────────┤
│ status bar                                                   │
└──────────────────────────────────────────────────────────────┘
```

- The band is the primary sidebar split in two, Finder-style (D2a): containers
  on the left (260pt, draggable from 180 to the window width less 260), and what
  is *directly inside* the chosen container on the right. → [primary.md](primary.md)
- The band is a fixed 320pt (`ShellMetrics.bandIdeal`). It is shown and hidden
  by the same Sidebar button as the column.
- The panel is a column beside the editor whenever the window is at least 540pt
  wide (320 of editor plus 220 of panel). That is every tall window, because a
  tall window is already 600pt or wider.

### 4.4 Where the panel goes

`ShellMetrics.hasPanelColumn(kind:width:)`:

| Shell | Panel is a column when | Otherwise |
|---|---|---|
| compact | never | carried over the expanded note, or over the current place when the note is put away (`InspectorOverlay`) |
| tall | `width ≥ editorFloor + panelFloor` = 540 | overlay (unreachable in practice) |
| column | `width ≥ sidebarIdeal + editorFloor + panelFloor` = 820 | overlay |

The column test uses the sidebar's *ideal* width (280), whether the sidebar is
showing or not and however wide it has been dragged. At the Mac's declared
minimum of 860pt the panel is a column. With the sidebar dragged to its 340pt
cap, the panel at its 220pt floor leaves the editor about 298pt: below its own
floor, because the sidebar's range does not know about the panel (§12).

### 4.5 Compact shell (`.compact`)

```
 iPhone, 402 × 874                        the note, expanded
┌──────────────────────────────┐      ┌──────────────────────────────┐
│ status bar (the OS's)        │      │ status bar (the OS's)        │
├──────────────────────────────┤      ├──────────────────────────────┤
│           Library          ⋯ │ 40   │ ⌄ Back        Trip plan      │ 40  ← expanded note's bar
├──────────────────────────────┤      ├──────────────────────────────┤
│ COLLECTIONS                  │      │ │ Trip plan │ Notes │    ⌄ ◨ │ 40  ← shell bar (tabs only)
│ 📚 My Vault        2,027 ✓ … │      ├──────────────────────────────┤
│ 📚 Obsidian Vault     81   … │      │  Trip plan                   │
│                              │      │  …                           │
│ 🗃 All Notes               ✓ │      │                              │
│                              │      ├──────────────────────────────┤
├──────────────────────────────┤      │ status bar (scrolls)         │
│ 📄 Trip plan               ⌃ │ 56   └──────────────────────────────┘
├──────────────────────────────┤
│  Notes  Search  Tags   AI    │ 49 + home indicator
└──────────────────────────────┘
```

- A bottom tab bar of four **places**: Notes, Search, Tags and AI. Each place
  draws its own 40pt bar (`CompactPlaceBar`). Places stay built once visited, as
  a `TabView`'s tabs do, so each keeps its scroll position.
- The open note is the **now-playing track** (L6): a 56pt mini strip above the
  tab bar. Tapping it expands the note over everything; its bar's Back collapses
  it. The strip and the tab bar are covered, not compressed (L11).
- Tapping a note in a place changes what the mini strip shows. It does not
  expand the note.
- The right panel has no column here. It is carried over the expanded note, or
  over the current place when the note is put away: 360pt wide, on a 12% black
  scrim that closes it when tapped. Putting the note away closes the panel too.
- The expanded note currently draws **two** 40pt bars, which breaks D1. See
  [toolbars.md](toolbars.md) §8.4.
- The compact shell is not iPhone-only. A Mac window or an iPad window narrower
  than 600pt gets it too; on the Mac that happens only when the OS forces a
  window below its declared minimum.

→ The places themselves: [primary.md](primary.md) §10.

### 4.6 Holding more than one note

> **Holding two notes is one job at three sizes.** Wide: **panes**. Narrow:
> **tabs**, the only way to switch when a second pane cannot fit, so tabs
> matter *more* as the screen shrinks, not less. Extreme: the strip gives way
> to a menu. **Switching is never removed.**

Surplus width buys **another note, never a wider line**. The contract allows
`maxPanes = min(4, pane width / 320)`, split manually only (L2): a wide display
opens with one pane, and the width only sets the ceiling. **Panes are not
built.** Today one pane holds the tabs, and the tabs are all there is:
[tabs.md](tabs.md) is their design, and its T9 is how switching survives at
every width. A way to switch between open notes must exist in every shell.

---

## 5. Sizes

Every size the shell uses belongs in `ShellMetrics` (layout) or `Chrome.Metric`
(drawing). A number that is in neither is a number nobody decided: add it to
one of them before using it. The tables below are the ones a designer needs;
the rest are there too: `insets` (16pt of text inset per side of a pane),
`noteRowTwoColumn` (420, [primary.md](primary.md) §4) and `tallRailMin` (900,
now read only by the pane-width estimate). Some sizes are still written in the
views instead (the status bar's 34pt row, the segmented control's 20pt
segments); §12 lists them.

### 5.1 Regions

| Region | Floor | Ideal | Cap | Source |
|---|---|---|---|---|
| Primary sidebar (column) | 220 | 280 | 340 | `sidebarFloor/Ideal/Cap` |
| Band (tall) | — | 320 tall | — | `bandIdeal` |
| Band's container pane | 180 | 260 | window width − 260 | `bandContainerPane`, `BandTwoPane.paneRange` |
| Editor pane | 320 (design target) | — | — | `editorFloor` |
| Right panel | 220 | 360 | *window − sidebar − 320*, but never below 220 | `panelFloor/Ideal`; see below |
| Window (Mac) | 860 × 480 | 1100 × 720 on first launch | — | `windowMinWidth/Height`, `firstWindowSize` |
| Note window (Mac) | 480 × 400 | system | — | `NoteWindowView.representingNoteFile` |
| Settings | 560 × 640 | | | `AppSettingsView.size` |

- **Clamped at use, never forgotten.** A dragged width is stored and clamped to
  what the window can give each time it is used. Narrow the window and the width
  is borrowed back; widen it and the width you chose returns
  (`ResizableDivider`).
- `panelCap` (560) is declared and read by nothing: the panel's upper bound is
  whatever leaves the editor 320pt, and its 220pt floor wins over the editor's
  when the two collide. Either the cap is applied or it is deleted (§12).
- The editor floor is enforced by the declared window minimum, never by a
  `minWidth` on the pane. Baked into the view, it makes the editor overflow a
  250pt Stage Manager tile and clip its own text (decision L9).

### 5.2 Chrome

| Element | Size | Token |
|---|---|---|
| Bar row: shell bar, sidebar header, panel header, place bar, sheet bar, note-window bar | 40pt | `Chrome.Metric.barHeight` |
| Bar button | 28pt drawn, with a 44pt hit area on every platform | `control`, `touchTarget` |
| Tab | 28pt; its target is its own frame | `control` |
| Segmented control | 20pt segments in a 24pt track, 10pt of extra hit area | written in `ChromeSegmented` |
| Bar padding · spacing · corner radius | 10 · 4 · 6pt | `barPadding`, `barSpacing`, `radius` |
| Search field in the bar | 120–180pt wide | `searchWidth` |
| Tab | up to 200pt wide | `tabMaxWidth` |
| Status bar (editor, collection) | 44pt: a 34pt row with 5pt above and below, under a rule | `statusRow` (the collection's); the editor's writes 34 itself |
| Compact tab bar | 49pt + bottom safe area | `ShellMetrics.bottomTabBar` |
| Mini strip | 56pt | `ShellMetrics.miniStrip` |
| Sidebar rows | note 32 · collection 24 · folder, place, file 22 | `SidebarRowHeights` |
| Row indent · selection inset | 14pt per level · 5 × 1pt | `indent`, `selectionInsetX/Y` |
| Resize grab area | 10pt around a 1pt line | `ResizableDivider.grabWidth` |

A bar button's drawing never grows for a finger. Only its invisible hit area
does, which is how a touch-only iPad draws the same pixels as a Mac and still
gets Apple's 44pt target. Tabs have no such margin; a segmented control's
segments reach 40pt, short of 44.

### 5.3 What is remembered, and where

| State | Scope | Key |
|---|---|---|
| Sidebar width, panel width, band container width | app-wide | `sidebarWidth`, `sidePanelWidth`, `bandContainerPaneWidth` (`@AppStorage`) |
| What the panel shows | app-wide | `sidePanel` |
| Whether the panel is showing | per window | `inspectorPresented` (`@SceneStorage`, default off) |
| Whether the band is hidden | per window | `bandHidden` |
| Whether the column sidebar is hidden | **not remembered** | `columnVisibility` (`@State`), see [primary.md](primary.md) §12 |
| Open folders | per window | `expandedFolders` |
| Folded collections | **not remembered** | `collapsedCollections` (`@State`) |
| The sidebar's scope collection | per window | `railPlace` ([primary.md](primary.md) §11) |
| Compact place | per window | `compactPlace` |
| The note and collection to reopen | per window | `restoredNotePath`, `restoredCollectionID` |
| Editor mode | app-wide, and synced between devices through iCloud | `editorViewMode` |
| The Settings page last shown | app-wide | `SettingsPage.storageKey` |

Every Appearance setting (theme, accent, text size, increased contrast, the
widths and the wrap guide in §6, the inline title, sort order) and the folder
conventions are app-wide and also sync between devices (`CloudPrefs`).

---

## 6. The text column

### 6.1 One column per pane

A pane has **one** text column, whatever mode it is showing
(`TextWidth.resolve`, `MeasuredText`). Two settings answer two questions:

- **Editor width** is a proportion of the pane, less its 16pt text inset on
  each side: Full pane (the default), 90%, 75% or 50%, never below 320pt
  unless the pane itself is narrower than 352pt.
- **Reading width** is a maximum measure in characters: Narrow (60), Normal
  (80), Wide (90), or **Full width (the default, no measure)**.

The column is the proportion capped by the measure. It is **centred only when
the measure is what bit**; a column narrowed by Editor width alone stays
left-aligned, VS Code style, because the pane *is* the workspace. The character
width is always measured against the body font, never the monospaced one, so
Source mode does not change the column's width.

> **What changed from `layout-architecture.md`.** Decision 5 gave Reading one
> rule (80ch, centred) and Editing another (proportional, left-aligned). In
> practice the first thing switching Edit→Preview did was move the text sideways
> and re-break every line before a glyph had been re-measured. One column per
> pane replaced it, and both defaults are now Full.

**Wrap guide** (off, 72, 80 or 100 columns) is a line drawn in the editor, not
a wrap point.

### 6.2 Modes

| Mode | What it shows | Editable | Shortcut |
|---|---|---|---|
| **Edit** | live WYSIWYG: markers revealed at the caret, blocks rendered | yes | ⌘1 |
| **Preview** | the note as it reads, GitHub-identical (`GFMPreview`) | no | ⌘2 |
| **Markdown** | the source, monospaced, unstyled | yes | ⌘3 |
| **Split** | source and preview together, side by side or stacked by aspect | source side | ⌘4 |

The mode is one app-wide value (`EditorMode.storageKey`). The first note opened
into an empty window uses the platform default: Edit on the Mac, Preview on iOS,
because a note reached by tapping is usually one you meant to read. After that
the mode is inherited. **An empty note always opens in Edit**, on every
platform.

---

## 7. The chrome: drawn by the app

### 7.1 What that means

Every bar, row, control, form, sheet bar and empty state is drawn by the app
from `Chrome` tokens (`UI/Shell/Chrome.swift`, `ChromeControls.swift`,
`ChromeRows.swift`). The rule is that nothing in the chrome is a system toolbar,
`List`, `Form`, `TabView`, `NavigationStack` bar, text style, system colour or
material, because each of those is a different drawing on each platform.
`.font(.body)` is 13pt on the Mac and 17pt on iOS; a `Toggle` is 36×16 on one
and 51×31 on the other. The rule has known breaches, listed in §12: a few system
colours, the Multicolor accent, and headers inside three panel views.

| Token set | Holds |
|---|---|
| `Chrome.Typeface` | title 13 semibold · body 13 · row 12 · secondary 11 · group 11 semibold · row icon 12 · bar icon 14 · status 12 |
| `Chrome.Metric` | the sizes in §5.2 |
| `Chrome.Colour` | AppKit's values, both appearances: label, secondary, tertiary and quaternary label, separator, content (the editor) and chrome (the bars, sidebar and panel), fill, hover, a grouped form's fill and separator, a control's fill and its pressed fill, a switch's track when off, a field's border, and the thirteen system hues |
| `Chrome.selection(accent)` | a selected row, tab or button: the accent at 30% |

`chromeDefaults()`, applied at every window root by `ThemedRoot`, makes the
app's styles the defaults. An unstyled `Button` is therefore a push button, and
a row, card or glyph needs `ChromePlainStyle`.

**What stays the OS's:** the window controls (the traffic lights; iPadOS's own
controls and resize grabber), the status bar, and anything the OS presents once
open: a menu, a popover, an alert, the colour panel, the caret and selection.
The button that opens a menu is the app's; the menu is the system's.

### 7.2 The differences fixed numbers alone did not remove

Measured by `scripts/chrome-parity.sh` and `ChromeParityTests`
(`implemented.md` §51.5):

1. **Font smoothing.** The Mac put 12–19% more ink on every glyph.
   `Chrome.matchTextRendering()` registers `AppleFontSmoothing = 0` for the app
   alone.
2. **Line boxes.** Each platform rounds a line box its own way (11pt is 14.0 on
   the Mac and 13.5 on iOS). `.lineHeight(.leading(increase: 3))` at the root
   makes every line its size plus 3, in whole points. Every vertical stack also
   names its spacing, because the default spacing is derived from each
   platform's rounding.
3. **Baselines.** Even where the totals agree, the Mac's baseline sits half a
   point lower. `ChromeLine` centres on the capitals in a box of
   `lineBox(size) = size + 3`.

**Text size.** Chrome text scales by one factor, `ChromeTextScale`, driven by
the app's own Text Size on both platforms, with iOS's Larger Text on top. The
factor is exactly 1.0 at the defaults.

**Accent.** Settings ▸ Appearance offers eleven accents (`AppearanceSettings.Accent`).
**Lavender**, the default, is the brand colour. Blue, Purple, Pink, Red, Orange,
Yellow and Green are the Chrome hues, the Mac's values on both platforms.
Graphite is a fixed mid-grey, and Custom is any colour. Each is then lightened on
dark backgrounds and deepened slightly on light ones, so it stays legible in
either appearance. **Multicolor** follows the system: the Mac's accent colour on
macOS and the tint colour on iOS. It is the one accent that is not the same
colour on both platforms (§12). **Accent on accent draws nothing**, so a glyph
inside a selected row is drawn in the secondary label colour, never the tint.

---

## 8. The sizing contract

Six layers; size information flows **down** only. A layer may report the size it
was *offered*, never the size of what it *contains*.

```
Scene → Shell → Sidebar / Band → Pane → Viewport → Content
```

**S1 — A viewport never advertises its content's size.** Every representable
wrapping a scrolling or content-sized view implements `sizeThatFits` through
`viewportSizeThatFits` and never returns `nil`. `nil` means "ask the platform
view", which is the bug. Every SwiftUI `ScrollView` of rows gets `.viewport()`
(an ideal of 320 × 240 and no maximum).

| Proposal | Answer |
|---|---|
| concrete | exactly that |
| `.zero` | collapse |
| `.infinity` | grow |
| `nil` | a small constant, **never** the content's size |

**S2 — A minimum is not a constraint.** State a maximum too, or a large ideal
still inflates the parent (`declaredWindowMinimum()` pairs its floor with
`maxWidth/maxHeight: .infinity`). *Breached* by the note window's 480 × 400
minimum, which has no maximum (`NoteWindowView.representingNoteFile`).

**S3 — Content expands, chrome is definite.** Content gets
`maxWidth/maxHeight: .infinity`; chrome gets a definite height from §5.2.

**S4 — Never nest an unbounded scroll inside a scroll.**

**S5 — Trust system safe-area insets.** Never disable
`automaticallyAdjustsContentInsets` in a window with a toolbar. Disabling it
once hid the first 66pt of every note. The windows have had no system toolbar
since D12, and the editor now disables it on purpose, to add half a screen of
room past the end of a long note (`MarkdownEditorView.updateScrollPastEndInset`).
That is the switch S5 warns about, so any change to the window's chrome has to
re-check the top of a note.

**S6 — Geometry never depends on the caret, the selection or the scroll
position.** Measured drift: a document's height changed from 3440 to 3516pt
*because the user scrolled*.

Full detail and the viewport rules for the editor: `implemented.md` §17, and
the "viewport" rule in `AGENTS.md`.

---

## 9. Windows, scenes and presentations

### 9.1 Scenes

| Scene | Platforms | What it is |
|---|---|---|
| `WindowGroup(id: "main")` | both | The shell (`ContentView`). File ▸ New Window (⌥⌘N) makes another. First size 1100×720; Mac minimum 860×480 |
| `WindowGroup(for: NoteRef.self)` | both | A single note in its own window (`NoteWindowView`): a 40pt bar the app draws with the note's title, then the note's editor and its status bar. No tabs, no sidebar, no panel. Opened by **Open in New Window**, and by following a link inside a note window |
| `Settings` | macOS | `AppSettingsView` at 560×640, ⌘,. On iPad the same view is a sheet (⌘, as well) |
| `MenuBarExtra` | macOS | Quick Capture from the menu bar. The same capture is a command on both platforms |

Both window scenes use `.windowStyle(.hiddenTitleBar)` on the Mac
(`appDrawnTitleBar()`) and ignore the hidden title bar's top safe area
(`contentUnderTitleBar()`), so the app's bar row is the window's top edge. The
main window is titled with the sidebar's scope collection for the Window menu and
Mission Control, and nothing draws that title (D10). (While an attachment is
shown, its viewer sets a title too, the file's name; which of the two the system
uses has not been checked.) A note window's bar draws its note's title.

**The app opens no other window** (principle 9). Graph, Mind Map, Ask Library
and the Assistant used to be windows on the Mac and sheets on iOS. On iPadOS a
scene *replaces* the notes in full screen and in Split View, and closing one
left the app. They are views of the right panel now.

### 9.2 Presentations

| Kind | Rule |
|---|---|
| **Sheet** | `chromeSheetFrame(width:height:)`: a fixed size on the Mac, the same size `.fitted` on iPad, the whole screen on iPhone. The intended top is a `ChromeSheetBar` (40pt, the title centred, the actions at either end). Eight sheets have one; the others open on a search field, a tab strip or a title of their own ([toolbars.md](toolbars.md) §10) |
| **Popover** | states its compact adaptation (`.presentationCompactAdaptation(.popover)`); otherwise a compact width turns it into a sheet with a 360pt island floating in it. `EditorToolbarContractTests` checks this |
| **Alert** | the OS's (Rename Note, New Folder, confirmations) |
| **Overlay** | the splash (at launch it fades after half a second; from About it waits for a tap), and the panel where there is no column for it |

The sheets the shell presents: Settings (on the Mac, ⌘, and the AI-settings
routes open the Settings window; the other in-window routes open this sheet),
Command Palette, Open Quickly,
Review Links, New Note from a Prompt, Git settings, Clone, New Repository,
Welcome, Quick Capture, the launcher (Open…), Acknowledgements and cloud
collections. The editor presents its own: the diagram zoom, Slides, Rewrite Note,
Version History and Rewrite Selection. On iOS the Assistant presents its own
Settings sheet (`AssistantHost`). The picker that opens a collection is a sheet
on iOS and an `NSOpenPanel` run directly on the Mac. Clone and New Repository
show `FolderPicker` in a sheet on both, which on the Mac is an `NSOpenPanel`
inside a sheet of no size.

---

## 10. Validation

Correctness is **measured**, never eyeballed.

| Check | What it proves | Run |
|---|---|---|
| `ShellContractTests` | the shell rule over the scenes in §4.1; the sidebar is the only collapsible column and fits at the window minimum; the pane ceiling | `./scripts/run-tests.sh -only-testing:HelloNotesTests/ShellContractTests` |
| `ShellViewportTests` | no view exceeds its scene or is stranded above it; resizing strands nothing; a viewport's ideal never depends on its content | same suite family |
| `ShellComplianceTests` | every platform gate has two branches; search is the bar's leading item; bar controls are labelled; New Note lands in the band's container; nothing in a shell re-implements shared logic | `./scripts/run-tests.sh` |
| `PlatformParityTests` | every `AppActions` field is wired; every prompted field is labelled on both platforms | `./scripts/run-tests.sh` |
| `ChromeParityTests` + `scripts/chrome-parity.sh` | the chrome (bar, rows, status bar, panel header, form, sheet bar, empty state, type) renders identically on the Mac and in the `HN-iPad` simulator, Δ≤12 per pixel and ≤0.1% of any scene | `./scripts/chrome-parity.sh` |
| `scripts/window-parity.sh` | the whole window, iPad landscape against a Mac window of its exact safe area (1210×790) | needs the Mac's screen unlocked |
| `HelloNotesUITests` | screens actually draw on iOS: every compact place, four of the five Settings pages (not Support), the open note is not clipped, every reachable control has a name | `xcodebuild test … -destination 'platform=iOS Simulator,name=HN-iPhone' -only-testing:HelloNotesUITests` |
| `EditorToolbarContractTests` | the formatting commands are installed in the system's keyboard bar (iPad) and an accessory (iPhone) by both editors, the app draws no format bar of its own, every formatting button is named, and every popover in `NoteEditorView` and `ContentView` states its compact adaptation | `./scripts/run-tests.sh` |

**Scenes to check by hand** after a shell change, beyond the table in §4.1: live
resize 1470 → 320 → 1470, and Stage Manager at arbitrary sizes. **Content
extremes:** an empty note, one line, 100k lines, a 2,000-note outline, a 4000px
image or large PDF, a wide table, Dynamic Type XS to AX5, the keyboard up (about
350pt of editor left on a phone). Chrome must *retract, not compress*.

The contract is checked on **viewports and their ancestors**, never on scroll
content: being a window onto something larger than itself is what a viewport is
for. For live diagnosis, `HN_GEOM_LOG=1 ./scripts/relaunch-debug.sh` makes a
Debug build write the editor's ancestor chain to
`~/Library/Containers/com.hellotham.HelloNotes/Data/Library/Caches/hn-geom.log`.
Any ancestor taller than the window is a live S1/S2 violation.

---

## 11. Layout decisions

Numbered as in `layout-architecture.md`, prefixed L, so code comments that cite
"decision 5" still find it. L15 onwards are the decisions made since.

| # | Decision | Status |
|---|---|---|
| L1 | **Tags live in the right panel**; the left is places only. Selecting a tag there filters the primary sidebar | ✅ The panel's Tags view; the phone's Tags place |
| L2 | **Panes split manually only**, up to `min(4, pane / 320)` | ⏸ Not built. `maxPanes` is computed and tested, and no view reads it. Tabs are the only way to hold two notes ([tabs.md](tabs.md)) |
| L3 | A persistent format bar at pane ≥ 560pt | ✗ Superseded by L20 |
| L4 | **Columns are draggable and collapsible**, remembered per window, clamped to the floors and caps | 🟡 Draggable and clamped. Widths are remembered app-wide, not per window. The band's collapse is remembered and the column's is not ([primary.md](primary.md) §12) |
| L5 | Reading at a fixed measure, editing proportional | ↻ Replaced by one column per pane (§6.1) |
| L6 | **Compact keeps the mini-note strip** above the tab bar (the Apple Music model) | ✅ |
| L7 | Graph, Mind Map, Assistant and Ask Library as full-screen sheets on iPad and iPhone | ✗ Superseded by L16 |
| L8 | **Note History is a panel view** | ✅ |
| L9 | **A hard window minimum; degrade if the OS forces smaller**, never an error | ✅ 860×480 on the Mac; the compact shell below 600pt on either platform |
| L10 | **The panel reopens on the view last used**, remembered globally | ✅ `sidePanel` |
| L11 | Compact chrome retracts on scroll-down and returns on scroll-up | 🟡 The expanded note covers the chrome; nothing is linked to scrolling |
| L12, L13 | A 64pt rail of places; the library retracting below 960pt | ✗ Superseded by L14 |
| L14 | **Collections and folders are one collapsible sidebar**, Recents and Bookmarks pinned above them; commands in the bar | ✅ (`shell-chrome.md` D2, D4, D8) |
| L15 | **In the tall shell the sidebar is two panes** | ✅ (D2a) |
| L16 | **The right panel holds nine views**, one panel, one state, one width; a column wherever the editor keeps its floor | ✅ (D6, D6a) |
| L17 | **The app opens no window of its own accord** | ✅ (principle 9) |
| L18 | **The chrome is the app's drawing; the Mac and the iPad are the same pixels** | ✅ (D12) |
| L19 | **One shell implementation**, `ContentView`, for both platforms | ✅ (2026-08-22) |
| L20 | **Formatting is the Format menu and the system's keyboard bar**; the app draws no format bar | ✅ ([toolbars.md](toolbars.md) §9) |
| L21 | **Tabs are designed, not a side effect** | 📝 Proposed in [tabs.md](tabs.md) |

### Consequences worth remembering

- L2 means a wide display opens with one pane, and there is no second one.
- L4's gap is visible after a relaunch. If the sidebar was hidden, the column
  shell reopens with it showing while the bar still says **Show Sidebar** and
  keeps the traffic-light inset ([primary.md](primary.md) §12).
- L9 is the only rule that permits violating a floor, and only when the OS
  forces it.
- L16 is why nothing ancillary is ever a sheet or a window: it has one place to
  go.

---

## 12. Open items across the UI

The component documents list their own. These cut across them.

1. ✅ ~~**Contract values with no reader.**~~ `ShellContext.tabBarHeight` (with
   `ShellMetrics.tabBarPointer`/`tabBarTouch`), `keyboardAccessoryBar`,
   `statusBar` (28pt; the status bars are 44pt), `noteRowTouchMinimum`/
   `noteRowPointerMinimum`, `needsLibraryAffordance`, `maxPanes`, `panelCap`,
   `ShellKind.editorIsScreen` and `SidebarRowHeights.fallback` are declared, and
   some are tested, but no view reads them. `ShellKind.hasSidebar` is read only by
   tests, and `ShellContext.prefersTouch` is published and read by nothing in the
   shell. A value with a rule and no reader reads as coverage and is worse than
   neither. Each is either wired or deleted, with its test. *Fixed (implemented.md §51.36).*
2. **The sidebar's range does not know about the panel.** The sidebar may be
   dragged to 340pt whatever the panel is doing, and the panel test assumes 280.
   In an 860pt window with a 340pt sidebar and the panel open, the editor gets
   about 298pt, below its floor, and the bar's fixed items overflow it by 6pt
   ([toolbars.md](toolbars.md) §3.1). One budget has to be shared by the three
   columns.
3. **Breaches of D1 and D12.**
   - *System colours:* `Color.orange` in the collection rows
     (`ChromeCollectionRow`) and `.orange` in the collection status bar, where
     `Chrome.Colour.orange` is meant.
   - *Multicolor* resolves to each platform's own accent, so it is the one
     accent that differs between the Mac and the iPad (§7.2).
   - *Rows inside the panel:* Graph adds two (its controls strip and its
     counts-and-zoom row), and the Mind Map's header (a title, zoom and Open)
     and the Assistant's header (agent mode, model, New conversation, AI
     settings) one each, under the panel's own header
     ([toolbars.md](toolbars.md) §11).
   - *Sizes written in views:* the editor status bar's 34pt row and the
     segmented control's 20/24pt, instead of tokens. *The system orange is gone from the rows and the status bar, and a rule keeps it out (`ShellComplianceTests`, implemented.md §51.36); multicolour, the panel's extra rows and sizes as tokens are design and stay.*
4. **Sheets have four different tops** ([toolbars.md](toolbars.md) §10). Eight
   use `ChromeSheetBar`; the others open on a search field, a tab strip or a
   leading title of their own.
5. **Two tab systems on the Mac.** The OS adds window tabs (View ▸ Show Tab Bar,
   Show All Tabs; Window ▸ Show Previous/Next Tab, Move Tab to New Window, Merge
   All Windows) beside the app's own. [tabs.md](tabs.md) T0 decides this.
6. **Routes missing in both directions.** Show/Hide Sidebar, Show/Hide Panel,
   most of the panel's views, New Folder and several row commands have no menu
   item. The Command Palette and Insert Template have no touch route.
   [menu.md](menu.md) §8.
7. ✅ ~~**Stale descriptions in the source.**~~ Comments that describe a design the
   code has left, so a reader believes the wrong thing:

   | Where | Says | True now |
   |---|---|---|
   | `NoteOutlineItem.swift`, `SidebarTree.swift`, `NoteRowContent.swift` headers; `ContentView`'s doc comment above `searchField` (orphaned from `collectionTree`) | an `NSOutlineView` on the Mac and a SwiftUI `List` on iOS | one drawn list on both (`NoteOutlineList`) |
   | `SidebarMenu.swift` (the header and `SidebarMenuItems`' comment; two other comments name `SidebarItemRow`) | the Mac walks the items into an `NSMenu`; a view called `SidebarItemRow` | SwiftUI menus on both; `SidebarItemRow` does not exist |
   | `SidebarRowHeights` | row heights for `heightOfRowByItem`; a collection row's "close button" | fixed heights for drawn rows; there is no close button |
   | `NoteOutlineList.swift` (the empty space below the rows) | drops land there | the empty space takes no drops |
   | `AdaptiveShell.bandHidden`; `ContentView`'s `columnVisibility` and `expandedFolders` comments | a toggle "for free" from `NavigationSplitView`; the shell overriding it below 960pt; an AppKit outline managing its own expansion | the app's own toggle; nothing overrides it; the shell holds expansion |
   | `ContentView` (the `prefersTouch` argument) | pointer detection decides whether the format bar exists | there is no format bar |
   | `PointerPresence.swift` header | the tab bar's height and the note-row floor follow `prefersTouch` | nothing reads either |
   | `AdaptiveShell.estimatedPaneWidth` and `EditorPaneContainer` | the pane width serves "the format-bar rule" | there is no format bar |
   | `EditorTabBar.swift` header | a tab's hit area grows for a finger | a tab's target is its own frame |
   | `CompactShell.swift` header | the Mac has no `tagList` or `aiPlace` for its compact places | both platforms have them |
   | `AssistantHost.swift` | the Assistant is itself a sheet on iOS | it is a panel view |
   | `NoteEditorView.swift` (the references popover) | for shells with no panel "below 1400pt" | the panel is a column from 820pt in a column window and 540pt in a tall one |
   | `NoteInspector.swift` (`summarize`) | `nil` hides the button; the summary is written as a callout | the caller never passes `nil`; the summary goes to `summary:` |
   | `SelectionActions.swift` (named `SelectionActionBar.swift` in its header), and comments in `ContentView` and `NoteEditorView` | a floating bar under the selection on the Mac | menu items in the editor's context menu. (`EditorHost`'s comment describes the menu correctly but cites `SelectionActionBar.swift`) |
   | `GlobalHotKey.swift` header, `TerminationGuard.swift` | ⌥⌘N summons Quick Capture | ⌃⌥⌘N makes a new note |
   | `AppCommands.swift` header | Mac-only commands are gated item by item | no Mac-only command is gated (only the iPad's own Settings… is); a command that cannot run greys out |
   | `AppCommands.swift` (`CloudBrowser.makeStore`) | the Mac opens four cloud-browser `Window`s | no such windows are declared |
   | `AssistantHost.swift` header | the Assistant lives in a `Window` scene on the Mac and a sheet on iOS | it is a panel view on both |
   | `CommandPalette.swift` (templates) | templates are reachable from the toolbar | only the menu bar and the palette |
   | `ContentView` (the launcher) | the launcher is on ⇧⌘O | it is on ⌘O; ⇧⌘O is Open Quickly |
   | `OpenQuicklyView.swift` header | Open Quickly is ⌘O | it is ⇧⌘O |
   | `AppCommands.swift` (About, with no window) | the new window shows the launch splash | the splash shows once per launch; a later window shows none |
   | `AppCommands.swift` (`insertTemplate`) | a template is inserted at the caret | it is appended to the end of the note |
   | `EditorTabs.totalLoadRevision` | a tab is appended only after its note has been read | the tab is appended first and fills in |
   | `NavigationRouter.swift` (Spotlight donation) | a Spotlight result is a deep link back into the note | nothing handles a Spotlight result |
   | `LibraryPlace.swift` header, and `RailPlace` | a `LibraryRail.swift`; `RailPlace` surviving only for the compact iOS shell | no such file; `RailPlace` is the sidebar's scope in every shell |
   | `ShellActions.move` | the Mac's `NSOutlineView` drop | one drawn list |
   | `AGENTS.md` ("The simulator tool's taps arrive as a mouse") | the band switches to 24pt rows once a pointer appears | row heights are fixed | *Fixed (implemented.md §51.36).*

---

## Glossary

| Term | Meaning here |
|---|---|
| **Collection** | An open folder of notes (a vault). Several can be open at once: the *library* |
| **Focused collection** | The one the window's commands act on: the collection of the note last opened, or the one chosen with Focus Collection. Its name is semibold in the sidebar |
| **Place** | A row that is not a folder on disk: Recents and Bookmarks in the sidebar; Notes, Search, Tags and AI in the compact shell |
| **Primary sidebar** | The left column, or the band in the tall shell ([primary.md](primary.md)) |
| **Band** | The primary sidebar laid across the top of a tall window, in two panes |
| **Panel** / **secondary sidebar** | The right column that shows one of nine views ([secondary.md](secondary.md)). Called the inspector in older code |
| **Pane** | The editor's column. There is one; L2 would allow more |
| **Bar** | A 40pt row the app draws. *The* bar, or shell bar, is the one over the editor ([toolbars.md](toolbars.md)) |
| **Status bar** | The 44pt strip under the editor, or under the empty editor |
| **Tab** | An open item in the bar's strip ([tabs.md](tabs.md)) |
| **Mini strip** | The compact shell's now-playing row for the open note |
