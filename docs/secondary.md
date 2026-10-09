---
status: CURRENT (2026-10-09). Describes the right panel as built, the rules it
follows and its open defects (§9). Decision record: `shell-chrome.md` D6, D6a,
D7, D13; decisions L1, L8, L10 and L16 in `ui.md` §11. Overview: `ui.md`.
---

# The secondary sidebar: the right panel

The right of the window holds **what the open note is**: its summary and
outline, its tags, its links, its properties, its history and its graph. It
answers **"what is this, and what touches it?"**, where the primary sidebar
answers "where is it, and what is the collection?" ([primary.md](primary.md)).
Older code calls it the inspector or the rail. The collection's tools — the
Mind Map, Ask Library, the Assistant — were views of it until D13; they open as
tabs beside the notes now (§6).

---

## 1. Six views, one panel, one note

| View | Symbol | What it shows |
|---|---|---|
| Summary & Outline | `list.bullet.indent` | a summary on request, the note's statistics and its headings |
| Tags | `number` | the note's tags, suggested tags, and every tag in the collection |
| Links | `link` | suggested links, outgoing links, linked mentions, unlinked mentions |
| Properties | `tag` | the note's front matter, as fields |
| History | `clock.arrow.circlepath` | the note's Git history, with restore |
| Graph | `point.3.connected.trianglepath.dotted` | the note's links in and out, as a graph — one link deep, or two or three |

**Why one panel** (D6, L16). They are one kind of thing: facts about the note in
the middle. For a while the app carried two of everything for them, two enums,
two states, two chromes and two widths, and the second set had been windows on
the Mac and sheets on iPad. A window or a sheet over the note is a note you
cannot type in, and **an editor never blocks editing**. So they share one panel,
one piece of state (`SidePanel`), one width and one header.

**Why only the note's** (D13). The panel held the collection's three as well —
nine views — and so did not say what it was about, and neither did its views:
a map of one note's ideas was called the Mind Map, while the whole collection's
links were the Graph. The Graph is this note's links now, and the Mind Map is
the collection's links, a tab of its own (§6). A choice stored as "mindMap",
"askLibrary" or "assistant" is read leniently, as the outline.

---

## 2. Where it appears

| Shell | Presentation | When |
|---|---|---|
| Column | **a column** beside the editor, after a `ResizableDivider` | the window is at least 820pt wide (280 sidebar + 320 editor + 220 panel), whether or not the sidebar is showing |
| Tall | **a column** beside the editor, under the band | the window is at least 540pt wide, which is every tall window |
| Compact, or a column window under 820pt | **carried over the content**: 360pt wide from the trailing edge, on a 12% black scrim; tapping the scrim closes it | always. On the compact shell it is drawn over the expanded note, or over the current place when the note is put away |

The rule is `ShellMetrics.hasPanelColumn` (D6a). It asks one question: does the
editor keep its 320pt floor beside the panel's 220pt one? It assumes the
sidebar's ideal 280pt, however wide the sidebar has been dragged, so with a
340pt sidebar in an 860pt window the editor gets about 298pt (`ui.md` §12). The
overlay (`InspectorOverlay`) is what a canvas too small for a column falls back
to, where there would be no room to type beside a panel anyway. It covers the
whole editor area, not just an open note, so a panel asked for with no note
open still draws.

```
 column                                   overlay (compact)
┌──────────┬───────────────┬─────────┐   ┌─────────────────────────┐
│ sidebar  │ editor        │ panel   │   │ note, dimmed   │ panel  │
│          │               │ header  │   │                │ header │
│          │               │─────────│   │  tap here to   │────────│
│          │               │ view    │   │  close         │ view   │
└──────────┴───────────────┴─────────┘   └─────────────────────────┘
```

---

## 3. The header

```
┌────────────────────────────────────────────────────────────────────┐
│ [▤] [#] [⇄] [◇] [↺] [⋈]                                          ⊗ │  40pt · chrome grey · rule below
└────────────────────────────────────────────────────────────────────┘
   the note's six                                                Close
```

- **40pt, the bar's height and colour**, so the panel's header, the bar over
  the editor and the sidebar's header make one continuous row (D1).
