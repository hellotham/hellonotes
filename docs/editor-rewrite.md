# HelloNotes Editor — greenfield architecture

*Written 2026-07-17. Status: design approved, implementation in progress.*
*Replaces the `swift-markdown-engine` fork with an in-repo, PRD-native engine.*

## Why a rewrite

The forked engine fails the PRD's own success metrics on large notes (scroll
jank, freezes, caret lag, no caret autoscroll) for **structural** reasons —
each one is a design choice, not a bug:

| Fork behavior | Cost | Where |
|---|---|---|
| Full-document AST re-tokenize on every edit; parse cache keyed by `String ==` | O(document) per keystroke *and* per caret move | `parsedDocument(for:)` |
| `ensureLayout(for: documentRange)` to place code-block overlays | O(document) layout — the freeze | `updateCodeBlockSelection` |
| Chrome as overlay subviews reconciled per scroll/layout via `DispatchQueue.main.async` | main-queue churn while scrolling | `updateWideTableOverlays` etc. |
| `text: Binding<String>` through SwiftUI | whole-string copy + O(n) compare per keystroke in `updateNSView` | `NativeTextViewWrapper` |
| Dual storage/display text forms (`[[Name\|id]]` vs `[[Name]]`) | two coordinate systems, constant range mapping | wiki-link machinery — **HelloNotes never uses ids** |
| Custom scroll-view clamping/overscroll | broke standard caret autoscroll | `ClampedScrollView` |

Fixing these means replacing the kernel. Since we own the product direction
(macOS-native, iOS editor ambitions, features beyond the fork), we own the
engine.

## Design principles

1. **Raw Markdown IS the text storage.** One text, one coordinate system.
   Byte fidelity (PRD §10) holds by construction — the editor never rewrites
   what the user didn't touch. Presentation is *attributes and drawing*,
   never text substitution.
2. **Every editing-path operation is O(damage), never O(document).**
   Parse, style, and caret work scale with the edit or the paragraph — full
   document passes happen exactly once, at open, off the main thread.
3. **TextKit 2 as designed** — viewport-lazy layout, custom
   `NSTextLayoutFragment` drawing for block chrome, rendering attributes for
   non-metric decoration. Never `ensureLayout(documentRange)`. No overlay
   subviews on the scroll path. No scroll-view subclass tricks.
4. **The document is an object, not a Binding.** SwiftUI holds an
   `EditorDocument` reference; text flows out at save granularity, edits flow
   as range-level events. No per-keystroke string round-trips.
5. **Core is platform-free.** `MarkdownCore` (parser, model, style spec) is
   Foundation-only, `Sendable`, fully unit-testable, shared macOS/iOS. The
   same kernel later powers the iOS editor the PRD defers.
6. **Editor-grade parsing, not spec-grade.** A hand-rolled line/inline lexer
   tuned for stability and speed (like every serious editor — Obsidian,
   Typora deviate from CommonMark too). `swift-markdown` remains for export
   (HTML/PDF), where spec fidelity matters.

## Architecture

```
Packages/NotesEditor
├── MarkdownCore            (Foundation-only, nonisolated, Sendable)
│   ├── LineIndex           line-start offsets, spliced per edit
│   ├── Block / BlockParser line classifier with carry state (fences,
│   │                       front matter); re-parses only damaged lines,
│   │                       splices until old/new states converge
│   ├── Inline / InlineParser  per-block, on demand, memoized
│   └── StyleSpec           pure (block, inlines, reveal, theme-tokens)
│                           → [StyleRun] with semantic color roles
└── MarkdownEditor          (AppKit + UIKit + SwiftUI, MainActor)
    ├── EditorDocument      @Observable; owns NSTextStorage + parse state
    │                       + undo; snapshot text; range-edit events
    ├── StyleApplier        maps StyleRuns → storage attributes; caret-
    │                       reveal transitions restyle ≤2 paragraphs
    ├── FragmentFactory     NSTextLayoutFragment subclasses: code chrome,
    │                       quote/callout bars, HR, block math/mermaid/
    │                       transclusion rendering (draw, not subviews)
    ├── MarkdownTextView    NSTextView subclass (TextKit 2); UITextView
    │                       sibling later (same core, same document)
    └── MarkdownEditor      SwiftUI view: takes an EditorDocument +
                            closures (link tap, caret rect, paste intents)
```

