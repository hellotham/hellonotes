---
status: PORTED (2026-08-11), amended the same day by docs/shell-chrome.md, which
replaced the left rail + note-list pair with a single collection tree (decision
14, superseding 12 and 13). Everything about *sizing* below still holds.
Originally: the sizing contract, the adaptive shell, both rails (including
the 64pt library switcher and the Library place) and the width model are in the app on both
platforms. Decisions 2, 3, 4 (persistence), 7 and 11 are not yet built; see
docs/unimplemented.md §6b. Shipped detail: docs/implemented.md §17.
Wireframes: docs/wireframes.html
---

# HelloNotes layout architecture

A shell that is correct at every size, derived from who uses the app and on what, then expressed as
numbers, then as structure. Wireframes for every device: [`docs/wireframes.html`](wireframes.html).

---

## Why this document exists

A note's first lines were unreachable — no scrolling would bring them into view. Six speculative fixes
failed because each treated it as a scrolling bug. Instrumenting the running app to print its own view
hierarchy gave the answer in one measurement. Inside a **923pt** window:

```
AppKitWindowHostingView                       h=923.0    y=0       ← the window
  NavigationSplitRepresentable                h=1477.5   y=-251    ← 554pt too tall
    NSSplitView                               h=1477.5
      column hosting view                     h=1477.5
        MarkdownEditorView host               h=1390.5   y=52
          NSScrollView                        h=1390.5
```

The scroll offset was always correct. **The view was larger than the window it lived in**, so its top 251pt
sat above the window frame — rendered nowhere, reachable by nothing.

| Measurement | Value |
|---|---|
| `NSScrollView.fittingSize` for a 76-line note | **3433pt** (the whole document) |
| Detail column height that produced | 1477.5pt |
| Window content height available | 871pt |
| Representables implementing `sizeThatFits` | **1 of 9** |
| Frame constraint on the shell | `minWidth: 860, minHeight: 480` — a floor, **no ceiling** |

`NSScrollView`, `NSOutlineView`, `UITextView`, `WKWebView`, `PDFView` and `QLPreviewView` all report their
**content** size as their fitting size. A representable with no `sizeThatFits` hands that to SwiftUI as an
*ideal* size. `NSSplitView` sizes to its **tallest column**, so a 2,000-note outline inflates the shell by
itself. This is systemic, not an editor defect.

---

## Part 1 — Who uses this, and where

| Persona | Context | Job | Cannot show |
|---|---|---|---|
| **P1 Desk researcher** | macOS, 1470–3840pt | cross-reference sources, write a synthesis, commit | — |
| **P2 Laptop writer** | macOS 860–1280, often half-screen ~660 | write beside a browser or PDF | three columns + references at 660pt |
| **P3 iPad reader** | 11–13", Stage Manager = any width | read, follow a link, fix a sentence | permanent three columns in portrait |
| **P4 Split capturer** | iPad ⅓ (320pt) beside Safari | paste a quote, jot two lines | any second column, status bar |
| **P5 Phone capturer** | iPhone 375–430pt | capture, look up, read one note | anything alongside the note |

**Priority under pressure, identical for all five:**

> **text > switching > list > library > references > properties**

Navigation yields first. The reading column is the last thing to shrink and the last to disappear.

---

## Part 2 — Reading is not editing

Intent tracks the device. Someone at a 3840pt display is **editing** — building tables, drafting Mermaid
diagrams. Someone holding an iPad is almost certainly **reading**. The measure serves reading; it must not
become a cage for editing.

**Resolution: cap the prose, not the page.**

| Intent | Prose width | Blocks — tables, code, Mermaid, math, images | Tools |
|---|---|---|---|
| Reading | **fixed measure**, centred — line length is the whole point | fit the pane, scroll inside if wider | none |
| Editing | **proportional to the pane** — the pane is the workspace | full pane width | always in reach |

**The constraint belongs to reading, not to editing.** A fixed measure is right when the activity is
reading a line and returning to the next one. It is wrong on a large editing surface: with manual-only
splitting (decision 2), a 3840pt display opens as a single ~3200pt pane, and a fixed 80ch column would sit
as a 560pt ribbon marooned in 1300pt of gutter on each side. That is not restraint — it looks broken, and
it wastes exactly the room the editing user opened a big display to get.