- **A strip of six buttons**, the bar's own 28pt `ChromeButton`s, 4pt apart.
  The chosen view is drawn as a bar button that is on: its glyph in the accent
  over the accent at 30%. **The strip is visible, not behind a tap** (D6): what you can switch to
  should be seen. The strip draws no title; the highlighted button says what is
  showing.
- **The six are disabled when no note is open.** The header does not switch
  away from one that is already chosen (§5).
- **Too narrow for the strip** (the panel's floor is 220pt), the header shows a
  pull-down instead: the current view's glyph and **name** and a chevron,
  opening a menu of the six, with a check on the current view. `ViewThatFits` chooses, so the fallback is the
  layout's own answer rather than a width written down twice.
- **Close panel** (`xmark.circle.fill`) at the trailing end. It is also the
  window's **cancel action**, so Escape closes the panel when nothing else
  consumes it (§9).

---

## 4. Opening it, and choosing what it shows

| Route | Effect | Platforms |
|---|---|---|
| Bar ▸ **Show Panel / Hide Panel** (`sidebar.trailing`, the bar's last button, drawn on while the panel shows) | toggles it, on the last view used | both |
| View ▸ **Graph** (⇧⌘G); the command palette | Graph | both (menu bar) |
| Note ▸ **Summarise Note** · **Suggest Tags** · **Suggest Links**; Note Actions ⌄; the palette; the AI place | Summary & Outline, Tags or Links, and asks that view to run the suggestion | both |

The routes that show a view go through `showPanel(_:)`, which sets the view and
shows the panel. The three suggestion routes go through `askInspector(_:)`,
which also sets the view and shows the panel, and then sets the request.
**Choosing a view from the header** changes the view and leaves the panel open.
**Close** (or Escape, or the scrim) hides it, and the view stays chosen. On the
compact shell, **putting the note away** (its Back, or Find Related on a
selection) hides it too, so a panel left showing does not follow you back to
the list.

**Remembered** (L10): the chosen view is app-wide (`sidePanel`, default
Outline); whether the panel is showing is per window (`inspectorPresented`,
default **off** on both platforms, because a stored "on" once opened windows
with a modal panel over the note and a toggle that lied); the width is app-wide
(`sidePanelWidth`).

**Width:** 360pt to start, dragged from 220 up to whatever leaves the editor
320; when those collide, the panel's floor wins. It is stored and clamped at
use. As an overlay it is always 360.

---

## 5. The note's views

Summary & Outline, Tags, Links, Properties and History are all `NoteInspector`
(whose cases keep their older names, `outline` and `references`). Its
content is aligned to the top, because a bare `maxHeight: .infinity` centres a
short outline in a tall panel, which reads as a layout fault. References and
Properties scroll as a whole. In Outline only the headings box scrolls, and in
Tags only the list of all tags. The summary, the statistics and THIS NOTE stay
where they are.

- **With no collection open**, the five views say **No Collection** ("Open a
  collection to inspect its notes.").
- **With a collection open and no note**, History says **No Note** and the
  other four draw an empty note: no summary, no tags, and References says
  "Nothing links to this note yet, and it links nowhere." (§9, item 2).

### 5.1 Summary & Outline

1. **SUMMARY**: a **Summarise** button (**Again** once there is a summary), a
   sentence explaining it, the summary once it arrives, and **Save to
   Properties**, which writes it to the note's `summary:` front matter. The
   section is always there; with no model available, pressing Summarise shows
   the service's error (§9, item 3).
2. **STATISTICS**: Words, Characters, Paragraphs, Reading time.
3. **OUTLINE**: every heading, indented 14pt per level, H1 semibold; clicking
   one jumps the editor there and highlights it briefly. "No headings" when
   there are none. The headings box is at most 320pt tall (§9, item 5).

A summary answers the same question an outline does, at another resolution,
which is why there is no separate "Intelligence" panel.

### 5.2 Tags

1. **THIS NOTE**: its tags as chips (tapping one filters the primary sidebar to
   that tag; tapping it again clears the filter), and **Suggest** (a model
   call, only on request). Suggestions appear under **SUGGESTED** as `+ #tag`
   chips; adding one writes it to the note's `tags:` property. "No new tags
   suggested." when there is nothing new.
2. **Find a tag**: the app's search field.
3. **ALL TAGS · n** (or **MATCHES · n**): every tag in the collection, sorted by
   how many notes carry it, each with its count, capped at forty ("+n more —
   type to filter"). Choosing one filters the primary sidebar.

**Following a tag is navigation**, and navigation results belong in the list
that already has rows, snippets and selection: the primary sidebar
([primary.md](primary.md) §3.3). The panel sets the filter; it does not draw a
second list of notes.

### 5.3 Links

1. **SUGGESTED** with **Suggest** (a model call over the collection's retrieval
   neighbours): accepted suggestions are added to the note's `related:`
   property.
2. **OUTGOING LINKS · n**: notes this one links to.
3. **LINKED MENTIONS · n**: notes that link here.
4. **UNLINKED MENTIONS · n**: notes that name this one without linking it, each
   with **Link**, which turns the first mention into a `[[link]]` in that note.
5. "Nothing links to this note yet, and it links nowhere." when all three are
   empty. It deliberately does not replace the tab, because a note with no
   references is the one most worth suggesting links for.

Clicking any note opens it ([tabs.md](tabs.md) says in which tab). References
are recomputed when the selection or the index changes, never in a view body
(`NoteReferences`). Backlinks and outgoing links are worked out on the main
actor; the unlinked-mention scan runs off it.

### 5.4 Properties

`PropertiesEditor` over the note's front matter. Edits write back into the
editor's buffer and are saved with it.

### 5.5 History

`NoteHistoryView` in its panel presentation: the note's commits in the
collection's Git repository, and restoring a revision into the editor. Without a
note: **No Note** ("Select a note to see how it has changed.").

### 5.6 Graph

`NoteGraphPanel` → `GraphPane`: the open note at the centre, ringed, and what
links to it and what it links to around it — arrows coloured by direction while
a node is focused — under two rows: "Links in and out" with **Link distance**
(Direct links, Within 2 links, Within 3 links; remembered as `noteGraphDepth`),
and the graph's own "*n* notes · *m* links" with zoom controls. Built from the
collection the note is in, not the focused one. A single click focuses a node; a
double-click opens its note, and the graph follows it. With no links: **No
Links**; without a note: **No Note** ("Open a note to see its links in and
out.").

---

## 6. The collection's tools — tabs, not views of the panel

The collection's tools open in the middle of the window as **tabs beside the
notes** (`CollectionTool`, `ToolTabs`), from the sidebar's rows
([primary.md](primary.md)), the View menu (⇧⌘M, ⇧⌘J, ⇧⌘A), the command palette,
a selection's Ask Your Library, and on a phone the AI place and the Notes
place's ⋯. Choosing a note puts them behind it; closing the one in front shows
the note again. They are not remembered across launches.

| Tool | Content |
|---|---|
| **Mind Map** | `MindMapView`: the links across the sidebar's collection, as a mind map (`CollectionMindMap`). The collection at the centre; its most-connected notes head the coloured branches — each group of linked notes' best-connected one, and any note with three or more links of its own besides those to other heads; every other note on the branch that reaches it first; the links the tree leaves out as faint dashed cross-links. A header with the collection's name, "*n* notes · *m* links" (the tooltip says how many linked notes the 160-note cap left off and how many notes have no links) and zoom. Built off the main actor from a snapshot of the link graph's backlinks. Clicking a note opens it |
| **Ask Your Library** | `LibraryChatView`: retrieval-augmented questions over every open collection, answers with links back. A question sent from a selection is taken as it is asked, whether the tab is just opening or already in front |
| **Assistant** | `AssistantHost`: the agentic assistant. It draws its own header row (agent mode, the model, New conversation, AI settings), and its edits need approval (`EditApprovalView`) |

---

## 7. The compact AI place

On a phone the tab bar's **AI** place is the touch route to everything the model
does (`AIPlaceList`):

| Group | Rows |
|---|---|
| — | Ask Your Library · New Note from a Prompt… · a footer: "Answers are drawn from the notes you have open, with links back to them." |
| **This note** | Summarize · Suggest Tags · Suggest Links · Rewrite Note… · Review Links… · a footer when they are disabled: "Open a note to use these." or "AI isn't available right now — AI Settings says why." |
| — | Assistant · AI Settings… |

A row that cannot apply is **disabled, not hidden**. In the This note group the
footer says why; the first group's footer is fixed text, so a disabled Ask Your
Library or New Note from a Prompt… gives no reason. Review Links… is disabled
with the rest of its group when no model is available,
although it needs none (`menu.md` §8). Ask Your Library and the Assistant open
as tools, expanded over the places as a note is; the three note actions open the
panel, which on a phone is drawn over the AI place itself while no note is
expanded (§2).

---

## 8. How it cooperates with the rest of the window

- **Tags filter the primary sidebar**: the two sidebars cooperate across the
  editor (L1).
- **A note window's bottom bar repeats three panel views as popovers** —
  Properties, Links (without suggestions) and Outline & statistics — and opens
  the Git pane as a popover and **Version History as a sheet**, because a note
  window has no panel. The main window's bottom bar holds none of them (D13):
  the panel is beside it.
- **Menu commands land here.** Summarise, Suggest Tags and Suggest Links are
  meant to run in the view that owns the answer (`InspectorRequest`), so the
  command is found in one fixed place (the Note menu) and its answer is where
  you would look for it. That works only in part today (§9, item 1).

---

## 9. Open defects and gaps

1. ✅ ~~**A suggestion command can open its view and do nothing.**~~ `askInspector`
   sets the view, shows the panel and sets the request in one update, and
   `NoteInspector` reacts only to a *change* in the request. A closed panel is
   removed from the window, and switching from Graph, Ask Library, the Assistant
   or the Mind Map builds a new `NoteInspector`; either way the view is created
   already holding the request, and nothing runs. So Note ▸ Summarise Note (and
   Suggest Tags, Suggest Links, from every route) works only when Outline, Tags,
   References, Properties or History is already showing. Read from the code; not
   yet reproduced. **Fix:** react to the request when the view appears as well
   as when it changes, **and** have the host clear the request once it has run
   (or remember which one ran). Without that second part, every note view that
   reappears would run the last request again, because nothing clears it
   today. *Fixed (implemented.md §51.36).*
2. ✅ ~~**The note's views have no "no note" state.**~~ With a collection open and no
   note, the header disables the note's six but leaves the chosen one showing,
   and four of them draw an empty note (§5). They should say **No Note**, as
   History and Mind Map do. *Fixed (implemented.md §51.36).*
3. ✅ ~~**Model-backed buttons show without a model.**~~ The summary section and both
   Suggest buttons are always drawn, because the shell always passes the model
   calls; with no model, pressing one shows an error. `NoteInspector` was written
   for `nil` to hide them, and the Note menu already greys them out. *Fixed (implemented.md §51.36).*
4. **Most of the panel has no menu item.** Show/Hide Panel, Summary & Outline,
   Tags, Links, Properties and History have none. Summary & Outline, Tags and
   Links are reachable from the menu bar only indirectly, through Note ▸
   Summarise Note, Suggest Tags and Suggest Links. Only the Graph is in the View
   menu (with the collection's Mind Map, Ask Your Library and Assistant beside it).
   See [menu.md](menu.md) §8.
5. ✅ ~~**The outline's headings are capped at 320pt high**~~, a leftover from when it
   was a popover. In a tall panel, a long outline scrolls inside a short box. *Fixed (implemented.md §51.36).*
6. ✅ ~~**The panel's cap is not applied.**~~ `ShellMetrics.panelCap` (560) is
   declared and read by nothing. The panel can be dragged to whatever leaves the
   editor 320pt: 1,000pt or more on a large display. Decide: apply the cap, or
   delete it and say that the only limit is the editor's floor. *Fixed (implemented.md §51.36).*
7. **The Graph adds two rows of its own** (its distance strip and its
   counts-and-zoom row) under the panel's own header, which D1 forbids.
8. ✅ ~~**Escape has three owners inside the panel's reach.**~~ The panel's Close, the
   find bar's Done and the Assistant approval card's Deny are all
   `.cancelAction`. During an approval, Escape may close the panel instead of
   denying the edit. *Fixed (implemented.md §51.36).*
9. **What the panel shows is app-wide; whether it shows is per window.** Two
   windows cannot show two different views: choosing the Graph in one switches
   the other. This follows L10 as written; it is recorded because it surprises.
