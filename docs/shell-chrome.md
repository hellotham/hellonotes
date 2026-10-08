---
status: DECIDED (2026-08-11). Supersedes the DRAFT of the same date, whose D2/D3
were wrong: they kept a non-collapsible rail as column 1, which is what denied
the app a correctly-placed sidebar toggle for a whole day.
Companion to layout-architecture.md (now incorporated into ui.md), which decided
the *arrangement* (columns, widths, breakpoints) and said nothing about *chrome*.
This file is the **decision record** for the chrome. How each part of the window
works today is in ui.md, primary.md, secondary.md, toolbars.md, tabs.md and
menu.md (2026-09-24).
---

# Shell chrome — what lives in the titlebar band, and what each panel owns

## Why this document exists

`layout-architecture.md` (now `ui.md`) answers "how many columns, how wide, at
what size". It never answers:

- what may be drawn in the band the titlebar and toolbar occupy;
- which panels get a show/hide control, and where that control sits;
- what belongs in the window toolbar versus inside a panel's own header;
- what happens to those answers when a panel is hidden.

Because nothing decided those, they were answered one at a time by taste, in the
running app, over about twenty attempts. This document ends that.

---

## Part 1 — Who this is for, and what chrome they need

Personas are inherited from `layout-architecture.md` Part 1 (now `ui.md` §3). What is new is the
*chrome* column: what each persona needs from the window frame, as opposed to
from the arrangement of columns.

| Persona | Context | What they do with chrome | What chrome must never cost them |
|---|---|---|---|
| **P1 Desk researcher** | 1470–3840pt | Keeps every panel open. Switches collection, filters, inspects references. | Width. Chrome must not eat the measure. |
| **P2 Laptop writer** | 860–1280, often ~660 half-screen | Collapses the sidebar to get text. Needs the way *back* to be obvious. | A hidden panel with no discoverable way to return. |
| **P3 iPad reader** | any width (Stage Manager) | Rarely toggles; expects the platform gesture. | Mac-only affordances that do not translate. |
| **P4 Split capturer** | 320pt | Nothing. There is no chrome at that size. | Any chrome at all. |
| **P5 Phone capturer** | 375–430pt | Bottom tab bar only. | Titlebar chrome, which does not exist there. |

**The chrome priority**, derived from the existing priority rule
(`text > switching > list > library > references > properties`):

> A control earns its place in the frame only if it is used *while* working, not
> before or after. Everything else belongs in the menu bar.

**The P2 corollary, which decides more than anything else here:** P2 collapses
the sidebar *while working*. Therefore **no command may live inside the
collapsible panel** — collapsing it would remove the command at the exact moment
it is wanted. Only *places* live in the sidebar. Commands live in the band.

The one exception, and it is Apple's: an action whose entire subject is the
sidebar's own content (New Folder, New Collection) may sit in the band **at the
sidebar's trailing edge**, beside the toggle, where it disappears with it.

---

## Part 2 — Survey: five apps, measured

Captured 2026-08-11 with `screencapture -l <windowID>` — the only rendering path
that draws materials and vibrancy truthfully. The PNGs are **not** in this repo:
they show real mail, invoices and personal folder names. They live in the
session scratchpad. Every number below is measured from them, in points.

### Apple Notes — the closest reference that exists

A notes app, by the authors of the HIG, with our exact data shape (accounts
containing folders containing notes).

| | |
|---|---|
| Structure | **Two columns + editor.** Sidebar (220pt) · note list · editor. |
| Sidebar contents | **One scrolling list, no tabs, no panes.** Pinned places first (`Quick Notes`, `Shared`), then a *section header* per account (`iCloud`), then that account's folders. |
| Sidebar toggle | **x≈197pt in a 220pt sidebar** — its own trailing edge, in the band. |
| Sidebar-scoped action | **New Folder at x≈155pt**, immediately left of the toggle. Nothing else. |
| Note list | Title (`All iCloud`) + count + `⋯` menu **inside the panel**. No row above it. |
| Editor | Toolbar items over the editor only. Search: expanded field, top-right. |

### Mail — 3 panes

Toggle at x≈240, inside the sidebar's width, acting on the **leftmost** pane.
Middle pane has **no** toggle (View menu only). List title sits in the band over
its own column. Search: expanded, top-right. One row throughout.

