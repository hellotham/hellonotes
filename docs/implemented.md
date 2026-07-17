# HelloNotes — Implementation history

> The archive of *how HelloNotes was built*. The other docs describe the **current**
> state; this one records the journey — the milestone sequence, the greenfield editor
> rewrite, the retired `swift-markdown-engine` fork, the GFM full-fidelity work, and the
> notable fixes worth remembering. It consolidates the former `implementation-plan.md`,
> `markdown-engine-strategy.md`, `editor-rewrite.md`, and `editor-parity.md`.

**Current status:** v1.0 shipped (Milestones 0–13). Builds clean on macOS + iOS; the
editor package suite (`swift test --package-path Packages/NotesEditor`) is **83 tests /
9 suites** green, plus the app unit tests. The editor is the in-repo
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
- **editor-M5** *(future)* — iOS `UITextView(usingTextLayoutManager:)` sibling on the shared kernel (the only remaining tracked editor gap).

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
