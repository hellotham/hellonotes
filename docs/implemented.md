# HelloNotes — Implementation history

> The archive of *how HelloNotes was built*. The other docs describe the **current**
> state; this one records the journey — the milestone sequence, the greenfield editor
> rewrite, the retired `swift-markdown-engine` fork, the GFM full-fidelity work, and the
> notable fixes worth remembering. It consolidates the former `implementation-plan.md`,
> `markdown-engine-strategy.md`, `editor-rewrite.md`, and `editor-parity.md`.

**Current status:** v1.3 (§22); v1.2 shipped 2026-08-15 (see [CHANGELOG.md](../CHANGELOG.md) for the user-facing
notes and §20 below for the batch); v1.0 was Milestones 0–13, plus the deeper Apple-platform
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

### The left rail became a switcher

The redesign's first pass left the left column as it was: a `List` holding a
collection card, five command buttons, a bookmarks section and the Git panel —
three scrolling lists side by side, with commands presented as though they were
destinations. Commands are not places. The only *places* on the left are the
library and the collections, so the column is now a **64pt vertical switcher**
of exactly those, with Git as a pinned footer button opening the full panel in a
popover.

The consequence, decided with the user, is that the rail **replaces the note
list's collection level**: the tree roots at the *folders* of the collection the
rail is standing in, not at the collections. Collection group rows survive in one
place only — search, which is cross-collection by design and still has to say
where each hit came from.

Everything that used to sit beside the collections moved into the **Library
place**, shown in the note-list column when the rail is on Library: the quick
actions (New Note, Today's Note, Graph, Ask Library, Assistant), bookmarks across
every open collection, and the most recently edited notes.

Three things that key on a collection row had to be rewired, each a real defect
if missed:

- The **outline cache key** must include the rail's place, or switching
  collections leaves the previous tree on screen until something unrelated
  happens to change the key.
- `NoteOutlineList.rootID(containing:)` found a node's owning collection by
  matching it against the roots. With *folder* roots that returns a folder path
  as if it were a collection id, and a drag from one top-level folder into
  another is then rejected as cross-collection. It now matches only group rows,
  and otherwise asks the rail (`scopedCollectionID`) — which also restores
  dropping onto empty space and the empty-space "New Note / New Folder", both of
  which had been the collection row's job.
- `ShellMetrics.railWidth` is the single source for the column width, so
  `estimatedPaneWidth` and the tall shell follow it automatically. Floor ==
  ideal == cap: a switcher has nothing in it to widen.

### The note's title, inline

A note appeared to start mid-content, because its title lives in the filename and
the only place it was shown was the window title bar. It is now drawn above the
body in the document's own H1 and renamed in place — which renames the file and
rewrites every `[[wiki-link]]` to it.

It is deliberately **not** part of the text storage. The editor's founding
invariant is that raw Markdown *is* the text — one text, one coordinate system —
so a title that lives in the filename cannot be a line in the buffer. It is
chrome that renders as though it weren't, and the caret crosses the seam:
arrowing up from the first character hands focus to the title with the caret at
its end; Enter, Tab or arrowing down hands it back to the body.

Both boundary behaviours needed AppKit, which is why the Mac owns the field
editor (`InlineTitleField`) instead of using SwiftUI's `TextField`: programmatic
focus makes the field editor **select all** (so arrowing up highlighted the whole
title), and handing focus *away* leaves the text view first responder with no
visible insertion point, because the blink timer only restarts when AppKit itself
moves focus. iOS keeps a plain `TextField` — it has no proxy to hand the caret
to, so there is no seam to correct.

### 3,156 tags were really 223

The Tags rail was unusable: thousands of entries, many of them nonsense like
`#_bookmark0`. It was a **parsing** problem, not a presentation one. Three rules
fixed it — a tag may not start mid-word (`(?<![\w/])`), link destinations are
excluded (`#anchor` in `](file.md#anchor)` is not a tag), and an all-digit tag is
a Markdown heading anchor or an issue number, not a tag. On the real vault: 3,156
distinct tags → **223**. Of 2,027 indexed notes only 81 carry a tag at all, and
only 40 tags appear in more than one note.

`CollectionIndexCache.version` had to be bumped with it, which is the general
rule: **a parser fix is a cache invalidation**. Without that the fix appeared to
do nothing, because the old tags were served from disk.

Measuring first also settled the design. With 223 tags and 40 of them shared, a
ranked list or a tag cloud would have been apparatus over almost nothing, so the
rail is **note-first**: this note's own tags as chips (the thing you actually
want to pivot on), then a search field, then matching tags with note counts. No
directory to scroll.

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
- **One more `onChange` tipped `MacContentView.body` into "unable to type-check
  in reasonable time".** The body is one expression to the type checker; it is
  now split into `shellCore` plus a `presentations(_:)` wrapper — two opaque
  halves are two smaller problems.
- **Two shared views reached into macOS-only code**, so the app built on the Mac
  and failed on iOS: `InlineNoteTitle` referenced the AppKit `InlineTitleField`
  unconditionally, and `WrapLayout` (used by the inspector on both platforms)
  lived inside a `#if os(macOS)` file. Building only the platform you are
  looking at is how both got in.

### How it is kept fixed

`HelloNotesTests/ShellContractTests` is Part 6's validation matrix: fourteen
scenes from a 320pt iPad slice to 3840x2160, plus a live resize sweep down to
250pt and back, measured in a real toolbar window that is never ordered front.
It asserts on viewports **and their ancestors**, never on scroll content — being
a window onto something larger than itself is what a viewport is *for*. Thirteen
tests, including the sidebar's width band and the pane estimate that must follow
it, and the single-pass recents behind the pinned Recents node.

The unreachable top-of-file was a layout fact, not a logic fact, so nothing in
the codebase could have caught it. Now it fails the build.

---

## 18 · The shell chrome redesign — one sidebar, one row (2026-08-11)

§17 decided the *arrangement* — how many columns, how wide, at what size. It
never decided the **chrome**: what may be drawn in the titlebar band, which
panels get a show/hide control, and where that control sits. Nothing having
decided those, they were answered one at a time by taste, in the running app,
over about twenty attempts, producing in turn a toggle floating mid-list, three
inspector toggles with one buried under a `»`, a search field collapsed to a
glyph, and a spurious row above the inspector.

### The one fact underneath all of it

**SwiftUI places a sidebar toggle for column one and no other column.** The old
shell made a fixed-width collection *rail* column one, so the panel that
actually needs collapsing — the folder tree, which a laptop writer hides to get
width — was column two. Its control therefore had to be hand-placed, and every
hand-placed variant was wrong in a different way.

Measured in `scratchpad/ChromeLab`, which renders candidate shells as real
`WindowGroup`s and captures them through the compositor: the three-column shape
produces **no toggle at all**; folding the collapsible panel into column one
produces the correct one, at that column's trailing edge, for free.

So the fix was structural. Collections and folders became **one tree** —
collections as top-level nodes, their folders nested, Recents and Bookmarks
pinned above — which puts the collapsible panel in column one where the platform
can place its control.

### What the survey changed

Five apps captured with `screencapture -l <windowID>` and measured, not
remembered (`docs/shell-chrome.md` Part 2). Two findings overturned decisions
that had been made from memory:

- **Apple Notes** — a notes app by the authors of the HIG, with our exact data
  shape — puts its sidebar toggle at **x≈197pt in a 220pt sidebar**, its own
  trailing edge, with New Folder beside it. That is now our position, to the
  point.
- **Pages** draws its inspector's selectors (`Format`, `Document`) **in the
  band, directly above the inspector**, with no chevron. So "nothing above the
  inspector" was too strong: the rule is *only the inspector's own selectors*.
  Our five tabs became five icon toggles there, which means the panel needs no
  strip of its own — and that is what removed the spurious row at its root.
- **VS Code** is commonly remembered as having sidebar *tabs*. It does not: its
  switcher is a vertical activity bar, and what it stacks inside a container is
  accordion sections. That settled the question against tabs, whose premise —
  mutual exclusivity — does not hold for Recents versus a folder tree.

### Two framework behaviours that were mistaken for our bugs

- **`.searchable` collapses to a magnifier glyph at 860pt.** That is the
  declared window minimum and the laptop writer's working width, so the control
  vanished exactly where it mattered. Replaced with a plain 190pt `TextField` in
  a leading toolbar item, which cannot collapse. ⌥⌘F (Edit ▸ Search All
  Collections) restores the keyboard route the system control came with; ⌘F
  stays find-in-note.
- **`.inspector()` forces an unsuppressable `»` chevron**, which then swallows
  toolbar items as the band tightens — the origin of "three toggles, one hidden
  under »". The inspector is now an `HStack` sibling of the editor with a
  divider, the mechanism finvestlens ships.

The band also draws no window title (the window keeps one for the Window menu).
At 860pt the title is the difference between one clean row and a `»` that
swallows search *and* all five tabs — measured, not assumed.

### How it is kept fixed

`ShellContractTests` now asserts the two-column arrangement: that the sidebar is
draggable between a floor and a cap rather than fixed, that **sidebar ideal +
editor floor fits inside the declared window minimum** (which is why the sidebar
is collapsible by choice at every size rather than forced shut below 960pt), and
that the pane estimate subtracts exactly the columns actually shown.

`docs/shell-chrome.md` Part 7 is the visual checklist, and it is run **in full**
after every change rather than only on the item last reported — eight items,
against a capture. The instrument matters as much as the checklist: judging any
of this from `cacheDisplay` is what cost the session before this one, because it
cannot render materials and paints them flat white.

---

## 19 · Two bugs the screenshot shoot found (2026-08-11)

Re-shooting the website screenshots is a 🔴 in `unimplemented.md §8c`. Driving
the real app to do it surfaced two defects that no test and no code reading had
caught — both of which would have quietly ruined the deliverable.

### The sidebar showed a library that no longer existed

Opening a collection did not add it to the tree, and **Close Collection did
nothing at all**. Both are the same fault: `outlineInputsKey` — the cheap
fingerprint that decides whether the expensive tree rebuild runs — still
described the world §18 replaced. It named *one* collection (whichever the old
rail was standing in) plus the rail's place id. Once the tree held **every** open
collection, opening or closing one changed no part of that key, so the cache
served the previous tree forever.

The key now names every collection and its revision, plus a bookmark count
(bookmarking changes no revision but does change the pinned Recents/Bookmarks
nodes above them). A refactor that widens what a view shows has to widen its
cache key by the same amount — the two are one decision, and splitting them is
how this survived a green build and 119 passing tests.

