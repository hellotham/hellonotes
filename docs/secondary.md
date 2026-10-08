---
status: CURRENT (2026-09-24). Describes the right panel as built, the rules it
follows and its open defects (§9). Decision record: `shell-chrome.md` D6, D6a,
D7; decisions L1, L8, L10 and L16 in `ui.md` §11. Overview: `ui.md`.
---

# The secondary sidebar: the right panel

The right of the window holds **anything ancillary** to what you are writing:
what the open note is, what touches it, and three views of the whole collection.
It answers **"what is this, and what touches it?"**, where the primary sidebar
answers "where is it?" ([primary.md](primary.md)). Older code calls it the
inspector or the rail.

---

## 1. Nine views, one panel

| Group | View | Symbol | What it shows |
|---|---|---|---|
| **This note** | Outline | `list.bullet.indent` | a summary on request, the note's statistics and its headings |
| | Tags | `number` | the note's tags, suggested tags, and every tag in the collection |
| | References | `link` | suggested links, outgoing links, linked mentions, unlinked mentions |
| | Properties | `tag` | the note's front matter, as fields |
| | History | `clock.arrow.circlepath` | the note's Git history, with restore |
| | Mind Map | `point.topleft.down.curvedto.point.bottomright.up` | the note's ideas as a map, from the live text |
| **This collection** | Graph | `point.3.connected.trianglepath.dotted` | the link graph |
| | Ask Library | `sparkles.rectangle.stack` | questions answered from every open note, with citations |
| | Assistant | `sparkles` | the agentic assistant, which can read and (with approval) edit notes |