### Width: fixed for reading, proportional for editing

| Setting | Applies to | Options | Default |
|---|---|---|---|
| **Appearance ▸ Reading width** | Reading mode | Narrow 60 · Normal 75 · Wide 90 · Full | **80ch**, centred |
| **Appearance ▸ Editor width** | Editing, Source | **Full** · 90% · 75% · 50% · fixed *n*ch | **Full pane** |
| **Appearance ▸ Wrap guide** | Editing, Source | off · 72 · 80 · 100 | **off** |

```
readingWidth = min(measure_ch, pane − insets)        // fixed measure, CENTRED
editorWidth  = max(320, (pane − insets) × proportion) // default 100%, LEFT-ALIGNED
blockWidth   = pane − insets                         // always, in every mode
```

**Alignment differs too, and that matters as much as width.** Reading is centred, because a centred
measure is what a page looks like. Editing is **left-aligned like VS Code** — text starts at the left
gutter and runs to the pane edge. Centring a proportional column would just reintroduce symmetric gutters,
which is the thing being fixed.

**The ruler becomes a guide, not a wrap point.** In Xcode and VS Code the page guide is a *line you can see*
while text still wraps at the view's edge. That is the right model here: editing fills the pane by default,
and anyone who wants a hard column switches Editor width to a fixed *n*ch.

**The reference is VS Code.** Nobody would accept a Markdown file rendered as a narrow ribbon down the
middle of a code editor, and a Markdown *editor* is no different. Editing uses the pane it was given.

**Implications:**
- Editing on a wide pane no longer strands a narrow ribbon in empty gutters — the text follows the pane.
- Reading keeps the measure that makes it comfortable, because that is the activity where it matters.
- Split shows both rules at once: the editing half proportional, the reading half fixed and centred.
- A narrow pane collapses the distinction — `min()` and the 320pt floor mean a phone never sees either
  setting bite.
- Source mode is monospace, so any fixed *n*ch resolves to a different point width; widths are always
  resolved against the current font, never stored as points.

### Modes

| Mode | Markers | Prose wraps at | Blocks | Tools | Type |
|---|---|---|---|---|---|
| **Reading** | hidden, fully rendered | fixed measure, centred | break out | none | prose |
| **Editing** (live) | revealed at the caret | proportional to pane | full pane | format / accessory bar | prose |
| **Source** | all visible, unstyled | proportional, or off → h-scroll | n/a — plain text | format bar | monospace |
| **Split** | Editing \| Reading | each half by its own rule | each half | format bar | both |

---

## Part 3 — Component sizes

| Component | Floor | Ideal | Cap | Why |
|---|---|---|---|---|
| **Prose — reading** | 45ch | 80ch | 90ch | line length; return-sweep accuracy |
| **Prose — editing** | 320pt | full pane, left-aligned | pane | the pane *is* the workspace (VS Code) |
| **Blocks** | — | full pane width | pane | tables and diagrams need room |
| Editor pane (incl. chrome) | 320 | 560 | — | the measure above |
| Sidebar (left) | 220 | 280 | 340 | collections + folders in one tree |
| Inspector rail (right) | 220 | 280 | 360 | outline, tags, backlinks |
| References (when inline) | — | 200 h | 280 h | 3–4 rows |
| Format bar | 36 h | 36 h | 36 h | chrome, definite |
| Tab bar | 32 h | 32 / 44 h | 44 h | 44 under touch (HIG) |
| Keyboard accessory bar | 44 h | 44 h | 44 h | touch editing |
| Status bar | 24 h | 28 h | 28 h | chrome, definite |
| Bottom tab bar (compact) | 49 h | 49 h + safe area | — | iOS standard |
| Mini-note strip (compact) | 56 h | 56 h | 56 h | the "mini player" |

---

## Part 4 — Structure

### Layout follows the axis of abundance, not width alone