### Rendered blocks kept the appearance they were born in

Display maths rendered dim and washed out on a dark ground while the inline
`$…$` on the very line above rendered crisp and white. Mermaid charts drew
light-mode boxes into a dark editor.

`blockImageCache` was keyed on the block's *kind* alone. Inline maths, in the
same file, folds `isDarkAppearance` into its key — so one path re-rendered on a
theme change and the other served a stale image forever. Two things were wrong
and both are fixed:

- the block key now includes the appearance **and** the render width, matching
  what inline maths already did;
- `isDarkAppearance` was only ever refreshed from `layout()`, and switching
  appearance does not necessarily lay a view out again. `MarkdownTextView` now
  overrides `viewDidChangeEffectiveAppearance()` and `MarkdownUITextView`
  `traitCollectionDidChange(_:)`; both call a new
  `EditorDocument.appearanceDidChange(isDark:)`, which marks every block
  unstyled so the images are drawn again in the new theme.

**Why this mattered more than it looked.** The whole point of the screenshots is
a light/dark *pair* from the same vault, same window, same note, where only the
app's theme differs. With images that never re-render, flipping the theme would
have produced pairs whose maths, diagrams and tables silently disagreed with the
text around them — a defect baked into the marketing rather than the app.

**The lesson, and it is the same one as §18's:** a bug that only shows up when
you drive the real product is invisible to a build, a test suite and a code
read. Two of them were sitting in a "finished" feature.

---

## 20 · The 1.1 batch — collapse artifacts, CRLF, and the stale register (2026-08-11)

Released as **1.1**. Worked from [unimplemented.md](unimplemented.md); the first
finding was that the register itself had drifted.

### The collapse path only ever saw one-line blocks

Every block-embed test used a single-line `![[pic.png]]` paragraph, and the
suite's stub renderer explicitly declined `.math`. So `collapse(range:to:)` was
never exercised on a multi-line block, and three defects lived in that gap —
all of them visible in any note with display maths, which is what had blocked
the website screenshots since §19.

| Defect | Cause |
|---|---|
| ~90pt of dead space under a formula | `paragraphSpacing` applies at the end of *every* paragraph, and a newline ends a paragraph. Set across a three-line `$$…$$` block it reserved the image band **three times**. |
| A full blank line under the image | The block's trailing newline sat outside the concealed range, so it kept the 15pt body font. Front-matter folding had the same bug — hence the blank line above every note with properties. |
| Coloured specks under a Mermaid diagram | A Mermaid fence is *both* a highlightable code block and a rendered embed. The highlighter runs async, so its colours landed after the collapse and repainted the concealed 0.1pt source. Measured: 18 characters. |

The band now goes on the last paragraph only, concealment covers the trailing
newline, and `refreshHighlight` skips a block that is currently collapsed.

**On the tests.** Each new test was run against the *unfixed* source. Two passed
against the bug and had to be rewritten: one counted attribute *runs* when the
defect is about *paragraphs* (a single run spanning three paragraphs still
reserves three bands), and one let the highlight/collapse race resolve the lucky
way until the stub highlighter was made deliberately slow. A test that passes
against the unfixed code documents nothing.

### CRLF, and a merge branch that could never run

`LineIndex.contentRange` strips the `\n` but not the `\r`, so every structural
classifier in `BlockParser` saw a trailing carriage return and refused to match.
In a file saved on Windows, setext headings, thematic breaks and front matter
all parsed as ordinary paragraphs. The fence classifier trimmed `0x0D` itself,
which is why fenced code was the one construct that worked — and why the bug
survived: the obvious test case passes.

Separately, the blank-run merge test sat *after* `closeOpen`, which resets
`open` to `.none`, so it never matched and every blank line became its own
one-line block.

### The register had drifted

Five items in unimplemented.md described gaps that had already been closed and
never struck off — the editor headings rotor (shipped on **both** platforms),
the Duplicate shortcut (⌘D, with Bookmark moved to ⇧⌘D), the clone Cancel
button, Reduce Motion (the only continuously animating surface already checks
it) and the canvas colour palette (built from adaptive system hues throughout).

Verifying before implementing turned four of those into no-ops and surfaced the
*real* remaining gaps underneath two of them:

- Both platform views implemented the rotor's next/previous walk separately, and
  neither honoured `filterString` — so typing in VoiceOver's rotor search field
  silently returned unfiltered results. The walk now lives on `EditorDocument`,
  where it is testable (no test constructs an `NSTextView`).
- The canvases sized labels from zoom alone, so raising the system text size
  moved every other surface and left the graph and mind map at a flat 11pt.

**The lesson:** a backlog is a claim about the present, and it decays. Reading
the code first cost minutes per item and prevented re-implementing four things
that already worked.

### Silent failures, and an inescapable sheet

- `ChatSessionStore` wrote with `try?`. A full disk stopped saving and the loss
  only appeared at the next launch, as an empty conversation.
- Creating a repository *with* a remote ends in a push, and a push to an
  unreachable host hangs; the sheet spun on `isBusy` with no way out. It now
  uses the cancellable runner `cloneRepository` already had — cancellation
  forwarded into the detached libgit2 work, half-made repository removed.
- `Library.restore()` awaited each collection's scan before starting the next,
  so launch cost the *sum* of the cold scans. They now overlap.
- `Task.detached` does not inherit cancellation, so a cancelled watcher-debounce
  task left its directory walk running and the replacement started a second one
  beside it. Cancellation is forwarded; partial results from a cancelled walk
  are discarded rather than applied (applying them would empty the collection).

---

## 21 · Collections that survive the real world (2026-08-15)

Released as **1.2**. Reported: **"Add as Collection" does nothing** for Box and Dropbox. Four defects sat
behind that one symptom — and investigating them found that the same class of problem
applied to **local folders and Git repos**, with nothing to do with cloud.

A collection is a reference to *a folder we do not control*. It can be large, slow,
full of non-documents, a Git repo, or gone. Cloud only makes the slow, large and
absent cases common rather than rare. So cloud-ness, repo-ness and bigness became
**attributes**, not modes, and the work was reordered by who was hurt rather than by
subsystem.

### The reported bug

| Defect | Was |
|---|---|
| `Task { try? await library.openRemote(…) }`, five sites | A 403, a rate limit and a complete success were indistinguishable — and identical to a dead button |
| Collection appended only *after* the whole download | Nothing appeared for minutes on a real account |
| `syncDown` uncancellable, all-or-nothing | One failed request discarded even the folders that had synced |
| Button had no state | No disabled state, no progress, no result |

Two further silent failures surfaced while testing live, both the same defect in
different clothes — presenting an absence of information as information:

- **The browser never listed anything when a token was already stored.** `connect()`
  was the only caller of `load("")`, and a window opened with a Keychain token skips
  it, so it issued *zero* requests and then said "Empty folder".
- **Non-Markdown files were skipped without a word**, so a Resume folder of PDFs
  synced to an unexplained empty collection.

### Availability, and honest change detection

`FileWatcher` discarded `eventFlags` entirely and never set `WatchRoot`. So a moved
or deleted root, an unmounted volume, and `MustScanSubDirs` — the kernel saying *"my
queue overflowed, I dropped events"* — all arrived as silence. A big `git checkout`
could silently desync the index while search went on returning a confident subset.

`CollectionState` now distinguishes **empty from unreadable**, which looked identical
on screen and mean opposite things. The rule: going unavailable **never** discards
anything. A test proved the old path emptied the collection — `notes.count` went 2→0
when a drive was unplugged, and the index cache was rewritten to match, so the damage
outlived the disconnection.

`Bookmark.resolve` had declared `isStale`, passed its address, and never read it —
so bookmarks decayed until one failed outright and the collection vanished at launch
with nothing said. Now re-minted, and an unresolvable bookmark **keeps** its
collection, restored as unavailable with Try Again and Remove.

### Git as an attribute

SwiftGitX exposes only `git_repository_open`, libgit2's *no-search* variant, so
opening `~/repo/docs` as a collection reported "not a repository" and offered no Git
UI at all. Upward discovery fixes it, and full Git UI is made safe there by
**pathspec scoping** rather than by a warning: status, counts, history and staging all
confine themselves to the collection's own subtree. The one hole scoping cannot close
— `commit` writes the whole index — is *refused* rather than silently included.

External `git pull` also left the branch indicator lying, because `onExternalChange`
never touched Git.

### One walk, for everything

`FileManager.enumerator` returns only when finished, cannot be checkpointed, and
yields nothing when cancelled. Replaced by an explicit **frontier** — a queue of
unvisited directories — behind a one-method `TreeSource`, so the same machinery
serves a local folder and a provider's API.

Benchmarked before it replaced anything, at the scale of the real 2,019-note vault:
1,111 directories / 2,222 notes, **enumerator 0.340s vs walk 0.350s (ratio 1.03)**,
identical note and folder counts. That equality is asserted in the benchmark so the
two cannot drift while both exist.

**A test caught a serious bug during integration.** Iterating an `AsyncStream` ends
when the *consuming* task is cancelled — so the loop could stop early while the
detached walk ran on to report `isComplete`, and publishing the accumulator then
replaced the note list with however little had arrived. A cancelled rescan emptied the
collection outright: the exact thing the availability work existed to prevent,
reintroduced through a different door.

iOS gained change detection **for the first time** (`DirectoryPresenter`,
`NSFilePresenter`) — previously an iPad showing a vault edited on a Mac stayed stale
until relaunch.

### Cloud: the mounted provider first

Phase 4 shipped four direct-API providers and quietly promoted the fallback to the
front door. But Box and OneDrive were *already mounted* on the author's Mac at
`~/Library/CloudStorage/`, needing no authentication whatsoever. **File ▸ Open Cloud
Folder…** now comes first; the API browsers moved under "Connect Over the Web".

This turned up a shipped bug: a browse hint only has to be *correct*, not readable,
but `ObsidianVault` built one from `homeDirectoryForCurrentUser`, which inside the
sandbox returns the **container** (measured from inside the shipping binary — the
test host *is* the app). The hint pointed at a path that had never existed.
`RealHome` uses `getpwuid_r`.

### Metadata-first mirroring

