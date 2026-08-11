# HelloNotes — Implementation history

> The archive of *how HelloNotes was built*. The other docs describe the **current**
> state; this one records the journey — the milestone sequence, the greenfield editor
> rewrite, the retired `swift-markdown-engine` fork, the GFM full-fidelity work, and the
> notable fixes worth remembering. It consolidates the former `implementation-plan.md`,
> `markdown-engine-strategy.md`, `editor-rewrite.md`, and `editor-parity.md`.

**Current status:** v1.0 shipped (Milestones 0–13), plus the deeper Apple-platform
integration (§10 and [native-roadmap.md](native-roadmap.md)) and **cloud storage** (§11–12,
[cloud-native-roadmap.md](cloud-native-roadmap.md)). Builds clean on macOS + iOS in **both
Debug and Release** (§13 — Release is checked explicitly now, because a Release-only
optimizer crash once broke every archive while Debug stayed green); the editor package suite
(`swift test --package-path Packages/NotesEditor`) is **83 tests / 9 suites** green, plus
**63 app unit tests**. Ships as a signed, notarized universal DMG. The editor is the in-repo
[`Packages/NotesEditor`](../Packages/NotesEditor); the markdown-engine fork is removed.

---

## 1. Build milestones (0–13)

The app was built as a milestone sequence, each ending on a green `xcodebuild` (0 errors,
0 warnings in app sources) plus off-UI smoke tests. **v0.1 = M0–9**, **v1.0 adds M10–13.**

- **M0 — Foundation.** `Note` model; `@Observable` vault indexer with scan + `NSOpenPanel`; 3-column `MacContentView`; `WindowGroup` app entry.
- **M1 — Editing MVP.** `EditorModel` (`@Observable`) with debounced atomic autosave (≤1 s), dirty tracking, flush on switch/terminate; live Markdown + code highlighting; note create/delete (to Trash) + rescan; title filter; vault persisted via a security-scoped bookmark.
- **M2 — Knowledge graph & math.** `Core/MarkdownParsing` extracts `[[wiki-links]]`, headings (AST), `#tags`; `LinkGraph` async backlink index off-main; backlinks panel; LaTeX math; wiki-link click→navigate via a resolver that reports existence only, so files stay byte-for-byte intact.
- **M3 — Search & navigation.** Full-text search (titles + bodies with snippets, cached off-main); "Open Quickly" fuzzy finder; external-change detection via FSEvents; folder tree with sort; `#tags` filter; open-note conflict handling.
- **M4 — Git sync.** `State/GitService` (`@Observable`) over SwiftGitX, libgit2 off-main; repo status; Initialize Repository; local Commit + opt-in debounced auto-commit (never auto-pushes); user-initiated Push/Fetch. (Pull/merge deferred — SwiftGitX has no merge.)
- **M5 — Native rendering polish.** Image paste → `assets/` PNG + relative link; front-matter summary panel; native Mermaid (no WebView). Tables/footnotes render live.
- **M6 — iOS shell.** App builds for iOS; `iOSContentView` `NavigationStack`; plain-text `TextEditor` sharing the same `EditorModel`; iPadOS adaptive `NavigationSplitView`.
- **M7 — Writing companions.** Document statistics; outline/TOC popover; export to HTML (swift-markdown) or PDF (offscreen `NSTextView`, no WebView); multi-tab editing (`State/EditorTabs`).
- **M8 — Organization & navigation.** Nested tags (`Core/TagTree`); Git version history (browse + restore); wiki-link autocomplete; open-in-new-window.
- **M9 — Core KB features.** Aliases; `[[Note#heading]]` completion; outgoing links + unlinked mentions; native `Canvas` force-directed graph; daily notes & templates; bookmarks; editable typed properties (`Core/FrontMatter` + Properties editor).
- **M10 — Editor unblocking via the fork.** The eight "engine wall" deferrals from M3–9 resolved by forking `swift-markdown-engine` and upstreaming each fix (see §3).
- **M11 — Library, files & git hosting.** Multi-collection Library (`State/Library` + `Collection`) with launcher/recents and Obsidian vault import; note ops (rename with vault-wide link rewrite, duplicate, drag-move); attachments + native file viewer; smart paste (HTML→Markdown); Vision image alt-text; Git hosting (HTTPS token creds in Keychain, clone/create-remote, in-app git identity).
- **M12 — AI: intelligence, assistant & providers.** Streaming `LLMProvider` protocol with adapters (Apple Foundation Models, MLX, OpenAI-compatible, Anthropic, Gemini); "Ask Library" RAG chat with citations; agentic Assistant (`AgentRunner`) with tools behind `PermissionBroker` approval, web search/fetch, skills, deep research; note intelligence (summarise/tags/links).
- **M13 — Exploration views, polish & hardening.** Edit/Preview/Source/Split modes; Marp slide decks; directional link map + content-based Mind Map; full menu bar, windowed Graph/Mind Map/Assistant/Ask Library, appearance settings, launch splash; production hardening (FIFO-serialized `GitService`, atomic chat persistence, provider timeouts, bounded web fetch, zero warnings).

> **Naming note:** the milestone plan numbers Git sync "M4"; the *editor rewrite* has its own
> independent M0–M5 track (§2). "M4" in the rewrite/fork context means **editor-M4 = fork removed**.

---

## 2. The editor rewrite — greenfield `Packages/NotesEditor`

*The TextKit 2 rewrite is now the **only** editor; the fork was removed at editor-M4 (2026-07-17).*

### Why the rewrite

The fork failed the PRD's own success metrics on large notes (scroll jank, freezes, caret
lag, no caret autoscroll) for **structural** reasons — each a design choice, not a bug:

- Full-document AST re-tokenize on every edit; parse cache keyed by `String ==` → O(document) per keystroke *and* per caret move.
- `ensureLayout(for: documentRange)` to place code-block overlays → O(document) layout — the freeze.
- Chrome as overlay subviews reconciled per scroll via `DispatchQueue.main.async` → main-queue churn.
- `text: Binding<String>` through SwiftUI → whole-string copy + O(n) compare per keystroke.
- Dual storage/display text (`[[Name|id]]` vs `[[Name]]`) → two coordinate systems (HelloNotes never uses ids).
- A custom scroll-view subclass broke standard caret autoscroll.

### Design principles

1. **Raw Markdown IS the text storage** — one text, one coordinate system; byte fidelity holds by construction; presentation is attributes and drawing, never text substitution.
2. **Every editing-path op is O(damage), never O(document)** — full-document passes happen once, at open, off-main.
3. **TextKit 2 as designed** — viewport-lazy layout, custom `NSTextLayoutFragment` drawing for block chrome, rendering attributes for non-metric decoration; never `ensureLayout(documentRange)`; no overlay subviews on the scroll path.
4. **The document is an object, not a Binding** — SwiftUI holds an `EditorDocument` reference.
5. **Core is platform-free** — `MarkdownCore` is Foundation-only, `Sendable`, shared macOS/iOS.

### Architecture (three targets)

- **`MarkdownCore`** (Foundation-only, nonisolated, Sendable): `LineIndex` (line-start offsets spliced per edit); `Block`/`BlockParser` (line classifier with carry state for fences/front-matter, re-parses only damaged lines until old/new states converge); `Inline`/`InlineParser` (per-block, memoized); `StyleSpec` (pure → `[StyleRun]` with semantic colour roles).
- **`MarkdownEditor`** (AppKit + UIKit + SwiftUI, MainActor): `EditorDocument` (`@Observable`; owns `NSTextStorage` + parse state + undo); `StyleApplier` (StyleRuns → storage attributes; caret-reveal restyles ≤2 paragraphs); block-fragment factory (`NSTextLayoutFragment` subclasses for code chrome, quote/callout bars, HR, block math/mermaid/transclusion — draw, not subviews); `MarkdownTextView` (`NSTextView`/`UITextView`); `GFMLiveStyle` (cmark-driven inline styling); `GFMPreview` (WKWebView Preview host).
- **`GFMRender`**: cmark-gfm-based GitHub-identical Preview + parity tests (§4).

### Text pipeline

- **Open:** parse everything (3.8 MB ≈ 12 ms), install *plain* text, style first screens synchronously (~48 ms for 3.8 MB). Rest styles progressively via an idle walker (~250-block batches) + a scroll observer styling the viewport (± margin).
- **Keystroke:** splice `LineIndex` → re-parse the damaged block neighborhood → restyle only those blocks. Budget < 2 ms (measured ~6 ms full cycle on the 3.8 MB stress note).
- **Caret move:** binary-search the block at the caret; restyle ≤2 paragraphs only if the reveal set changed.
- **Save:** app-side debounce asks `document.text` for one snapshot.