**Why one panel** (D6, L16). They are one kind of thing: ancillary to the note
in the middle. For a while the app carried two of everything for them, two
enums, two states, two chromes and two widths, and the second set had been
windows on the Mac and sheets on iPad. A window or a sheet over the note is a
note you cannot type in, and **an editor never blocks editing**. So they share
one panel, one piece of state (`SidePanel`), one width and one header.

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
│ [▤] [#] [⇄] [◇] [↺] [◈]  │  [⋈] [✧] [✦]                         ⊗ │  40pt · chrome grey · rule below
└────────────────────────────────────────────────────────────────────┘
   the note's six          the collection's three                Close
```

- **40pt, the bar's height and colour**, so the panel's header, the bar over
  the editor and the sidebar's header make one continuous row (D1).
- **A strip of nine buttons**, the bar's own 28pt `ChromeButton`s, 4pt apart:
  the note's six, a 1 × 16pt rule, the collection's three. The chosen view is
  drawn as a bar button that is on: its glyph in the accent over the accent at
  30%. **The strip is visible, not behind a tap** (D6): what you can switch to
  should be seen. The strip draws no title; the highlighted button says what is
  showing.
- **The note's six are disabled when no note is open.** The header does not
  switch away from one that is already chosen (§5).
- **Too narrow for the strip** (the panel's floor is 220pt), the header shows a
  pull-down instead: the current view's glyph and **name** and a chevron,
  opening a menu with two sections, **This note** and **This collection**, and
  a check on the current view. `ViewThatFits` chooses, so the fallback is the
  layout's own answer rather than a width written down twice.
- **Close panel** (`xmark.circle.fill`) at the trailing end. It is also the
  window's **cancel action**, so Escape closes the panel when nothing else
  consumes it (§9).

---

## 4. Opening it, and choosing what it shows

| Route | Effect | Platforms |
|---|---|---|
| Bar ▸ **Show Panel / Hide Panel** (`sidebar.trailing`, the bar's last button, drawn on while the panel shows) | toggles it, on the last view used | both |
| Bar ▸ **Note Actions ⌄ ▸ Show Panel / Hide Panel** | the same | both |
| Bar ▸ **Note Actions ⌄ ▸ Mind Map**; status bar ▸ mind map button | Mind Map | both |
| View ▸ **Graph View** (⇧⌘G), **Ask Library** (⇧⌘J), **Assistant** (⇧⌘A) | that view | both (menu bar) |
| Bar ▸ **More ⋯ ▸** Assistant, Ask Your Library, Graph View | that view | both |
| Collection status bar (no note open) ▸ Graph view, Ask your library, Assistant | that view | both |
| Note ▸ **Summarise Note** · **Suggest Tags** · **Suggest Links**; the status bar's ✦ menu; Note Actions ⌄; the palette; the AI place | Outline, Tags or References, and asks that view to run the suggestion (see §9, item 1) | both |
| A selection's **Ask Your Library** | Ask Library, asking "Explain this, using my notes: *phrase*" | both |
| Compact **AI** place ▸ Ask Your Library, Assistant | that view | both, compact shell |
| Command palette | Graph View, Ask Your Library, Assistant | both |

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

Outline, Tags, References, Properties and History are all `NoteInspector`. Its
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

### 5.1 Outline

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

### 5.3 References

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

### 5.6 Mind Map

`MindMapPanel`: the open note as a map, built from the **live buffer** (what is
being typed) when the editor holds the note, and from the file otherwise. A
link node opens the linked note. A section node opens the note and searches its
text for the heading, which lands on the first match, not necessarily the
heading itself; the root and bullet nodes only open the note. Without a note:
**No Note** ("Open a note to map it."). The view draws its own header row: a
"Mind Map" title, zoom controls and **Open "*note*"** (§9, item 7).

---

## 6. The collection's views

| View | Content | Notes |
|---|---|---|
| **Graph** | `GraphPane`: the link graph, under two rows. The first is a strip of two unlabelled pop-ups: the scope, **Whole Collection** or **Around "*note*"** (or "Around Focused Note"), and, around a note, the link distance, **1–3 links**. The scope is disabled while no node is focused. When the graph is capped: "Showing the *n* most-connected notes · *m* more hidden". The second is the graph's own: "*n* notes · *m* links" and zoom controls | the strip falls back to one line, a shorter line, or two rows (`ViewThatFits`) |
| **Ask Library** | `LibraryChatView`: retrieval-augmented questions over every open collection, answers with links back | a question sent from a selection waits on the app-wide library and is asked automatically when an Ask Library view next appears, in whichever window that is. If Ask Library is already showing, it waits |
| **Assistant** | `AssistantHost`: the agentic assistant. It draws its own header row (agent mode, the model, New conversation, AI settings), and its edits need approval (`EditApprovalView`) | |

None of the three keeps a window's habits. The graph used to demand a 560pt
minimum and drew past the edge of the first panel it was put in.

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
although it needs none (`menu.md` §8). Ask Your Library, Assistant and the three
note actions open the panel, which on a phone is drawn over the AI place itself
while no note is expanded (§2).

---

## 8. How it cooperates with the rest of the window

- **Tags filter the primary sidebar**: the two sidebars cooperate across the
  editor (L1).
- **The editor's status bar repeats three panel views as popovers**: Properties,
  Links (the References content, without suggestions) and Outline & statistics.
  It also opens the Git pane as a popover and **Version History as a sheet**.
  The popovers are routes for a note window, which has no panel. In a note
  window, though, Links always says "No References", because the window passes
  no references, and the mind-map button does nothing (`toolbars.md` §14). The
  History sheet is a modal over the note, which §1 rules out; the panel's
  History view is the same content without it.
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
4. **Most of the panel has no menu item.** Show/Hide Panel, Outline, Tags,
   References, Properties, History and Mind Map have none. Outline, Tags and
   References are reachable from the menu bar only indirectly, through Note ▸
   Summarise Note, Suggest Tags and Suggest Links. Only Graph, Ask Library and
   Assistant are in the View menu. See [menu.md](menu.md) §8.
5. ✅ ~~**The outline's headings are capped at 320pt high**~~, a leftover from when it
   was a popover. In a tall panel, a long outline scrolls inside a short box. *Fixed (implemented.md §51.36).*
6. ✅ ~~**The panel's cap is not applied.**~~ `ShellMetrics.panelCap` (560) is
   declared and read by nothing. The panel can be dragged to whatever leaves the
   editor 320pt: 1,000pt or more on a large display. Decide: apply the cap, or
   delete it and say that the only limit is the editor's floor. *Fixed (implemented.md §51.36).*
7. **Three views add rows of their own.** Graph adds two (its pop-up strip and
   its counts-and-zoom row), and the Mind Map and the Assistant one each, under
   the panel's own header: four extra rows of chrome, which D1 forbids, drawn
   four different ways.
8. ✅ ~~**Escape has three owners inside the panel's reach.**~~ The panel's Close, the
   find bar's Done and the Assistant approval card's Deny are all
   `.cancelAction`. During an approval, Escape may close the panel instead of
   denying the edit. *Fixed (implemented.md §51.36).*
9. **What the panel shows is app-wide; whether it shows is per window.** Two
   windows cannot show two different views: choosing Graph in one switches the
   other. This follows L10 as written; it is recorded because it surprises.