### Text pipeline

- **Open:** parse everything (3.8 MB ≈ 12 ms), install *plain* text, style
  the first screens synchronously — open is effectively instant at any note
  size (measured: 48 ms for 3.8 MB). The rest styles progressively: an
  idle-time walker works forward in ~250-block batches, and a scroll
  observer styles whatever enters the viewport (± margin) on demand.
  *Why not pre-style off-main and install once?* Measured dead end:
  `setAttributedString` imports attribute runs lazily and NSTextStorage
  converts each region on first mutation — ~100 ms stalls landing on the
  user's first keystroke into a fresh region of a multi-MB note. Batched
  native-path styling settles those structures as it walks; a final
  net-zero synthetic edit absorbs the one remaining first-edit cost. (A
  standard `NSTextView`'s viewport delegate also can't be replaced on our
  OS floor — framework views gain overridable viewport hooks only in
  Apple's post-26 releases — so the scroll observer uses
  `boundsDidChangeNotification` + `viewportRange`, no delegate takeover.)
- **Keystroke:** splice `LineIndex` → re-parse damaged block neighborhood
  (stable boundaries: blank lines / fence edges) → restyle only those blocks.
  Budget: < 2 ms.
- **Caret move:** binary-search block at caret; if the reveal set changed
  (caret entered/left a paragraph with concealed syntax), restyle those ≤2
  paragraphs. Everything else untouched.
- **Save:** app-side debounce asks `document.text` for one snapshot.

### Syntax concealment (Typora-style reveal)