Wide displays have horizontal room → navigation becomes **side rails**. Tall displays have vertical room →
navigation becomes a **band across the top**, and the editor keeps the full measure beneath it. Phones have
neither → the **editor is the whole screen**.

> An iPad in portrait is 834pt wide. By width alone that buys a second column and a 554pt measure. Band it
> instead and the editor gets the **full measure**, with navigation spending the height portrait has spare.
> Same pixels, better reading.

| Condition | Shell | Navigation lives | Reading column |
|---|---|---|---|
| `width < 600` | **Compact** | bottom tab bar + retracting mini-note | full screen |
| `width ≥ 600 · height > width` | **Tall** | band across the top | full width, ≤ ruler |
| `width 600–960 · landscape` | **Two** | sidebar (collapsible) | rest |
| `width ≥ 960` | **Wide** | sidebar (collapsible) | panes |
| `width ≥ 1400` | **Wide + inspector** | sidebar + right inspector | panes |

One rule reads both platforms: a Mac window and an iPad at the same size get the same shell. Stage Manager
makes device identity meaningless, so it is never consulted.

### The sidebar and the inspector

| Panel | Question | Contents |
|---|---|---|
| **Left — sidebar** | "Where is it?" | Recents and Bookmarks pinned above one section per open collection, each expanding into its folder tree |
| **Right — inspector** | "What is this, and what touches it?" | tabbed: **Outline · Tags · References · Properties · History** |

**Tags live entirely in the inspector** (decided). The sidebar is purely places; the inspector is the
single cross-cutting surface. Selecting a tag there still filters the notes — the two cooperate across
the shell.

**One sidebar, not a rail plus a list** (decision 14, superseding 12 and 13). Collections are top-level
nodes and their folders nest beneath, Apple Notes' account-then-folders arrangement. The reason is
structural rather than aesthetic: SwiftUI hands a correctly-placed sidebar toggle to **column one only**,
so while a fixed-width rail held that slot, the panel that actually needs collapsing was column two and
its control had to be hand-placed — which produced a button floating mid-list, three inspector toggles and
a `»` chevron over twenty attempts. Measured in `scratchpad/ChromeLab`: the three-column shape produces
**no toggle at all**. Recents and Bookmarks are pinned collapsible nodes rather than a separate place,
because they span collections and so correspond to no folder on disk. Full reasoning, survey and
wireframes: `docs/shell-chrome.md`.

The inspector consolidates four surfaces scattered today — references beneath the note, outline in a
popover, tags in the left sidebar, graph in a separate window. Below 1400pt they collapse back to
on-demand popovers and the Graph window. Selecting a tag still filters the note list: the rails cooperate.

### Panes and tabs — one job, three implementations

Surplus width buys **another note, never a wider line**.

| Detail width | Panes on open | Max (manual split) | Switching |
|---|---|---|---|
| `< 640` | 1 | 1 | tab strip, 44pt, scrolls + overflow ⌄ |
| `≥ 640` | 1 | 2 | full tab bar |
| `≥ 1400` | 1 | 3 | full tab bar, per pane |
| `≥ 2100` | 1 | 4 | full tab bar, per pane |

**Splitting is always manual** (decision 2) — width sets the *ceiling*, never the default.

`maxPanes = min(4, floor(detail / 320))`. Each pane owns its tab bar and note history.

> **Holding two notes is one job at three sizes.** Wide: **panes**. Narrow: **tabs** — the only way to
> switch when a second pane cannot fit, so tabs become *more* important as the screen shrinks, not less.
> Extreme: the strip scrolls with an overflow menu. **Switching is never removed.**

### Compact — the Apple Music model

The open note behaves like the now-playing track. A bottom tab bar carries the app's places (Notes,
Search, Tags, AI); the note being edited persists above it as a **mini strip**, one tap from full screen.
**Both retract as you scroll or type** and return on scroll-back, so writing gets the whole display without
losing the way back.

Worst case that must not break: **keyboard up leaves ~350pt of editor height**. Chrome must *retract, not
compress*, and the caret must stay visible above the keyboard.

### Toolbars — tools follow the hand, not the window