`syncMetadata` mirrors the folder's *shape* — every file, not just Markdown —
without fetching a byte; content hydrates on open. The **hydration gate** is a
data-loss guard, not a feature: `FileIO.isMaterialized` answers only for iCloud items
and calls a zero-byte placeholder "available", so the indexers would have recorded an
empty note and the editor would have uploaded that emptiness over the real one. All
three indexers now share `FileIO.hasContentAvailable(note)`, and the save path
refuses outright to upload a note that was never downloaded.

Conflicts are settled by the provider's **revision**, not by comparing clocks across
devices, and both versions are kept. Refresh uses the provider's delta cursor, with
the invariant that **a delta may never prune** — it reports what changed, not what
exists.

### Verification

169 tests (up from 128). Each new invariant was proven **red first**: the failed
subfolder, the incomplete prune, the emptied collection, the unrecognised repo
subfolder. Two bugs were found *by* those tests rather than by reasoning — the
cancelled-rescan wipe above, and Dropbox `deleted` entries parsing as ordinary files,
which would have resurrected every note deleted on another device.

Also: `scripts/clean-preview-stubs.sh`, because a test build leaves unsigned
`__preview.dylib` stubs that make the *next* ordinary build die in CodeSign — an
intermittent failure with no connection to the code just written, which cost a
debugging detour twice.

### Shipped as 1.2 (2026-08-15)

| | |
|---|---|
| Version / build | `1.2` / `3` |
| Artefact | `HelloNotes.dmg`, 37,472,715 bytes (35.7 MB) |
| SHA-256 | `cb72851b5b951f454ce31162d43e45ec267990562a6a88eae10e141e82ad44a0` |
| Release | <https://github.com/hellotham/hellonotes/releases/tag/v1.2> |

Verified from the *mounted image*, not from the packaging script's own output:
universal (`x86_64 arm64`), Gatekeeper `accepted` with
`source=Notarized Developer ID`, ticket stapled so it validates offline, and
`CFBundleShortVersionString` 1.2.

The checksum was taken **after** stapling. Stapling rewrites the DMG, so a hash
computed before it is one no user's `shasum` will ever reproduce — and the
download page prints that hash for exactly the people who check. Confirmed by
downloading the published asset back from
`releases/latest/download/HelloNotes.dmg` and re-hashing it: identical.

1.1's DMG was moved to `dist/HelloNotes-1.1.dmg` rather than overwritten;
`package-dmg.sh` writes to a fixed path.

---

## 22 · The AI release — making it findable, and making it connect (2026-08-16)

Planned as 1.3, "the AI release". Surveying the code first changed what the release
was: **most of the AI already existed.** Summarise, Suggest Tags, Suggest Links,
Rewrite, Ask Library, the tool-using agent with approval gating, and a deep-research
tool that decomposes a question and returns a cited synthesis — all shipped, all
working, and all but unused. They were organised by *the fact that a model produced
them* rather than by what they act on, and they lived in an "Intelligence" panel and
an "Assistant" window that nobody had a reason to open.

So the release became three jobs: make what exists findable, add the one thing
genuinely missing (link discovery, which needs retrieval), and be ready for a better
on-device model without betting on its specifics.

### The finding that reordered everything

The plan called for an embedding index. The benchmark said otherwise — full numbers
and method in [semantic-retrieval-benchmark.md](semantic-retrieval-benchmark.md), on
the real 2,027-note vault with 520 link pairs as ground truth:

| Backend | recall@5 | recall@10 | MRR | build |
|---|---|---|---|---|
| **TF-IDF, hashed, length-capped** | **42.9%** | **52.1%** | **0.324** | **2.4s** |
| `NLContextualEmbedding` | 30.2% | 38.3% | 0.221 | 951s |
| `NLEmbedding.sentenceEmbedding` | 20.1% | 28.1% | 0.181 | 2,090s |

The instrument was checked before the result was believed: on six hand-built
paraphrase triples both neural models scored 6/6 and TF-IDF 5/6. The models work.
They lose *on this vault*, whose links run on rare proper nouns — the exact case IDF
is strongest at and sentence embeddings smooth away. A second round killed two more
assumptions: BM25 lost (25.3%) because it is built for short queries, not
document-to-document similarity; and capping a note's length scored the same as
per-chunk normalisation, which meant the *cap* carried the win and one sparse vector
per note was enough.