### Pages — the inspector reference

| | |
|---|---|
| Band | **One row, full window width, spanning over the inspector.** |
| Inspector selectors | `Format` (x≈900) and `Document` (x≈962) — **in the band, directly above the inspector**, active one drawn pressed. |
| Chevron | **None.** |
| Inspector internals | Panel header (`Text`) and its segmented strip (`Style / Layout / More`) are **inside** the panel, below the band. |

### Obsidian — our old shape, and why it costs

Icon ribbon at x≈32 (full height, traffic lights on it, **no toggle**), then the
collapsible sidebar whose toggle sits at **its** trailing edge (x≈320 of a 343pt
panel), then editor with file tabs in the band. It works — but Obsidian is
Electron and hand-draws every pixel of that chrome. In SwiftUI the same shape
means hand-placing a control the framework places for free, which is exactly
what produced buttons floating mid-list.

### Outlook — a rail that is not our rail

Far-left rail switches **modes** (Mail / Calendar / People) — different
applications sharing a window, not views of one dataset. Then `Favourites`,
then account `Hello Tham`, then its folders: **one tree**, one toggle.

### VS Code — the tabs question, answered by looking

Commonly remembered as "sidebar tabs"; it is not. The switcher is a **vertical
activity bar at x≈32** — a rail. What VS Code actually does *inside* a container
is **stacked accordion sections**: the file tree with `OUTLINE` collapsed to a
single title row. It affords a rail because its containers are incompatible
modes with large UIs (search results, diffs, a debugger). Ours are 5–15 row lists.

### What varies, and the rules behind it

1. **The toggle belongs to column one, at one of its edges** — never in the
   window's far corner. Every app here gets it from the platform.