### Concealment / caret-reveal (Obsidian/Bear style)

Markers (`**`, `` ` ``, `[[`, `#`) stay in storage always. Concealed = same-length attribute
transform (near-zero-size font + clear colour); revealed = normal dim styling on the paragraph
containing the caret. Pure colour-state changes (find highlights) use **rendering attributes**
through `NSTextLayoutManager.renderingAttributesValidator`. Programmatic scroll uses the
doc-verified TK2 pattern: `ensureLayout(for:)` on the *target range only* → `enumerateTextSegments`
→ `scrollToVisible`.

### Key subsystems

- **Code blocks:** async syntax highlighting via **HighlighterSwift** (highlight.js/JSCore) behind a `CodeHighlighting` protocol; editor takes *foreground colours only*, cached per content hash → synchronous restyles, no flash. Uses GitHub's `github`/`github-dark` theme to match the Preview.
- **Block embeds / math / mermaid / transclusion / tables:** one fragment-drawn `BlockRenderer` path — renders image/card *in draw* when the caret is outside, reveals source inside; storage stays pure Markdown; async render with content-hash LRU cache. LaTeX via in-app `MathImageRenderer` (direct SwiftMath), tables via `TableImageRenderer` (GitHub palette + zebra), Mermaid via `MermaidDiagramRenderer`.
- **Callouts** (`> [!type]`): tinted band + gutter bar + icon + coloured title; `>` syntax concealed outside the caret; collapse/fold via a right-aligned disclosure chevron (ephemeral state, never written to file).
- **Task checkboxes:** real glyphs over concealed `[ ]`/`[x]`; click toggles undoably and persists to disk.
- **AI-native seam:** Writing Tools (`.complete`, `.plainText` so rewrites can't corrupt Markdown); system inline predictions; `EditorProxy` (undoable `replace(range:with:)`, `performAITransform`) as the AI surface.

### Rollout

- **editor-M0** — package scaffold, MarkdownCore parser + style spec, unit + perf tests.
- **editor-M1** — macOS editor view (styled open, incremental typing, caret reveal, autoscroll, link taps), behind a Settings toggle.
- **editor-M2** — parity + AI: autocomplete, find/replace, format commands, image/HTML paste, code highlight, Writing Tools, inline predictions, AI rewrite-selection.
- **editor-M3** — embeds (image, Mermaid, block math, transclusion cards), clickable checkboxes, callouts.
- **editor-M4** — flipped the default; **fork removed**; toggle deleted; LaTeX ported off the fork's `SwiftMathBridge` to `MathImageRenderer`; Mermaid/transclusion/embed providers decoupled from the fork.
- **editor-M5** — iOS `UITextView(usingTextLayoutManager:)` sibling on the shared kernel: live inline styling, caret concealment, and the full fragment chrome via an overlay renderer. Remaining: app-side services (code colours, embeds) on iOS.

Post-M4 polish: inline `$…$` LaTeX as baseline images, tables, `> [!type]` concealment,
front-matter fold, callout collapse/fold, footnotes.

---

## 3. The `swift-markdown-engine` fork saga (retired)

**What it was:** `ChristineTham/swift-markdown-engine`, branch `hellonotes-patches`, a fork of
`nodes-app/swift-markdown-engine` (Apache-2.0, macOS 14+ AppKit/TextKit 2, no iOS, pre-1.0). HelloNotes
depended on it by URL + branch through M3–M13, before the greenfield rewrite replaced it.

**Why fork:** every editor-layer deferral from M3–9 was blocked by a missing engine hook. Of the
options — (A) host-side only [exhausted], (B) upstream PRs [best long-term], (C) fork & maintain
[best short-term], (D) new editor [last resort] — the choice was **B+C together**: fork as the
working copy, raise each fix as a focused upstream PR. (Building from scratch was rejected *at the
time*; it became the right call later once TextKit 2's own scrolling/height quirks were understood.)

**The eight patches** (each resolving an M3–9 wall): (1) scroll-to-location (universal TK2 fragment
path); (2) inline Mermaid (`DiagramRenderer` service); (3) find & replace (`replaceCurrent`/`replaceAll`);
(4) tag autocomplete (`.tag` inline-selection kind); (5–7) callouts / `%%comments%%` / front-matter
hiding (new `.calloutTint` fragment attribute); (8) note transclusion (host-side `VaultEmbedProvider`,
no engine change).

**Upstream PRs** opened to `nodes-app/swift-markdown-engine`: #91 scroll, #92 DiagramRenderer,
#93 find & replace, #94 tag token, #95 callouts/comments/front-matter.

**Removal:** at editor-M4 (2026-07-17) the fork was removed from the codebase once
`Packages/NotesEditor` became the sole editor. Its patches remain published on `hellonotes-patches`
and in the upstream PRs; the local checkout was later deleted and stale references scrubbed from
code comments and docs.

---

## 4. GFM full-fidelity work (most recent arc)

Made both the Preview *and* the live editor provably GitHub-faithful, using GitHub's own engine.

**GitHub-identical Preview (`GFMRender`)** — renders through **cmark-gfm** (Apple's `swift-cmark`,
`gfm` branch, 5 GFM extensions) into HTML shown in a WKWebView styled with **github-markdown-css** +
**highlight.js** GitHub themes. Provably identical:
- `fullSpecConformance` runs the GFM spec's own `spec.txt` corpus: **648/648** (638 exact + 10 documented tagfilter / extended-autolink overrides GitHub also applies).
- `identicalToGitHubMarkdownAPI` asserts byte-identity to a captured `api.github.com/markdown` response (normalising only GitHub's display post-processing).

**Live-editor cmark styling** — the editor's own styling was moved onto the same cmark-gfm AST so it
matches the Preview: `GFMRenderer.nodes` exposes the AST with source positions; `GFMLiveStyle` maps
nodes → style runs; heading bottom borders, indented code blocks, and cmark inline styling **inside
lists and blockquotes** all landed. Conformance: **340/340** inline constructs across the corpus,
**711/722** block classifications agree with cmark.

**GitHub table/code theming** — the editor's code blocks use GitHub's highlight theme and its tables
match github-markdown-css exactly (zebra rows, `#d1d9e0`/`#3d444d` borders, `#f6f8fa`/`#151b23`
zebra, semibold header, aligned columns) — verified pixel-faithful in both appearances.

**Offscreen fidelity snapshot tests** (`HelloNotesTests/EditorFidelitySnapshotTests.swift`) render the
editor and its components offscreen (no Screen Recording permission needed) and assert editor↔Preview
parity — the table collapses to its rendered image and code keywords carry GitHub's exact palette
(`#d73a49` light / `#ff7b72` dark).

**Coverage:** full GFM (headings ATX+setext, bold/italic, strikethrough, inline/fenced code with
~190-language highlight, blockquotes, ordered/unordered lists, task lists, aligned tables, links/images,
extended autolinks, thematic breaks, footnotes, hard line breaks) plus HelloNotes/Obsidian extensions
(`[[wiki-links]]`, `![[embeds]]`, nested `#tags`, `==highlight==`, `%%comments%%`, callouts,
`$$…$$`/inline `$…$` math, Mermaid, hidden front matter). Not rendered natively (shown as text, as on
raw GitHub source): emoji shortcodes and raw HTML entities.

---

## 5. Notable fixes & gotchas (worth archiving)

- **O(document) → O(damage) is the whole rewrite's thesis.** The fork's per-keystroke and per-caret-move full-document re-tokenize/re-layout was the root freeze. Two precursor fixes attacked it even before the rewrite: stopping full-document scans on every body eval (per-caret-move lag), and dropping the in-RAM note-text corpus (~207 MB on the test vault).
- **GUI apps can't read `~/.gitconfig`.** Commits failed silently with no signature. Fix: write a commit identity into the repo's *local* config (`GitService.ensureCommitIdentity`), falling back to the macOS account name.
- **Byte fidelity by construction.** The wiki-link resolver reports existence only (empty `id`) so `[[Name]]` is never rewritten to `[[Name|id]]`; raw Markdown is the sole storage, so the editor never touches untouched bytes.
- **TextKit 2 rendering-attributes trap.** One-shot `setRenderingAttributes` silently vanish when a fragment re-lays out; the persistent channel is `NSTextLayoutManager.renderingAttributesValidator`.
- **Same-length substitution contract.** `NSTextContentStorageDelegate` paragraph substitution requires equal length to the backing range, so marker elision via substitution is out of contract — hence the same-length attribute-transform concealment.
- **`setAttributedString` import stall.** Pre-styling off-main and installing once causes ~100 ms stalls on first keystroke (NSTextStorage converts attribute runs lazily). Fix: batched native-path styling that settles as it walks.
- **`scrollRangeToVisible` is unreliable in TK2** against estimated heights — always `ensureLayout(for:)` the target range, then `enumerateTextSegments`. Same root cause behind the pre-fork "scroll-to-heading"/"outline jump"/"heading scroll" deferrals.
- **Concealed-font clobber.** `NSTextView.font` set *after* storage attach clobbered per-run concealed fonts, breaking `> [!type]` concealment — root-caused and fixed by ordering font-before-attach.
- **O(n²) byte→UTF-16 map.** The naive cmark source-position map rescanned from byte 0 per node (3 MB hung); fixed with per-line prefix arrays (O(document)).
- **cmark overlay scope regression.** A `    - x` list item parsed *in isolation* reads as indented code; fixed first by restricting the overlay to paragraphs/headings, then properly with a whole-document cached-runs overlay.
- **Concurrency posture.** `MarkdownCore` is nonisolated value types + `Sendable`; `MarkdownEditor` uses `defaultIsolation(MainActor.self)`. `OSSignposter`-gated perf tests fail CI on regression (1 MB parse < 50 ms, keystroke cycle < 5 ms). Production hardening added a FIFO-serialized `GitService` and atomic chat persistence.

---

## 6 · Production-release hardening

A pre-release pass that resolved the go/no-go items from the production audit (the
register in [unimplemented.md](unimplemented.md); items are removed there as they land here).

### Release & packaging (register §0)
- **Privacy manifest.** Added `HelloNotes/PrivacyInfo.xcprivacy` (auto-bundled via the synchronized file group): `NSPrivacyTracking = false`, no collected data types, and required-reason API declarations for **UserDefaults** (`CA92.1`), **file timestamp** (`C617.1`), and **disk space** (`E174.1`). Verified present in `Contents/Resources/` of the built bundle.
- **`.md` UTI association.** Added `UTImportedTypeDeclarations` to `Info.plist` — imports `net.daringfireball.markdown` conforming to `public.plain-text`, tagging `md`/`markdown`/`mdown`/`markdn` + `text/markdown`. (Imported, not exported, so it can't hijack the system default handler.) Fixes the latent bug where `.md` files wouldn't bind on a Mac where no other app declared the community UTI.
- **Optimized Release build.** Set `SWIFT_OPTIMIZATION_LEVEL = -O` on the app Release config (it was unset → `-Onone`); verified via `-showBuildSettings`.
- **Acknowledgements.** Added `UI/AcknowledgementsView.swift` (a Preferences tab) listing the bundled open-source packages and their licenses — libgit2 (GPL-2.0-with-linking-exception), swift-cmark, SwiftGitX, HighlighterSwift, SwiftMath, mermaid/elk, MLX/transformers, OpenAI, and the Apple/transitive libs.

### Data safety (register §1)
- **Flush-on-quit.** Added `UI/TerminationGuard.swift` — an `NSApplicationDelegate` that implements the `applicationShouldTerminate` → `.terminateLater` handshake, draining every window's registered `tabs.flushAll()` before the process exits. Wired via `@NSApplicationDelegateAdaptor`; `MacContentView` registers/unregisters its tabs. No more "lost the last ~600 ms of edits on ⌘Q".
- **Atomic assistant writes.** `EditNoteTool`/`WriteNoteTool` now write with `.atomic` (`CollectionTools.swift`), so a crash mid-write can't truncate a note.
- **Surfaced file-operation failures.** `Collection` gained a `lastError` (observable) set by every create/rename/duplicate/delete/new-folder/move failure path (previously silent `nil`/`try?`); `MacContentView` presents it as an alert (`FileOperationErrorAlert`). Rename now distinguishes "name already exists" from an OS error.
- **Rename link-rewrite reports partial failures.** `rewriteWikiLinks` collects the notes it couldn't rewrite and surfaces "links may now be broken in N notes (…)" instead of swallowing each write with `try?`.
- **Export errors surface.** `EditorExport` shows an alert on a nil render or a failed write (was `try?` + silent nil), and writes atomically.
- **Off-main reconcile.** `EditorModel.reconcileWithDisk` reads the changed file off the main actor so a large external change doesn't stall the UI.
- **No config-wipe on encode failure.** `LLMSettings.persist` and `GitCredentials.persist` only write when `JSONEncoder` succeeds (were `set(try? encode(...))`, which wrote `nil` and wiped saved providers/accounts on any failure).
- **Serialized git reads.** `GitService.refreshStatus`/`history`/`content` now run through the same FIFO chain as writes (`serializedRead`), so a status/history walk never opens a second libgit2 handle concurrently with an in-flight commit's index write.

### Security (register §2)
- **SSRF protection for the agent's web tools.** Added `LLM/Agent/WebGuard.swift`: `web_fetch`/`web_search` now reject non-http(s) URLs and any host that resolves (via `getaddrinfo`) to a loopback / private / link-local / unique-local / CGNAT address — covering `127.0.0.1`, `localhost`, `169.254.169.254` (cloud metadata), `10./172.16/12/192.168.`, IPv6 `::1`/`fc00::/7`/`fe80::/10`, and IPv4-mapped forms. A `RedirectGuard` `URLSessionTaskDelegate` re-validates every HTTP redirect so an allowed host can't bounce to an internal one. This closes the prompt-injection → internal-exfiltration path.
- **Scoped "Allow all".** `AssistantModel.clear()` now calls `PermissionBroker.reset()`, so a blanket "Allow all" grant no longer persists across conversations — injected content in a fresh thread can't drive `write_note`/`delete_note` without a new approval.
- **Bounded response buffers.** `web_search` now streams with the same 4 MB cap as `web_fetch` (through the guarded session), and the Anthropic/Gemini SSE error paths cap the accumulated error body at 16 KB (were unbounded).

### Performance & memory (register §3)
- **Debounced search-aggregate rebuild.** `CollectionSearchModel.updateNote` (called on every autosave) now patches `entryByURL` O(1) synchronously but debounces the O(collection) rebuild of tags / tag-tree / link-targets / quick-open items (250 ms), so a burst of edits coalesces into one rebuild instead of one per save — the largest remaining main-thread hotspot at the 2,000-note scale.
- **Bounded embed caches.** `CollectionEmbedProvider.cache` and `BlockRenderAdapter.cache` (both keyed by mtime, so previously monotonically growing) now cap at 64 entries — matching the editor's own image caches.
- **Bounded, off-main chat transcript.** `ChatSessionStore.save` encodes + writes off the main actor and caps the persisted JSONL at the most recent 1,000 messages, so a long-lived conversation with verbatim tool outputs can't grow the file (or block the main actor) without limit.

### Usability (register §4)
- **Print (⌘P).** Added `EditorExport.printNote` (renders the note's HTML through the native text system into `NSPrintOperation`, no WebView) and a `CommandGroup(replacing: .printItem)` wired to the current note — the standard menu item a notes app must have.
- **Folder-delete confirmation.** Deleting a folder (which trashes all its contents) now goes through a `confirmationDialog` (`FolderDeleteConfirmation`) instead of executing instantly.
- **"AI not configured" state.** `LLMSettings.isActiveProviderConfigured` (local providers need no key; cloud providers need a Keychain key); the Assistant's empty state now shows a "Set up AI" prompt with a `SettingsLink` when the active provider has no key, instead of inviting input that will only error.
- **File-operation errors are visible.** (Cross-ref §1: `Collection.lastError` alert; rename distinguishes "name taken"; export shows errors.)

### Accessibility (register §5)
- **Graph is VoiceOver-navigable.** The force-directed graph is drawn into a `Canvas` (previously an opaque rectangle to VoiceOver); it now exposes `.accessibilityChildren` — a labelled, activatable list of the notes (each with its link count), so a VoiceOver user can enumerate and open notes. (The Mind Map already renders its nodes as real `Text`/`Button` views, so it was already navigable — only its edges are a decorative Canvas.)
- **Git state isn't colour-only.** The outline's git dirty-state dot (orange vs grey) now carries a VoiceOver label ("Uncommitted changes" / "No uncommitted changes").

### iOS live editor — editor-M5 (register §6/§7)
The live TextKit 2 editor now runs on **iOS**, not just macOS — iOS is no longer plain-text-only.
- **Cross-platform port.** `BlockRendering`'s custom `NSTextLayoutFragment` chrome was rewritten from AppKit primitives (`NSGraphicsContext`/`NSBezierPath`/`NSImage`) to platform-neutral CoreGraphics via a new `PlatformDraw` helper (fills, ellipses, flipped image draw, SF-symbol→CGImage). `EditorLinkTap` and `renderMaxWidth`/`isDarkAppearance` were hoisted out of the AppKit guard. The macOS chrome (heading rules, list bullets, quote bars, callouts, checkboxes, table/code/math embeds) is **unchanged** — verified pixel-for-pixel by the existing macOS snapshot test.
- **iOS view.** New `MarkdownUITextView` (a `UITextView(usingTextLayoutManager:)` bound to the shared `EditorDocument`'s storage, fragment delegate, selection→reveal, tap-to-navigate links) + a `MarkdownEditorView` `UIViewRepresentable` with the same public surface (`init`/`editable`/`onLinkTap`) as the macOS one.
- **iOS shell.** `HelloNotes/UI/iOSLiveEditor.swift` hosts it (builds the document, syncs edits back for autosave, rebuilds on note/font/appearance change); the iOS view-mode picker gains an **Edit** mode (default) alongside Preview/Markdown/Split.
- **Fragment chrome via overlay.** `UITextView` — unlike `NSTextView` — doesn't invoke a custom `NSTextLayoutFragment.draw`, so the block chrome (unordered-list bullet glyphs, callout tint band/bar/icon, blockquote gutter bar, task checkboxes, heading bottom-rule) wouldn't paint. A transparent `ChromeOverlayView` subview enumerates the laid-out `RenderedBlockFragment`s and calls a chrome-only draw entry point (`drawChromeOnly(at:in:)` — the same callout/checkbox/bullet/rule/inline-image passes as macOS, minus `super.draw`/block image since `UITextView` draws the text). Refreshed on layout / edit / selection change. `blockLayoutDelegate` + `chromeOverlay` are `lazy`: `init(usingTextLayoutManager:)` is an inherited convenience initializer that skips the subclass's stored-property synthesis, so plain defaults were left null (a weak-assign into the null overlay faulted `EXC_BAD_ACCESS` at 0x8).
- **Verified on the simulator** (`iOSEditorSnapshotTests`, captured via `layer.render` — `drawHierarchy` re-enters TextKit during the render pass): live inline styling (bold, italic, inline-code with background, strikethrough, coloured links), caret-driven **concealment** of markers, heading sizes + bottom rules, dimmed blockquotes with gutter bars, callout tint band/bar/icon with coloured title/body, filled/hollow list bullets, coloured ordered-list numbers, and empty/checked task checkboxes all render correctly on iOS — matching the macOS chrome.
- **Remaining iOS gap (documented in [unimplemented.md §6](unimplemented.md)):** app-side services — code-syntax colours and block embeds (table/math/mermaid/transclusion images) — aren't wired on iOS yet (the renderers are AppKit `NSImage`/`lockFocus`).

---

## 7 · Post-review fix pass (2026-07-19)

A full-codebase review (cross-platform editor-services port, TextKit 2 editor,
concurrency/isolation, LLM-agent security, entitlements) produced the fixes below. All
landed together; **macOS + iOS builds are green, the 83-test editor package suite and the
app unit tests pass.** Items are struck from [unimplemented.md](unimplemented.md) as they
land here; what the pass deliberately left open stays in that register (see the end).

### Security (agent / networking / secrets)
- **`create_note` path traversal (the one blocker).** The `folder` argument was passed
  straight into `appendingPathComponent` (which does not resolve `..`), so an injected
  tool-call — `create_note(folder: "../../../Library/LaunchAgents", …)` — could write a
  `.md` file outside the collection root. Now the resolved target is containment-checked
  (`standardizedFileURL` must carry the root prefix) **before any write, independently of
  the permission broker**, so it holds even under "Allow all" (`CollectionTools.swift`).
- **"Allow all" no longer auto-approves deletions.** `PermissionBroker.confirm` still
  auto-approves ordinary edits under a blanket grant but always requires an explicit click
  for a deletion (`diff.isDeletion`) — the highest-consequence mutation, and the one most
  worth gating against injected tool-calls.
- **Write-tool symlink containment.** `edit_note`/`write_note` reject a note whose file
  resolves (via `resolvingSymlinksInPath`) outside the collection root (`ToolContext.isWithinRoot`),
  defending against a pre-planted symlink the directory enumerator would otherwise follow.
- **NAT64 in the SSRF classifier.** `WebGuard` now classifies the `64:ff9b::/96`
  well-known prefix (embedded IPv4), alongside the existing loopback/private/link-local/
  ULA/IPv4-mapped/CGNAT coverage.
- **Keychain secrets are `…WhenUnlockedThisDeviceOnly`.** Both BYO API keys
  (`LLMKeychain`) and the Git PAT (`GitCredentials`) moved off `…WhenUnlocked`, so they're
  excluded from encrypted device backups / can't restore onto another device.
- **Git errors are credential-scrubbed.** libgit2 error strings echo the remote URL, which
  for HTTPS auth carries the PAT; `GitService.scrubCredentials` strips any `user:token@`
  before the string reaches `lastError` (push/create/clone), matching the existing
  sanitisation on the status/display path.

### Concurrency / isolation
- **Mermaid block render off the main actor.** `BlockRenderAdapter.renderMermaid` was the
  only block renderer that didn't hop to the main actor, yet on macOS it ran `NSImage.lockFocus`
  (the upright flip) on the actor's background executor — unsafe AppKit drawing. It now
  `await MainActor.run`s like its sibling renderers.
- **Serialized editor writes.** `EditorModel.save` chained a new write behind any in-flight
  one (a `writeInFlight` task), so two atomic writes can't race at the filesystem — closing
  the stale-text-on-quit window where an older debounced write could land after the flush.
- **`GitService` queue hygiene.** `createRepository`/`cloneRepository` route through the
  FIFO queue (a value-returning `runReturning`) instead of setting `isBusy` directly, so a
  bypass op can no longer clear the busy flag (or clobber `lastError`) mid-way through a
  user push; `authenticateRemote` reads the remote URL through the serialized read queue
  (off-main) instead of opening the repo synchronously on the main actor.
- **`FileWatcher` teardown.** The FSEvents callback ran on a shared queue with an unretained
  `self`; `stop()` now uses a dedicated serial queue and drains it (`queue.sync {}`) after
  `invalidate`, so a callback already dispatched can't run `onChange` after the object is
  freed.
- **macOS editor observer leak.** The `boundsDidChangeNotification` observer registered per
  editor was never removed; its token is now stored and removed in `deinit`.

### Cross-platform / editor
- **iOS storage stays byte-pure Markdown.** `MarkdownUITextView` overrides `paste` to insert
  plain text only (never a rich-text attachment) and disables autocorrect/autocapitalization,
  matching the macOS view — so neither a paste nor a substitution can inject foreign
  attributes into the shared `EditorDocument` storage.
- **iOS chrome overlay is O(visible), not O(document).** `ChromeOverlayView` clips its
  fragment walk to the dirty rect and `refreshChrome` invalidates only the visible slice,
  instead of repainting the whole document on every keystroke/selection change.
- **iOS large-note open doesn't block.** `makeUIView` only styles the whole document up
  front for notes ≤ 200 KB; larger notes rely on the document's synchronous prefix + idle
  background pass, and `ensureVisibleRangeStyled` now invalidates layout for the styled span
  (mirroring macOS) so first-seen concealed markers lay out at their true width.
- **macOS copy is plain-text only.** The rich-text view's default ⌘C also wrote an RTF flavor
  carrying the concealed 0.1 pt / clear-colour marker runs (invisible, un-round-trippable in
  Mail/Pages); `copy`/`cut` are overridden to put only the Markdown source on the pasteboard.
- **Checkbox toggle keeps the box rendered.** Toggling a task checkbox restored the caret to
  the block's `[`, which revealed the block back to raw `- [x]`. It now restores the
  pre-click selection (the toggle is a 1-for-1 char swap, so offsets are unchanged).
- **Wide tables render un-clipped.** `TableImageRenderer` renders the grid at its natural
  width and scales the whole bitmap to fit, instead of shrinking column widths but not the
  font (which clipped cells and mis-positioned right/centre-aligned text).
- **visionOS renders the app.** The `WindowGroup` body was `#if os(macOS) … #elseif os(iOS)`,
  so a visionOS build (a configured platform) fell through to `EmptyView`. It now falls back
  to the iOS content view for any non-macOS platform. *(visionOS compile unverified locally —
  the visionOS SDK isn't installed on this machine.)*

### Tidy-ups
- Removed the dead `revision` counter in `CollectionEmbedProvider` (written, never read; the
  cache is mtime-keyed) and documented its `@unchecked Sendable`; the code-highlight cache
  keys on the full snippet (not `hashValue`) so two snippets can't collide; corrected the
  stale "iOS is plain-text-only / block embeds are wired on iOS" comments.

### Deliberately left open (in [unimplemented.md](unimplemented.md), not patched)
- **SSRF DNS-rebinding (§2).** `WebGuard.validate` resolves + classifies the host, but
  `URLSession` re-resolves independently for the connection, so the check isn't pinned to the
  fetched IP — an attacker controlling DNS with a short TTL can pass validation then connect
  to an internal address. A correct fix needs socket-level pinning (custom `URLProtocol` /
  Network.framework); a `URLSession` metrics check fires too late for the streamed body to be
  reliable, so no fragile partial mitigation was shipped.
- **Git PAT in `.git/config` (§2)** remains upstream-blocked on a SwiftGitX credential
  callback; **iOS block-embed / inline-math consumption (§6)** still needs the collapse +
  fragment-image path ported to the iOS overlay (the renderers and adapter are now
  cross-platform and wired, but `EditorDocument` only consumes them under `#if canImport(AppKit)`).

---

## 9 · Whole-codebase review — fix passes (2026-07-19)

Two max-effort reviews (10 finder angles each) swept the recently-landed changeset and
then the **entire codebase**. Fixes below are all landed and verified (macOS + iOS builds
green; package 83/83; app AgentTool/SmartPaste/SkillStore + EditorFidelity + iOS-editor
snapshot suites pass). Ranked roughly by severity.

### Crashes
- **VisionAlt** could resume its `CheckedContinuation` twice (Vision's completion handler
  *and* a thrown `perform`) — funneled through a lock-guarded `OnceResumer`.
- **PropertiesEditor** list-property bindings crashed on removing a non-last item
  (stale enumerated index) — bounds-guarded; "Add item" now persists (`onChange`).
- **GraphView** click hit-test indexed `nodes`/`degrees` by stale `positions` during an
  off-main relayout — added the count guard the draw path already had.
- **EditorDocument.blockEmbedKind** read `character(at:)`/`substring(with:)` without the
  `<= storage.length` guard its siblings use — added it.

### Data loss / corruption / integrity
- **MentionScanner** only checked for a preceding `[[`, so "Link mention" nested a link
  inside an existing one (`[[My Note]]` → `[[My [[Note]]]]`) — now detects an open `[[`.
- **NoteWindowView** (standalone note window) never registered a termination flush hook,
  losing the last edit on ⌘Q — registered with `TerminationGuard`.
- **NoteHistoryView** applied an out-of-order git preview, letting "Restore" write the
  wrong revision — guarded on the current selection.
- **Collection.noteDidSave** incremental branch didn't cancel an in-flight rebuild, which
  could revert a just-saved index update — cancels `deriveTask`.
- **Bookmarks** survived rename/move (paths updated); **rename/move wiki-rewrites** now
  register as self-writes (no spurious external-change reconcile); **case-only rename**
  ("todo"→"Todo") no longer blocked with a spurious "already exists".

### Correctness
- **GFMTree** depth counter drove negative on empty containers (blank table cells, empty
  list items), mis-styling nesting — made the EXIT decrement symmetric with the increment.
- **EditorDocument.replaceText** applied the old document's cached GFM inline runs to the
  new storage on external reload — resets the cache before styling.
- `[[#heading]]` produced a spurious graph link; **GitHubMarkdown** rewrote wiki-links
  inside inline code spans; **IntelligenceService.matchTitles** trimmed digits from both
  ends (dropping "2026 Goals"); FrontMatter kept empty list items; DocumentStatistics
  mis-counted CRLF paragraphs; FuzzyMatch awarded a spurious first-char run bonus; the
  sibling-collection path-prefix false-match (Notes vs NotesArchive) at 4 sites.

### LLM / agent
- **OpenAI-compatible** token usage was dropped (early-return before the trailing
  usage-only chunk) — reads to stream end. **AssistantModel/AgentRunner**: a turn that
  hit the tool-iteration cap left a blank answer — a final tool-less turn now summarizes;
  a cancelled turn no longer leaves an empty persisted bubble; `clear()` no longer lets a
  cancelled turn resurrect the cleared transcript. **ChatSessionStore** writes are
  serialized. **DeepResearch** surfaces sub-agent failures (instead of laundering them
  into a confident empty answer) and aborts promptly on cancellation.
  **FoundationModels** no longer advertises tool support it can't honor (agent mode falls
  back to chat), and its streaming diff handles snapshot revisions (common-prefix, not
  append-only). **MLX** shares one in-flight model load instead of racing two multi-GB
  downloads. **EditorTabs** dedups concurrent opens of the same note (no duplicate tabs).

### UI / perf
- **CloneRepositoryView**: account-switch race (stale repo list) and a leaked
  security-scoped resource on clone failure. **SplashScreen** "About" no longer
  auto-dismisses if opened during the launch splash. **RewriteSelectionView** force-unwrap
  → guard. **OutlineView** computed stats/headings once (was 4×/2× per render);
  **MermaidPreview** renders each diagram once into `@State`; **MindMapView** memoizes its
  O(N²) layout; the document-stats debounce now covers zero-word notes.

### Deliberately left open (reported, not blindly patched)
- **BlockParser incremental convergence** only fires at `open == .none`, so editing long
  *prose* re-parses to EOF (O(document)/keystroke). Real perf regression, but the fix is
  deep in correctness-critical convergence logic — needs its own change + fuzz
  re-verification, not a `--fix` edit. (Related: blank-run merge dead branch; CRLF in the
  block classifiers — same risk profile.)
- **One-account-per-host** Git credential model is by design (`account(forHost:)` must
  resolve a single account for auth), so the "collision" is not a bug.
- **Bookmark `isStale`**: the primary stores (`Library`/`LibrariesStore`) already re-mint
  bookmark data on every persist, so stale bookmarks self-heal there.

## 10 · Human Interface Guidelines usability pass (2026-07-20)

A full review against Apple's HIG, then the fixes applied (both platforms build clean).

### Keyboard shortcuts & menus
- **Shortcut collisions resolved**: the global hotkey moved to **⌃⌥⌘N** (was ⌥⌘N, which
  shadowed File▸New Window). Duplicate is now **⌘D**, Bookmark **⇧⌘D**, Move to Trash
  **⌘⌫**, Dictate to Daily Note **⌃⌘D**. Editor **Find** is a real Edit-menu command
  (**⌘F**) posting `.hnEditorToggleFind` (which also switches to Edit mode first), instead
  of a shortcut buried on a toolbar button that did nothing when the toolbar was hidden.
- **Ellipsis conventions**: "Dictate…" → "Dictate to Daily Note" (it starts immediately,
  no follow-up dialog). Note-action ordering regrouped by relatedness.

### Navigation & windows
- Main window gets a sensible **`.defaultSize`** (1100×720). Single-note windows expose a
  **`.navigationDocument(fileURL)`** proxy icon (drag/right-click the title to reveal the
  file), matching document-app expectations.

### Feedback & error surfacing
- **Silent save failures** now raise a persistent, readable **save-error banner** in the
  editor (selectable error text + Retry), replacing a hover-only status glyph. A banner,
  not a modal — a failing autosave retries on its own, so an alert would spam.
- **Git errors** (sidebar status + Clone sheet) are now **selectable, copyable**, and show
  up to 4 lines with the full text on hover, instead of a 2-line truncation you couldn't
  read or copy.
- **Empty-collection state**: when the open library has no notes, the note list shows a
  "No Notes" `ContentUnavailableView` with a **New Note** action instead of a blank pane.
- **Cancelable clone**: a clone can run for minutes, so the Clone sheet now shows a **Stop**
  button while busy. `GitService.cloneRepository` runs on a retained cancellable handle and
  forwards cancellation into the detached libgit2 clone (`withTaskCancellationHandler` →
  `inner.cancel()`); SwiftGitX's transfer-progress callback then aborts the fetch and the op
  reports "Clone cancelled." and cleans up the partial checkout. Scoped to clone (the
  dominant long op); push/fetch stay on the shared short-lived runner.

### Accessibility
- **VoiceOver Headings rotor on iOS** (`UIAccessibilityCustomRotor(systemType: .heading)`
  in `MarkdownUITextView`), mirroring the existing macOS rotor — long notes are navigable
  by heading.
- **Reduce Motion**: the splash-screen animation pauses (`TimelineView(.animation(paused:))`)
  when the system setting is on.
- **Labels added**: slide-deck chevrons / position ("Slide X of Y"), Properties toggles &
  fields, iOS accent swatches. Hover-only affordances gained accessible equivalents.

### Controls & terminology
- **Sentence-case section headers** across Settings ("Accent color", "Text size", "Daily
  notes"). "PROPERTIES" → "Properties".
- Clearer labels: **"Replace All"** (was "All"), **"Reset"** (was "Reset to Default"),
  sheet **"Close"** (was "Done" where nothing was being confirmed). **"Temperature"** →
  **"Creativity"** with a plain-language caption; the daily-note date-format field gained a
  worked-example caption ("Today would be …").
- **iOS custom accent color**: added the `ColorPicker` the macOS Appearance tab already had,
  so iOS is no longer limited to the ten preset swatches.

### Native sidebar styling
- **macOS sidebar** was a hand-built `VStack` of buttons; restructured into a `List(.sidebar)`
  — collection actions, **Bookmarks**, and **Tags** as proper `Section`s with native headers —
  keeping the prominent **Open…** action and the **Git** panel as chrome above/below the list.
  Verified live: renders as a native source list, action rows work (created + trashed a scratch
  note to confirm).
- **iOS sidebar** now uses `.listStyle(.sidebar)` for the standard inset/grouped source-list
  look. Verified on the iPad simulator — the **Collections** section header and inset rows show
  the native sidebar treatment.

### First-run onboarding
- **`WelcomeView`** — a one-time welcome sheet shared verbatim by macOS and iOS. A brand-new
  install (empty library, nothing to restore) now meets a branded sheet — wordmark, tagline,
  four capability highlights (local files, GitHub-identical preview, links/graph, on-device
  intelligence) and a primary **Open a Collection** action — instead of a bare launcher or
  blank pane. Gated by `@AppStorage("hasSeenWelcome")`; afterwards an empty launch falls back
  to the launcher. macOS presents it as a sheet on first empty launch; iOS queues it during
  launch and presents it only after the splash overlay fades. Verified live on a cold launch.

### Consciously not changed
- **Note deletion stays immediate** (no confirmation): a delete is a recoverable move to
  Trash, matching Apple Notes. Folder deletion keeps its confirmation because it bulk-trashes
  many notes — the asymmetry is intentional, not an inconsistency to "fix."
- **Editor Dynamic Type**: the note editor deliberately uses its own text-scale control
  (Appearance ▸ Text size) rather than system Dynamic Type — the iOS settings footer says so
  explicitly, and honoring both at once would fight the TextKit chrome layout. Left by design.

## 11 · Cloud-native storage (2026-07-20/21)

Full plan, provider matrix and rationale: [cloud-native-roadmap.md](cloud-native-roadmap.md).
Two independent paths shipped — the OS File Provider layer (Phases 0–3, covers all five
providers with no credentials) and direct provider APIs (Phase 4, for "no client installed").

### Phase 0 — Coordinated I/O *(the load-bearing fix)*
The app used `NSFileCoordinator` **nowhere**: every read was `String(contentsOf:)`, every
write `.write(to:.atomic)`. On a File-Provider volume an *online-only* file read that way can
fail outright with `EDEADLK`, so cloud folders were effectively unusable — including iCloud.
- New `Core/FileIO.swift`: coordinated `readData`/`readString`, `write` (atomic replace),
  `create` (no-overwrite). Coordinated reads materialise on demand; a no-op for local files.
- Migrated **every vault read/write** (editor open/save/reconcile, collection index, create,
  rename-link rewrite, daily notes, append, search + link-graph indexing, mentions, template
  insert, agent tools, image paste, export). App-private files (index cache, chat transcripts,
  widget snapshot) intentionally keep direct writes.
- Hardening: `writeWidgetSnapshot()`'s write moved off the main actor — a synchronous
  main-thread write hangs the whole UI when a volume stalls (observed in practice).
- **Verified live on a real iCloud/File-Provider vault** (2,019 notes): open, read, create,
  autosave (bytes confirmed on disk), index/backlinks — no hangs, no `EDEADLK`.

### Phase 1 — Dataless-aware indexing *(don't download the vault)*
The eager indexers read *every* note body, which on a cloud vault would materialise the whole
thing on first open — the opposite of on-demand.
- `FileIO.isMaterialized(at:)` — true for local + already-downloaded files, false only for
  explicitly `.notDownloaded` items; conservative (true) on unknown status. Cheap metadata.
- `Collection.refreshDerived` (the main offender), `CollectionSearchModel.refresh`, content
  search, and `LinkGraph.rebuild` now **skip online-only notes**; they still list (title from
  filename) and are indexed once opened/downloaded. Full-text search likewise never silently
  downloads — title/tag/alias search still covers everything.

### Phase 2 — Online-only state in the UI
`Note.isOnlineOnly` (captured free during the scan), a cloud badge on macOS/iOS rows, a
status-bar "N online-only" indicator, per-note **Download / Remove Download**,
`CloudProvider.name(for:)` labelling a collection with its provider, a "Downloading from the
cloud…" banner while a note materialises, and cloud-aware onboarding copy.

### Phase 3 — Git-on-cloud guardrails
libgit2 reads the whole object store, so online-only objects thrash it. A cloud-backed
collection now shows a caution in the Git panel and **auto-commit is disabled** (both in the
UI and at the trigger, so a pre-existing enabled flag can't fire). Manual Git stays available.

### Phase 4 — Direct provider APIs *(four providers, no vendor SDKs)*
A ~60-line `RemoteStore` protocol + `URLSession` adapters — SwiftyDropbox/Box SDK/Google
SDK/MSAL all rejected as large dependencies for what typed requests already do (§5.10 of
architecture.md has the per-provider divergence table).
- **Dropbox** (PKCE, path-based), **Box** (client secret, ID-based, single-use refresh
  tokens), **Google Drive** (PKCE with redirect derived from the client id, ID-based,
  string sizes, skips native Docs), **OneDrive** (PKCE on the `common` authority — one
  registration serves **personal *and* business** — path-based).
- Shared: Keychain tokens, single-flight `RefreshCoordinator`, pagination on every provider.
- **`RemoteMirror` promotes an account to a first-class sidebar collection**: mirrors into a
  local cache opened as a normal `Collection` (scan/index/backlinks/editor unchanged), uploads
  on save, propagates deletes, and reconciles on sync (prunes remotely-deleted notes; won't
  overwrite a local file newer than the remote copy).
- Entry points: macOS **File ▸ Connect Dropbox/Box/Google Drive/OneDrive…** (each with
  *Open as Collection*), iOS **Settings ▸ Cloud (direct API)**.
- **Verified against each real service**: Dropbox proven fully end-to-end (real sign-in →
  real token → real `list_folder` of the account's root); Box/Drive/OneDrive verified at the
  authorize endpoint with the real client ids plus request-shape probes returning clean
  auth-only 401s. Interactive sign-in needs a signed build (`ASWebAuthenticationSession`).

### Credentials
Provider keys moved out of the repo into a **git-ignored `Config/Secrets.xcconfig`**,
substituted into Info.plist at build time via `baseConfigurationReference`; a committed
`Secrets.example.xcconfig` documents each provider's console setup. Before the first push,
the previously-committed values were **purged from git history** (the commits were still
unpushed, so no force-push was needed and nothing ever reached GitHub).

## 12 · Cloud review fix pass (2026-07-25)

Ten findings from a full-diff review, all verified against the source before fixing:
- **Deletes now propagate** to the provider — a delete only trashed the local mirror, so the
  next sync resurrected the note.
- **`syncDown` reconciles** — prunes remotely-deleted notes and emptied folders, and skips
  overwriting a local file newer than the remote copy (which could discard a pending edit).
- **Pagination on all four providers** (Dropbox cursor, Box offset compared against the *raw*
  entry count, Drive `nextPageToken` — also added to `fields` — OneDrive `@odata.nextLink`).
  Previously a folder past ~1000 entries silently lost its tail, and for the ID-based
  providers those notes then 404'd.
- **Binary-file corruption fixed** — the browser decoded with the *lossy* `String(decoding:)`,
  so opening a PDF and saving uploaded mojibake over the original; it now decodes strictly
  and refuses non-UTF-8.
- **Single-flight token refresh** (`RefreshCoordinator`) for the rotating-token providers.
- **Box multipart filenames** RFC 7578-escaped (a quote in a note name produced a 400).
- **Cancelled clone can't report success** (Stop landing after libgit2 finished opened the
  repo anyway). **`CloudPrefs`** `@objc` handlers hop to the main actor (they ran on the
  poster's background thread, defeating the reentrancy guard). **Spotlight** donations retract
  stale ids on rename/delete. **Small widget** rows get a working deep link via `widgetURL`.
- +5 tests (all four pagination cursors, mirror prune). 63 unit tests pass; both platforms build.

## 13 · Release-only optimizer crash — found while packaging the DMG (2026-07-25)

**Every Release build was broken and nothing caught it.** Packaging a signed DMG
failed at the archive step: `swift-frontend` **segfaulted** with no `error:` line, so
no archive — and therefore no DMG or App Store build — could be produced at all. Debug
built perfectly, which is exactly why it survived ~6,400 lines of work: every
verification build in the session (including the review fix-pass) had been Debug.

**Diagnosis.** The `.ips` crash reports named the pass but not the function; the useful
line was buried in the full `xcodebuild` output (a filtered tail hid it):

```
While running pass "EarlyPerfInliner" on SILFunction
"$s10HelloNotes11OnceResumer…CfD"        → OnceResumer<A>.__deallocating_deinit
```

The SIL performance inliner walked a **null generic signature** in
`isCallerAndCalleeLayoutConstraintsCompatible` while inlining the compiler-generated
`deinit` of the *generic* class `OnceResumer<T>` (`Core/VisionAlt.swift`). A toolchain
bug — but one our code triggers: Xcode 26.6 / Swift 6.3.3 was installed 2026-06-27,
i.e. unchanged since the last good universal build (2026-07-12), so the trigger came in
with our own code, not a compiler update.

**Fix** — remove the generics, which bought nothing here:
- `OnceResumer<T>` → **non-generic** over `CheckedContinuation<String?, Never>`. Both
  callers already funnel to `String?`, so `classify()` now joins its own labels (which
  also simplified `describe()`).
- `perform<T>(… once: OnceResumer<T>, empty: T)` → non-generic `perform(… onFailure:)`,
  each caller closing over its own resumer — a second instance of the same
  caller/callee generic-layout shape.
- Both carry comments explaining the constraint so they aren't "tidied" back later.

**What did *not* work** (recorded so it isn't retried): `-Osize`, non-whole-module
compilation (`SWIFT_COMPILATION_MODE=singlefile`), and dropping `AnyObject` from
`RemoteStore`. Only removing the generic fixed it. Per-file bisection *was* useful:
`SWIFT_COMPILATION_MODE=singlefile SWIFT_ENABLE_BATCH_MODE=NO` narrows a whole-module
crash to one file.

**Verified:** Release arm64 ✓, Release universal (arm64 + x86_64) ✓, Debug ✓ — then a
full archive → Developer ID export → notarize → staple → `scripts/package-dmg.sh`,
producing a `dist/HelloNotes.dmg` that `spctl` assesses as *accepted / Notarized
Developer ID*, universal, with all three extensions embedded.

**Process change:** [production.md §1h](production.md) now spells out that Debug proves
nothing about Release, with the `While running pass` debugging recipe; the README build
section says the same. Appendix A2 there documents the whole Developer ID → DMG path.

---

## 14 · The product site — Astro rebuild and expansion (2026-07-25)

The public site was a hand-written three-page static site (`site/`), deployed from a
committed **`gh-pages` branch**. It is now an **Astro 7 + Tailwind 4** project in
[`website/`](../website/), built from source by a GitHub Actions workflow, and expanded
to the sixteen pages an App Store submission is expected to have. Full detail — site
map, deploy, the URL traps — is in [website.md](website.md).

### Two silent-failure traps, both hit live

Neither shows up at build time; the build succeeds and only the deployed site is wrong.

1. **`base`.** This is a project page under `/hellonotes`, so every internal link must
   go through `href()` in `src/lib/paths.ts`. A bare `href="/privacy"` resolves to
   `hellotham.com/privacy` — someone else's page.
2. **`site`.** Canonical and OG URLs were emitted on `hellotham.github.io`, which merely
   *301s* to the custom domain. A canonical must name the final URL.

### The legacy `.html` URLs — and the redirect loop

`privacy.html` and `support.html` are registered with **App Store Connect**, so they
have to keep resolving. Two approaches were tried and both failed:

- Astro's `redirects` config honours `build.format`; under the default `'directory'`, a
  key of `/privacy.html` emits a `privacy.html/` **directory** — so `/privacy.html`
  still 404s.
- Hand-written redirect files in `public/` are worse. GitHub Pages resolves
  `<path>.html` **before** `<path>/index.html`, so `public/privacy.html` *shadowed* the
  real `/privacy` route and redirected to itself. **This shipped and broke both
  document pages live.**

The fix is `build: { format: 'file' }`: one artefact, `dist/privacy.html`, answers
`/privacy` and `/privacy.html` alike, with no redirects at all.

### The expansion

Sixteen pages: landing, feature tour, screenshot gallery, download, an **eight-section
user manual**, and about / privacy / support. `src/lib/site.ts` is the single source of
truth for app metadata, the publisher (**Hello Tham**), the download artefact and both
navigation structures — the manual's ordering, prev/next links and index cards are all
derived from one array. Screenshots moved into `src/assets/` so `astro:assets` can
process them: 3.1 MB PNGs become 10–84 KB WebP with intrinsic dimensions.

The **disk image is not in the repo.** The download button points at
`releases/latest/download/HelloNotes.dmg`; at ~35 MB, committing it would sit in git
history forever and be re-uploaded in every Pages artefact. Publishing a build is
therefore `gh release create`, and the version/size/SHA-256 the download page prints
must be updated in `site.ts` to match.

### Caught in review

- **Two invented keyboard shortcuts.** A first draft of `manual/shortcuts.astro`
  documented `⌃⌘S` and `⌘T`; neither exists. The page was rebuilt from the
  `.keyboardShortcut(…)` modifiers in `AppCommands.swift`. Documenting a UI from memory
  produces confident, plausible, wrong output — grep first.
- **The nav clipped its own links on a phone** (`Manual`, `Download`, `Support` ran off
  a 375 pt viewport with no affordance). Inline links are now `md:` and up; below that a
  JavaScript-free `<details>` disclosure menu.
- **Headings inherited `body { line-height: 1.6 }`**, which looks broken once a heading
  wraps. Base rule: `1.15` plus `text-wrap: balance`.

---

## 15 · Light/dark screenshots, and the SEO the site was missing (2026-07-26)

### The OG image was 404ing on every page

`Layout.astro` defaulted `ogImage` to `assets/shot_02.png`. That file had been
moved from `public/` into `src/assets/` in §14 so `astro:assets` could optimise
it — which meant the URL stopped existing. The build stayed green, every page
kept emitting the tag, and **every link unfurl was broken** until someone
actually fetched it.

The rule now written into the code and [website.md](website.md): **`og:image`
must be a file in `public/`**, never one processed by `astro:assets`. Asset
filenames are content-hashed, so they change on every re-export, and social
crawlers cache by URL.

The replacement is a real 1200×630 card — brand gradient, app icon, name,
tagline — generated by the same script that builds the screenshots.

### Light and dark screenshots

Five scenes, each shot twice from the same SampleVault with the same window
geometry and the same note, so only the app's Appearance differs.
[`src/lib/screens.ts`](../website/src/lib/screens.ts) is the registry and pages
reference scenes by id, so re-shooting never means editing a page.

- `screenshots.astro` gets an explicit **Light / Dark switch** — two radio inputs
  styled as a segmented control, driving the figures through `:has()`. No
  JavaScript, and it defaults to the reader's own system setting.
- `index.astro` / `features.astro` use a new `Shot.astro`, a `<picture>` that
  follows `prefers-color-scheme` silently. `<Image>` can't do art direction, so
  `Shot` builds the srcsets with `getImage()` and writes the element by hand.

Replacing the old `screen_*`/`shot_*` pairs with ten composited frames also cut
the committed image sources from **21 MB to 4.3 MB**.

**Capture notes** (all three cost a re-shoot):

- **The first pass captured the author's real 2,019-note vault**, personal folder
  names legible in the sidebar. Marketing screenshots use SampleVault, with every
  other collection closed. The app's whole preferences container was backed up
  first and restored afterwards, so the session left no trace.
- The Claude Code window **floats above everything**, so a region `screencapture`
  catches it regardless of which app is frontmost. Hide it for the duration.
- **Synthetic `click at` events do not register in this SwiftUI app**, though
  AppleScript `set position`/`set size` work fine.

### The sitemap advertised a redirecting URL

`@astrojs/sitemap` hands `serialize` a correct `…/hellonotes/` and then the
underlying `sitemap` package strips the trailing slash — and `…/hellonotes`
**301s** to `…/hellonotes/`. That is the same error as pointing `rel=canonical`
at a redirect, so the integration was dropped for a 30-line endpoint that applies
exactly the rule `Layout.astro` uses. All 16 sitemap URLs now equal their page's
canonical, checked at build.

Also added: `robots.txt`, `og:site_name` / `og:locale` / `og:image:width|height|alt`,
explicit `twitter:title|description|image`, `theme-color`, `apple-touch-icon`,
`author`, `robots`, and JSON-LD `SoftwareApplication` (with `offers` at price 0 —
omitting it reads as "price unknown" rather than "free") on the home and download
pages.

---

## 16 · Auto / light / dark themes for the website (2026-07-26)

The site was dark-only. It now follows the reader's system appearance and can be
pinned to Light or Dark from a control in the nav. Full detail — the palette
mechanism, the pre-paint script, the contrast table — is in
[website.md § Theming](website.md#theming).

### How it works

**`light-dark()` carries the palette.** Each token is declared once as
`light-dark(<light>, <dark>)` and resolves against `color-scheme`, so switching
appearance is one declaration rather than a duplicated palette — and
`color-scheme` fixes form controls, scrollbars and the canvas for free. The
`@theme` block keeps the dark values as plain hex, so a browser without
`light-dark()` skips the `@supports` block and gets the site's original dark
appearance rather than a broken one.

**Nothing outside `global.css` holds a colour.** Introducing semantic tokens
(`body`, `edge`, `chip`, `emphasis`, `shadow-plate|card|cta|menu`) replaced 38
`hover:text-white`, 10 `bg-white/5`, 9 `text-[#d7d3e6]`, 5 `border-[#4a4360]`
and 11 hard-coded shadows. `text-white` now survives **only** on
`.brand-gradient` buttons, where white is right in both appearances.

**The choice is applied before first paint** by an `is:inline` script in
`<head>`. "Auto" is the *absence* of a stored value, not a third value, so a
reader who never touches the control keeps following their system.

### Traps hit

- **`light-dark()` takes colours, not values.** Wrapping a whole
  `linear-gradient(...)` in it makes the declaration invalid, which silently
  turned the hero's gradient-filled text transparent — it rendered as nothing at
  all. It has to go on each *stop*.
- **The light gradient needs deeper stops.** The button gradient's amber end
  (`#f59e0b`) is 2.1:1 on a white page, under the 3:1 large-text floor. Light
  uses `#6d28d9 → #db2777 → #b45309`, worst stop 4.4:1.
- **`<picture>` cannot follow a pinned theme.** A `prefers-color-scheme` source
  only ever sees the *system* setting, so pinning light on a dark Mac left dark
  screenshots on a light page. `Shot.astro` now emits both and lets the same CSS
  that drives the palette reveal one.
- **A stale `s.image` reference** survived the earlier rename to `s.screen`, so
  the features page had silently collapsed to one column — the layout tested a
  field that no longer existed, and `undefined` is falsy rather than an error.

### Two pre-existing bugs found while testing

Both were mine, from §14, and both are invisible on a desktop:

- **The download and manual pages scrolled horizontally on a phone** (690px of
  content in a 375px viewport). A grid item's `min-width: auto` refuses to shrink
  below its content's min-content width, and a `<pre>` never wraps — so
  `overflow-x-auto` on the code block did nothing. Fixed with `min-w-0` on the
  content column, plus `overflow-wrap: anywhere` on inline `<code>` for long
  container paths. All 16 pages now fit 375px.
- **28 missing spaces before inline tags**, including the footer's "published
  byHello Tham" on every page. Astro applies JSX whitespace rules to any element
  containing an expression, so a newline between text and `<a>` collapses to
  nothing. Fixed with `{' '}`, and the built HTML is now scanned for the pattern
  in both directions.

---

## 17 · The layout redesign (2026-08-11)

A note's first lines were unreachable — no scroll position would bring them into
view. Six speculative fixes failed because each treated it as a scrolling bug.
Instrumenting the running app to print its own view hierarchy gave the answer in
one measurement, inside a 923pt window:

```
NavigationSplitRepresentable   h=1477.5  y=-251   ← 554pt too tall
  MarkdownEditorView host      h=1390.5  y=52
    NSScrollView               h=1390.5
```

The scroll offset was always correct. **The view was larger than the window it
lived in**, so its top 251pt sat above the window frame — rendered nowhere,
reachable by nothing.

Full design and rationale: [layout-architecture.md](layout-architecture.md);
wireframes for every device: [wireframes.html](wireframes.html).

### The bug class

`NSScrollView.fittingSize` derives from its document view, so for a 76-line note
it measured **3433pt**: the whole document. A representable that doesn't
implement `sizeThatFits` hands that to SwiftUI as an *ideal* size, and
`NSSplitView` sizes itself to its **tallest column**. Only **1 of 9**
representables implemented it, and the shell declared `minWidth/minHeight` with
no ceiling, so nothing clamped the ideal back down.

This was systemic, not an editor defect: `NSOutlineView`, `UITextView`,
`WKWebView`, `PDFView` and `QLPreviewView` all report content size the same way.
A 2,000-note outline inflated the shell by itself.

### What shipped

**The sizing contract** (Part 5). All nine representables answer `sizeThatFits`
with the proposal via a shared `viewportSizeThatFits`, and never return `nil` —
`nil` means "ask the platform view", which *is* the bug. Containers whose
children are viewports clamp to `.infinity`; the shell states a maximum as well
as a minimum.

**`AdaptiveShell`** picks the arrangement by the **axis of abundance**, never
the device: wide displays spend room on side rails, tall ones band navigation
across the top, phones give the editor the whole screen. A Mac window and an
iPad of the same size get the same shell, so Stage Manager stops being a special
case. Native where native delivers the contract — the wide shells are a real
`NavigationSplitView` plus a real `.inspector`.

**The inspector rail** consolidates four scattered surfaces (references under
the editor, outline in a popover, tags in the left sidebar, history in a sheet)
into one place that reopens on its last-used tab. Tags left the left rail: it
answers "where is it?", the inspector answers "what is this, and what touches
it?". Selecting a tag there still filters the note list — the rails cooperate.

**Reading is not editing** (decision 5). Reading holds a fixed measure and
centres it; editing takes the pane and stays left-aligned, VS Code style. A
fixed 80ch column in a 3200pt pane is a ribbon stranded in gutters. Widths
resolve against the font in use, never stored as points. The wrap guide is a
line you can see, not a wrap point.

**`EditorDocumentStore`** keeps built documents above the shell. Building one
parses and styles the whole note, and it used to happen again on every tab
switch and every shell rearrangement — each time dropping the caret and scroll.

### Also fixed on the way

Editing a note while Obsidian had the same iCloud vault open made the caret lag
badly. Three causes, all on the main actor: derived index state was rebuilt and
republished on the main actor even when unchanged (now computed off-main, with
an O(1) signature-gated handoff); the file watcher ran a full vault scan per
event where a co-editor delivers bursts (now debounced 400ms); and an external
reload rebuilt the whole editor document (now patched in place, preserving caret
and scroll).

### Traps hit

- **`automaticallyAdjustsContentInsets = false` looked like the fix and was the
  opposite.** In a `.fullSizeContentView` toolbar window the scroll view extends
  up under the toolbar, and the automatic inset is what makes the minimum scroll
  offset *negative* so document y=0 can clear it. Disabling it hid the first
  66pt with no way to reach them. A clean-room harness proved it (stages 7 vs 8).
- **Clamping the scroll origin to `max(0, y)` forbade the very offset reaching
  the top requires.**
- **`Group` has a `TableColumnContent` overload.** With a `List` inside, the
  compiler picks it and then fails to infer its generics, reporting errors about
  `TableColumn` in a file with no table. `@ViewBuilder` on the property instead.
- **A custom band layout has no navigation context.** `NavigationSplitView`
  gives each column one; a hand-built band must supply its own or `.searchable`,
  `.navigationTitle` and every column toolbar button silently vanish.
- **`NoteHistoryView` was hard-coded to 720x480** — fine as a sheet, an overflow
  in a 280pt rail, which is the exact failure the redesign exists to stop.

### How it is kept fixed

`HelloNotesTests/ShellContractTests` is Part 6's validation matrix: fourteen
scenes from a 320pt iPad slice to 3840x2160, plus a live resize sweep down to
250pt and back, measured in a real toolbar window that is never ordered front.
It asserts on viewports **and their ancestors**, never on scroll content — being
a window onto something larger than itself is what a viewport is *for*.

The unreachable top-of-file was a layout fact, not a logic fact, so nothing in
the codebase could have caught it. Now it fails the build.