Recorded rather than quietly dropped, because the honest scope of the result is
narrow: it is one vault, and a future failure of
`paraphraseWithoutSharedTermsIsNotFound` is the signal to re-run the benchmark, not
to delete the test. `RelatednessIndex` is a protocol (`Actor`, so "never tokenise on
the main actor" is structural) with a `schemeID`, so swapping the scheme later costs
a rebuild, not a rewrite — which matters because second-brain frameworks are coming
and may want framework-specific indexing.

### Auto-linking: the measurement that shaped the feature

Two designs died to data before anything shipped.

| Measurement | Result |
|---|---|
| Volume | 91% of notes get proposals; median 8, p90 40, max 114 |
| Precision by title length | 1 word 0.6% · 2 words 1.3% · 3 words 4.3% · 4+ words 3.1% |
| Common-word suppression | **Every** threshold loses real links — at 5%, 182 of 520 |
| Mention ∧ top-10 by relatedness | Keeps 216 of 233 real links, cuts proposals 29,533 → 13,179 |

The suppression result was the surprise: the "too common to link" titles in a real
vault are `INDEX`, `BIBLIOGRAPHY`, `Abbreviations`, `China` — linked constantly and
*on purpose*. Suppression was rejected outright. The intersection shipped as the
default cap.

The same numbers rule out an **unattended collection-wide auto-link pass**, which the
plan had mentioned. At these precisions it would corrupt a graph silently, so it was
not built. Low proposal precision costs review time and never correctness — but only
because nothing is written without confirmation, which is what makes that trade
legitimate rather than an excuse.

### What shipped

| Phase | Work |
|---|---|
| 1 · Findable | AI actions into the **Note** menu, each landing in the inspector tab that already owns that kind of answer — summary → Outline, tags → Tags, links → References. `IntelligenceView` deleted. Command palette (⇧⌘P). Floating selection bar carrying only what the OS cannot do. |
| 2 · iOS parity | Every AI feature was `#if os(macOS)`. Lifted: intelligence actions, rewrite, Ask Library, the Assistant, selection actions via the native edit menu. |
| 3 · Retrieval | `Core/RelatednessIndex.swift` — sparse hashed TF-IDF, FNV-1a (Swift's `hashValue` is per-process seeded), built lazily off-main on first use, patched per save. |
| 4 · Review Links | ⇧⌘L. Spell-check walk: **Link / Skip / Never**, showing the phrase in its sentence *and* the target's opening lines. "Never" persists per collection, outside the vault — a decline belongs to you, not to your collaborators' Git history. |
| 5 · Compose & research | New Note from a Prompt… (⌃⌘N), Write or Research. Research lands `DeepResearchTool`'s cited synthesis **as a note**, with provenance front matter and gathered sources. |
| 6 · Capability seam | `LLM/ProviderCapabilities.swift` — features declare needs, providers declare capabilities. `appleOnDevice` is the single property a new OS moves. |
| 7 · Ghost text | Inline completion, macOS only, on-device only, off by default. |

### Three invariants, each pinned by a test

1. **A composed note's links are verified, not trusted.** A model told which notes
   exist will still name ones that do not, and `[[Memex]]` renders identically to a
   real link — it just quietly adds a node the graph and backlinks take at face
   value. `ComposedNote.resolveWikiLinks` keeps only links naming a real note,
   unwraps the rest to plain text, and *reports* what it dropped. A research note is
   the one kind nobody proofreads.
2. **Ghost text is never in the document.** It lives in a stored property and is
   painted in `draw`; there is no code path from what the drawing reads to the
   storage that autosave, the index, the link graph and Git all read. Proven by
   deliberately breaking it: with a one-line insert into storage, every assertion in
   `aShownSuggestionIsNotInTheDocument` fails.
3. **A suggestion cannot outlive the caret it was computed for.** The first version
   cleared on caret movement and a test caught it *not* clearing — `setSelectedRange`
   did not reach the override it relied on. Chasing the funnel would mean finding
   every path that moves a caret; missing one leaves a suggestion that is not merely
   drawn in the wrong place but can be **accepted**, inserting a completion for a
   sentence the caret has left. It is now validated on read, so there is no path to
   miss.

### Bugs found on the way

- **`std::bad_alloc` at chunk 26,000 — twice, at the same index.** Blamed on an
  autorelease pool and "fixed"; the second run died identically. A deterministic
  failure at a fixed point is a specific input, not accumulation — and the chunk
  histogram said so in one line: median 839, p99 900, **max 327,680**. A
  PDF-converted note with no sentence-ending punctuation made `NLTokenizer` return
  the whole note as one "sentence". The pool fix was correct and kept; it was just
  never the bug. The shell reported exit 0 throughout, because the abort belonged to
  the program.
- **Ground truth was 45% short.** Matching raw link targets against titles missed
  every `[[Folder/Note]]` — which in this vault were the only links that resolved.
  295 → 520 pairs.
- **A composed title starting with a dot vanished.** Sanitising `../Escaped` yields
  `..-Escaped`; the scanner skips dotfiles. The file was written successfully and the
  note never appeared — file exists, note does not, nothing reports a failure. Found
  by a test written for path escape, not for this.
- **`DeepResearchTool` gated on the wrong question.** `kind.supportsTools` reads the
  wire format, so it said yes for a search-backed provider that cannot drive our
  tools; the run then failed several sub-agents in, looking like broken research
  rather than an unsuitable provider. It now shares one answer with the compose
  sheet.
- **`ExclusionZones` had to split.** Link *proposals* must avoid existing links;
  link *validation* has to see them. One shared set meant the validator could never
  see a link.
- **iOS had no `noteDidSave`.** Its saves reach the indexes via a 400ms debounced
  presenter rescan — fine for the editor, not for a note created and selected
  immediately, which would spend that window absent from search and backlinks while
  looking present.

### Verification

267 app tests in 30 suites (from 185 at the start of the release), 106 editor-package
tests in 11 suites (from 91). macOS Debug, **macOS Release** and iOS Debug all clean;
the website builds (16 pages).

Release was run as its own gate rather than assumed from Debug, because §13 is the
Release-only SIL optimizer crash that broke every archive while Debug stayed green
throughout.

The user-facing copy went through the `docs-fact-checker` agent, which checked 107
claims and found **nine wrong** — every one now corrected. **Six were written for this
release; at most three predated it** (the `shortcuts.astro` rows). The worst of the
three inherited ones is `⌥⌘1 … ⌥⌘6` for heading levels when the app binds
`ForEach(1...3)`: three shortcuts that had never existed, in the same file where 1.2
shipped two invented ones.

The six new ones are worth naming, because they share one failure mode — describing
what the design *intended* rather than what the code does, always in the flattering
direction:

- "Related notes are found by **meaning**" — the shipped index is lexical, and
  `paraphraseWithoutSharedTermsIsNotFound` asserts precisely the opposite. The example
  given (*Zettelkasten* surfacing for "second brain") is the exact case the benchmark
  measured and rejected, written up as if it had been delivered.
- "A phrase is only proposed when it names another note **and** the two are about the
  same things", in two places — `Collection.linkProposals` returns early at or below
  the cap (`guard found.count > limit`), so relatedness ranks and caps rather than
  filters. The measurement was of the intersection; the shipped behaviour is the cap.
- "Both default to on-device Apple Intelligence" — `activeProvider ?? .openai`. Only
  the *intelligence* provider defaults to Apple; the chat provider is nominally OpenAI
  and inert until it is both enabled and keyed.
- The palette "built from the same list the menu bar is, so nothing can be in one and
  missing from the other" — it was built from the same `AppActions` *value*, which is
  not the same guarantee: eight menu commands were missing from it. **Resolved rather
  than reworded** — see below.
- "**All of it** works on iPhone and iPad" — the palette is `#if os(macOS)`, and
  selection actions surface as the system edit menu rather than the floating bar.

A seventh was introduced *while correcting the other six*: this very paragraph first
claimed three were mine and six predated the release — self-undermining, since four of
the nine sit in a changelog section written for this release. The fact-checker caught
it on the re-run. That is the argument for re-checking corrections rather than trusting
them: the second pass found an error the first pass could not have, because the error
did not exist yet.

### Closing the palette's gap, rather than documenting it

The fact-check's most useful finding was not a wrong sentence — it was that the
sentence had *become* wrong. The palette shipped in Phase 1 covering the command
surface; eight commands had since arrived by other routes and were absent from it:
Find…, Search All Collections, Close Tab, New Window, Connect Over the Web (four
providers), Dictate to Daily Note, and the four editor-mode toggles.

None of them were broken. Each worked, appeared in its menu, and was simply
unfindable by name — which is the precise failure the palette was built to fix,
reintroduced one command at a time. Rewording the changelog to promise less would
have been the cheap fix and would have left the app worse.

The cause was structural. `AppActions` was *most* of the command surface, and a menu
item whose implementation was a notification post (`Find…`, `Search All Collections`),
an `openWindow` call (`New Window`, the four cloud browsers) or an `@AppStorage`
binding (the mode toggles) could reach the menu bar without going through it. The
palette reads `AppActions`, so those were invisible to it — silently, because a
missing row looks exactly like a row you have not scrolled to.

- **Every command now goes through `AppActions`**, whatever its implementation. The
  menu bar calls the same closures the palette does.
- **`CloudBrowser`** replaces four window-id string literals that appeared in three
  places — scene declarations, menu, and (about to be) the palette. A typo in one of
  those opens nothing and reports nothing.
- **The mode you are already in is not offered.** A palette row that does nothing is
  the same broken promise in miniature.
- **The palette does not offer to open the palette.** The one deliberate omission,
  now a test rather than an oversight waiting to be "fixed".

`CommandPaletteTests` pins it from the end that can actually be checked: SwiftUI menus
cannot be enumerated, but both surfaces are built from one value, so the test asserts
every action on a fully-populated `AppActions` produces an entry, that ids are unique
(a duplicate silently breaks selection for both rows), and that commands needing a
note, a collection or a provider are *absent* rather than present-and-failing — the
palette greys nothing out, so unavailable has to mean invisible.

272 tests in 31 suites.

### Shipped as 1.3 (2026-08-16)

| | |
|---|---|
| Version / build | `1.3` / `4` |
| Artefact | `HelloNotes.dmg`, 37,978,417 bytes (36.2 MB) |
| SHA-256 | `00143e2ff407b5b3cf6cd4a376d7aea0387657094d6ab6ec10887dddce10b394` |
| Release | <https://github.com/hellotham/hellonotes/releases/tag/v1.3> |
| Notarization | app `0016c7a3-7403-49e5-9028-cc39f0417409`, DMG `afa18644-99e7-44e8-b9be-7235c0943cab` — both Accepted |

Verified from the **mounted image** rather than the packaging script's own
output: universal (`x86_64 arm64`), Gatekeeper `accepted` with
`source=Notarized Developer ID` for the app *and* the disk image, ticket stapled
so it validates with no network, and `CFBundleShortVersionString` 1.3.

The checksum was taken **after** stapling, which rewrites the DMG — the same
trap 1.2 recorded, and the reason a hash computed a step earlier is one no
user's `shasum` can reproduce. Then closed the loop the way 1.2 did: downloaded
the published asset back from `releases/latest/download/HelloNotes.dmg`, re-hashed
it, and compared against the rendered `download.html` rather than the source
constant. Identical.

1.2's DMG was moved to `dist/HelloNotes-1.2.dmg` before packaging — its hash was
confirmed against this file's 1.2 record first, so what was preserved is provably
the published artefact and not a stale local build. `package-dmg.sh` writes to a
fixed path and would have overwritten it.

## 23 · The editor is never blocked — and a build setting that said otherwise (2026-08-18)

Reported on a real 2,012-note Obsidian vault in iCloud Drive: the editor locked
during scans, creating a note reindexed the folder, *naming* one reindexed it
again mid-keystroke, and a note being edited vanished from the sidebar. Two
previous fixes had reasoned carefully about which code ran on which thread, been
locally correct, and changed nothing.

### The cause was not in the code's logic

The app target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so **every
unannotated declaration and closure in the module is `@MainActor`**.
`LocalTreeSource` was unannotated. So `await source.children(of:)` hopped the
folder walk *onto* the main actor from inside the very `Task.detached` written
to keep it off — `detached` governs priority, task-locals and cancellation,
never isolation.

On a local folder that is merely wasteful. On a File Provider vault each
directory listing becomes a **synchronous XPC round-trip to `fileproviderd`**
(`FPDaemonConnection valuesForAttributes:`) on the main thread, which is why the
bug reproduced only on the user's real vault and never on a synthetic one.

Measured on that vault, before → after:

| | before | after |
|---|---|---|
| `renameNote` | **13.35 s** | 0.003 s |
| walk-only (2,000 notes) | 0.179 s | 0.0004 s |
| `scan` (2,000 notes) | 0.243 s | 0.0019 s |
| worst main-actor stall | 5.9 s | 0.48 s (SwiftUI first render) |

### What changed

- `ResumableTreeWalk.swift` is `nonisolated` throughout, as is `Collection`'s
  nested `ScanAccumulator` — nested in a `@MainActor` class, it inherited that
  isolation and dragged the walk back on its own.
- `offMain(_:)` (`Core/OffMain.swift`) replaces `Task.detached` for work that
  must not block the editor. Its `body` is a *nonisolated* `@Sendable` function
  type, so a closure that touches main-actor state is a **compile error**
  instead of a silent hop. The rule no longer depends on remembering it.
- The walk stopped asking for `.contentTypeKey`: it materialises a
  LaunchServices record per file, and LaunchServices tears those down on the
  main thread, so an off-main walk was posting 3.5 s of main-thread releases.
  `.isPackageKey` is asked only of directories.
- `renameNote` no longer awaits `rewriteWikiLinks`, and the rewrite reads the
  **backlink set** rather than every note. Naming a new note is a rename, so
  this was the cost of typing a title.
- `noteDidSave` can no longer reach a rescan. A save whose note is missing from
  the picture adopts it (O(1)); an alias change rebuilds derived indexes from
  records. The old path was caught live: *"noteDidSave → FULL RESCAN"*.
- `CollectionEmbedProvider.image` is `async`, with the `stat` and coordinated
  read off-main — it ran per `![[transclusion]]` during editor layout.
- `hydrateIfNeeded` no longer awaits a walk (it is `tabs.prepareToOpen`, so
  *selecting* a note waited on one); `AgentTool.refreshAfterMutation` uses
  `scanOffMain`; `activate` no longer awaits `git.refreshStatus()`, which
  queued behind any in-flight push.
- One canonical URL form, applied to `rootURL` at init. `Note.id` *is* its file
  URL, so two spellings meant a click that did nothing or an autosave mistaken
  for an external edit.
- `scanOffMain` has a re-entrancy guard: a second caller joins the walk in
  flight rather than racing it over the shared checkpoint, and cancellation is
  forwarded explicitly (an unstructured `Task` does not inherit it).
- iOS editor autonomy: a `focusedID` change deselects only a note the new
  collection does not contain, and a selection that resolves to nothing leaves
  the editor alone instead of opening `nil`.
- `TerminationGuard` bounds its quit flush at 5 s, so a wedged File Provider
  cannot make the app unquittable — forcing a quit that discards the very edits
  the guard exists to protect.

### The instruments, which failed six times

This is the lasting lesson. Every wrong answer this cycle came from an
instrument that was perturbed by what it measured:

1. `sample` taken *after* the freeze — read an idle stack as "nothing wrong".
2. A latency probe on the cooperative pool — measured its own starvation.
3. The same probe on a real `Thread` — the test harness parks the main runloop,
   so an idle main actor read as 2.9 s.
4. Main-thread CPU — contaminated by other `@MainActor` tests running
   concurrently; an idle control read 3.38 s.
5. `MainActorWatchdog.note(…)` placed *inside* the walk — a `@MainActor` call
   makes its enclosing closure `@MainActor`, so the probe **created** the defect
   it reported, and nearly justified refactoring the whole app.
6. The watchdog's own logging took a lock and did file I/O inline; it caught the
   main thread stalled six seconds inside `MainActorWatchdog.log`.

What finally worked was an instrument entirely outside the measured code:
`MainActorWatchdog` suspends the main thread, walks its frame pointers into a
**pre-allocated** buffer (allocating while the main thread holds the malloc lock
would deadlock the process), resumes, and only then symbolicates — sampling
**while still blocked** rather than after the wait returns. It printed the
`fileproviderd` stack, and the argument was over.

`DiagnosticSelfTest` (`HN_SELFTEST=1`, Debug only) drives the real app against
the real vault unattended — select, type 40 keystrokes, create, rename, delete —
so this no longer requires a person at the keyboard. It quits via
`RunLoop.perform`: `terminate:` spins a nested loop that does not drain the main
queue, so quitting from a main-queue block deadlocks forever (it wedged the app
for four hours before that was understood).

### Guarantees, checked

- `OffMainActorInvariantTests` — one test is `@concurrent` and `nonisolated`, so
  if any walk type regains main-actor isolation **the build fails**. Runtime
  probes live in the test's own closures, where they cannot perturb.
- `ScanCoverageTests` — a resumed pass may add but never remove; a whole-tree
  pass still removes deletions. Verified to *fail* when the guard is removed
  (6 notes → 2, the tail of the vault: the vanished-note bug exactly).
- `MainActorBudgetTests` is skipped unless `TEST_RUNNER_HN_BUDGET_TESTS=1` and
  run alone. It failed on every full run, and a suite that always fails is a
  suite everyone learns to ignore.

### Shipped as 1.3.1 (2026-08-18)

| | |
|---|---|
| Version / build | `1.3.1` / `5` |
| Artefact | `HelloNotes.dmg`, 38,606,928 bytes (38.6 MB) |
| SHA-256 | `7e56b66f158c5a83f67289f51690cfed53c8d9325ec44c92e6c7334d3dc82a7b` |
| Release | <https://github.com/hellotham/hellonotes/releases/tag/v1.3.1> |
| Notarization | app `d09ef462-9498-4fe0-8a56-dbd11ee43e62`, DMG `ecc977b4-7320-461b-8db8-adc5cdf48c32` — both Accepted |

Verified from the **mounted image** rather than the packaging script's own
output: universal (`x86_64 arm64`), Gatekeeper `accepted` with
`source=Notarized Developer ID` for the app *and* the disk image, ticket stapled
so it validates with no network, and `CFBundleShortVersionString` 1.3.1.

The checksum was taken **after** stapling, which rewrites the DMG — the trap
1.2 and 1.3 both recorded. Then the loop was closed as before: the published
asset was downloaded from the exact URL the site's button uses
(`releases/latest/download/HelloNotes.dmg`, HTTP 200) and hashed, and it matches
the value the download page prints byte for byte. `website/dist` was checked to
carry no stale 1.3 hash or size.

A patch release, and the whole of it is §23 above: the editor is no longer
blocked by folder scans, saves, renames or transclusion reads; a partial scan
can no longer remove notes; and Markdown reveal moved from per-block to per-line
so a multi-line blockquote keeps its bars while you edit inside it.


## 24 · The iPad, actually usable (2026-08-20)

The iOS app had shipped for months and almost nothing in it could be reached.
Four defects sat on top of one another in the UIKit editor, each hidden behind
the one in front, and the root cause of all four surviving was a testing gap:
`swift test --package-path Packages/NotesEditor` **only ever builds the package
for macOS**, so the UIKit half of an editor whose package declares
`.iOS(.v18)` had never had a single test run against it.

### The four, in the order they were unstacked

**A text view showing a document it believed was empty.** `NSRangeException` from
`attribute:atIndex:longestEffectiveRange:inRange:`, with no app frames in the
stack, on any tap past the first character. Two suspects were eliminated by
bisect and neither was the cause; three lines of assertion found it:

    tv.textStorage.length                          → 0
    document.storage.length                        → 19450
    tv.offset(beginningOfDocument → endOfDocument) → 19450

A TextKit 2 `UITextView` holds two references to the document — the content
storage its layout manager reads, and its own `textStorage`. `bind(to:)`
replaced only the first, so UIKit took ranges from one and read attributes from
the other. AppKit supports that swap; it is why the same code is correct in
`MarkdownTextView`. The fix is to build the content storage, layout manager and
container around the document *first* and hand the finished container to
`UITextView(frame:textContainer:)`.

**A link tap that ate the caret tap.** `make(document:)` adds a
`UITapGestureRecognizer` for wiki links with no delegate. Two recognisers that
both recognise a single tap are mutually exclusive unless a delegate says
otherwise, so ours won, found no link under the finger, and returned — tap
consumed, caret never placed. `cancelsTouchesInView = false` reads as though it
covers this and does not: it governs touch *delivery*, not arbitration. The
delegate must be a separate object; `UITextView` is already the delegate of its
own six recognisers.

**A format bar that never rendered**, because `ToolbarItemGroup(placement:
.keyboard)` attaches only to responders SwiftUI manages, and then a replacement
that was zero-width — an `inputAccessoryView` is laid out by the keyboard, and
an empty one can take the input session down with it.

**A stale document on note switch.** `updateUIView` never rebound; AppKit's half
does (`if textView.document !== document`). It could not simply copy that line,
because rebinding on iOS *is* the storage swap above. The answer is identity:
`MarkdownEditorView` wraps the representable and gives it
`.id(ObjectIdentifier(document))`, so a different document is a different view.
This was not cosmetic — the stale document's `onEdit` still fed the model, so
typing into what looked like the old note would have written it over the new
file.

### Rendering: one engine, and it was not the one in use

`docs/implemented.md` §4 records the Preview as GitHub-identical — cmark-gfm into
github-markdown-css, 648/648 GFM spec tests, byte-parity against
`api.github.com/markdown`. The package ships `GFMPreview`, whose init is
`GFMRenderer.page(markdown)`. **Nothing in the app called it.**
`MarkdownWebView` — the Preview on both platforms — called `MarkdownExport.html`,
a different formatter under forty lines of hand-written CSS. The live editor
styled from cmark's AST while the Preview beside it did not.

Preview, Export and Print now all render `GFMRenderer.page`, and
`MarkdownExport` is deleted rather than left unused: its existence is how this
drifted, because it was the easier thing to reach. That also fixed a serif bug
present since the file was written — `font: -apple-system-body, system-ui,
sans-serif` is not a legal `font` shorthand, so WebKit dropped the declaration
and fell back to Times in every preview, export and printed page.

Block embeds became cross-platform in the same pass: `EditorDocument`'s
collapse-and-band step was `#if canImport(AppKit)`, so iOS wired a
`BlockRenderAdapter` that was never invoked and a table stayed as pipes. The
overlay then had to draw it — and to *skip fragments TextKit has not laid out*,
which report a `.zero` frame and were being painted at the top of the document.

### Reachability

The iPad now has a menu bar (iPadOS builds one from a scene's `.commands`
exactly as macOS does; the call was inside `#if os(macOS)`, which gated every
keyboard shortcut with it), file tabs backed by the Mac's `EditorTabs`, the
inspector as an overlay, and a folder tree that remembers what is open.

The inspector deserves a note: it was unreachable because `shellKind` requires
1400pt for a third column and an 11-inch iPad is 1194pt landscape, 834pt
portrait. Every fix in that direction was an argument about thresholds. An
overlay has no threshold to lose.

### Minimum OS

Raised to **26.5** on both platforms. The Intelligence features are built on
Foundation Models, and the Quick Look extensions already required 26.5 while the
app claimed macOS 15.0 — an app cannot promise an OS its own embedded extensions
refuse to run on.

### The parity audit (2026-08-21)

Reachability, twice more. A sweep for `#if os(macOS)` was the wrong instrument —
it reports that a file *contains* a gate, not what the gate covers or whether iOS
has a call site — so the audit went feature by feature instead, and the pattern
held: what was missing was usually the middle, not the feature.

- **Marp slides.** `SlidesView` already had a `#else` `UIViewRepresentable`
  twin. Only a caller was missing.
- **Find & Replace.** `presentFindNavigator(showingReplace: false)`. One
  argument.
- **`[[wiki-link]]` / `#tag` autocomplete.** `EditorDocument.inlineContext(at:)`
  has been public and cross-platform since it was written, and the popup list was
  pure SwiftUI behind a gate that guarded nothing platform-specific. What iOS had
  no equivalent of was the seam between them: nothing asked the document what the
  caret was inside, and nothing could write an answer back. That is now
  `onInlineContextChange` plus a UIKit `EditorProxy`. The caret rect is reported
  in **viewport** coordinates — a `UITextView` scrolls its own content, so a rect
  in content space is correct exactly once, and the popup would then drift up the
  screen as the note scrolled.
- **Heading navigation.** iOS was already posting on the find bus with no
  listener, for want of a proxy to scroll with. It has one now.
- **Inline completion (ghost text).** The one item that genuinely needed
  designing rather than wiring, and only in one place: the acceptance gesture.
  ⌥⇥ / → / Esc assume a keyboard. The touch answer is **a tap on the ghost
  itself**, which works because that region is the only place on screen where a
  tap currently means nothing — the caret is already at the end of that line,
  which is all a tap there could otherwise ask for. So nothing was taken away to
  make room for it. ⌥⇥ and Esc are still offered while a suggestion shows, and
  only then; offered unconditionally, Esc would be a key nobody gets back.
  Drawing goes through `ChromeOverlayView` for the usual reason — UIKit does not
  invoke a subclass's `draw` over its own text.

**Folds, inline maths, and chrome you can touch.** The last
`#if canImport(AppKit)` in `EditorDocument` covered front-matter folds, callout
folds and inline `$…$` maths, on the stated grounds that they need "the
fold/replacement machinery, not just an image band". True when written, and no
longer true by the time it was read: the *drawing* half had become
cross-platform when the chrome overlay landed — `drawChromeOnly` already painted
the fold chevron and the baseline math images through `PlatformDraw`. Only the
document half was gated, plus two `NSImage` annotations that should have been
`PlatformImage`. What was genuinely absent was the touch: a task checkbox has
been *drawn* on iOS since the overlay shipped and nothing ever handled a tap on
it, which is worse than not drawing one.

The caret is deliberately not restored after a checkbox tap, unlike the Mac.
AppKit lets `mouseDown` be intercepted before the click moves the caret; on iOS
the text view's own recogniser runs alongside ours, so there is no "before" to
restore to. The tapped line reveals its source instead — which is exactly what
tapping any line in this editor does, so the checkbox behaves like everything
around it.

One ordering trap, found by testing rather than reasoning: UIKit fires
`textViewDidChangeSelection` **before** `textViewDidChange` on an insertion, so
reporting inline context only from the selection callback reads a parse one edit
behind — the keystroke that completes `[[` would report nothing. It is reported
from both.

Two more were found the same way: a stale layout cannot turn a point back into
a character index (the second tap in a test landed at the end of the document),
and the collapsed-block concealment test computed alpha only under AppKit — so
on iOS every character read as concealed and the assertion was vacuous.

Twelve new iOS editor tests (38 in the suite, up from 26), and
the ranking that used to live inside the macOS-only `NoteEditorView` moved to a
cross-platform `WikiCompletions.swift`, so there is one fuzzy ranker rather than
two drifting.

---

## 25 · The second parity pass — settings that did nothing, and a window that was never built (2026-08-21)

§24 closed the features iPad was missing. This pass asked the harder half of the
same question: where do the two platforms have the same feature and *behave
differently* — and it found that the most common shape of that bug is not a
missing feature but **a setting with no reader**.

### A framework name in an API name is a platform boundary in disguise

`AppearanceSettings.editorAccentNSColor` could only ever be called from AppKit.
`EditorTheme` has taken a cross-platform `accent: PlatformColor?` since it was
written, so iOS simply passed `nil` and got `.tintColor` — a chosen accent
coloured the Mac's editor and not the iPad's, for the whole life of the iOS
editor, with nothing gated and nothing missing.

Underneath it sat eleven functions of WCAG colour science inside
`#if os(macOS)`, written in `NSColor` (`blended(withFraction:of:)`,
`redComponent`, `usingColorSpace` — none of which UIKit has). So **"Increase
contrast" was a switch iPad drew, stored, synced, and ignored**: `accentTextColor`
returned the raw tint and the AAA target the toggle exists to select was never
consulted. Nothing crashed; the text was simply harder to read than the user had
asked for.

The fix is structural rather than a UIKit transcription — a second copy of colour
maths is how the collection lifecycle drifted into two behaviours in the first
place. `AccentContrast.swift` writes the arithmetic **once**, on framework-free
sRGB triples, and each platform supplies three adapters: read components, build a
colour, build one that answers differently in dark mode. The ratios are now
testable without a window, which is what the eight new tests in
`AccentContrastTests` do.

### Settings with no reader

Three more of the same shape, all with a picker, a `UserDefaults` key and a
`CloudPrefs` sync entry — everything except somewhere to be read on iOS:

- **Reading width / Editor width.** Their only reader was a `private func` on the
  macOS-only `NoteEditorView`, written in `NSFont`. Now a `MeasuredText` modifier
  in `ShellContract.swift` that both shells apply, reading pane width from the
  shell environment rather than taking it as a parameter — so a caller cannot
  measure against a width the shell disagrees with.
- **Wrap guide.** Drawn by `MarkdownTextView.draw` only. UIKit does not call a
  `UITextView` subclass's `draw(_:)` over its own text, which is why every other
  piece of editor chrome lives on `ChromeOverlayView`; the guide now does too.
- **Sort order.** `SortOrder` is `CaseIterable`, `Identifiable`, and carries a
  `systemImage` per case — built for a picker that was never drawn on *either*
  platform. It was a `@State` on `MacContentView` that nothing wrote and a
  hard-coded `.modified` on iOS: the same value by coincidence rather than by
  agreement. It moves to `AppearanceSettings`, both trees read it, and — per the
  cache-key rule — the iOS `treeInputsKey` had to start naming it, or changing the
  setting would have looked exactly like a setting that does nothing.

### Two screens describing the same key differently

`GeneralSettingsView` offered "Pasted images" as a two-way picker with a
remembered subfolder name and a worked example of the Markdown it produces;
`iOSSettingsView` offered a bare text field whose empty state means "same folder
as the note" — true, and discoverable only by reading the placeholder. The Mac
also previews what today's daily note would be called, which is the only feedback
the date-format field has. That is not a platform difference; it is one screen
having been improved and the other not. Both now render
`FolderConventionSections`.

### The window that was never built

`AppActions.note.openInNewWindow` is an **optional** closure, nil on iOS. So File ▸
Open in New Window and the palette's "Open in New Window" both drew, both
enabled, and both did nothing when chosen. iPadOS has supported multiple scenes
since iOS 13 and the app's generated scene manifest already declares
`UIApplicationSupportsMultipleScenes` — what was missing was a view to put in the
second scene, because the Mac's hosts `NoteEditorView`, which is macOS-only.

Rather than write a second note view, the four view modes, the inline title and
the two buffer banners came out of `iOSContentView` into `iOSNoteEditorPane` and
`EditorBanners`, which the main window and the new `iOSNoteWindowView` both use.
The window owns its own `EditorModel`, as the Mac's does — a second window on the
same note is a second buffer — and drains it on scene-phase change rather than
through `TerminationGuard`, which does not exist on a platform that suspends
rather than quits.

### The launcher, and what its gate actually cost

`LauncherView` was `#if os(macOS)` end to end and nothing inside it needed to be:
`RecentsStore`, `LibrariesStore` and `Bookmark` are all ungated, and the body is
a `ScrollView` of buttons. Only the fixed 560×560 frame was Mac-shaped. What the
gate cost the iPad was not the window but the *contents* — iOS wired
`openLauncher` straight to the file importer, so a vault opened twenty times was
still a folder to go and find again, and a saved library could be created on the
Mac, synced, and never opened on the iPad. `library.onOpened` had no iOS
assignment either, so even with somewhere to draw them the lists would have
stayed empty.

### A trade-off worth re-litigating, re-litigated

`makeUIView` ran `styleEverythingNow()` for any note under 200KB — a synchronous
restyle of every block, on the main thread, at the moment a note opens, which the
Mac has never done. The comment called it the proven path. The actual asymmetry
was one line: macOS styles its viewport from a scroll-view bounds observer, which
fires on *first* layout as well as on every scroll, and iOS had only the scroll
half. `layoutSubviews` calls `ensureVisibleRangeStyled()` now, and the
whole-document pass is gone — opening a note costs what it costs on the Mac.

### Also

- **CSV/TSV** rendered as a table on iPad. `CSVTableView` and `CSVParser` were
  born inside the macOS-gated `FileViewerView` and inherited its gate, so iPad
  sent spreadsheets to Quick Look with everything else — which opens them, as a
  wall of comma-separated text. A spreadsheet whose columns are gone is not a
  spreadsheet.
- **"Rewrite with AI…"** reaches the iPad's edit menu. It is the one vault action
  that could not be an `EditorMenuItem`, whose `perform` is a synchronous
  `(String) -> String?`: a rewrite opens a sheet with alternatives, a Replace and
  an Insert Below. The UIKit view contributes the item and hands back the
  *range*, exactly as `MarkdownTextView.menu(for:)` does.

Nine new iOS editor tests (47 in the suite, up from 38) and eleven new app tests
(302, up from 291).

---

## 26 · The audit that found the audit was wrong (2026-08-22)

§25 was reported as an exhaustive parity pass. It was not, and the way it failed
is worth more than the fixes in it.

**The method answered the wrong question.** Both passes worked by enumerating
`#if os(macOS)` gates and asking, of each, *does iOS have an equivalent?* That
finds features which are **absent**. It is structurally blind to features which
are **present and different** — and "behaves the same" is most of what parity
means. `NoteOutlineList.swift` was in the gate list, was looked at, and was
classified "the Mac shell's own view; iOS has its own" — which is true, and
answers nothing about what the two views actually render.

They rendered very different things:

| | macOS | iPad |
|---|---|---|
| Note row | semibold title, cloud badge when online-only, second line carrying the search snippet or the modification date | `Text(note.title)` |
| Collection | expandable outline row — a vault can be folded away | `Section` header — not collapsible |
| Search | snippets per hit, plus `fileRows`: attachments whose *contents* matched | bare `[Note]`; **no snippets, no attachment hits at all** |
| Tag filter | drops the collection group row (the selection already says which) | keeps the header |
| Recents / Bookmarks | full note rows — same cell, same menu, draggable | inert `Text` |

The third row is the one that matters most: on iPad, a phrase living only inside
a PDF was unfindable. Not slow, not badly presented — *unfindable*, while the
same query on the Mac found it. iOS was already running the identical Spotlight
wave and discarding the result (`found.formUnion(matches.map { $0.note.fileURL })`
threw away every snippet, and `collection.attachments` was never consulted).

The fix follows §25's own rule, which the sidebar had been exempted from: the two
sidebars genuinely cannot share a view — `NSOutlineView` cells against SwiftUI
rows — but they can share what a row *says*. `NoteRowContent` decides title,
subtitle and badge once; each platform draws it. A row that gains a field now
gains it on both or neither.

### Delete did not delete

Running the iOS test suite — the one verification §25 could not complete — failed
immediately on `createAndDeleteNote`: the file was still on disk afterwards.

`Collection.deleteNote` called `FileManager.trashItem`, caught the throw,
reported it, and called `forget(note)` **regardless**. On macOS that is right:
every location the app can reach has a Trash. On iOS there is no Trash for an app
container, so `trashItem` throws, the note leaves the sidebar, stays on disk, and
**comes back at the next scan**. Delete appeared to work and quietly undid itself.
`deleteFolder` had the identical shape.

`Trash.item(at:)` now tries the Trash and, where the platform has no Trash for
that location, removes the item — and throws *only* when the item is still there,
which is what makes it safe for the caller to drop it from the model. An item
already gone counts as success, so a stale row cannot be stranded.

### The tests themselves were not at parity

`HelloNotesTests` ran 302 tests on macOS and 236 on iOS. Three of the missing
suites covered code that is cross-platform and were gated for no reason left
standing: `CommandPaletteTests` (the palette was un-gated in 1.3.2),
`ResumableTreeWalkTests` (`ResumableTreeWalk` has no platform gate at all), and
part of `HelloNotesTests` itself. Un-gated: iOS now runs 257 tests in 29 suites.

Still macOS-only, and correctly so: `ShellContractTests` (measures real
`NSWindow`s), `EditorFidelitySnapshotTests` (AppKit rendering; iOS has its own
snapshot suite), `SmartPasteTests` (genuinely an `NSPasteboard` fixture — the iOS
`UIPasteboard` half needs tests of its own, and does not have them).

### Two more capability gaps, from diffing menus item by item

- **Download / Remove Download** existed only in the Mac's sidebar menu, on the
  platform where a vault is *least* likely to be cloud-backed. `FileIO.download`
  and `.evict` have no platform gate; iPad simply never called them.
- **Focus Collection** had no iOS command. Focus was reachable only as a side
  effect of selecting a note, so a collection with nothing selected in it could
  not be made the scope for New Note, the graph, tags or Open Quickly.

### What to do instead of a gate sweep

Pair the surfaces, then diff the capabilities: for each user-facing surface, name
the macOS view and the iOS view, and compare what each *offers* — every row
field, every menu item, every state it can show. A gate sweep answers "does it
exist"; only a capability diff answers "does it behave the same", which is the
question parity is actually asking.

### The mechanical version, and the guard

Diffing menus by eye found two gaps; diffing the *command surface* mechanically
found three more, and the method is cheap enough to keep. `AppActions` has 50
fields and most are **optional closures** — an unwired one still draws an
enabled menu item and a palette row that do nothing when chosen. Comparing which
fields each shell supplies took one pass and named:

- **Open in New Window** — wired this pass, but `AppCommands` still hid the item
  behind `#if os(macOS)` with the comment "Both are Mac desktop concepts". Half
  right: the item is now offered wherever the closure exists, which is what a
  command should key on.
- **New Window** — gated with "No second window to open on iPad", which the gate
  was the only thing making true. `WindowGroup(id: "main")` is cross-platform.
- **Connect Over the Web** — all four direct-API browsers have been on iOS since
  they were written and were reachable only from Settings, because the menu was
  gated and `connectOverWeb` was nil.

Only `revealInFinder` genuinely differs, and it now says so in one place.

`PlatformParityTests` makes the check a test: it reads the two shells and fails
naming any `AppActions` field wired on one platform and not the other, with an
allowlist that must carry a reason. Validated by unwiring `connectOverWeb` and
watching it fail with that field's name — an instrument that has not been shown
to fail is not evidence. A second test asserts the allowlist's entries still
exist, so a stale excuse cannot sit there being read as a rule.

`SmartPasteIOSTests` covers what the macOS suite structurally could not: the
`UIFontDescriptor` branches of `isBold` / `isItalic` / `isMonospaced`, which
decide what rich text becomes when it is pasted into a note. They pass — but
until now, pasting formatted text on iPad wrote a `.md` file through code no
test had ever executed.

### The editor and toolbar surfaces, diffed the same way

**Editor.** Comparing the two representables' public builder surfaces left one
real difference: `onCaretEscapeTop`. On the Mac, ↑ from the first line (or ← from
character zero) lifts the caret into the inline title above the note. iOS had
neither half — no escape hook, and `InlineNoteTitle`'s iOS field ignored
`focusRequest` entirely, so on an iPad keyboard ↑ at the top of a note did
nothing at all. Both halves now exist. One difference stands and is deliberate:
the Mac carries the *column* across the seam through its own `NSTextField`
representable; SwiftUI's `TextField` cannot place a caret at an x offset, so iOS
focuses the field.

UIKit gives a `UITextView` no `moveUp` to override, so the escape is a
`UIKeyCommand` — and an always-installed ↑ would swallow ordinary caret movement
through the whole document. It is therefore offered only while the caret is
somewhere the escape applies, and the test asserts the **absence**: no ↑ command
mid-document, none for a selection, none when the host wired no hook.

That test earned its place immediately. The first implementation asked
`textLayoutFragment(for:)` whether the caret's fragment sat at the top of the
document — and a fragment TextKit 2 has not laid out yet reports `.zero`, so
every offset past the viewport read as "first line" and ↑ stopped working
everywhere. The same trap this codebase already documents for chrome drawing,
walked into again in a new place. Comparing caret *rects* — which lay out what
they need — is both correct and the right answer for a wrapped first paragraph.

**Toolbar.** At capability parity, with one adaptation that is a width decision
rather than a gap: the Mac's five inspector toggles are one toggle plus an
in-panel tab strip on iPad, because five do not fit at 834pt. Every tab is
reachable; it costs one more tap. Search is a toolbar field on the Mac and a
`.searchable` on the sidebar on iPad — the same capability in each platform's
own spelling.

---

## 27 · Two implementations is the bug (2026-08-22)

Every fix in §25 and §26 made the second copy match the first. None of them
removed a second copy. That is worth stating plainly, because it is the
difference between parity today and parity as a property.

A scan of the two shells:

| | `MacContentView` | `iOSContentView` |
|---|---|---|
| Lines | 2,192 | 3,106 |
| Members | 122 | 151 |
| **Same name in both** | **55** | |

Of 26 sampled by hand, **23 are logic, not views** — `openWikiLink`,
`linkMention`, `runCompose`, `revalidateSelection`, `beginLinkReview`,
`propertiesBinding`, `editorCollection`, `appActions`, `selectionActions`,
`tree`, `closeTab`, `openTodaysNote`. Only `collectionTree`, `inspector` and
`shellCore` are views — and `shellCore`, the shell's own composition root, is
the same idea written twice under the same name.

The model layer is genuinely shared: `Collection`, `Library`, `EditorModel`,
`EditorTabs`, `NoteInspector`, `CollectionTree`, `AppActions`, the whole
`NotesEditor` package. The *shell* layer is duplicated, and every parity defect
this audit found lives in it.

### The first extraction, and the shape of the rest

`openWikiLink` is the case that proves it. The Mac's was 45 lines — web schemes,
`[[#heading]]` meaning this note, the link graph's aliases and relative paths, a
case-insensitive title match, create-on-miss, and a heading jump that waits for
the tab to exist. The iPad's was six lines of title comparison. Same command,
same gesture, different feature.

`WikiLinkNavigation.resolve` now decides, and each shell keeps only what is
genuinely platform-specific: which API opens a URL, and how that shell moves its
own selection. Nine tests cover the decision on both platforms — tests that could
not exist at all while the logic was a `private func` on a view struct, which is
its own answer to how the two drifted so far without anything failing.

The remaining extractions follow the same split, in rough order of how far they
have already drifted:

| Extract | Shared decision | Stays per-shell |
|---|---|---|
| Search | debounce, the two waves, snippet and attachment merge | the field's chrome |
| Link review | proposal generation, accept/decline application | sheet vs panel |
| Compose | permissions, run, create | sheet vs window |
| Selection | revalidation, focus-follows-selection, tab pruning | — |
| Actions | `appActions` / `selectionActions` / `aiActions` construction | — |

Each is a `@MainActor` type with the decision and no view, plus tests. What is
left in the two content views afterwards is layout, which is the one thing that
*should* differ.

The alternative — one content view with `#if` inside it — was considered and
rejected: it produces a file neither platform's reader can follow, and the
layouts genuinely differ (an `NSOutlineView` sidebar against a SwiftUI `List`, a
column inspector against an overlay). The split is decision-shared,
presentation-separate.

### Extractions 2–4: search, link review, compose

**Search.** `LibrarySearch` owns the debounce, both waves, the minimum query
length and the merge rule; each shell keeps only how it draws a result row. The
two shells lose 238 lines for its 161. This removes the arrangement that produced
the shipped defect rather than the defect: two debounces, two minimum query
lengths, two merge rules, none of them tested, in two files nobody diffs.

**Link review.** Extracting it found a defect in the *Mac* — the one platform
this audit had been treating as the reference. `beginLinkReview` gathered
proposals from `focused`; the iPad's used the open note's own collection, and its
comment said why: the proposals are character offsets into that note's text and
are looked up in that collection's index. With two collections open the Mac
reviewed a note from one against the index of the other, and reported the failure
onto the wrong collection's error banner. The iPad's copy had been fixed and this
one had not, and nothing could notice.

The re-derivation guard is now tested on both platforms, which it never was: a
proposal is a range, a range describes only the text it was computed from, and
applying accepted proposals to a note that moved would silently link different
words. Both shells had the guard; neither had a test, because it lived in a
`private func` on a view struct.

**Compose and mentions.** `runCompose` differed only in how each shell spells
"the collection the user is working in", so the scope stays a parameter and the
decision moves out. `linkMention` differed by one identifier and was otherwise
twenty byte-identical lines — including a coordinated file write and the comment
explaining why both the read and the write go off the main actor.

### What the metric is not

The count of same-named members across the two shells reads 56, up from 55 —
because `search` now appears in both, as the same shared type. Names in common
say nothing about implementations in common; the honest measure is lines removed
from the shells, which is now 5,150 against 5,298 with four shared types added
under them.

### The enforcement point moves from the test to the hook

Two parity tests already existed and both are tripwires: they fire after somebody
has written the second implementation, which means the second implementation gets
written. `.claude/hooks/platform-parity-check.py` refuses at the moment the gate
is typed — a newly added `#if os(…)` in `HelloNotes/`, or a newly created file
named `iOS*` / `Mac*` — unless the diff carries a written reason:

    // PARITY-EXEMPT: <reason>

Not forbidden, argued for. `revealInFinder` genuinely has no iOS meaning. What
the hook stops is divergence *appearing*, which is how all three of this audit's
worst defects arrived — each one added quietly, each one defended in a comment by
whoever added it, none of them noticed again for months.

Validated across six cases before being trusted: a new gate rejects, the same
gate with an exemption passes, pre-existing gates pass, a new `iOS*` file rejects,
a shared file passes, and paths outside `HelloNotes/` are left to the parity
suites.

### Every divergence defended in this audit turned out to be a substitution

Worth recording, because the pattern is the finding:

| Defended as | Actually about |
|---|---|
| "the iPad is never wide enough for a third column" | window width — which `ShellKind` already decides |
| "touch sizing, not arrangement" (`prefersTouch`) | whether a pointer is attached — `GCMouse` answers it |
| "Move to Trash" catching its own throw | whether the platform *has* a Trash for that location |
| "the Mac shell's own sidebar view" | nothing; five row behaviours had simply drifted |

In each case a platform was standing in for a fact, and the fact was available.
The one exemption that survives is `revealInFinder`, and even that is "the OS has
no such concept", not "our code should differ".

### Exemptions abolished, and the rule that replaced them

The exemption mechanism was wrong twice over. First it accepted a reason written
by whoever wanted the gate — the same self-granted permission that produced every
divergence here. Then, with the reason moved to an owner-approved registry, it
was still asking someone to adjudicate case by case. Both claimed exemptions were
rejected outright, and the right answer turned out to be mechanical.

**A platform gate must supply both platforms.** There are two kinds of
`#if os(…)` and they are not alike:

```swift
#if os(macOS)
throw error                                  // the Mac has a Trash everywhere
#else
try FileManager.default.removeItem(at: url)  // iOS does not, so remove it
#endif
```

gives both platforms the same behaviour through different calls. Against:

```swift
#if os(macOS)
Button("Reveal in Finder") { … }
#endif
```

which gives one platform a capability the other lacks. Every divergence this
audit found is the second kind; every shared type it built — `AccentContrast`,
`Trash`, `PointerPresence`, `FileReveal` — is the first. The distinction is
mechanical: **the second kind has no `#else`.** That is now the whole rule, with
no exemption path, no registry and nothing to sign off. A whole-file gate fails
it by construction, which is exactly right: `#if os(macOS)` at the top of a
739-line view with `#endif` at the bottom has no `#else` because the view exists
on one platform.

### "iOS has no Finder" was the wrong question

`revealInFinder` was the last entry on the parity allowlist, justified as "iOS
exposes no public API to reveal an arbitrary path in Files". The first half is
true; the second half asked about an API rather than about the capability. iOS
has Files, `shareddocuments:` opens it at a path, and *show me this file where it
lives* is a question both platforms answer.

`FileReveal` answers it: `NSWorkspace.activateFileViewerSelecting` on one side,
`shareddocuments:` on the other, one `revealInFileManager` action above them, and
one title — "Reveal in Finder" or "Reveal in Files" — from a shared constant, so
the menu bar, the command palette and both sidebars spell it the same way. The
action is nil where the file cannot be revealed at all, so the item disables
rather than doing nothing.

`PlatformParityTests.platformSpecific` is now empty, and the file says it is
meant to stay that way.

### One selection mechanism, and the floating bar goes

`SelectionActionBar` was a floating panel over a macOS selection, positioned by
an `onSelectionChange` hook UIKit did not have. iOS put the same three vault
actions — Link to…, Find Related, Ask Your Library — into the system edit menu
through `selectionMenuItems`, which AppKit did not have. Two implementations of
one feature, each free to drift, and they had: "Rewrite with AI…" reached only
the Mac's until this session, and the vault actions reached only the iPad's.

Both platforms already show a menu on a selection — iOS floats the system one,
macOS opens the context menu — and both already carried Rewrite through it. So
`selectionMenuItems` becomes the one mechanism: `EditorMenuItem` moves out of the
UIKit-gated file, `MarkdownTextView.menu(for:)` builds the same items in the same
order, and `SelectionActions.menuItems(for:)` is the single builder both hosts
call. Deleted: the 46-line bar, the `onSelectionChange` hook, `reportSelection`,
`selectionEndRect`, and the two `@State` fields that positioned the bar.

This is a visible change on the Mac — the actions are now a right-click rather
than a bar that appears on selection. It is the unification that adds no code;
the alternatives (a floating bar on both, or the actions in the toolbar proper)
are equally valid resolutions of the same divergence and cost more to build.

The editor hosts' builder surfaces now share 15 methods, with the remainder being
framework conformances (`makeNSView`, `textViewDidChange`) and proxy methods
rather than host-facing hooks — which is what the two hosts were waiting on.

### The editor hosts merge

`NewEditorHost` (283 lines, macOS) and `iOSLiveEditor` (474, iOS) did the same
job: build an `EditorDocument` from the note buffer, feed the model back at save
cadence, rebuild on note/font/appearance change, patch in place on external
reload. Same shape, the same comments in places, and not the same code.

They had drifted, and on all three differences the **iPad's** was correct:

- `onEdit` captured `built` *strongly* on the Mac — a document retaining itself
  inside its own callback, which no eviction from the store could free. iOS took
  it `[weak built]` and said why.
- `onDisappear` **cancelled** the sync debounce on the Mac and **landed** it on
  iOS. Cancelling drops up to half a second of typing at a note switch, which is
  the moment it is most likely to be holding something.
- Nothing cancelled the inline-completion task on the Mac when the host went away
  or the note changed.

So `EditorHost` is the iPad's implementation, plus the two things only the Mac's
had: `isEditable` (Preview has no caret, so syntax stays rendered) and the
`.hnEditorFocusStart` handover that brings the caret back down from the inline
title. It contains **no platform gate and no platform API**. Three things
genuinely differ and all three sit below it: `ExternalURL` opens a URL,
`EditorProxy.resetUndo` is a no-op on AppKit (undo lives on the document there,
and UIKit resolves `undoManager` up the responder chain so its stack outlives a
wholesale replacement), and the representable under `MarkdownEditorView`, which
is the platform boundary itself.

Two supporting additions, each a half the other platform was missing: the AppKit
proxy gained `resetUndo` so the host can call it unconditionally, and the UIKit
proxy gained `focusFirstLine(atX:)` — the other half of `onCaretEscapeTop`, so
the title and the body are one flow on iPad as they have been on the Mac.

`HelloNotes/` is down to three platform-named files: `MacContentView`,
`iOSContentView` and `iOSNoteEditorPane`, plus `NoteOutlineList` as the last
whole-file gate that is not one of them.

### No allowlists either

Exemptions were withdrawn, and two allowlists survived the withdrawal by not
being called that:

- `PlatformParityTests.platformSpecific` — a dictionary of commands permitted to
  exist on one platform. It had been emptied when `FileReveal` retired its last
  entry, but an empty allowlist is still an allowlist: the next divergence has
  somewhere to be written down. Deleted, along with the test that policed it.
- `ShellComplianceTests.mayDiffer` — the four slot names `sidebar`, `pane`,
  `inspector`, `compact`. These genuinely do differ, being the two shells'
  presentations, which is why `AdaptiveShell` takes them as closures at all —
  but naming them in a set is an exemption list by another name. Replaced with
  a structural test: an argument passed as `{ … }` is the caller's own view, and
  an argument passed any other way is configuration both callers must agree on.
  No names, nothing to add to.

Verified after both removals by reinstating the `prefersTouch: true` hard-code
and watching the guard name it:

    prefersTouch: macOS `PointerPresence.shared.prefersTouch` vs iOS `true`

### One exporter

`EditorExport` and `iOSEditorExport` had byte-identical public signatures —
`exportHTML`, `exportPDF`, `printNote`, all `(markdown:title:)` — and no
relationship in the type system, so every caller had to know its platform to
name the type. That is how `NoteMenuActions.exportHTML` came to be wired to one
enum on the Mac and a different one on iPad, each free to diverge in what it
produced. They already had: the page margin was 48pt on macOS and 36pt on iOS.

One enum now, with the platform inside each entry point — a save panel and
`NSPrintOperation` against a share sheet and `UIPrintInteractionController` —
and both rendering the same GFM HTML, which is what actually decides how the
file looks.

### One file viewer

`FileViewerView` and `iOSFileViewer` had drifted into disagreeing about what
previewing a file *is*. The Mac dispatched on `CollectionFile.kind` — PDF to
PDFKit, CSV to a table, the rest to Quick Look — and drew a bottom bar with
"Open in default app" and "Reveal in Finder". iOS took a bare `URL`, sent
everything to Quick Look, and had no bar: so on iPad a PDF got Quick Look's flat
rendering instead of a continuous scrolling reader, and there was no way to hand
the file to another app at all.

They also disagreed about *when the bytes arrive*, and this is the part worth
recording. The Mac was handed `isPlaceholder` / `prepare` by the shell, because a
collection that mirrors a provider knows how to fetch its own files. iOS
re-implemented hydration inside the view against iCloud's ubiquitous-item
status. Neither is wrong and both are needed — a direct-API collection hydrates
through its provider, a Files-backed one through iCloud, and either shell may
hand over either kind. The merged view uses the callbacks when it has them and
falls back to the ubiquitous-item watch when it does not, on both platforms. The
iPad gained provider hydration; the Mac gained the iCloud fallback.

PDFKit ships on both, so even the PDF path is one decision behind an `#else` —
the three representables (PDF, Quick Look, and the shared `ExternalURL` for
"open in the default app") are the only platform-shaped code left in the file.

### One settings screen's worth of controls

`AppearanceSettingsView` (a Preferences tab) and a stretch of `iOSSettingsView`
drew the same four groups — Appearance, Accent colour, Text size, Text width —
over the same `AppearanceSettings` object. That duplication is what earlier in
this audit had cost three settings: Reading width, Editor width and Wrap guide
existed on the Mac's screen and not on the iPad's. They were "fixed" then by
adding a second copy of each control, which closed the gap and left the reason
for it in place.

`AppearanceSettingsSections` is that reason removed. What stays per-screen is the
container — a Preferences tab against a `NavigationStack` — and one layout
parameter: the Mac's accent row is a line of swatches, the iPad's an adaptive
grid, because 44pt targets do not fit on one line at sheet width. That is a
width decision, taken by the caller, not a second set of controls.

`AppearanceSettingsView` is 27 lines; `iOSSettingsView` lost 108.

### The sidebar's contents, decided once

The tint question — whether `NoteOutlineList` still needs to be an
`NSOutlineView` because "SwiftUI's List forces the system-blue highlight" —
blocks *deleting* the AppKit path. It does not block unifying, and treating it
as a blocker was a category error: `FileViewerView` already shows the shape. One
view, one API, two representables behind an `#else`. The decision is shared; only
the widget differs.

So `NoteOutlineItem` moves out of the macOS-gated file (nothing in it is
platform-shaped: an id, a kind, children) and `SidebarTree.roots(_:)` becomes the
one construction. It is the Mac's, because the Mac's was complete: pinned places
above every collection, search replacing the tree by result groups carrying
snippets *and* matching attachments, a tag filter flattening to bare notes with
no group row.

Those are exactly the five behaviours the iPad's tree had drifted away from, each
of which was fixed earlier in this audit by editing the iPad's copy. Six tests
now pin them over the shared construction — tests that could not exist while the
tree was built by a `private func` on each shell, which is the whole reason
five behaviours could drift without anything failing.

Remaining on the sidebar: the iOS renderer still walks `CollectionTreeNode`
rather than the shared `[NoteOutlineItem]`, so this is the model unified and the
rendering not yet. That is the next step, and it needs no answer about tint.

### …and the iOS renderer walks them

`SidebarItemRow` replaces `CollectionTreeRow`: one recursive view over the shared
`[NoteOutlineItem]` instead of a second walk over `CollectionTreeNode` composing
its own sections. Both sidebars now derive their structure from
`SidebarTree.roots`, and the folder id is the folder's absolute path on both —
which is also the expansion key, so `folderActions` no longer needs a node to
open the folder it just created a note in.

A recursive renderer has to be a `View` rather than a `@ViewBuilder` function:
an opaque `some View` that calls itself is defined in terms of itself and does
not compile. `CollectionTreeRow` had discovered the same thing.

What is left of the split is the widget: `NSOutlineView` against SwiftUI `List`.
Same shape as `FileViewerView`'s two representables — and the tint question,
which decides whether the Mac keeps its native outline, is now a question about
one view rather than a blocker on the sidebar's behaviour.