| Context | Placement | Height | Contents |
|---|---|---|---|
| Pointer · pane ≥ 560 · Edit | persistent format bar, top of each pane | 36 | style · lists · link · **insert: table, code, math, Mermaid, callout, image** |
| Pointer · pane < 560 | format bar collapses to overflow ⋯ | 36 | same set, one menu deep |
| Pointer · any size | window toolbar (native) | 52 | mode switcher · find · inspector toggle · split pane |
| Pointer · always | menu bar — Format menu | — | every command, keyboard-first |
| Touch · editing | **keyboard accessory bar** above the keyboard | 44 | scrolling row of the same actions |
| Touch · reading | none | — | mode switcher in the nav bar only |

Two bars, two scopes: the window toolbar acts on the **document**, the pane's format bar on the
**selection**. The toolbar is always a shortcut, never the only route.

---

## Part 5 — The sizing contract

Six layers; size information flows **down** only. A layer may report the size it was *offered*; never the
size of what it *contains*.

```
Scene → Shell → Rail/Band → Pane → Viewport → Content
```

**S1 — A viewport never advertises its content's size.** Every representable wrapping a scrolling or
content-sized view implements `sizeThatFits` and never returns `nil` (`nil` means "ask the platform view",
which is the bug):

| Proposal | Answer |
|---|---|
| concrete | exactly that |
| `.zero` | collapse |
| `.infinity` | grow |
| `nil` | a small constant — **never** content size |

**S2 — A minimum is not a constraint.** State a maximum too, or a large ideal still inflates the parent.

**S3 — Content expands, chrome is definite.** Content gets `maxWidth/maxHeight: .infinity`; chrome gets a
definite height from Part 3.

**S4 — Never nest an unbounded scroll inside a scroll.**

**S5 — Trust system safe-area insets.** Never disable `automaticallyAdjustsContentInsets` in a toolbar
window: with it on, the minimum scroll offset is `−toolbarHeight` so document y=0 clears the toolbar;
disabling it hid the first 66pt of every note.

**S6 — Geometry never depends on caret, selection, or scroll position.** Measured drift: document height
changed 3440 → 3516pt *because the user scrolled*.

---

## Part 6 — Validation

Correctness is **measured**, never eyeballed. For every scene × content combination:

1. No ancestor of any viewport exceeds the scene.
2. No viewport origin is negative.
3. First **and** last line of content are reachable.
4. Resizing strands nothing outside the scene.
5. Reading prose stays within its measure and is centred; editing prose tracks the pane at the set
   proportion with a 320pt floor; blocks never exceed the pane.
6. Touch targets ≥ 44pt in compact shells.
7. A way to switch between open notes is present in every shell.
8. Below the declared window minimum the editor still renders (decision 9) — degraded, never an error.
9. A ☰ affordance for the library is present in every shell below 960pt (decision 12).

**Scenes:** 320×1024 · 375×667 · 402×874 · 507×1024 · 660×900 · 834×1194 · 860×480 · 900×1400 ·
1194×834 · 1470×923 · 2560×1440 · 3840×2160 · live resize 1470 → 320 → 1470 · Stage Manager arbitrary.

**Content extremes:** empty · 1 line · 100k lines · 2,000-note outline · 4000px image / large PDF ·
wide table · Dynamic Type XS → AX5 · keyboard up.

**Where the matrix lives:** `HelloNotesTests/ShellContractTests` — it drives the app's own
`AdaptiveShell` and `NoteOutlineList` in a real toolbar window that is never ordered front, so this
class of bug fails the build. It asserts on viewports **and their ancestors**, never on scroll
content: being a window onto something larger than itself is what a viewport is *for*.

**Exploratory harnesses** (headless, no app relaunch, outside the repo): `scratchpad/LayoutRef/`
proved the shell rules before the port; `scratchpad/RealProbe/` drives the real `MarkdownEditor`
package. For live diagnosis, `HN_GEOM_LOG=1` makes a Debug build append its ancestor chain to
`~/Library/Containers/com.hellotham.HelloNotes/Data/Library/Caches/hn-geom.log` — any ancestor taller
than the scene is a live S1/S2 violation.

---

## Plan

