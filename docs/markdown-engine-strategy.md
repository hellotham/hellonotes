# MarkdownEngine — Strategy for Unblocking Editor Limitations

> Research + recommendation · 2026-07-11 · Companion to [unimplemented.md](unimplemented.md)

## Progress

- **Fork is live:** [`ChristineTham/swift-markdown-engine`](https://github.com/ChristineTham/swift-markdown-engine)
  (a GitHub fork of `nodes-app/swift-markdown-engine`), branch **`hellonotes-patches`**
  based on the `0.8.0` tag. HelloNotes depends on it by URL + branch.
- **Fix #1 landed — scroll-to-location.** The `handleFindQuery` default scroll now
  uses the TextKit 2 fragment path universally (7-line change). Outline **jump-to-heading
  now scrolls** (verified live). `[[Note#heading]]` **link clicks** now navigate *and*
  scroll — a host-side follow-up: the resolver strips the `#heading` so the link renders
  clickable, and the click handler posts the find query to scroll.
- **Fix #2 landed — inline Mermaid.** The fork adds a `DiagramRenderer` service and a
  `styleDiagramBlocks` pass (`hellonotes-patches` @ `759c26e`); HelloNotes supplies a
  `MermaidDiagramRenderer` so ` ```mermaid ` fences render inline as images and toggle to
  source on caret-enter (verified live). Same `appendRenderedStandaloneBlock` machinery as
  block LaTeX. Diagrams also theme-match the editor and clamp wide diagrams to the reading
  column (fork @ `d37b913`).
- **Fix #3 landed — find & replace.** The fork adds `replaceCurrent` / `replaceAll` bus
  handlers on top of the existing display-coordinate find (fork @ `7221f73`); HelloNotes
  ships a ⌘F find/replace bar (live count, next/prev, replace, replace-all, single-step
  undo). Verified live.
- **Fix #4 landed — tag autocomplete.** The fork adds a `.tag` inline-selection kind (caret
  scan + caret rect) and an `isLiteralMode` replacement (fork @ `41f4304`); HelloNotes offers
  existing vault tags in the same popup as wiki-links. Verified live.
- **Fixes #5–7 landed — callouts, comments, front-matter hiding.** Three styling passes on the
  fork (@ `51e64e2`): `> [!type]` callouts render as tinted boxes (new `.calloutTint` fragment
  attribute), `%%…%%` comments dim, and the leading `---` front matter collapses (revealing on
  caret). All verified live. Remaining: transclusion (#8), plus the Foundation Models track.
- Workflow: patches land on `hellonotes-patches`; open upstream PRs to shrink the delta.

Every editor-layer item in [unimplemented.md](unimplemented.md) is blocked by a missing
hook in **[swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine)**
(`MarkdownEngine`). This document researches how to unblock them — including forking —
and evaluates the app-level Apple Intelligence path.

## TL;DR recommendation

1. **Fork `swift-markdown-engine`, and upstream the fixes as PRs.** It's Apache-2.0,
   ~11.7k LOC, zero core dependencies, cleanly protocol-oriented, and actively developed
   with a `CONTRIBUTING.md`. Most "walls" are **shallow** — the machinery we need already
   exists internally (inline image rendering for LaTeX, reading-column scroll, an
   extensible notification bus). Keep our fork as a thin patch set and rebase on upstream
   releases; open PRs so the delta shrinks over time.
2. **Apple Intelligence — Writing Tools already works** (the engine has a dedicated
   macOS 15.1+ coordinator). The *other* half — an on-device LLM for summarize / semantic
   search / auto-linking — is the **Foundation Models framework**, which is **independent
   of the editor** and can be added directly to the app.
3. **Do not build a Markdown editor from scratch** unless the fork becomes untenable. It's
   a multi-year effort, and per the author of [STTextView](https://github.com/krzyzanowskim/STTextView)
   (a 4-year TextKit 2 project), TextKit 2 itself still has "unstable scrolling, unreliable
   height estimates, and viewport issues" — some of our pain is Apple's, not the engine's.

## The engine, as it actually is (facts that drive the decision)

| Property | Finding |
|---|---|
| License | **Apache 2.0** — fork/modify/redistribute freely |
| Size | **~11.7k LOC** core, zero external deps (bridges for code/LaTeX are opt-in products) |
| Platform | macOS 14+, AppKit + TextKit 2 (iOS not supported → our iOS build already excludes it) |
| Maturity | **pre-1.0** (207 commits, 11 releases, 13 contributors in ~2 months) → **API churn is the main risk** |
| Docs | ships `ARCHITECTURE.md` (codemap) + `CONTRIBUTING.md` (PR process, design constraints) |
| Extension points | 4 service protocols (`WikiLinkResolver`, `EmbeddedImageProvider`, `SyntaxHighlighter`, `LatexRenderer`), a `MarkdownEditorBus` of ~20 notification hooks, an inline-token bus (`onInlineSelectionChange` / `onCaretRectChange` / `pendingInlineReplacement`), and a Writing Tools coordinator |
| Reusable internals | `appendRenderedStandaloneBlock(image:…, mode:.collapsedSource)` renders a block token as an inline image (used by block LaTeX); the reading-column find path already does correct `ensureLayout` + fragment-enumeration scrolling |
| Inline token kinds | `wikiLink`, `imageEmbed`, `inlineLatex`, `blockLatex` — **no `tag` token** yet |

## Options considered

| Option | What it is | Verdict |
|---|---|---|
| **A. Host-side only** | Work purely in HelloNotes against the current public API | Already exhausted for most items — the hooks aren't there. |
| **B. Upstream PRs** | Contribute fixes to `nodes-app/swift-markdown-engine` | **Best long-term** — shared maintenance, no drift. Depends on maintainer responsiveness. |
| **C. Fork & maintain** | Keep a patched copy we control | **Best short-term** — unblocks us immediately; cost is tracking upstream (pre-1.0 churn). |
| **D. New editor** | Build on [STTextView](https://github.com/krzyzanowskim/STTextView) / [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView) or from scratch | **Last resort** — multi-year; inherits TextKit 2's platform bugs. |

**Chosen path: B + C together** — fork as our working copy (SPM local package / `.package(url:branch:)`), and raise each fix as a focused upstream PR. As PRs merge, drop them from the fork.

## Per-limitation unblock plan

Difficulty is for a fork/upstream patch. "✅ machinery exists" means the engine already
does something structurally identical we can copy.

| # | Feature | Difficulty | Approach |
|---|---|---|---|
| 1 | **Jump to location / scroll-to-heading / outline jump** | **Easy** ✅ | `handleFindQuery`'s default (non-reading-column) scroll calls `scrollRangeToVisible`, a no-op for off-screen TextKit 2 content. The reading-column branch **already** scrolls correctly via `textLayoutManager` fragment enumeration with `.ensuresLayout`. Apply that path universally (or `ensureLayout` before the reveal). Unblocks the outline jump *and* `[[Note#heading]]` navigation in one change (~20–40 lines). |
| 2 | **Inline Mermaid rendering** | **Small–moderate** ✅ | Add a `DiagramRenderer` service protocol mirroring `LatexRenderer` (returns an `NSImage`), plus a `MarkdownStyler+Diagrams` that intercepts ` ```mermaid ` code tokens and calls the existing `appendRenderedStandaloneBlock(...)`. We already produce the image via `beautiful-mermaid` (see `MermaidPreviewView`). Same pattern as block LaTeX. |
| 3 | **Find & replace** | **Moderate** | Find (`findQuery`) exists. Add a `replace` / `replaceAll` bus request + handler that edits the text storage and restyles, reusing the `applyInlineReplacement` mechanics; scrolling to matches falls out of #1. Add a `replace` name to `MarkdownEditorBus`. |
| 4 | **Tag autocomplete (`#tag`)** | **Moderate** | Add a `tag` inline-token kind to `InlineParser`, then fire `onInlineSelectionChange` / `onCaretRectChange` for it exactly as for `wikiLink`. Our host-side completion UI already exists — it just needs the token + caret rect the engine currently only emits for wiki-links. |
| 5 | **Callouts `> [!note]`** | **Moderate** | A styled blockquote variant: detect the `[!type]` marker and apply background/icon/title styling. The engine already styles blockquotes. |
| 6 | **Comments `%%…%%`** | **Small–moderate** | Tokenize `%%…%%` and dim/collapse it, reusing the marker-collapse machinery LaTeX uses for `$$`. |
| 7 | **Hide raw front matter** | **Small–moderate** | Collapse the leading `---` block (same collapse machinery), pairing with our existing editable Properties panel so the raw YAML no longer shows as body text. |
| 8 | **Note transclusion `![[Note]]` / `![[Note#heading]]`** | **Moderate–hard** | Render an embedded note inline: resolve the target, render its content to an attributed block or image, and insert as a standalone block (extends #2's block-render path, but with live/read-through semantics). Heaviest item; reasonable to defer even after a fork. |

Net: **six of eight are easy/moderate**, and the two highest-value (jump-to-location, inline
Mermaid) are the *cheapest* because the engine already contains the pattern.

## Apple Intelligence — two independent tracks

1. **Writing Tools** (rewrite / proofread / summarize a selection, macOS 15.1+): **already
   integrated.** `NativeTextViewCoordinator+WritingTools.swift` handles the full session
   lifecycle — pausing styling, re-syncing accepted results, fixing the child-window
   position, and recovering from Apple's stale-accept bug on mid-session undo. **No work
   required**; a fork must simply preserve this.

2. **Foundation Models framework** (on-device LLM, macOS 26 / Xcode 26): the app-level AI
   path, **entirely independent of the editor**. A `LanguageModelSession` runs inference
   in a few lines of Swift; WWDC26 also lets other providers (incl. Anthropic/Google) swap
   into the same API. Candidate HelloNotes features, all buildable without touching the
   engine:
   - Summarize / outline the current note or a selection.
   - Semantic vault search and "chat with your vault" (retrieve over the existing search
     index, answer with citations to notes).
   - Suggest `[[links]]` and `#tags` for a note (great pairing with our unlinked-mentions
     and tag features).
   - Generate from a template / expand a stub note.
   These are a separate workstream from the engine fork and can proceed in parallel.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Engine is **pre-1.0**; APIs shift between releases | Pin the fork to a known-good SHA; keep our changes a small, well-labeled patch set; upstream them so the delta shrinks; rebase on tagged releases, not `main`. |
| Fork **maintenance burden** | Prefer upstream PRs; only carry unmerged patches. ~11.7k LOC with a codemap is tractable for the ~8 targeted changes above. |
| **TextKit 2 platform bugs** (scroll/viewport) are Apple's, not the engine's | Fix what's fixable (e.g. #1), accept that some jank is inherent; don't chase parity the platform can't give. |
| Diverging from upstream causes **merge conflicts** | Keep each feature patch isolated to as few files as possible (new files > edits where feasible: e.g. `MarkdownStyler+Diagrams.swift`, a new `DiagramRenderer`). |

## Suggested sequencing

1. **Spike (½ day):** fork, wire HelloNotes to the local fork, land fix #1 (scroll) — it's
   the smallest change and instantly upgrades the outline jump + heading links we already
   shipped as "display-only". Validates the whole fork workflow.
2. **Inline Mermaid (#2)** — high visible payoff, machinery exists.
3. **Find & replace (#3)** and **tag autocomplete (#4)**.
4. **Callouts / comments / front-matter hide (#5–7)** as polish.
5. **Transclusion (#8)** only if still wanted.
6. **Foundation Models features** — parallel track, editor-independent; start with
   summarize + suggest-links.

For each, open an upstream PR; carry it in the fork until merged.

## Sources
- [swift-markdown-engine (GitHub)](https://github.com/nodes-app/swift-markdown-engine) · [Swift Package Index](https://swiftpackageindex.com/nodes-app/swift-markdown-engine)
- [Apple Foundation Models framework](https://developer.apple.com/documentation/foundationmodels) · [Bring an LLM provider to Foundation Models (WWDC26)](https://developer.apple.com/videos/play/wwdc2026/339/)
- [STTextView](https://github.com/krzyzanowskim/STTextView) · ["TextKit 2 — the promised land" (Krzyżanowski)](https://blog.krzyzanowskim.com/2025/08/14/textkit-2-the-promised-land/)
- Engine source (local checkout): service protocols, `MarkdownStyler+Latex`, `NativeTextViewCoordinator+WritingTools`, `+Find`, `InlineParser`.