2. **A panel that is not column one gets no chrome toggle** (Mail's list: View
   menu; Notes' list: none at all).
3. **A panel's title and controls live either in the band over that column, or
   inside the panel — never both, never stacked.**
4. **Search is always an expanded field**, never collapsed to a glyph.
5. **The only things drawn above an inspector are the inspector's own
   selectors** (Pages). Not a chevron, not unrelated items, not a second row.

---

## Part 3 — Where HelloNotes went wrong

The old shell made the **collection rail** column one and left the folder tree —
the thing that must collapse — as column two. SwiftUI hands a correctly-placed
sidebar toggle to column one only, so ours was either wired to the wrong panel
or hand-placed. Hand-placing it produced, in turn: a button floating mid-list,
three inspector toggles, a `»` chevron, a collapsed search glyph, and a spurious
row above the inspector.

Bench evidence (`scratchpad/ChromeLab`, design 4 vs 5): with our three-column
shape **no toggle appears at all**; folding the rail into column one produces the
free toggle at that column's trailing edge.

**The fix is structural, not cosmetic: the thing that collapses becomes column
one.**

---

## Part 4 — Decisions

**D1. One row of chrome. Ever.** No panel adds a row beneath the band.

**D2. Collections and folders are one tree, in one collapsible sidebar.**
Collections are top-level nodes; their folders nest beneath. Selecting a
collection's root shows all its notes. This is Notes' account-then-folders
sidebar, Outlook's, and Finder's. It replaces the rail entirely.

**D2a. In the _tall_ shell the sidebar is two panes, Finder-style.** Containers
on the left — Recents, Bookmarks, each collection and its folders — and what is
*directly inside* the selected one on the right. D2 still holds for a sidebar
**column**, and for the same reason it was written: a column is 220–340pt
(`ShellMetrics.sidebarCap`), which has room for one list and no more, and
splitting it is what produced the rail-plus-tree shape whose toggle could never
be placed.

A band is a different shape and the argument does not carry. On an iPad in
portrait it is 834pt wide and 320pt tall — very wide, very short — so one tree
spends its width on nothing and runs out of height in about eight rows. Two
panes scroll independently, so the same 320pt shows the folders *and* the notes.
The structural objection does not apply either: the band is a `NavigationStack`
inside a `VStack` (`AdaptiveShell.tallShell`), not column one of a
`NavigationSplitView`, so there is no platform-placed toggle to lose.

Both panes are derived from `SidebarTree.roots` — the left through
`containers`, the right through `leaves(of:)` — so they are one tree seen twice
rather than two constructions to keep in agreement. The right pane shows direct
children only; recursing would make it a second copy of the tree and the left
pane redundant. Implemented in `BandTwoPane`, chosen by `SidebarLayout`, which
must be its own view because `@Environment(\.shell)` read in `ContentView`
resolves *above* `AdaptiveShell` and is always `.wide` there.

**D3. The sidebar is column one, and its toggle is the bar's own button** —
the second item of the bar over the editor, after search, on every shell.
*Superseded 2026-09-23:* this said the toggle came "for free from
`NavigationSplitView`", and it did — at a different place, size and drawing on
each platform, which D12 does not allow. The column is an `HStack` sibling with
a `ResizableDivider`, like the panel (D7); the one toggle hides whichever left
region the shell has, the sidebar column or the tall shell's band.

**D4. Recents and Bookmarks are pinned collapsible sections above the
collections** — Notes' `Quick Notes` / `Shared`, VS Code's `OUTLINE`. Not tabs:
tabs assume mutual exclusivity, and a writer scans recents *and* walks the tree
in the same minute. Not a split: two resizable stacked lists double the scroll
surfaces and halve each at P2's window height.

**D5. No tab strip and no rail inside the sidebar.** A tab bar is, per HIG, "for
navigating between areas of an app"; Recents is a filter over the same area, not
an area. A strip would also re-introduce chrome inside the collapsible panel —
the defect being removed from the inspector.

**D6. The right panel holds anything ancillary, and its own header says
which.** The window is three regions: collections on the left, the editor in the
middle, anything else on the right. Outline, Tags, References, Properties,
History and the Mind Map are about the note; Graph, Ask Library and the
Assistant are about the collection; all nine are the same kind of thing —
ancillary to what you are writing — and they share one panel, one piece of state
and one width (`SidePanel`).

The band carries **one** toggle, which shows and hides the panel; the panel's
own header carries the **strip of nine**, grouped note-then-collection with a
rule between, the current one drawn in a tint of the accent. Five icon toggles
in the band were the strip while the panel held five things, and that was right
for five: nine do not fit a band that also carries search, and they do fit the
panel, where both platforms draw the same thing — which the old arrangement did
not, the Mac having the toggles and iOS a strip of its own.

What a person can switch to is **visible**, not behind a tap, for the same
reason nothing in this app is long-press-only. Squeezed below the width nine
icons need — the panel's floor is 220pt — the header falls back to a pull-down
naming the current panel; `ViewThatFits` chooses, so the fallback is the
layout's own answer rather than a width written down twice.

**D6a. The panel is a column wherever one fits, and never a modal.** A panel
drawn *over* the editor is a note you cannot type in, and **an editor never
blocks editing** — so the panel is a column whenever the editor keeps its 320pt
floor beside the panel's 220pt one (`ShellMetrics.hasPanelColumn`). That is
nearly everywhere: a 1100pt Mac window and an 834pt iPad both used to fall to a
modal overlay with the note dimmed behind it. `inspectorMin` (1400pt) still
names the width at which the shell *starts* with three columns; only a canvas
with no room for a column — a phone — carries the panel over the note.

The panel is 360pt (floor 220, cap 560), one number for everything it holds. The
three views that came from windows keep no window habits: the graph and the mind
map each demanded a 560pt minimum, and drew past the edge of the first panel
they were put in.

**D7. `.inspector()` is not used.** It forces an unsuppressable `»` chevron,
violating D6. The panel is an `HStack` sibling of the editor inside the detail
column, with a draggable splitter — proven in finvestlens (`Views.swift:1293`).
The splitter is `ResizableDivider`, and it took until 18 September 2026 to
exist: this decision described one for months while every panel was a fixed
number. It stores the width and clamps it at use, so the editor keeps its floor
without the panel forgetting how wide you wanted it. The band's two panes
(D2a) drag the same way.

**D8. Commands live in the band, not the sidebar** (the P2 corollary). In the
band: **New Note**, **Open Quickly**, **Search**. At the sidebar's trailing edge
beside the toggle, because their subject *is* the sidebar: **New Collection /
New Folder**.

**D9. Search is a plain `TextField` at the _leading_ end of the bar** — the
bar's first item (it was a leading toolbar item until the bar became the app's
own, D12) — not `.searchable`. Two measured reasons, both from `ChromeLab`:

- **`.searchable` collapses to a magnifier glyph at 860pt** — P2's laptop, and
  the exact UI-4 defect. It is a framework behaviour, not something the app was
  doing wrong. A field sized in points cannot collapse.
- **`.searchable` always claims the trailing end of the band**, which pushes the
  inspector's tabs left, over the *editor*. Pages puts a panel's selectors above
  that panel, so search has to yield the trailing edge.

Leading placement also reads correctly: search is about files and folders, so it
belongs against the panel that holds them (Xcode's navigator filter, VS Code's
search view, Obsidian's). The cost is `.searchable`'s free ⌘F binding and
scopes; both are cheap to restore, and neither is worth a control that vanishes
at the width it is most needed.

**D10. The band draws no window title.** The window keeps one (Window menu,
Mission Control) via `.navigationTitle`; the Mac's title bar is hidden
(`.windowStyle(.hiddenTitleBar)`) and the bar is drawn by the app, so nothing
draws it. Apple Notes shows no title there either, and at 860pt the title
is the difference between everything fitting and a `»` overflow — measured:
with it, search *and* all five tabs collapsed into the chevron.

**D11. Traffic lights sit over the sidebar**, whose 40pt header row (the same
height as the bar, so the three columns share one top edge) holds only Add
Collection at its trailing end — Notes' arrangement, where the lights read as
part of the panel. With the sidebar hidden the bar is the window's top-left
corner, and it leaves the lights 78pt (`WindowControls.leadingInset`): the one
number in the chrome that differs by platform, because what it makes room for
is the OS's.

**D12. The chrome is the app's drawing, and the Mac and the iPad are the same
pixels** (2026-09-23). Every bar, row, control, form, sheet bar and empty state
is drawn by the app from `Chrome` tokens at the Mac's metrics — never a system
toolbar, `List`, `Form`, `TabView`, `NavigationStack` bar, text style, system
colour or material, each of which is a different drawing on each platform. The
layout is the iPad's (the bar below), the scale the Mac's (13pt, 28pt controls,
AppKit's colours), with 44pt touch targets that draw nothing. Verified by
`scripts/chrome-parity.sh`, which renders the chrome on both platforms and
compares the pixels; `implemented.md` §51.5 has the three differences fixed
numbers alone did not remove. The OS keeps its window controls and anything it
presents once open — a menu, a popover, an alert.

---

## Part 5 — Wireframe (wide, 1470pt)

*As built (D12), on both platforms:*

```
┌────────────────┬────────────────────────────────────────────────────────────┐
│ ●●●          + │ 🔍 Search   ⊟  ✎  ⋯  │ Note A │ Note B │          ⌄  ◨   │ ← ONE bar, 40pt
├────────────────┼────────────────────────────────────────────────────────────┤
```

Search · Sidebar · New Note · More ⋯ | the open notes' tabs | Note Actions ⌄ ·
Panel. The tabs take whatever the buttons leave and scroll inside it, so the
buttons never move and never fold away.

*The original wireframe, for the reasoning:*

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ ●●●          ⊟ ⊞ 🔍 Search      ✎  ⇥              │ ▤  #  🔗  ⌂  ↻       │ ← ONE band
├───────────────────────┼───────────────────────────────────┼─────────────────┤
│ ▸ Recents             │  # A Note Title                   │ STATISTICS      │
│ ▸ Bookmarks           │                                   │ Words       512 │
│                       │  The quick brown fox jumps over   │ Read      2 min │
│ MY VAULT              │  the lazy dog.                    │                 │
│   ▸ 1 Rupa            │                                   │ OUTLINE         │
│   ▸ 2 Sanna           │                                   │ ▸ Heading one   │
│   ▸ AI                │                                   │                 │
│                       │                                   │                 │
│ OBSIDIAN VAULT        │                                   │                 │
│   ▸ Daily             │                                   │                 │
├───────────────────────┴───────────────────────────────────┴─────────────────┤
│ 🗀 My Vault · 2,027 notes · 223 tags · ☁ iCloud · ⑂ main ●    ✎ ▦ ⚭ ⊞ ✦     │
└─────────────────────────────────────────────────────────────────────────────┘
     220–340pt                    flexible                      220–360pt
```

- `⊟` the toggle at the sidebar's trailing edge (the Notes position), then `⊞`
  New Collection/Folder, then the search field — all at the leading end, against
  the panel they act on (D3, D8, D9). No window title in the band (D10).
- `✎` New Note and `⇥` Open Quickly — over the editor, so P2 keeps them (D8).
- `◨` — one toggle for the right panel, over the panel (D6). Nothing else is
  ever drawn there; what the panel shows is chosen in its own header.
- The note list is **not** a separate column: selecting a folder fills the
  editor column's list. (`layout-architecture.md` planned for the list to split
  out at ≥1100pt; it never did. See `ui.md` §4.)

### Collapsed (P2, sidebar hidden)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ ●●● ⊟ ⊞ 🔍 Search    ✎  ⇥                        │ ▤  #  🔗  ⌂  ↻       │
├───────────────────────┴───────────────────────────────────┼─────────────────┤
│  # A Note Title                                           │ STATISTICS      │
```

The toggle moves beside the traffic lights — Mail's and Notes' behaviour — because
the edge it was pinned to no longer exists. *(As built, the bar is the app's, so
the app does this: it pads its leading end by `WindowControls.leadingInset`.)*

---

## Part 6 — Can it be built? (checked before approval, not after)

*Superseded by D12 for every row that names a system mechanism — the bar is an
`HStack` the app draws, the sidebar a `LazyVStack` of `ChromeRowFrame` rows —
and kept for the measurements that chose the positions.*

| Element | Mechanism | Verified |
|---|---|---|
| Toggle at the sidebar's trailing edge | Free from `NavigationSplitView` for column 1 | ✅ bench design 5 |
| Sidebar-scoped actions beside it | `ToolbarItem(placement: .navigation)` | ✅ bench design 10 |
| Search that never collapses | plain `TextField` in a leading toolbar item | ✅ bench design 10 @ 860pt |
| No title in the band | `.toolbar(removing: .title)` | ✅ bench design 10 |
| Collections + folders in one `List` | `Section` per collection + `DisclosureGroup` | ✅ existing tree code |
| Five inspector toggles, no chevron | No `.inspector()`; `HStack` + splitter; `ToolbarItem` trailing | ✅ finvestlens `Views.swift:1293` |
| ~~`.searchable` in the band~~ | ~~split-view level~~ | ❌ collapses to a glyph at 860pt — see D9 |
| Window title = collection | `.navigationTitle` on the shell root | ✅ measured in-app |

Every row is settled in `scratchpad/ChromeLab` before the app is touched:
`swift run ChromeLab --design 10 --width 860` (expanded) and `--design 11`
(collapsed). Designs 6–9 are the rejected steps, kept so the reasoning survives.

---

## Part 7 — How this gets verified

Every claim in Part 5 is checkable from a capture, not from an opinion:

```bash
swiftc -O scripts/winid.swift -o /tmp/winid && /tmp/winid
screencapture -l<id> -o -x /tmp/hn.png
```

**And the same picture on both platforms:** `./scripts/chrome-parity.sh`
renders the chrome on macOS and on the `HN-iPad` simulator and fails if the two
differ by more than antialiasing (D12). `./scripts/window-parity.sh` does the
same for the whole window — the iPad in landscape against a Mac window of
exactly its safe area, same settings, same sample collection — and is what
found the strip a hidden Mac title bar still reserves and the notes that sorted
differently on each; it needs the Mac's screen unlocked.

Checklist, run **in full** after every change — not just the item last reported:

1. One row of chrome; nothing stacked in any panel.
2. Exactly one sidebar toggle, the bar's second button, and it works. *(It was
   "at the sidebar's trailing edge" until D3 was amended.)*
3. The panel's own header carries its nine views and Close, and nothing else is
   drawn above the panel. No `»`. *(It was "five tab toggles" until D6 moved
   the views into the panel.)*
4. The panel's views are chosen in its header, not in a second strip inside it.
5. Search is an expanded field, the bar's first item.
6. Recents and Bookmarks are collapsible sections above the collections.
7. Window title is the collection.
8. Hiding the sidebar pads the bar clear of the traffic lights.

**Never judge any of this from `cacheDisplay`/`bitmapImageRepForCachingDisplay`.**
It cannot render materials and paints them flat white, which cost an entire
session chasing a "white capsule" that did not exist.