1. **Design** — this document + `docs/wireframes.html`. ✅ reviewed
2. **Reference implementation** — `scratchpad/LayoutRef/`, 38/38 against the contract. ✅
3. **Port** — the 9 representables got S1; `AdaptiveShell` now arranges both shells; rails, bands and
   the compact model got S2/S3. ✅ *(the parts deliberately left: unimplemented.md §6b)*
4. **Regression test** — `HelloNotesTests/ShellContractTests`, 11 tests over the full scene matrix. ✅

---

## Part 7 — Decisions (settled in review)

| # | Decision | Rationale |
|---|---|---|
| 1 | **All tags move to the right inspector.** Left rail is collections + folders only. | One cross-cutting rail; left answers "where is it", right answers "what is this". |
| 2 | **Panes split manually only.** No automatic second pane at any width. | Resizing a window must never silently rearrange the workspace. |
| 3 | **Format bar is persistent when a pane is ≥560pt**, hidden in Reading mode, with a View-menu toggle. | Large screens are editing machines; tools stay in reach. |
| 4 | **Columns are draggable and collapsible**, remembered per window, clamped to the contract's floors and caps. | Standard Mac behaviour; clamping means a drag can never break the layout. |
| 5 | **Reading is a fixed measure (80ch, centred); editing fills the pane, left-aligned (VS Code model).** The ruler becomes an optional guide line, not a wrap point. | The measure serves reading. A fixed 80ch column in a 3200pt pane is 17% of the display — a ribbon stranded in gutters. No one would accept that in a code editor, and a Markdown editor is no different. |
| 6 | **Compact keeps the mini-note strip** above the tab bar (Apple Music model). | The open note stays one tap away while browsing. |
| 7 | **Graph, Mind Map, Assistant and Ask Library become full-screen sheets** on iPad and iPhone. | A canvas needs the whole display; gives iPad real parity for the first time. |
| 8 | **Note History is an inspector tab.** | It answers "what happened to this note?" — the right rail's job. |
| 9 | **Declare a hard window minimum; if the OS forces smaller, degrade** — keep showing the editor with text below its floor rather than an error state. | Stage Manager may ignore minimums; never break, never show a warning instead of the note. |
| 10 | **Inspector reopens on its last-used tab**, remembered globally. | Least surprise for a tool used in a rhythm. |
| 11 | **Compact chrome retracts on scroll-down, returns on scroll-up**, and retracts when the keyboard appears. | The Safari/Apple Music gesture people already know. |
| ~~13~~ | ~~The left rail is a 64pt switcher of places.~~ **Superseded by 14** — the rail held column one, which is the only column the platform will place a toggle for. | |
| ~~12~~ | ~~The left rail vanishes below 960pt and opens as an overlay.~~ **Superseded by 14** — that was forced by three columns not fitting; two fit at the 860pt window minimum with room over, so the sidebar is collapsible by *choice* at every size. | |
| 14 | **Collections and folders are one collapsible sidebar**, with Recents and Bookmarks pinned above them; commands live in the toolbar, never in the sidebar. | The collapsible panel must be column one or its toggle cannot be placed by the platform. And P2 collapses the sidebar *while working*, so anything inside it disappears exactly when it is wanted. See `docs/shell-chrome.md`. |

### Consequences worth remembering

- Decision 1 is **the biggest visible change**: tags leave the left sidebar, where they live today.
- Decision 13 removes the collection level from the note list. Anything that keyed on a collection row —
  the outline cache key, drop targets, "New Note" at a collection's root — has to read the rail's
  selection instead; each of those is a real defect if missed.
- Decision 2 means the two-pane plate in the wireframes shows a *capability*, not a default — a wide
  display opens with one pane until the user splits.
- Decision 3 adds 36pt of permanent chrome per pane while editing; Reading mode gets it back.
- Decision 5 means **switching Reading↔Editing reflows** on a wide pane, by design: the two modes
  legitimately want different widths. On a narrow pane the two converge and nothing moves.
- Decision 9 is the only rule that permits violating a floor, and only when the OS forces it.
- Decision 12 means the ☰ affordance must be present in every shell below 960pt.