Markers (`**`, `` ` ``, `[[`, `#`) stay in the storage always. Concealed
state = same-length attribute transform (near-zero-size font + clear color);
revealed = normal dim styling, per paragraph containing the caret. Pure
color-state changes (find highlights) use **rendering attributes** — draw-
only, no layout invalidation — supplied through
`NSTextLayoutManager.renderingAttributesValidator` (doc-verified: rendering
attributes are invalidated whenever their fragment re-lays out, so one-shot
`setRenderingAttributes` calls silently vanish after edits; the validator is
the persistent channel).
*Rejected alternative:* `NSTextContentStorageDelegate` paragraph substitution
with markers removed — Apple's docs state the substituted paragraph **must**
have the same length as the backing range, so marker elision is out of
contract, not merely risky. Same-length substitution stays available behind
the StyleSpec seam as a polish pass.

### Presentation technique by element

| Element | v1 technique |
|---|---|
| Emphasis/code/strike/highlight/tags/comments | storage attributes + concealment |
| Headings (ATX + setext), lists, task checkboxes | attributes; checkbox glyph via same-length symbol styling, toggled by click hit-test |
| Wiki links `[[Name]]` (+aliases, `#heading`) | attributes + link attribute; resolver = existing app service |
| Code blocks | background via storage `.backgroundColor` (selection-compatible — fragment `draw(at:in:)` paints *above* the selection highlight per Apple DTS, so chrome drawing is reserved for bars/chips at the margins); async syntax highlight upgrades attributes when ready (never blocks typing) |
| Blockquotes / callouts | fragment-drawn bar/tint; callout collapse = later milestone |
| HR, front matter (hidden), footnotes | fragment draw / concealment |
| Block LaTeX, Mermaid, `![[image]]`, `![[transclusion]]` | custom fragment renders the image/card *in draw* when caret is outside; caret inside reveals source. Storage stays pure Markdown. Async render, content-hash LRU cache. (If live views are ever needed instead of draws, the documented TK2 route is an `NSTextAttachment` subclass overriding `viewProvider(for:location:textContainer:)` — there is no per-instance `viewProvider` property) |
| Inline LaTeX | v1: styled source (rendered inline images return as a later pass — requires the substitution machinery above) |
| Tables | v1: aligned monospaced styling + fragment grid lines; editing UX later |

Existing app services plug in unchanged behind one `EditorServices` bundle:
`CollectionWikiLinkResolver`, `CollectionEmbedProvider`/`NoteTranscluder`,
`HighlighterSwiftBridge`, `SwiftMathBridge`, `MermaidDiagramRenderer`.

### App-facing API (replaces 15 wrapper params + notification buses)

```swift
let document = EditorDocument(text: loaded, services: services)
document.onEdit = { edit in /* app debounces, then document.text */ }

MarkdownEditor(document: document)
    .editable(mode == .edit)
    .onLinkTap { target in ... }          // wiki/heading/url routing
    .onInlineContext { ctx in ... }        // [[..]] / #tag autocomplete
    .onPaste { intent in ... }             // image → asset, HTML → md

document.apply(.bold)                      // Format menu, direct calls
document.find("query")                     // find/replace, match count
document.scroll(to: .heading("Setup"))    // outline, [[Note#h]], search
```

`EditorModel` keeps its role (load/save/conflicts) but owns an
`EditorDocument` instead of a `String`; dirty tracking comes from edit
events, not O(n) string compares.

### AI-native by design

The editor treats AI as a first-class text producer, not a bolt-on:

- **Apple Intelligence Writing Tools** come free with the native TextKit 2
  view: `writingToolsBehavior = .complete` (inline proofread/rewrite/
  summarize), `allowedWritingToolsResultOptions = [.plainText]` so a
  rewrite can never return rich text and corrupt Markdown syntax.
- **System inline predictions** (`inlinePredictionType = .yes`).
- **External-session protocol**: any AI mutation (Writing Tools or a
  provider) runs inside `beginExternalTextSession()` …
  `endExternalTextSession()` — parsing stays live per edit (correctness),
  restyling pauses so our attributes never fight session decorations, and
  one catch-up restyle runs at the end.
- **`EditorProxy`** is the app's AI surface: `replace(range:with:)`
  (undoable, through the same path typing takes), `performAITransform`,
  plus `document.selectedRange` / `text(in:)` for context extraction.
  Rewrite-selection-with-prompt, selectable task transforms, and
  provider-driven ghost completion all build on this seam with the app's
  existing multi-provider IntelligenceService.

### Modes, undo, autoscroll

- **Preview** = the same editor, `isEditable: false`, reveal permanently off
  (everything renders). **Source** and **Split** keep their current app-side
  implementations.
- **Undo** = stock per-view NSUndoManager against the raw storage — the
  storage *is* the document, so no snapshot/stack juggling across tabs; each
  tab's document owns its undo manager.
- **Autoscroll** = don't break it: standard NSScrollView, insets for
  breathing room. Programmatic jumps use the doc-verified TK2 pattern:
  `ensureLayout(for:)` on the *target range only*, then
  `enumerateTextSegments(in:type:options:)` for the exact segment frame,
  then `scrollToVisible` — never trust `scrollRangeToVisible` alone against
  estimated (not yet laid out) heights, a known TK2 weak spot.

### Concurrency & observability

- `MarkdownCore`: nonisolated, value types, `Sendable`. `MarkdownEditor`
  target: `defaultIsolation(MainActor.self)` (Swift 6.2 package setting);
  async work (open build, highlight, renders) via structured tasks.
- `OSSignposter` intervals on parse/style/open/viewport paths; perf tests
  assert generous budgets (1 MB parse < 50 ms, keystroke cycle < 5 ms) so
  regressions fail CI, not the user.

## Rollout

1. **M0** — package scaffold; `MarkdownCore` block+inline parser, style
   spec, unit + perf tests. *(this session)*
2. **M1** — macOS editor view: styled open, incremental typing, caret
   reveal, autoscroll, link taps; wired into `NoteEditorView` behind a
   Settings toggle (old engine remains the default fallback). Live-verify
   scroll/caret on the 1.3 MB p99 note.
3. **M2** — parity core: autocomplete contexts, find/replace,
   format commands, image paste, code highlight upgrade, quote/code chrome.
4. **M3** — embeds: block math, Mermaid, image embeds, transclusion cards;
   callouts; front-matter fold; task toggles; footnotes; tables v1.
5. **M4** — flip default; remove the fork dependency; delete the toggle.
   Parity gaps tracked in `docs/editor-parity.md` from M1 onward.
6. **M5** — iOS `UITextView(usingTextLayoutManager:)` sibling — the PRD's
   deferred "richer iOS editor" becomes real on the shared kernel.

Fork stays referenced (unused) until M4 so every intermediate build ships a
working editor. Nothing in the app writes engine-specific state, so the
toggle is risk-free.
