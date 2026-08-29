# HelloNotes — Implementation history

> The archive of *how HelloNotes was built*. The other docs describe the **current**
> state; this one records the journey — the milestone sequence, the greenfield editor
> rewrite, the retired `swift-markdown-engine` fork, the GFM full-fidelity work, and the
> notable fixes worth remembering. It consolidates the former `implementation-plan.md`,
> `markdown-engine-strategy.md`, `editor-rewrite.md`, and `editor-parity.md`.

**Current status:** `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in the project are
**1.3.2 / 8** as of this doc pass (re-check `project.pbxproj` — this line goes stale
every release, which is exactly how it drifted to "v1.3" while the project moved
two point releases past it). v1.3 was §22; **§23–27 cover everything since**, which
this summary previously didn't mention at all: the 1.3.1 patch (§23), the iPad
editor actually becoming usable in 1.3.2 (§24; see
[release-notes-1.3.2.md](release-notes-1.3.2.md)), and further hardening including
the `MacContentView`/`iOSContentView` merge into one cross-platform `ContentView`
(§27). v1.2 shipped 2026-08-15 (see [CHANGELOG.md](../CHANGELOG.md) for the
user-facing notes and §20 below for the batch); v1.0 was Milestones 0–13, plus the
deeper Apple-platform integration (§10 and [native-roadmap.md](native-roadmap.md))
and **cloud storage** (§11–12, [cloud-native-roadmap.md](cloud-native-roadmap.md)).
Builds clean on macOS + iOS in **both Debug and Release** (§13 — Release is checked
explicitly now, because a Release-only optimizer crash once broke every archive
while Debug stayed green); ships both as a signed, notarized universal DMG **and**,
now that both platforms are live in App Store Connect, via TestFlight/App Store
(macOS + iOS, one app record — see [production.md](production.md)). The editor
package suite (`swift test --package-path Packages/NotesEditor`) and the app's own
unit tests have both grown well past the **83 tests / 9 suites** and **63 app unit
tests** this line used to cite — `Packages/NotesEditor/CLAUDE.md` and the repo-root
`CLAUDE.md` carry current counts from an actual test run; trust those over any
number restated here. The editor is the in-repo
[`Packages/NotesEditor`](../Packages/NotesEditor); the markdown-engine fork is
removed.

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

### The OS-facility singles

Three files existed on macOS and simply not on iOS. Two of them are genuine
platform facilities and one was a real behavioural gap hiding among them.

**`TerminationGuard` was the gap.** HelloNotes autosaves on a debounce, so at any
moment up to half a second of typing exists only in an editor's buffer. macOS
asks an app whether it may quit, and this held the quit open until every
registered flush had run. iOS never asks — an app is backgrounded and later
killed without a second word — so the file was `#if os(macOS)` end to end,
`TerminationGuard.current` was **nil on iPad**, and every registration the iOS
shell made was a no-op. `iOSNoteWindowView` had grown its own `scenePhase` flush
to compensate, which covered the standalone window and left the main window's
open tabs with no drain at all.

Both platforms have a moment where "you are about to lose the buffer" is known —
`applicationShouldTerminate` on one, `willResignActive` on the other — so the
registry and the bounded five-second drain are shared and only that moment
differs. The iPad's tabs register now, and the note window uses the shared guard
instead of its own half-measure.

**`GlobalHotKey` and `ServicesProvider` are genuinely macOS.** A background iOS
app cannot register a system-wide hot key, and the Services menu's equivalent —
offering "New Note from Selection" to other apps — is a Share extension, a
separate target rather than an implementation of this type. Both now have an
`#else` holding a no-op that says so. A no-op that exists beats a type that does
not: the call site is one line on both platforms and the reason lives with the
thing rather than in a `#if` wrapped around the caller.

### One change-observer, and the Git status iPad never refreshed

`FileWatcher.swift` (FSEvents, macOS-gated) and `DirectoryPresenter.swift`
(`NSFilePresenter`, ungated but used only on iOS) merge into `DirectoryObserver`.
`Collection` already had one `startObserving` / `stopObserving` pair over them —
the right shape — and underneath it two properties, two callbacks and two
handlers. The handlers had drifted: the macOS one refreshes Git status when
`.git` churns, because an external pull moves the branch and the change count
and the status bar would otherwise assert the old ones indefinitely. **The iOS
one did not**, so a `git pull` on another device left an iPad's status bar
permanently wrong.

The event is shared and the mechanisms are not. FSEvents genuinely reports more
than a presenter can — which paths changed, a moved root, an unmounted volume, a
dropped batch — and `DirectoryEvent` is a superset rather than the coarser
vocabulary of the two, because levelling down would throw away information the
Mac can act on. A presenter emits `.itemsChanged([one])` or
`.unspecifiedChange`; one handler treats each case as the rescan it always meant.

### The rule got more precise

The hook rejected `DirectoryObserver`'s own `#if os(macOS) import CoreServices
#endif`. That is the rule being literal rather than a divergence: naming a
framework that exists on one platform grants no capability by itself, and the
code that uses it is checked on its own terms. Gates whose body is nothing but
`import` lines are no longer one-sided gates.

This is a refinement, not an exemption — there is nothing to argue and nothing
to record, because an import-only gate cannot make the two platforms behave
differently. Re-validated after the change: an import-only gate passes, a real
one-sided gate still rejects, and a gate mixing an import *with code* still
rejects.

### macOS was corrupting Markdown source

Merging the source editors found the sharpest defect of the audit, and this time
on the Mac.

Markdown mode shows the note's *literal* source. iOS had `iOSSourceEditor` — a
`UITextView` with `smartDashesType`, `smartQuotesType` and `smartInsertDeleteType`
all `.no` — and its header explains why: `---` under a table header becomes an em
dash, `"` becomes a curly quote, and the file on disk then holds characters no
Markdown parser recognises, so a table silently stops being a table.

macOS was still on SwiftUI's `TextEditor`, whose `NSTextView` follows the user's
system substitution settings. Same corruption, on the platform where a
hand-written table is most likely to live, in the mode whose entire purpose is
showing what is actually in the file. iOS found the bug and fixed its own copy;
nothing carried it across.

`SourceEditor` is one type with two representables, and the settings are a named
`makeSourceOnly(_:)` on each side rather than a run of assignments inside
`makeNSView` — so the reason the type exists can be asserted instead of read. The
test starts from a text view configured the way the *system* would leave it, so
it fails if the call stops being made rather than passing on a view that happened
to default correctly.

### The editor pane merges, and takes 180 lines of the Mac's with it

`NoteEditorPane` — banners, inline title, and the four view modes with their
per-mode width rules — is now one view that `NoteEditorView` (the Mac's editor
column and its note window) and `iOSNoteEditorPane`'s callers both use.
`NoteEditorView` goes from 917 lines to 776, and what remains of it is this
window's own chrome: the find bar, the bottom bar, the mode sheets, and the
commands that act on the open note.

Three things surfaced in the merge:

- **The Mac had no `SourceEditor`** — see above; Markdown mode was substituting
  typography into source.
- **The iPad had no downloading banner.** `editor.isDownloading` is raised on
  both platforms and only the Mac drew it, on the platform *less* likely to be
  looking at an online-only note.
- **`MarkdownWebView` was a duplicate of `GFMPreview`**, which has been
  cross-platform since it was written. The app carried a second `WKWebView`
  wrapper over the same renderer, on one platform, because `GFMPreview`'s
  `markdown:` initialiser had no `fontScale` — so one caller worked around it
  with `GFMRenderer.page` and the other wrote a whole view. The parameter exists
  now and both use the package's.

The split layout is the one genuine platform branch inside the pane:
`HSplitView` / `VSplitView` give the Mac a *draggable* divider and exist only
there. The arrangement — side by side in a landscape column, stacked in a
portrait one — is shared; the splitter is not.

### `NoteEditorView` and the note windows go cross-platform

Once the pane was extracted, the only AppKit left in `NoteEditorView` was three
members nothing called — `blockRenderAdapter`, `pasteImage` and `smartPaste`, all
of which had moved into `EditorHost` when the hosts merged. Removing them left a
file with no platform API in it at all, and the gate came off. `FindReplaceBar`
went the same way: pure SwiftUI over bindings, gated for no reason left standing.

That matters beyond tidiness. **The iPad's note window had no find bar, no mode
switcher and no mode sheets**, because the view carrying them was macOS-only —
so "Open in New Window" on iPad opened a strictly lesser editor than the same
command on the Mac.

`NoteWindowView` is one view now. Its two copies had drifted the way the rest
have: the Mac's `openWikiLink` compared titles while the iPad's, written four
weeks later, used the link graph — so a `[[Alias]]` opened a window on iPad and
did nothing on the Mac. Both go through `WikiLinkNavigation`, with
`createOnMiss: false`, because a link followed in a single-note window should not
silently write a new note into the vault.

What is left platform-shaped in it: a minimum window size and
`navigationDocument` (which restores the title-bar proxy icon) on one side, a
`NavigationStack` to hang a title bar off on the other.

### iPad had no large-folder warning

`Library.openChecking` probes a folder for a second before opening it, and warns
when a full second was not enough *and* there is already a lot there — offering
"Add Anyway", "Choose a Subfolder…" or Cancel. Adding a huge folder is never
blocked; it is the user's folder. The warning exists so the wait is not a
surprise, and so the far more common intent ("I meant my Notes subfolder") has
somewhere to go.

The whole flow sat inside `#if os(macOS)`, because the confirmation was an
`NSAlert` — a model presenting its own modal. So **iPad had none of it**: picking
a 2,000-note vault there opened it with nothing said, on the platform where the
wait is longest and where the picker is most likely to land on a whole iCloud
Drive folder. Its own import path called `library.open` directly and never went
near the check.

`Library` publishes the question now and `LargeFolderAlert` presents it, with the
answer travelling back through the continuation `openChecking` is waiting on.
Both shells apply the modifier and iPad's picker routes through `openChecking`,
so the estimate, the threshold and the wording are one implementation. Four tests
cover the judgement and the message — the part that was unreachable while it
lived behind a modal button press.

The same publish-rather-than-present move fixes the two open panels:
`requestOpenCollections` and `requestOpenCloudFolder` are one function each, with
iOS publishing a `FolderPickRequest` the shell answers with the picker it already
owns. And `CloudProvider.installedClients()` returns empty on iOS rather than not
existing — the Files picker lists whichever File Provider extensions are enabled,
which is the same out-of-process answer the Mac's panel gives, so the caller's
job is to offer the picker rather than a list it built itself.

### Settings, and a tab bar that ignored its own contract

**Settings.** `GeneralSettingsView.swift` (a tabbed Preferences window) and
`iOSSettingsView.swift` (a sheet) become one `SettingsView.swift`. The controls
were already shared; what was left in each file was *arrangement*, and that is
where the two genuinely differ — macOS Preferences is a tab bar of panes and iOS
Settings is one scrolling list. Putting both in one file with an `#else` says
that out loud and stops a setting being added to one arrangement and forgotten in
the other, which is exactly how Reading width, Editor width and Wrap guide came
to be Mac-only.

One thing there was not arrangement: **Acknowledgements had no iOS route.**
`AcknowledgementsView` has never been gated — it was only ever placed in the
Mac's tab bar, so the licences and credits this app ships were unreachable on
iPad. It is a row in Settings there now.

**The tab bar** had drifted three ways. Its close button carried an accessibility
label on iPad and none on the Mac, so VoiceOver announced a row of unlabelled
buttons there. Its selection tint was `selectedContentBackgroundColor` on one
side and `.selection` on the other. And neither read
`ShellContext.tabBarHeight` — the contract defines it as
`prefersTouch ? 44 : 32` and states "tab bars are never removed; they only change
height (HIG: 44pt touch)", while the Mac hard-coded 30 and iPad used padding. The
one number the contract states about this view was consulted by nothing, which is
the same shape as `sortOrder`: a rule with no reader.

### The four small ones

**`InlineTitleField`** now exists on both platforms. `InlineNoteTitle` used to
choose between an `NSTextField` representable and a SwiftUI `TextField` with an
`#if` — and the two had different *capabilities*, which is fine, and different
*contracts*, which was not: the iOS branch ignored `focusRequest` entirely, so ↑
from the note's first line did nothing on an iPad keyboard until this audit.
One type, two implementations, four parameters both honour. The column genuinely
does not cross the seam on iOS — SwiftUI cannot place a caret at an x offset —
and that is now a documented property of one type rather than an absent feature
of a different one.

**`FolderPicker`** gains a Mac half: an `NSOpenPanel` run when the view appears,
rather than a representable, because AppKit's panel is a window and not a view to
embed. It is presented the same way — in a sheet — so a caller asks for a folder
identically on both platforms instead of choosing between a view here and a
method on `Library` there.

**`MLXProvider`** exists on both and answers `.unsupported` off the Mac, so
`ProviderFactory` has one call site rather than a gate. Whether MLX *could* run
on an M-series iPad is a dependency question rather than a code one — MLX Swift
targets Apple silicon generally and this project's package is not configured for
iOS — and the type says so where the answer belongs.

**`ChromeProbe`** keeps an empty `#else`, and that is the point: the problem it
measures — a split-view column painting up into the titlebar because AppKit keeps
the content view full height — has no iOS analogue. A reader who comes looking
for "why is this macOS-only" gets an answer instead of inferring one from a gate.

*Note for whoever owns this file: `ChromeProbe`, `TitlebarClearance`,
`TitlebarInsetReader` and `ChromeProbeLog` have no callers anywhere in the app.
The header's record of what has been ruled out is worth keeping either way; the
code may not be.*

### The iPad's graph was a lesser graph

`GraphWindowView` was inside `AuxiliaryWindows.swift`, gated to macOS, and the
iPad drew its own `graphSheet`: `GraphData.build(for:)` with every parameter left
at its default. Both sides carried a comment saying the *builder* was shared —
"so the two cannot disagree about what is connected" — which was true, and beside
the point. Everything around the builder disagreed:

- **Scope.** The Mac shows the whole collection or just the notes within *n*
  links of a focused one. iPad had only the whole collection.
- **Depth.** One to three links, and iPad took the default with no control.
- **The cap.** A force-directed layout of every note is O(N²), so past
  `GraphData.maxNodes` the whole-collection view keeps the most-connected notes —
  and the Mac says so in an overlay. **iPad silently showed a subset of a large
  collection's graph with nothing to indicate it.**

`GraphPane` is the graph on both, with `onOpen` supplied by the caller: a
separate window has to ask the main one to open a note, and a sheet can simply
select. The window's minimum size stayed with the window rather than becoming a
gate inside the pane — the hook caught that when I first put it there, correctly:
a minimum belongs to a scene, and a sheet is given its size.

`GraphPane` contains no platform gate at all. The scope and depth controls are a
`.toolbar`, which lands in a window's toolbar on one platform and a sheet's
navigation bar on the other, without either shell having to know.

### Two `#if`s side by side are an if/else written the long way

`OpenQuicklyView` had `#if os(iOS)` for its keyboard hints and, thirty lines
later, `#if os(macOS)` for its palette chrome. Both are one-sided, and together
they cover both platforms — which reads as independent, and is the shape where
one gets updated and the other does not. They are now two small
`#if/#else` view extensions with names: `plainSearchField()` and
`paletteChrome(dismiss:)`.

### Mind map, Ask Library, and a prompt written twice

**The mind map's section jump did nothing on iPad.** `MindMapView.onShowSection`
defaults to a no-op, the Mac passed it, and the iPad's sheet did not — so tapping
a heading node opened the note and scrolled to that section on one platform and
did nothing at all on the other. A silently defaulted closure is the quietest way
for two call sites to disagree: no error, no warning, and nothing on screen
except a tap that does not work. `MindMapPane` is the map on both now, with the
text a parameter — a window has no editor and reads the file, a sheet is over the
open note and uses the live buffer, which is what makes the map reflect unsaved
edits.

**Ask Library was seeded two different ways.** The Mac wrote
`library.requestAsk("Explain this, using my notes: …")` and opened its window;
iPad wrote the same sentence into a local `chatSeed` and opened a sheet. Two
consequences: the prompt existed twice and could differ, and *anything else* that
called `requestAsk` reached the Mac's chat and not the iPad's — the pending
question had one reader. `Library.askAboutSelection(_:)` owns the sentence, and
iPad's sheet is `LibraryChatWindowView`, seeded from the same pending question.

`AuxiliaryWindows.swift` has no gate left: nothing in it was ever AppKit. It
holds the scene wrappers — the window minimum, reading a note off disk, asking
the main window to open something — around panes both platforms share.

### A Mac window in a Stage Manager tile cannot reach its notes

`ShellKind` resolves `.compact` at 250pt on *either* platform — it is in the
contract's own scene table as "Stage Mgr tiny" — and at that size the iPad got
the compact architecture (a tab bar of places, the open note as a strip above it)
while the Mac's `compact:` slot got `EditorPaneContainer { editorColumn }`: **the
editor alone, with no way to reach another note at all.**

Decision 9 wrote that as "degrade to the editor rather than an error", which was
right when there was no compact shell to degrade *to*. There is one now, and
`ShellComplianceTests` could not see the difference because it compares the two
`AdaptiveShell` call sites and skips closures — the slots are exactly where this
divergence lives.

`CompactShell` is ungated. It uses no UIKit types but did use three iOS-only
SwiftUI modifiers — `fullScreenCover`, `.topBarLeading` and
`navigationBarTitleDisplayMode` — each of which now has a macOS equivalent in the
same file. Worth recording how that was found: a grep for `UI…` type names
reported the file as portable, which was the wrong question; the compiler asked
the right one. An instrument that answers a near-miss of your question is worse
than no instrument, and this is the third time in this audit that has bitten.

**What is fixed is that nothing stops the Mac using it. What is not fixed is
that the Mac has nothing to fill it with:** `iOSContentView` supplies four places
(`collectionsList`, `noteList`, `tagList`, `aiPlace`) and `MacContentView` has no
equivalent of the last two — its tags live in the inspector and its AI actions in
the menu bar. Building them is designing new Mac UI rather than unifying existing
code, which is a decision for the project's owner, not a repair. It is recorded
here so the choice is visible rather than lost.

### The Mac gets the compact shell, and the guard learns to see slots

`MacContentView` now fills its `compact:` slot with `CompactShell`, so a window
the OS forces below the compact threshold gets the same architecture an iPad does
at that size: a tab bar of places, the open note as a strip above it.

Nothing was designed for it. Every place is a view this shell already had — the
outline answers both Notes and Search, because `buildOutlineRoots` replaces it
with result groups while a search runs; the inspector owns Tags; and the AI place
is `AIPlaceList`, extracted from `iOSContentView` and built from the same
`AIActions` both shells already hand the menu bar. That extraction *was* the
blocker: the AI place being a `private var` on one shell is why the other had
nothing to put in that tab and therefore no compact shell at all.

**And the guard could not see it.** `ShellComplianceTests` compares the two
`AdaptiveShell` call sites and skips closures — right for the sidebar and the
pane, where an `NSOutlineView` against a SwiftUI `List` is the presentation
difference the slots exist for, and wrong for `compact`. Compact is not the wide
shell rearranged; it is a different information architecture, and `CompactShell`
*is* that architecture. A shell rendering something else at 250pt is not laying
out differently, it is not being compact. The test now follows the one hop each
shell puts between the slot and the view and asserts both reach `CompactShell` —
verified by restoring the old degraded slot and watching it fail with the
offending expression quoted.

That is the second time a guard I wrote had a hole where the defect was. Both
times the hole was a deliberate exclusion — "skip closures", "skip imports" — and
both times the exclusion was right in general and wrong for one member of the
set it covered.

### One sidebar API, two widgets

`NoteOutlineList` is now one type on both platforms: an `NSOutlineView`
representable on macOS, a SwiftUI `List` of `SidebarItemRow` on iOS, behind one
signature that both shells call identically. That is the same shape
`FileViewerView` uses for PDFs and Quick Look — the decision is shared and only
the widget differs — and by this point *everything* around the widget already
was: `SidebarTree.roots` decides what is in the tree, `NoteRowContent` decides
what a row says, and the menus and drop targets are the shell's on both.

Two parameters are accepted by the AppKit branch and ignored there:
`expandedFolders` and `collapsedCollections`. `NSOutlineView` owns its own
expansion and restores it across a reload; SwiftUI has no such memory and needs
the shell to hold it. They are accepted rather than removed so the call site is
one call site — the alternative is two signatures, which is where this whole
audit started.

The tint claim in the file's header — that SwiftUI's `List` forces the system
selection colour, which is why the Mac keeps an `NSOutlineView` — remains
**untested**. It no longer blocks anything: the API is one either way, and if the
claim turns out to be stale the AppKit branch can be deleted without touching a
single call site. Settling it needs `screencapture -l` on a running window.

### iPad had no word count and no save status

The Mac's detail column is `NoteEditorView`; the iPad's was `NoteEditorPane`. The
pane is banners, the inline title and the four modes. The *view* is the pane plus
this window's chrome — the find bar, the mode sheets, and a bottom bar carrying
the word count, the save status and the Git change count.

iPad had none of that bar. `DocStats` carried the evidence in a comment — "the
Mac's `DocStats`, minus the word count that nothing on iOS shows" — which
described the gap and read as its justification. Nothing on iOS showed it because
nothing on iOS drew the bar that shows it.

Both platforms render `NoteEditorView` now, so the iPad gains the word count, the
save indicator, the Git change count, the find-and-replace bar and the
front-matter properties button. This is a visible change to the iPad's editor:
there is a status bar along the bottom of the note that was not there before.

Still duplicated after this step: iOS keeps its own Mermaid, Slides and Rewrite
sheet state, which `NoteEditorSheets` now also provides. They do not conflict —
each set of buttons drives its own — but they are two of the same thing, and
collapsing them means routing the iPad's menu through the notifications
`NoteEditorView` already listens on.

---

## 28 · One library, one vocabulary (2026-08-25)

> **The problem, stated as the user did:** *"The + toolbar is misleading… What
> happens when we have 100 cloud providers implemented?"* and, later, *"our
> terminology should always be related to collections."*

The ways into a library had accumulated one at a time. The sidebar's `+` had
grown eight entries of four unrelated kinds — two of which were **the same
command listed twice** (`Open Collection` and `Open Obsidian Vault` both called
`requestOpenCollections()`, and that request opened in the Obsidian directory,
so neither the label nor the behaviour distinguished them). Four surfaces drew
overlapping subsets of the set under different names, and the first-run screen
offered two of the ways in while the toolbar offered eight.

The fix is structural rather than cosmetic: the set of ways to add a collection
is **data** (`AddCollectionActions.options`), and menus, cards and the command
palette are renderings of it. "The welcome screen shows what the toolbar shows"
became a property of the code. The palette had already drifted twice — still
naming a command the menus had renamed, and never gaining two others at all —
and now generates its rows from the same list.

The vocabulary is the library's: **New Collection** (empty folder / Git
repository) and **Open Collection** (from folder / iCloud Drive / Obsidian vault
/ cloud / repository). `New Repository` stopped being a peer of collections and
became one way of making one.

### Where a distinction belongs

Two kinds of cloud folder exist — one the provider's own app already syncs to
the device (no sign-in, works offline) and one reached over the provider's API
— and the menu carried both, briefly under a parallel pair of names. Several
namings were tried and each failed on the same point: *synced* is true of both
(the difference is **who** syncs), and *local/remote* is one axis but still asks
a question a menu item cannot answer.

The resolution was to move the fork rather than name it better. **Whether a
provider is set up on this device is a fact about the device**, which
`CloudProvider.installedClients()` can state and a menu item can only ask. So
the menu carries one plain `from Cloud…`, and **Manage Cloud Collections** —
which has room for a subtitle — names the providers it found. That also answers
the hundred-providers question: the locally-synced half is *one row forever*
regardless of how many providers exist, and the only list that grows is the one
of providers we have written OAuth for, which gets a search field.

### Several accounts on one service

`CloudBrowser` had one case per provider and `RemoteTokenStore` keyed the
Keychain by provider name, so a personal and a work OneDrive were one entry with
one credential: **the second sign-in silently overwrote the first**. Accounts
now have generated identities, the Keychain is keyed by those, and the manifest
of a mirrored collection records *which account* it came from — a provider name
alone can no longer identify credentials.

### Four defects found by using it

- **A cloud collection added over a provider's API stopped syncing after one
  relaunch.** `persist()` wrote it to both the plain-path list and the
  remote-cache list; the plain restore won, `restoreRemoteCollections` saw the
  id already present and skipped it, and the collection lost its mirror
  permanently — becoming a stale local copy with nothing said.
- **An account was recorded before it signed in**, so every cancelled OAuth left
  a phantom in "Connected Accounts". Then, once that moved after the sign-in, it
  was placed after an `await` inside a `.task` — which is cancelled when the
  sheet closes, so it never ran and left a token in the Keychain that no listed
  account owned.
- **The same account appeared twice in one `List`** under the same id, once as a
  source and once as a managed account. Duplicate identities make SwiftUI reuse
  one row's content for the other, so a connected account rendered as its "From
  …" twin — deterministically, surviving every relaunch, which is what made it
  look like stale data.
- **OneDrive was never detected as installed**: it ships as
  `com.microsoft.OneDrive-mac` and only `com.microsoft.OneDrive` was checked. A
  missed bundle id is invisible — the app simply never mentions a provider the
  user has.

### Credentials belong in Settings

Git accounts had no macOS route but the inspector's Git pane, which needs a
repository already open — so the credentials needed to *clone* a repository were
behind having cloned one. AI keys had the mirror-image gap: a Settings tab on
macOS, nothing in iOS Settings. Both are now in Settings on both platforms, and
**Acknowledgements** moved beside About, since nothing in it is a preference.

---

## 29 · Ask the provider (2026-08-27)

> **The problem, stated as the user did:** *"How are you deriving the list of
> models for Gemini. Is this dynamic or a fixed list? Your list is very old"*,
> then *"I think we need to declare Gemini as 1m context size. Why aren't all
> these parameters configurable?"*

The list was fixed — `ModelCatalog.suggestedModels`, a hand-written array of
strings per provider, still offering `gemini-2.0-flash` and `gpt-4o` a
generation and a half after both were superseded. Nothing in the app had ever
asked a provider what models it had.

### Raising the number would have changed nothing

The obvious fix — declare Gemini at 1M — was a no-op, and finding out why
located the real defect. `IntelligenceNeeds.inputBudget` served two
contradictory purposes:

- `satisfied(by:)` read it as a **floor**: the least a provider must offer for
  the feature to be worth showing.
- `IntelligenceService.budget(for:)` read the same number as a **cap**, via
  `max(500, min(feature.inputBudget, capabilities.inputBudget))`.

The floor was always the smaller operand, so the provider's number never once
mattered. Ask Library, declared at 12,000, sent 12,000 characters — about 3,000
tokens, or **0.3% of a 1M-token window** — and would have gone on sending 12,000
however large the provider's declared budget grew. Summarising a 20,000-character
note summarised its first 4,000 and said nothing about the rest; that was never a
judgement about the feature, it was the eligibility floor being read as a cap.

`minimumBudget` and `inputCeiling` are now separate fields. Every content-bearing
feature declares a floor and **no ceiling**, so what the provider can hold is the
only limit. Ghost text keeps a ceiling, for a reason about the feature rather
than the provider: it races a keystroke, so a wider window is a slower answer.

### Fourteen providers answer, eight of them fully

`LLMProvider` gained `availableModels()`. Support is genuinely uneven, so the
mapping is written out per provider rather than pattern-matched:

| | Lists models | Reports a window | Also reports |
|---|---|---|---|
| Gemini | `/v1beta/models` | `inputTokenLimit` | `maxTemperature`, `topP`, `topK` |
| Anthropic | `/v1/models` | `max_input_tokens` | `capabilities.structured_outputs` |
| OpenRouter | `/models` | `context_length` | `supported_parameters` |
| Mistral | `/models` | `max_context_length` | `capabilities.function_calling` |
| Groq | `/models` | `context_window` | `max_completion_tokens` |
| Together | `/models` | `context_length` | `type` |
| LM Studio | `/api/v0/models` | `max_context_length` | `type` |
| Ollama | `/api/tags` + `/api/show` | `<arch>.context_length` | `capabilities` |
| OpenAI, xAI, DeepSeek, Cerebras, Perplexity | yes | — | — |
| Apple, MLX | — | — | in-process |

**The mapping is an allow-list of key names, and xAI is why.** Its listing
carries `long_context_threshold`, which is the token count above which input is
billed at a higher rate — not the context window. Anything scooping up "the field
with `context` in the name" would report 200k for a model holding far more, which
is a filed bug in another client. A key appears in `OpenAIModelEntry` only where
it has been checked to mean what this app wants it to mean.

Two asymmetries had to be reconciled so `ModelInfo.inputTokenLimit` means one
thing everywhere. Gemini and Anthropic report an **input** limit directly; the
OpenAI-compatible family reports a **total** window covering both directions, so
`ModelDiscovery.inputTokens(total:output:)` reserves the reply's share. That
reservation is capped at half the window, which is not defensive padding: a live
OpenRouter entry advertises a 943,718-token output cap against a 1,048,576-token
window, and naive subtraction turns a million-token model into a 104,858-token
one.

### What the user can now set

Per provider, in the one form both platforms render:

- **Model** — free text as before, plus **Available models** listing what the key
  can reach with each one's context size, and a **Refresh** button. Refreshing
  never overwrites a model the user typed: an unlisted ID is very often a
  fine-tune or deployment alias that works perfectly well.
- **Temperature** — over the range the provider genuinely accepts. The single
  global slider was pinned to `0...1`, which is the wrong range for Anthropic
  (which rejects anything above 1.0 outright) *and* half the available range for
  everyone else.
- **Context budget**, in characters, and **Max reply length**, in tokens.
  `LLMRequestOptions.maxTokens` had existed since the beginning and no caller
  had ever set it.

Where a number came from is carried on `ProviderCapabilities.budgetSource` and
said out loud, because a discovered 3.6M-character budget and a fallback
100,000-character one look identical written down and mean different things.

### Two traps, both silent

**A non-optional property added to a persisted `Codable` throws on decode.**
`ProviderConfig` gained `models: [ModelInfo] = []`, and `LLMSettings.init`
decodes with `try?` falling back to defaults *for every provider* — so one throw
would not be a loud failure, it would silently reset the user's entire provider
configuration. Both `ProviderConfig` and `ModelInfo` decode field by field with
`decodeIfPresent`.

**An empty list is silence, not denial.** Three of OpenRouter's 417 models
return `supported_parameters: []`. Reading that as "no tools" is worse than not
asking, because a discovered `false` overrides the table's `true` and switches
Deep Research off for a model that may support tools perfectly well.

### Structure, because sixteen providers is a lot of rows

The first cut appended controls linearly and it was a wall: every provider was
its own open `Section`, so the form was sixteen stacked blocks before anything
was configured, and an *enabled* one went from six rows to thirteen — four of
them multi-line grey captions.

It is three levels now. Closed, a provider is **one line** saying whether it is
on and which model it uses (`Off` / `Needs a key` / the model ID), so sixteen of
them read as a list. Open, it shows the two things anyone changes: the model and
the key. The knobs that exist so the *app* can be honest — temperature range,
context budget, reply cap — sit behind **Advanced**, with a single caption for
all three instead of one each.

### Two bugs that only looking could find

Both were invisible to the compiler, the tests, and the Mac.

**The iOS AI settings screen had never rendered.** `iOSSettingsView` wrapped the
form as `Form { LLMSettingsForm(…) }`, and `LLMSettingsForm` *is* a `Form`
(`.formStyle(.grouped)`). `Form { Form { … } }` collapses: the screen showed a
clipped, half-drawn "Defaults" label inside an empty rounded box and nothing
else. It was added in the previous session, never opened, and shipped that way in
build 11.

**On iOS the two numeric fields had no labels.** `TextField(title:text:prompt:)`
shows its title *as the placeholder* on iOS, and a supplied `prompt:` replaces
the placeholder — so the title never appeared. On the Mac the label sat to the
left and read correctly; on iPhone the same two rows were bare grey numbers with
nothing to say which was the context budget and which the reply cap. They are
`LabeledContent` now.

The rule these share: **a shared view is not the same as a verified one.** One
`LLMSettingsForm` for both platforms guarantees the two screens are built from
the same code, which is worth having — and guarantees nothing about whether
either of them draws.

### Verified against real payloads, not recollection

Every field name and type above was checked against live data or current
documentation rather than remembered — Anthropic's Models API, in particular,
now reports `max_input_tokens` and a `capabilities` object it did not use to.
The decoder itself was extracted verbatim and run against OpenRouter's live
417-model listing: all 417 decode, all 417 resolve a window, 348 declare tools,
and the three silent ones stay `nil`. Ollama's `/api/show` confirmed the
architecture-prefixed `qwen3_5.context_length` key and `capabilities: ["tools"]`
on a real local model.

---

## 30 · Adding a large cloud folder (2026-08-27)

> **The problem, stated as the user did:** *"Adding a large cloud folder with
> lots of folders takes a long time. Any opportunities for speed up?"*

Three costs, all multiplied by the thing that makes a large folder large.

### The walk listed one directory at a time

`ResumableTreeWalk.run` awaited `source.children(of:)` for each directory before
starting the next. For a local vault that is right — a listing is a syscall over
a warm cache. For a provider it is a network round trip the app spends *idle*,
so a folder of N directories cost N latencies laid end to end. That was the bulk
of the wait.

Listings now run in a window, applied strictly in order. `TreeSource` declares
`listingConcurrency`, defaulting to **1** so nothing changes for a source that
has not thought about it; `RemoteTreeSource` returns 6 — chosen to sit well
inside every provider's rate limit rather than to saturate a link, because a walk
that earns a 429 finishes later than one that never asked.

**The invariant that makes it safe:** `head` still means *the next directory to
apply*. A listing in flight has been fetched past `head` but not applied, so it
is still inside `frontier[head...]` — which is exactly what `snapshot()` writes.
The checkpoint therefore keeps meaning what it meant when the walk was serial,
and cancelling mid-window loses nothing. Only the fetching overlaps: `onBatch` is
not `@Sendable` and mutates the caller's accumulator, so it is never re-entered.

**And the serial path must not pay for any of it.** Routing width-1 through the
window put an unstructured `Task` — an allocation and two hops — around every
local directory listing, and made the local walk roughly **four times slower**.
The enumerator benchmark caught it on the first run. `outcome(for:)` awaits
directly when `width == 1`. Concurrency here buys back latency and nothing else;
where there is no latency to hide there is nothing to win and a measurable amount
to lose.

### Progress was recounted from scratch, per directory

```swift
outcome.progress.filesMirrored = updated.entries.values.count { !$0.isDirectory }
```

That walked the entire manifest on every batch, for a number that changes by one
at a time — D×E work for a folder of D directories and E entries, quadratic in
the size of the thing being synced, on the sync's own hot path. It is a running
counter now, adjusted by the delta between the old entry and the new one.

### Three syscalls per note to decide to do nothing

`writePlaceholder` runs once per file. It asked the file system three separate
questions: a `resourceValues` for the size, a `createDirectory` for a parent the
walk had already created moments earlier, and a `fileExists` for what the first
call had already established. In the common case — a re-sync, where every file is
already there — that is three syscalls per note to take no action. One
`fileExists` answers it.

---

## 31 · Metadata belongs in metadata (2026-08-27)

> **The problem, stated as the user did:** *"I think summary and tags needs to
> write to frontmatter rather than body, so do links. We should never rewrite
> bodies."*

Every accepted suggestion used to write prose. A tag was appended after the last
paragraph, a link went under a `## Related` heading the app **invented** if it
was absent, and a summary was pushed in as a callout above the note's first
line. All three are metadata, none of them is prose, and none was reversible by
any means the app offered: a property can be deleted in the Properties pane, a
paragraph the app inserted has to be found and removed by hand.

They write `tags:`, `related:` and `summary:` now, through two helpers —
`NoteEdits.appending(_:toListProperty:of:)` and `setting(_:property:of:)`. The
body comes back byte-identical, which is what the tests assert.

### The reader was broken independently, and the sample vault proved it

`MarkdownParsing.tags(in:)` matched `#tag` with a regex over the raw document, so
a YAML `tags:` key — carrying no `#` — was invisible. Every front-matter-tagged
note in an imported Obsidian vault was therefore *untagged* as far as this app
was concerned: absent from the tag tree, unfilterable, unfindable.

**The app's own sample vault has three of them** — `tags: [demo]` in Callouts,
`tags:\n  - intro` in Welcome and in Deck. And the test covering this asserted
`allTags() == ["intro", "todo"]`, the inline hashtags only. It had been written
from the implementation rather than from the vault, so it passed for the entire
life of the bug and would have gone on passing.

`tags(in:)` now reads the `tags:` key **plus** inline tags in the body — and
only the body, which is not a detail. Front matter is structured data; scanning
it for `#` turns any property containing one into a tag nobody wrote, and that
became live the moment summaries started being stored as a property. There is a
test for exactly that: a summary reading "Covers #hashtag syntax." produces no
tags.

### Two YAML traps

`quoteIfNeeded` quoted `true`, numbers, and anything containing `:` or `#`. It
did **not** quote a leading `[`, and a related link is written `- [[Some Note]]`
— which unquoted is a nested flow *sequence*, not a string. The value would not
have survived its own round trip, and every other tool reading the vault would
have seen something the author never wrote. Quoting now covers every YAML
indicator character, and `scalar` unescapes what it escapes, so the pair is
actually a round trip.

Second: a YAML scalar is one line, so a multi-sentence summary is folded to one
rather than breaking the block.

Backlinks are unaffected — `wikiLinkTargets` scans the whole document, so a
`related:` property is an outgoing link exactly as the body version was, and a
test pins it.

---

## 32 · The parity checks that could not see the screen (2026-08-27)

> **The problem, stated as the user did:** *"You keep assuring me we have parity,
> but we keep running into parity issues. Clearly the way you are detecting
> parity is wrong."*

Correct. `PlatformParityTests` asks one question — *is every field of
`AppActions` supplied on both shells?* — which is source symmetry over the
**command surface**. Every parity defect actually found was on an axis it is
structurally blind to:

| Defect | Axis | Why the check could not see it |
|---|---|---|
| iOS Settings ▸ AI rendered a clipped stub | **rendering** | a nested `Form`; no `AppActions` field involved |
| Ten fields unlabelled on iOS | **labelling** | not commands at all |
| Tags browsable on iOS, not macOS | **reachability** | an iOS `CompactShell` place vs a macOS inspector tab; neither is in `AppActions` |

### Two instruments that did not work, and the control that said so

**`sizeThatFits` answered 0** for a perfectly healthy `Form` — a Form is a
viewport, so it reports the size it is *offered*, which is the rule this app
already applies to every representable it owns.

**`ImageRenderer` renders the nested form and the plain one identically** —
48,534 glyph pixels each. The collapse needs a live navigation hierarchy, which
an offscreen render does not build. An earlier attempt was worse still: counting
"not white" scored both at 312,000, the whole canvas, because a grouped form
fills its background with a light grey.

Both were caught by a **negative control** — a test asserting the *broken* form
really is broken. Without one, a check of this kind quietly starts passing for
everything, which is precisely how the preceding parity test came to certify a
screen that had never once drawn. `ScreenRenderTests` keeps what it can honestly
claim and states the limit in its header.

### The check that works, and the proof it works

`HelloNotesUITests` launches the app and navigates it. That target had been the
untouched Xcode template — `testExample` was empty, which is why it always
passed. It now sweeps the compact shell's four places, the Settings sheet's seven
sections, the AI screen and the Git screen.

**It was verified by reintroducing the bug**: with `Form { LLMSettingsForm(…) }`
restored, `testAISettingsScreenIsNotEmpty` fails with *"AI settings opened but
drew no content — the form collapsed"*; with the fix back, it passes. That is
the first parity check in this project demonstrated to detect the defect it
exists for.

Three environmental traps cost real time and are pinned in the tests:
- **Orientation decides which shell you get.** The simulator keeps its last
  orientation, and an iPhone 13 Pro Max in landscape is 926pt wide — regular
  width — so the app correctly draws the sidebar shell and no compact tab bar
  exists. Five tests skipped with "Compact shell only", which was true and read
  exactly like a broken test.
- **The compact shell remembers its place**, and the overflow button lives on
  Notes; without selecting it first the test is a coin toss decided by the
  previous session.
- **The splash is deliberately `.isModal`**, and XCUITest reads any modal as an
  interrupting alert, hunts for a Cancel button, finds none, and abandons the tap
  it was making. Wait it out rather than fight it.

The **editor and inspector are not swept** — selecting a collection marks it
selected rather than navigating, and a test that skips reads as coverage while
providing none. Named as a known gap rather than left as an assumed pass.

### And the fields nobody could read

`TextField(title:text:prompt:)` draws its title left of the field on macOS and
*as the placeholder* on iOS — so supplying a `prompt:`, which replaces the
placeholder, leaves the title drawn nowhere. Ten shipped that way: iOS Settings
had a "Daily notes" section of two anonymous boxes reading "Collection root" and
"yyyy-MM-dd", and a Git section whose fields could be told apart only by guessing
that "Ada Lovelace" meant name. `LabeledField` fixes them; a guard test with a
justified allow-list keeps them fixed. The rule it encodes: **a field must be
identifiable without typing in it** — a prompt that names the field is a label, a
prompt that shows an example is not.

### The tag list that was hidden behind typing

The macOS Tags pane disclosed collection tags only once you had typed, on the
reasoning that 223 tags is too many for a rail. That traded the feature for the
problem: with nothing on screen there was no way to learn the collection *had*
tags. It is always shown now, headed `ALL TAGS · n`, sorted by note count, capped
at forty, with the field above filtering it — while iOS had listed every tag in
its own tab the whole time.

---

## 33 · 1.3.2 shipped — both channels (2026-08-29)

The first release to go out on both channels on the same day.

| | |
|---|---|
| **DMG** | [v1.3.2](https://github.com/hellotham/hellonotes/releases/tag/v1.3.2) — universal, notarised, stapled; 39.7 MB, `0deb43d8…` |
| **App Store** | iOS **and** macOS 1.3.2 (12), both *Waiting for Review* |
| Verified | Gatekeeper `accepted / source=Notarized Developer ID`, staple validates offline, `x86_64 arm64` |

### The download page had been announcing a release that had not happened

`site.ts`'s version was bumped to 1.3.2 the day the work landed, and the download
button points at `releases/latest/download/HelloNotes.dmg` — which went on
serving **1.3.1 for eleven days**. Bumping a constant announces a release;
publishing one is a separate act, and nothing tied the two together.

The release skill made it worse by ordering the website update *before* the
GitHub release, which briefly put 1.3.2's checksum on a live page whose button
still served 1.3.1. A checksum that does not match is not cosmetic — it is the
alarm the checksum exists to raise, fired at the person carefully doing the right
thing. Publishing now comes first, and `scripts/check-download-page.sh` downloads
what the button serves, **mounts it**, and compares the version inside the image,
its size and its SHA-256 against the page's claims. Size and hash alone would not
have caught the drift: both were 1.3.1's and agreed with each other perfectly.

### The submission was carrying builds from four days earlier

The iOS version page had **build 9** attached and macOS had **build 8** — both
predating every fix in §29–§32. Nothing in App Store Connect flags a stale build;
it simply reviews and ships what is attached. Swapped to 12 on both.

macOS had **no screenshots at all**, which is a hard submission blocker
(`Unable to Add for Review: You must upload at least one screenshot`) and had
never been noticed because the version had never been submitted. The five
2560×1600 frames documented in production.md §8 were uploaded; the light set, on
the §8 rule that a gallery which switches appearance halfway reads as
inconsistent.

### Also corrected

**The export plist the docs named was the wrong one.** §9 Option B said to export
with the repo-root `ExportOptions.plist`, which is `method = developer-id` — the
DMG path. Following it would have signed an App Store build for the wrong
channel. `ExportOptions-AppStore-macOS.plist` / `-iOS.plist` now exist for the
upload, and `ExportOptions-iOS.plist` is kept for producing a local `.ipa`
(`destination = export`, so it uploads nothing).

**The release notes were three times the field they fit in.** 11,887 characters,
grown a section at a time in the order things shipped. The App Store's What's New
takes 4,000, and the three prior releases came in at 3,207 / 4,003 / 4,848 — the
file has always doubled as that field. Rewritten to 3,979, ordered by what a
reader notices rather than by when it was written.

---

## 23. Edit and Preview render the same document

> **The problem, stated as the user did:** *"Edit and Preview must render Markdown
> identically (to pixel level) and pass all GFM compliance tests. Currently there is
> significant layout shift switching between them."*

HelloNotes draws every note two ways. Edit lays it out in **TextKit**; Preview lays it
out in **WebKit** under GitHub's own `github-markdown-css`. Two engines will only agree
if they are given the same numbers, and they were given none: they had no shared
description of the document's geometry at all.

### What was actually different

| | Edit | Preview |
|---|---|---|
| Heading scale | ×1.7 / 1.4 / 1.2 / 1.1 / 1 / 1 | ×2 / 1.5 / 1.25 / 1 / .875 / .85 |
| Heading weight | bold (700) | semibold (600) |
| Line height | the system font's own | 1.5 |
| Space between blocks | **none** — whatever the blank line measured | 16, or 24 above a heading |
| List indent | `14 + 13 × source columns` | 2em per nesting level |
| Blockquote indent | `12 × depth + 8` | `.25em` border + `1em` padding |
| Code block | a background behind the glyphs | a 16pt-padded rounded box |
| Column | the whole pane | 980pt, centred |
| Text Size | scaled everything | scaled **nothing** |

The last two are worth separating out, because neither is typography.

**The column.** The note pane asked for its width by *mode*: Preview asked for the
reading measure and got 80 characters centred, Edit asked for the editing measure and
got the pane. So the first thing switching Edit→Preview did was move the text sideways
and re-break every line in the note. No amount of matching type fixes a column that
changes width.

**Text Size.** `GFMRenderer.page` applied the scale as `html { font-size: N% }`. But
`.markdown-body { font-size: 16px }` is absolute and overrides it, so the setting moved
the editor and left the Preview at 16px — and every margin in the stylesheet is an
absolute px constant besides, so even a working scale would have grown the type and left
the spacing.

### One table, two consumers

`MarkdownCore/GFMBoxMetrics.swift` holds GitHub's box model as numbers, expressed as
multiples of a base font size. `EditorTheme` and `StyleApplier` turn it into fonts and
`NSParagraphStyle`s; `GFMRenderer.page` emits it as a CSS override block. If a number is
wrong, both surfaces are wrong *together* — which is a bug you can see. Before, one
surface was wrong alone, which is a bug you can only measure.

`GFMRender` gained a dependency on `MarkdownCore` for this. It is the only way two
targets can share a number.

### The two rules that are easy to get wrong, and were

**Margins collapse.** The space between a paragraph (`margin-bottom: 16`) and the
heading after it (`margin-top: 24`) is 24 — the larger, not the sum. TextKit's
`paragraphSpacing` and `paragraphSpacingBefore` simply add. So the editor never sets
both: it asks `GFMBoxMetrics.gap(after:before:)` for the one collapsed number and puts it
below the earlier block. And `paragraphSpacing` is per *paragraph*, not per block —
TextKit ends one at every newline — so the gap lands on the block's **last line** only,
or a five-line blockquote spaces its own lines apart.

**A blank line is not a margin.** The editor's storage is raw Markdown, so the blank line
a writer types between two paragraphs is a real line with a real height: ~24pt where
GitHub's margin is 16, and 48 where the writer left two blank lines and GitHub still
shows 16. That single fact accounted for most of the drift down a long note. A run of
blank lines is now given exactly the gap the stylesheet would have left, shared between
its lines — the source is unchanged and the caret still has somewhere to sit on each one.

The same treatment covers the lines the source has and the render does not: a setext
heading's `===` underline, and the blank lines the parser leaves inside an indented code
block. They do not collapse to nothing — a line the caret cannot be seen on is a line you
cannot edit your way out of — and they do not collapse to a hairline either, because a
hairline only ever *adds* (it drifts once per setext heading down a long document) and
because a sub-point line height is one TextKit rounds, which it did differently at
different pane widths. Instead the gap between the two boxes is **shared** between the
blank lines and the collapsed ones, so nothing is sub-point and the total is exact.

### Things only measuring could have found

`Tools/RenderParity` lays the same note out in both engines offscreen and prints where
every block landed. Five of these were invisible in the numbers:

- **WebKit does not use a fractional line height as given.** `line-height: 19.72px` on a
  code block laid its lines out 19px apart. Every line height is now a whole point, on
  both sides, so there is nothing left to round.
- **An inline `code` span grew its line by a point in WebKit** and not in TextKit, which
  pins the line height. Any paragraph containing code was a point taller on one side.
- **cmark-gfm emits a bare `<input type=checkbox>`** with none of the classes
  github.com's pipeline adds, so GitHub's rule pulling the box into the list's gutter
  never matched and a task item's text started a checkbox-width right of every other
  item's.
- **`.markdown-body { font-size: 16px }` overriding the root scale**, above.
- **Inline `code` reserves no space in the editor.** `code { padding: .2em .4em }`
  advances the text in CSS, so every word after an inline code span on the same line sat
  **9.56pt** left of where the Preview put it. The editor reserves it now as `.kern` on
  the concealed backticks either side — the only characters in the right places, and
  already invisible — and the fragment paints the rounded pill, padding included. A
  `.backgroundColor` attribute cannot: it paints behind the glyphs and nowhere else.
- **The cmark overlay was un-concealing setext underlines.** `StyleSpec` conceals a
  setext heading's `===` line, and the whole-document GFM overlay — which runs *after* it
  — restyled cmark's heading node, whose range covers the underline as well as the text.
  So the underline got the heading's own 32pt font back. It stayed invisible until a note
  was narrow enough for 19 `=` at 32pt to wrap, at which point a concealed line silently
  occupied two of them. Found only because the harness sweeps pane widths.

### Where it ended up

Across a sample exercising every construct — all six heading levels, tight/loose/mixed
and nested lists, task lists, blockquotes, fenced and indented code, setext headings,
thematic breaks, tables, and paragraphs separated by one and two blank lines:

**worst per-block vertical drift 0.03pt; worst indent drift 0.83pt**, across every
combination of five text sizes (0.8×…1.5×) and three pane widths (420 / 800 / 1200pt).
The indent residual is the two engines rounding glyph advances differently inside a code
block; it does not accumulate.

`scripts/render-parity.sh` runs that comparison across the whole matrix — five text sizes
× three pane widths — and exits non-zero on drift over a point.

It is a script and not a test **because it cannot be a test**: a `WKWebView` will not
start its content process under `swift test` *or* under XCTest in the app's own test host
("Could not signal service com.apple.WebKit.WebContent"), so every load hangs and every
case times out. An ordinary executable renders fine. Both were tried before settling
here.

`GFMBoxMetricsTests` covers the half that *can* be a unit test, and is where a routine
regression will be caught first: that the stylesheet states the same numbers the editor
lays out with, that no line height is left as a unitless ratio, and that margins collapse
rather than sum.

### And one thing only a picture could have found

Every number agreed, and the h1/h2 rules still stopped at the end of the heading's text
while the code block's background ended at its longest line. An `NSTextLayoutFragment` is
clipped to its `renderingSurfaceBounds`, which defaults to the width of the text it holds
— so chrome drawn across the container was being cut off at the words. The geometry was
right and the paint was clipped, which no measurement of *where blocks land* can see.
`drawsFullWidthChrome` now widens those bounds for heading rules, code bands, thematic
breaks and callouts alike.

This is the argument for `EditorFidelitySnapshotTests` continuing to exist alongside the
geometry harness. It renders the real editor to a PNG **inside the app**, which is the
only place an `NSTextView` will draw: `cacheDisplay` outside an app process returns the
coloured runs and none of the body text — a page of list markers on white. A picture
taken anywhere else would be a picture of the instrument.

### A heading inside a list item, and four ways a margin can be wrong

`- # Foo` is an `<h1>` inside an `<li>`, and the editor read it as one more
line of the item's prose. Giving it the heading's font and line height was the
easy half. The margins took four separate corrections, and every one of them
was found by reading both engines' boxes rather than by reasoning about CSS:

- **Sum where CSS collapses.** Adjoining margins take the *larger* of the two,
  never their sum. The heading's `margin-bottom: 16px` and the list's are the
  same 16, so adding them put a whole extra block margin under the item.
- **A gap that was already held.** When a blank line follows, the collapsed
  blank *fragment* is already standing for the margin between the blocks —
  adding the heading's on top counted the same gap twice. What still had to be
  added there is the rule's `padding-bottom` and border, because those are
  *inside* the element and collapse with nothing.
- **A margin that escapes.** Neither the `<li>` nor the `<ul>` has padding or a
  border, so the heading's `margin-top` collapses straight out through both. In
  the first item it lands *above the list*, which is how a list whose own
  margin is 16 ends up sitting 24 below the block before it — and it does so
  even at the top of a note, where `github-markdown-css` zeroes the first
  child's margin with `!important`: the rule applies to the `<ul>`, not to the
  heading nested inside it.
- **An edge TextKit drops.** Opening the document there is nothing above to
  collapse into, and `paragraphSpacingBefore` is discarded on the first
  paragraph — the same edge that once cost an indented code block its top
  padding. The margin goes into the line box instead, where a pinned line
  height puts every bit of spare height above the glyphs.

`- # Item heading` / `- plain` measured **47pt short**; it and seven
neighbouring arrangements now sit within a point.

**And the rule was never painted.** The attribute landed, the metrics were
right, the space was reserved — and a pixel scan found no rule row. An h1/h2
border is drawn *below* the line box, in the margin the heading carries, and
that is outside the surface a layout fragment is handed by default, so it was
clipped away. A thematic break in a sibling item, drawn *inside* its own line
box, painted correctly the whole time; that contrast was the clue.
`renderingSurfaceBounds` now reaches down to the rule when a fragment carries
one.

**The instrument this needed.** `RenderParity --measure --dump` prints both
engines' boxes for a snippet: WebKit's elements with their tops, heights and
*used* margins, and the editor's layout fragments with the paragraph metrics
that produced them. Working a disagreement back from a single total means
re-deriving margin collapsing by hand, and guessing wrong there is what turned
one missing margin into three wrong ones. With the two tables side by side, the
`UL` sitting at 36 under a `margin-top: 0px` said what no total could.

### Six rules the corpus was asking for

Reading the failures by section rather than one at a time turns 85 into a
handful of causes. Six of them were real rules, each found by rendering the
example in both engines and reading the two box tables side by side:

- **Items stepped one space at a time are siblings, not a staircase.**
  CommonMark nests by the parent's *content column*, which ` - bar` never
  reaches. Deciding it from `listDepth`'s indent/2 guess invented a level for
  every second item, so four items carried two `li + li` margins instead of
  three — and on alternate rows.
- **An indented marker below a paragraph is lazy continuation.** A line
  indented four or more, but short of the open item's content column, is not
  inside that item: it dedents to the document, where four columns means
  indented code, and indented code cannot interrupt a paragraph. `   - d` then
  `    - e` is one item reading "d ⏎ - e".
- **With no paragraph open, the same line is indented code.** The list closed at
  the blank, so `1. a` / blank / `  2. b` / blank / `    3. c` is two items and
  a `<pre>` — 40pt of code box the editor drew as a third item.
- **Only a list starting with 1 may interrupt a paragraph.** Prose wrapping onto
  a line that begins `14. ` is one paragraph; read as a marker it broke the
  sentence in two and put a block margin through it.
- **An unbalanced HTML block collapses line by line.** `</div>` draws nothing
  and `*foo*` is text the reader sees. The collapse was all-or-nothing per
  block and refused the whole block because one line had content, so the tag
  stayed visible. The mechanism was never the obstacle — the cache is a list of
  ranges, and the container branch beside it had always appended single lines.
- **A blank line above only-unrendered content collapses.** It was holding a
  margin above something the reader never sees: `- b` / blank / `[ref]: /url`
  is one visible line.

- **A fence opened on an item's marker line belongs to the item.** This one is
  worth more than its corpus entry: `1. ``` ` was swallowed as item text and the
  *closing* delimiter read as a fresh, unclosed fence, so **everything below it
  in the note came out as code, to the end of the document**. The parser now
  keeps the fence inside the item — the same shape as indented code on a marker
  line — and the interior pass gives it the code box, delimiters as its 16pt
  padding. That example went from +40pt to −4.

- **An item ending in a thematic break exports the rule's 24pt bottom margin**,
  the mirror of the heading margin above it: an `<hr>` has no padding or border
  for a margin to stop at either, so it collapses out through the `<li>` and the
  `<ul>`, where it is larger than the list's own 16. The Thematic breaks section
  is now at zero failures.
- **An unquoted line does not continue a quote with an open fence.** Lazy
  continuation runs a *paragraph* on; a fence swallows nothing. `> ``` ` then an
  unquoted `foo` is a quote holding an empty code block and then a paragraph —
  read as continuation, the unquoted text joined the quote and everything below
  it went with it (−24pt → −8).

- **A block indented *into* an item is inside it, not after the list.** A quote
  written under an item's text sits flush against it: GitHub gives `blockquote`,
  `pre` and `table` `margin-top: 0`, and a tight item's own text is not a `<p>`,
  so nothing separates them. The editor applied the item's bottom margin while
  the item had not ended. The rule needs the block to *immediately* follow —
  with a blank line between them the item may well have ended, and `-` / blank /
  `  foo` is an empty item and a separate paragraph, which the first version of
  this fix broke (caught by diffing the failing set, not the total).

In context the corpus went **563 → 574**, and the Lists section from 11 failures
to 5, List items 9 to 7, Thematic breaks 1 to 0. Bare, 523 → 530.

**What was deliberately not done.** Two candidates were investigated and left
alone, which is worth as much as the six above:

- The **Images** section is 18 failures of exactly −4.00pt, and all of them are
  WebKit's broken-image placeholder — the corpus has no image files. Matching it
  would fit the editor to one browser's placeholder metric.
- A **loose item whose second paragraph follows a nested list** needs the parser
  to reopen an enclosing container. Tried, and reverted: the block model is flat
  and non-overlapping, so re-opening the outer item emitted a second block
  spanning the nested one and dropped the open item on the floor. A probe showed
  exactly that. It is a model change, not a rule.

### The marker is a box, and it is not in the box you think

**574 → 578, and two bullets that were drawn in the wrong place — one of them
nowhere at all.**

A `<li>` does not draw its marker beside the item. It draws it in the **first
line box of the item's first child**, and the marker is set in the *item's*
font at the item's line height. Everywhere that child is a paragraph the
distinction is invisible, because a line of prose is already that tall. Where it
is a code block, it is not:

    1. ```
       foo
       ```

`pre` has `line-height: 20px` at body size and the item has 24, so the listing's
**first** line is 24 and every line under it is 20. The editor gave the whole
listing the code line height and came out 4pt short — on every fenced *and*
indented code block that opens a list item (spec #7, #243, #244, #294). It is
the one place a code box is not uniform, and `applyNestedCode` now takes a
`carriesMarker` flag for exactly that line.

Finding it took a new instrument. Two rounds of specificity reasoning produced
two wrong answers — the first blamed `.markdown-body li code { line-height: 1 }`
reaching a `pre > code`, which turned out to be true, over-broad, and *not the
cause*: reordering the rule fixed the computed value and moved no box. So
`--measure --dump` gained **`PARITY_CSS=line-height,font-size`**, which appends
those *computed* values to every row of the box dump. One run then said it
plainly: identical `line-height` and `font-size` on both `<pre>`s, and heights
of 52 and 56. A box that is the wrong height is a declaration that did not
apply or one that applied where it should not have, and only the engine can
tell you which.

The same rule decides where the **bullet** goes, and the editor was drawing it
on the line the author typed the marker on. Two constructs put the marker on a
line the page gives no line box:

- `-` with its content on the line below. The marker line collapses to a
  hundredth of a point, so the bullet drew inside a hairline — which is to say
  **the item rendered with no bullet at all**.
- `- ``` `, where the opening fence *is* the code box's top padding. The bullet
  sat a padding's height above the code it belongs to.

The carry for the first case was already written, inside the block pass — and
had never worked, because `StyleSpec`'s own marker run is applied *after* it and
put the attribute straight back. That is why it is now `carryListBullets`, a
pass of its own at the end of the block, and why there is a test asserting that
an *ordinary* item keeps its bullet where it is.

### The appearance gate had been reading dark ink on a dark page

`render-parity.sh` ends with a chrome check that renders both sides and measures
the bullets and quote bars, because "height parity is not appearance parity".
It had been reporting `chrome: no list bullet found` — for chrome both sides
were drawing correctly. Three faults, stacked:

1. **The editor dump painted its canvas in the dark theme while its glyphs were
   styled in the light one.** `EditorTheme` resolves against the process
   appearance, which is Aqua in a command-line tool, so the text was the light
   theme's near-black; the canvas was nailed to `canvas(isDark: true)`. Measured
   over the dump: page 53 of a possible 765, body text 107. A contrast of 54.
   Every `--png` comparison in this project had been made against that.
2. **`bright()` meant literally bright** — `R+G+B > 200`. That reads ink on a
   dark page and reads *the entire page* as ink on a light one, so the Preview
   side had no bands to group at all. Ink is now a difference from the page, and
   the page is whatever the image's own border is.
3. **The failure said only "not found".** It now prints every band it scanned
   with its leftmost ink column, which is what turned this from a shrug into
   three findings in one run.

Green, and now with numbers to read: bullet 5.0pt above its baseline against
Preview's 5.5, and 9.0pt left of the text against 9.5.

The lesson is the one already in `CLAUDE.md` about `cacheDisplay` — **validate
an instrument before trusting it** — with a corollary. A gate that fails for a
reason nobody can act on gets read as noise, and this one had been failing long
enough that a summary of the session recorded it as passing.

### Visible changes to the editor

- Code fences conceal when the caret is elsewhere, and the fence lines *are* the code
  box's 16pt vertical padding. The box itself is now drawn by the fragment — a rounded,
  full-width band — rather than being a background attribute behind the glyphs.
- A `---` is drawn as GitHub's 4pt bar; the source returns when the caret is on the line.
- An indented code block's four leading columns conceal, so its listing starts at the
  box's padding rather than four characters inside it.
- h6 takes GitHub's muted colour; inline code inherits its context's size, so `` `code` ``
  in a heading is heading-sized, and it draws as a rounded pill with GitHub's padding
  rather than a tight rectangle behind the glyphs.
- An ordered list's `1.` takes the document's text colour. It was the accent, which read
  as a link — the one thing GitHub renders in plain text, in the one colour it reserves
  for links.
- **Reading width now applies to the whole note pane, not to Preview alone**, and its
  default becomes Full. The pane's column is the Editor width proportion capped by the
  Reading width measure, centred only when the measure is what bit. `TextIntent` is gone:
  a pane has one column, and a mode cannot change it.

### The incremental-restyle consequence

A block's trailing gap is the collapsed margin between it and its neighbour, so it
belongs to two blocks: typing `#` in front of a paragraph changes spacing stored on the
block *before*. `EditorDocument.restyle` widens its damage set by one block on each side
— still O(damage) — and the passes that run *after* the styler (syntax highlighting,
folds, block embeds) had to widen with it. They did not at first, and the neighbour came
back freshly base-styled and stripped: a folded callout one block from an edit came
unfolded and a rendered table came back as pipes.

### Two more passes against the spec corpus — and the instrument was measuring the wrong quantity

Everything above was measured against a hand-written sample note and against
whatever fraction of the GFM corpus the harness could read. Two further passes
were run against the corpus itself. The first thing each of them found was the
harness.

| | agree | differ ≥1pt | denominator |
|---|---|---|---|
| as written, before | 530 | 115 | 645 of 672 |
| as written, after wave 1 | 605 | 67 | **672** |
| as written, after wave 2 | **637** | **35** | 672 |
| in context (`PARITY_CONTEXT=1`), before | 578 | 55 | 633 of 672 |
| in context, after wave 1 | 626 | 46 | **672** |
| in context, after wave 2 | **649** | **23** | 672 |

The denominator is the part worth reading first. **Nothing is excluded from
either row now**, and every one of the three exclusions the previous pass
recorded — plus the twenty-four examples nobody knew were missing — turned out
to be the instrument rather than the corpus.

**`scrollHeight` was never the quantity the editor answers with.** The page's
height was `scrollHeight - paddingTop - paddingBottom`; the editor's is
`usageBoundsForTextContainer.height`. Those are not the same measurement, and
that is exactly why the wrong one looked right: on a well-formed page they agree
to within WebKit's integer rounding of `scrollHeight`, because
`github-markdown-css` zeroes `.markdown-body > *:last-child`'s `margin-bottom`
and nothing sits below the last box. The moment an example leaves a tag open,
the `<p>` that gets re-parented into it is no longer that last child: its 16pt
bottom margin survives, collapses out through the unclosed element, and is
stopped only by the article's own padding — 16pt of page that nothing paints in,
charged to the editor. TextKit drops the last paragraph's `paragraphSpacing` for
the same reason CSS zeroes that margin, so the editor was already reporting the
*painted* bottom and the page was not.

`paintedContentBottom` walks the article and takes the lowest edge anything
actually draws at. Three details it cannot skip, each found by getting them
wrong first:

- **A box of zero height paints nothing.** An empty `<p>` parked after the last
  visible box must not push the answer down by the margin above it.
- **An inline box is not a line box.** A `<code>` span carries `.2em` of
  vertical padding and a background, so its border box hangs 2.72pt below the
  glyphs — inside the 24pt line box its block already accounts for. Counting it
  charged the editor a point on three examples where both engines drew one
  identical line.
- **A text run whose nearest block ancestor is the article itself** — the
  tagfilter escapes an unclosed `<style>` into one — is laid out in an
  **anonymous** block box that no element walk can reach. Its `Range` rect is
  the glyph box, so the half-leading CSS centres it with has to be added back.
  The tempting alternative, appending a zero-height probe element and reading
  where it lands, silently moves the answer 16pt down: the probe takes over
  `> *:last-child` and hands the paragraph above it back the margin that rule
  was zeroing.

That one change retired the entire fifteen-example context exclusion — the raw
inline tags that "swallowed the trailing paragraph" — with real numbers rather
than with an apology, and retired the three named `#126`–`#128` exclusions too.
A `<script>` is `display: none`; it moves no painted edge, so a page that
re-parents the harness's own scripts is an ordinary page once you stop measuring
scroll extent. The box dump gained `#text` rows for those anonymous blocks at
the same time, which is where the missing height usually turns out to be.

**Twenty-four examples had never been read.** `specExamples` matched an opening
fence of ` ```… example `, and GFM's extension examples are written
` ```… example table ` / `autolink` / `strikethrough` / `tagfilter` /
`disabled`. Matching only the bare word skipped every one of them — including
the whole Tables section, which is the construct with the most geometry in it.
Nothing said so: the sweep printed "648 examples", and 648 is what `spec.txt`
appears to hold if you only count what you already match. The numbering is now
the file's own, 1…672, which is what the published spec numbers these by — so
**every example number recorded before this change is stale by up to twelve**
(the old #568 is #580).

**`parity:` — an origin of the harness's own.** The Images section was recorded
above as "one cause, eighteen times": 18 failures of exactly −4.00pt, blamed on
WebKit's broken-image placeholder and left alone on the grounds that matching it
would fit the editor to one browser's fallback. That was half true and entirely
the harness's doing. The sweep loaded every page with `baseURL: nil` and handed
the editor no image base at all, so **neither side drew an image**: WebKit drew
its placeholder, the editor's renderer had no folder to open and left the
`![foo](/url)` source on screen, and the harness scored one fallback against the
other.

A `file:` base cannot fix it. Half the corpus's targets are root-absolute
(`/url`, `/path/to/train.jpg`), and a browser resolves those against the
origin's root — `file:///url`, which no harness can create. Under a private
`WKURLSchemeHandler` the fixture folder *is* the root, so `/url` and `train.jpg`
both land in it and `ParityScheme.resolve` gives the editor the identical rule.
`Tools/RenderParity/Fixtures` holds twelve 20×20 squares named after the
corpus's own targets, most without an extension because the corpus writes none;
both engines identify them by content. `--measure` was moved onto the same
origin, because a `--measure` that answers a different question from `--spec` is
an instrument that cannot explain its own failures.

### Which list an item belongs to, asked once

`box(at:)` compared **content columns** — CommonMark's rule — and
`listIsLoose` compared `indent / 2`, so the two disagreed about which items were
in a list. `1. a` / blank / `  2. b` was one list to `box`, which duly gave the
second item its `li + li` margin, and two separate lists to `listIsLoose`, which
therefore scored a genuinely loose list tight and left every item's text 16pt
short of the `<p>` the page wraps it in. Four callers wanted that answer and
three of them computed their own.

`BlockBoxes.membership(of:in:)` is now the only one. It returns `sibling`,
`interior` or `outside`, and the distinction between the first two is the whole
point: CommonMark makes looseness a property of an item's **own** blank lines,
so a blank belonging to an item two levels down must not loosen the outermost
list, and the blank lines inside a fenced code block must not loosen anything at
all. `listIsLoose` walks back to the list's first item and forward over every
block including the blanks — the blanks *are* the evidence — carrying which item
it is inside and how deep the nesting goes. It is linear in that one list, which
is what makes it affordable on the editing path: a keystroke restyles three
blocks and each walks its own list, never the document.
`ListLoosenessTests` exists as a file of its own because one wrong answer here
is 16pt per item on an ordinary note, not a corpus curiosity.

### A reference link is a link

`[foo]` with `[foo]: /url` elsewhere in the note is a link, and the editor had
no idea. The definition scanner could say "this line is a definition" — enough
to conceal it — and threw away the label, the destination and the title while
walking over them. So a reference **image**, `![photo]`, reserved no box: the
paragraph was one image filling itself, and the editor showed source.

`ReferenceDefinition.parse` now returns what it read, `ReferenceDefinition.all`
walks the document once, and `LinkReferenceMap` turns the result into
label → (destination, title) under CommonMark's own normalisation: Unicode case
folding via `folding(options:)` — not `lowercased()`, because the corpus has
folding pairs simple lowercasing keeps apart — ends trimmed, internal whitespace
runs collapsed to one space, newlines counted as whitespace. It is built
**first-wins**, because `byLabel[key] = …` in a loop keeps the *later*
definition and CommonMark keeps the earlier one.

`InlineParser.parse` gained `references:` with `.empty` as its default, and the
default is load-bearing: without it every bracketed aside in ordinary prose
becomes a link. Full, collapsed and shortcut forms are tried only after the
inline `(url)` form fails, and a node is only emitted when the label actually
resolves — a second bracket that fails to resolve is final rather than a
fallback to the shortcut, which is what the spec says. `EditorDocument` resolves
block embeds through the map and unwraps one wrapping link, because
`[![moon](moon.jpg)](/uri)` draws no box for the anchor and the paragraph is
still one image filling itself.

The scan and the map are cached together on `revision`. Two scans would be two
opinions about which lines are definitions, and that failure is silent: a line
concealed by one and unresolvable by the other.

**13 examples**, and the same 13 in both sweeps: #525, #539, #581, #584–585,
#590–594, #596–597, #599. Cost: two new files in `MarkdownCore` (340 lines),
17 tests. The harness had to learn the same rule — without it `needsBlockRender`
decided `![foo]` needed no renderer, attached none, skipped the settle wait, and
then measured the editor with its source still on screen, reporting a shortfall
it had itself arranged.

### The table numbers had been meaningless, in a way that read as tidy

Six failures across the two Tables sections, all in a neat band around −3pt.
They were not a spacing bug. **The sweep had no table renderer**, so it laid the
*source* out — `| foo | bar |` and friends at 24pt a line — and compared that to
a rendered `<table>`. #198's three source lines (72pt) happen to land near a
two-row grid (75pt), which is the only reason the family read as a tidy −3
rather than as nonsense.

Attaching a renderer to the sweep exposed what was underneath:

- **A collapsed border is a box.** `table { border-collapse: collapse }` makes
  each border its own box, so N rows carry N+1 of them. The app's renderer
  stroked its grid *inside* the cells, so its picture was one hairline per row
  shorter than the page's. `GFMBoxMetrics.tableHeight(rows:)` now carries them:
  38 / 75 / 112pt for 1 / 2 / 3 rows, which is what WebKit measured for the
  specification's own tables.
- **The delimiter row is a ruler, not a row.** Four source lines were being
  measured against three rendered ones — the whole −16pt on #200 and #204.
- **A delimiter row must match its header's cell count**, or there is no table.
  The editor had been drawing a two-column grid over what GFM calls a paragraph
  (#203) and scoring green only because three source lines happened to measure
  the same as three lines of prose.
- **A plain line continues an open table's body.** GFM breaks a table at a blank
  line or another block-level structure, and at nothing else, so the line under
  the last row is a one-cell row (#202).
- **Only an unescaped pipe divides.** `| f\|oo |` is one cell; splitting on every
  pipe invented a column with a different width and a different scale factor.
- **A checkbox is content, not marker.** `listInfo` measured `contentColumn`
  after stepping over `[x] `, which counted the space after `]` as marker padding
  and put the column at 3 — so a sub-list needed three spaces to read as nested
  and the two everybody writes read as a sibling, `li + li { margin-top: .25em }`
  where the page puts `ul ul { margin-top: 0 }` (#280).

`GFMTableLayout` (MarkdownCore) reads a pipe table as a grid and answers its
height from the box model; `GFMTableGeometry` (MarkdownEditor) measures the
columns in the theme's own fonts — `th { font-weight: 600 }` — and states
`PlatformImageKit.scaled`'s downscale-never-upscale rule as arithmetic. One cell
scanner is exposed twice, as `cells(_:)` for the renderer and `cellCount(_:…)`
over a UTF-16 buffer for the block parser, so the count that decides whether this
*is* a table cannot disagree with the split that decides what is in it.
`TableImageRenderer` was rewritten to own pixels only and strokes the grid down
the middle of the border boxes *between* cells, so the drawn image is exactly the
size the box model says.

One more thing surfaced with them: `EditorDocument.collapse` replaces the style
`StyleApplier` laid down, and that is where the collapsed CSS margin sits when
there is no blank run below to hold it — so a rendered block butted straight
against the next one lost its `margin-bottom: 16` the moment its picture arrived.
Invisible until now, because the only kind reaching that path with a non-zero
bottom margin is the table, which the sweep was not measuring.

**7 examples** in both sweeps: #198–#201, #204–#205, #280, and both table
sections now read 0 differing of 8. Cost: two new files, a rewritten renderer, 20
tests. **Known limit, stated rather than hidden:** for a table *wider* than its
pane, Edit scales the whole bitmap down and Preview wraps the cells' text. Every
table in the corpus fits at the sweep's 800pt, which is why no table was added to
the hand-written sample `render-parity.sh` gates — at 420pt and base 24 it would
fail for the wrong reason.

### `NSTextLayoutFragment.bottomMargin` — the place space can survive the end of a note

Three things had been parked in `paragraphSpacing` that are not margins, and
TextKit drops the trailing `paragraphSpacing` of the document's *last* paragraph.
That drop is **right** — GitHub zeroes `.markdown-body > *:last-child`'s
margin-bottom too — and it took everything else parked there with it.

An h1's rule is `padding-bottom: .3em` plus a border. Padding is *inside* the
box, and the fragment *is* the box: so `bottomMargin` is padding-bottom and
`paragraphSpacing` is margin-bottom, which is precisely why one must survive at
EOF and the other must not. A note that ended in an h1 stood ~11pt short and drew
its own rule below `usageBounds`, off the end of the note. `StyleApplier` now
only marks the line; `RenderedBlockFragment.bottomMargin` reserves the inset off
that marker, and the four sibling sites that had been adding it into the gap
stopped doing so.

The measurement came before the code, on a standalone AppKit harness: overriding
`bottomMargin` adds the space once per fragment at one wrapped line and at six,
adds it on the document's last fragment, adds *on top of* `paragraphSpacing`
rather than replacing it, and grows `usageBoundsForTextContainer.height` by
exactly the override. Counted once per **fragment**, however many visual lines it
wraps to — which is the whole reason it works where the two tempting repairs do
not. `minimumLineHeight` applies to every wrapped line and `StyleApplier` styles
without knowing the pane width, so an h1 wrapping to three lines gained the inset
three times; `lineSpacing` shortens the line box, so chrome drawn from
`typographicBounds` stripes. Both were tried, measured and reverted.

The second thing parked there really *is* a margin, and still has to survive:
`hr::before` / `hr::after` are `display: table`, a clearfix, so an `<hr>`'s
margins never collapse out to the `:last-child` that gets zeroed. Inside a list
item that `:last-child` is the `<ul>` two levels up, so the page keeps 24pt below
a rule ending an item and the editor threw it away with every other last
paragraph's. `keepARulesBottomMargin` **moves** it into an escaping-margin
attribute rather than copying it — with a trailing blank run below, it is not the
last paragraph after all and the two would be counted twice.

The first draft of that rule kept *any* nested block's bottom margin at EOF, and
the page disagrees: an h2's margin-bottom inside an `<li>` collapses out through
the list and dies on `:last-child`. Narrowed to the one element whose margins
cannot collapse. The same draft also asked "is any block after me still
rendered?" forwards, per block — quadratic over a note, and `swift test` went
from 26 seconds to 307. Walking backwards from the last block stops at the first
rendered one it meets, which is a couple of trailing blank lines at most.

**8 examples**, all in the bare sweep — the context sweep cannot move here by
construction, since wrapping every example in `Above.` / `Below.` means no
example ends the document. #10, #36–#38, #45–#46, #111 are notes whose last block
is an h1 or h2; #31 is `- Foo` / `- * * *`. Cost: one override, one attribute, a
10-test suite that lays notes out for real through the editor's own layout
delegate rather than reading a paragraph style back — because the point of the
mechanism is what survives layout.

### A blockquote holds blocks

Three of the remaining failures were the same shape: a quote line whose meaning
is carried by the line above it. `> aaa` is prose or a line of a listing
depending on what came before it; `>>     two` is an indented code block or a
list item's own paragraph depending on what column the item opened at. Four
columns is only the right ruler when nothing is open.

Per-rule patching would have been faking it, because the rules contradict each
other — a fence inside an item, an item inside a fence — and only a stack decides
which is open. But the stack does not belong in `BlockParser`: its blocks are a
flat, non-overlapping tiling and that shape cannot express a reopened container
at all (the probe that tried came back with two `listItem` blocks both starting at
line 0 and the inner content dropped). What a quote's interior needs is one open
fence plus the content columns of the items open inside it — never deeper than
the quote, computed in one pass over its lines, dead when the function returns.
So `applyQuoteBars` carries it, and every per-line rule below is guarded on being
outside a code box, because inside one a blank line is a blank line of the
program and a `#` is a character of it.

With that in place: a fenced block inside a quote gets the `<pre>` box, its
delimiters as the 16pt paddings and the mono font on the *content* only (the `>`
is the quote's marker and stays hidden); the box is laid out whether or not the
caret is on the line, because a quote that grew and shrank by 8pt as the caret
crossed its fence would be worse than one showing its backticks. An unclosed
fence with nothing under it holds both paddings itself — the empty `<pre>`
GitHub draws for a quote that is nothing but `> ``` `, and the same missing
branch at the top level, which is what `` ``` `` alone had been −16pt for. And a
loose list opening a note inside a quote reserves its `<p>`'s top margin, which
collapses straight out through the `<li>`, the `<ul>` and the `<blockquote>` —
none of the three has padding or a border on that edge, and
`blockquote > :first-child` zeroes the *list's* top margin, not the paragraph's.

One appearance bug fell out of it. The quoted code box added its padding with
`para.headIndent += m.codePadding` a dozen lines above the gutter block that
*assigns* both indents from the quote's nesting, so the `+=` was overwritten and
did nothing — and `drawCodeBand`, which reads the band's left edge back off
`headIndent`, painted the band straight through the quote's own bar. The padding
is now carried in a `codeInset` that the gutter block adds, which is what the
band-drawing code's own comment had always claimed was happening.

**4 examples**: #96, #98, #215, #237 (three of them in both sweeps). Cost: a
container pass in `applyQuoteBars`, 13 cross-platform tests.

### Where the two waves ended up

`swift test` went from 229 tests in 20 suites to **289 in 25**, and the iOS
simulator run — the same package built for UIKit — to 122 in 8. `render-parity.sh`
stays green at 15/15 configurations with worst per-block drift 0.03pt and chrome
parity ok; GFM spec conformance is unchanged at 648/648; the app builds clean.
Every stage was set-diffed against its own captured baseline in both sweeps
rather than judged on the aggregate, which is how #202 and #203 were caught being
broken by the table renderer that fixed the other six, and how the first
escaping-margin draft was caught trading `x` / blank / `- ## Foo` for the rules it
was meant to keep.

The three claims the previous pass recorded as impossible were all disproved, and
`docs/unimplemented.md` now says so. Each of them was a claim about the platform
that nobody had put to the platform.

### The last family: a newline the page does not break at

Eleven examples had one shape. Preview renders with `CMARK_OPT_HARDBREAKS`, so
every line ending the writer typed comes back as a `<br>` and the editor's
line-for-line layout is right — *except* where cmark has already eaten the
newline into a token. Inside a code span, inside a link's `(…)`, inside a raw
tag or an HTML comment, a line ending is not a line break: it is a space, the
construct is one token, and the page draws one line where the editor drew two.

`docs/unimplemented.md` had recorded this as impossible, in two halves, and both
halves were false in this repository's own source. "Concealment sets width, not
line-breaking behaviour" — concealment here sets a **line height**
(`BlockBoxes.collapsedLine`). "The only route is rewriting the user's text" —
`EditorDocument.collapse` already stands every table, every `$$…$$` and every
raw HTML block's multi-line source in a single visual box with the source
untouched in the storage. What the claim actually described was *not attempted*.

Text substitution stays off the table: the storage **is** the document. What
TextKit 2 allows instead is a content element spanning more of the document than
one paragraph — `NSTextContentStorage` asks its delegate for the paragraph at a
range and the delegate may answer with a longer one. The storage keeps its
newline; the element handed to the layout manager has a space in its place and
covers both source lines. Length-preserving, so every offset↔location round-trip
stays exact and the caret lands on the character the reader clicked.

Three things were measured into `JoinedLines.swift` and none is obvious:

- **`NSTextParagraph.paragraphContentRange` is computed once and kept.** It is
  documented as "derived from `elementRange` and `attributedString`", and in fact
  `NSTextContentStorage` assigns `elementRange` the moment the delegate returns
  and derives the content and separator ranges from the *source* paragraph.
  Widening `elementRange` afterwards changes nothing. Selection navigation reads
  those ranges, so a merged element that only widened `elementRange` laid out
  perfectly and then clamped every caret at the join: click anywhere in the tail
  and the insertion point went to the newline. **Layout being right is not
  evidence that selection is.**
- **A paragraph the content storage did not create has no paragraph ranges at
  all** — they come back nil, and `NSTextLayoutFragment` crashes laying one out.
  So the merged element is built inside the delegate callback, where the
  framework still adopts it, and nowhere else.
- The normalisation is CommonMark's, not "replace `\n` with a space": fold every
  line ending to a space, then strip one leading and one trailing space if both
  are present and the result is not all spaces.

### Three more things the corpus could not see

The corpus is pathological markdown, and three defects sat outside it.

**A code box's bottom padding had never been drawn.** `padCodeLine`,
`applyNestedCode` and the blockquote's own listing lines each reserved 16pt below
the last line and then "lifted the glyphs off it" with `.baselineOffset` — which
under a pinned line height moves the *reported* baseline and not the ink, so the
reservation and the lift cancelled exactly. A one-line indented code block put
its listing hard against the floor of its box. The gate could not see it because
`render-parity.sh`'s baseline column reads `glyphOrigin`, which already has the
offset applied: **the instrument was confirming its own input.** The repair is
the same `NSTextLayoutFragment.bottomMargin` the heading rule now uses, with
`drawCodeBand` taught to paint over it — one change covering all four sites — and
a new chrome check that measures the ink's distance from the panel's top and
bottom edges, so it cannot go undrawn again silently.

**A heading inside a blockquote drew no rule and reserved no padding for one.**
`StyleApplier`'s quote pass never set `headingRuleAttribute`, so the fragment's
`bottomMargin` never fired there. `x` / `> ---` measured 20pt short.

**An image inside a line of text did not grow its line.** The editor had never
had an inline replaced box at all: `applyInlineMath` reserves *width* only, and
`BlockBoxes.baseStyle` pins `min`/`maximumLineHeight`, which clamps any run that
wants to be taller. CSS grows a 24pt line box to 26 to seat a 20pt image on the
baseline. Spec #595 is the control that rules out the cheap repair — only the
line *carrying* the image grows, so a per-paragraph line-height change overshoots.

### Where the two waves ended, and the three examples still carrying a name

Both sweeps, bare and in context:

    672/672 compared, 670 agree, 2 named, 0 differ by ≥1pt

`agree` is `compared − failures − named`, so 670 + 2 = 672: a named divergence is
never counted as an agreement, and the rate is printed against the corpus rather
than against what survived it. The predicates are asked of the **page**, not of an
example number — a hardcoded list of numbers goes stale the day the corpus gains
an example, and silently.

That is where this write-up stood for a while, and the last three sections below
are what happened when somebody asked what the two names were actually claiming.
**All three were wrong, all three are closed, and `NamedDivergence` is now empty
by construction.** The final numbers are at the end.

`swift test` was **356 tests in 29 suites** at that point; the iOS simulator run
337. The parity gate held at 15/15 with chrome parity ok, and the app compiled in
Release as well as Debug and for the iOS simulator.

What the whole effort is really a record of: **the scoreboard was wrong in more
ways than the code was.** Fifteen examples were dropped from the denominator, 24
were never parsed at all, the two engines were being asked for different
quantities, the image corpus compared two fallbacks against each other, and the
appearance gate was reading dark ink on a dark page. Every one of those made the
editor look better than it was, and every one had to be fixed before a single
real defect could be seen.

### The corpus is 672 single constructs; a README is not

With every example agreeing, one realistic note was laid out in both engines —
a heading, a paragraph with inline code, numbered steps with a ```bash block
under the first one, a nested bullet list, a quote containing a fence, a table,
task items, a rule. It came out **+7.06pt**. Bisected, all of it was one shape:

    1. Install the thing:

       ```bash
       brew install thing
       ```

A fenced block with an **info string**, written under an item's text. Without the
info string: exact. At the top level with it: exact. Only the combination.

Two separate defects were hiding there, and each explains why the other stayed
hidden.

**`.markdown-body li code { line-height: 1 }` reaches a `pre > code`.** The rule
exists so an inline `` `code` `` span cannot inflate the line it sits on; it has
the same specificity as `pre code { line-height: inherit }` and was written after
it, so inside a list item it won. This exact fix was made earlier in the effort
and **reverted as a measured no-op**, on the strength of a full corpus sweep that
showed not one example changing — because every fenced-in-a-list example the
corpus has puts the fence *first* in the item, where the marker sits in that line
box and is taller than either value. A code block under an item's text has no
marker in it. The revert was correct on the evidence available, and the evidence
was the wrong shape.

**The fence delimiters inside a list item were never concealed.** At the top
level `StyleSpec` conceals the fence and the 16pt band is what is left over;
inside an item nothing did, so the ``` — and far more visibly its info string —
was drawn as the listing's first line. `1. Install:` over a ```bash block put the
word *bash* inside the code box. Every height agreed, so only a picture could
find it; and it took a picture to notice that `drawCodeBand` paints from
`typographicBounds`, which for a concealed line is the concealed font's couple of
points rather than the 16 the paragraph style pins — so once the text was hidden
the padding band collapsed to a sliver. The band now paints the fragment.

Both are now in the hand-written sample `render-parity.sh` gates, which is where
they should have been all along: the sample had a code block and it had a list,
and never a code block *in* a list. The note now measures **+0.06pt**.

The general lesson is the one worth keeping: a conformance corpus tests
constructs one at a time, and every real document is a combination. Passing 672
of 672 is necessary and it is not sufficient, and the cheapest way to find what
it misses is to lay out a page somebody would actually write and look at it.

### The three names, and what a name was hiding

A *named divergence* is an example the sweep measures, finds different, and
excuses with a reason written down beside it. Three examples carried one. All
three reasons were true sentences about one engine and false sentences about the
comparison, which is the defect the mechanism itself had: **a reason that
describes what one side cannot do, rather than what the two sides were each
asked to render, has nothing in it to check.**

**`![[foo]]` — "an Obsidian embed, a feature cmark has no equivalent for"
(#598, +2.01pt).** True about cmark, and irrelevant: the app never hands cmark a
`![[…]]`. `HelloNotes/UI/GitHubMarkdown.swift` rewrote `![[foo]]` to
`![](foo)` — and `[[t|alias]]` to `[alias](t)`, and stripped front matter —
before Preview built a page, on both platforms, at the only place the app builds
one. So in a real note the embed had *always* drawn as a picture on both
surfaces. The sweep called `GFMRenderer.page` on the raw note, drew the literal
characters, and scored the difference against a page the app never builds. That
step is now `GFMRender.NoteMarkdown.prepare`, in the package where the harness
can take it too, and the app file is a one-line forwarder. The divergence closed
at +0.01pt with **neither surface changing** — which is the signature of a gate
grading its own copy of the thing.

Two details worth keeping. Front matter is now stripped by asking `BlockParser`
where it is, rather than by a second rule claiming to be the same one; and the
two regexes live inside the function behind a `contains("[[")` guard, because a
`Regex` is not `Sendable` and at file scope in a Swift 6 module it is a
concurrency error rather than a cache.

**`:last-child` counts elements (#142 in context, +16.05pt).** The excuse said
modelling it needed the editor's block-gap arithmetic to know whether the next
block produces an element, "which no other rule in `GFMBoxMetrics` depends on".
True, and beside the point: it is not a `GFMBoxMetrics` question. That file says
what margins a box has; **which** box `.markdown-body > *:last-child` lands on is
a `BlockBoxes` question, and `BlockBoxes` already answered a harder version of it
(`paints`, `nextPainted`). GitHub's tagfilter escapes the leading `<` of
`<style`, `<script`, `<title`, `<textarea` and `<iframe`, so the browser is handed
`&lt;style …` and makes *text* of it, with no element anywhere — and the paragraph
above becomes the article's last child. `producesElement` is four lines on top of
`HTMLBlockShape.opensTagFilteredElement`, which already existed and was already
used one file over. Both `gapAfter` and `gapShares` take the guard, because the
gap lands on the block's last line when no blank line follows it and on the blank
run when one does, and fixing only one of the two is silent.

**A box that paints nothing, inside a rendered embed (#160 bare, +16.10pt).**
The paints-nothing rule was implemented in `BlockBoxes`, which reasons over the
`Block`s the editor parsed — and a rendered HTML embed is **one** block whose
interior boxes belong to WebKit. So the rule could never have reached this
example from where it lives. The one place it can is where the embed's height is
measured, and there it had been written as "put a sentinel at the bottom, or
don't", which is the `:last-child` rule again rather than the paints-nothing one.
`contentHeight(keepsTrailingMargin: false)` now measures `paintedContentBottom`
instead of `.markdown-body`'s border box; the mid-note branch is untouched, where
an empty `<table>` really does separate two margins.

The harness had been holding *two* ideas of where a page stops —
`paintedContentBottomJS` in `Tools/RenderParity`, `contentHeight` in the package —
and they disagreed by exactly the 16.10pt this was scored at. The rule now lives
once, as `GFMRender.PaintedContent.bottomJS`, beside the function that emits the
page. Same shape as `NoteMarkdown`, same lesson: **a gate that keeps its own copy
of what it is grading can only ever measure the copy.**

`NamedDivergence.reason()` now returns `nil` unconditionally and the two
JavaScript shape flags that fed it (`endsInBareText`, `lastBoxPaintsNothing`)
are deleted. Left in, a regression on precisely those shapes would come back
*named* rather than failing — which is worse than never having closed them.

### The gate that lays out a whole document

The corpus tests one construct at a time and every real document is a
combination; §23 already recorded one README-shaped note measuring +7.06pt with
all 672 examples agreeing. The answer to that is not a bigger corpus, it is a
different gate. `RenderParity --docs` lays out **58 real documents** —
`Tools/RenderParity/Documents` — in both engines and compares the painted height
of each, through the same page builder, the same painted-bottom measurement and
the same editor call `--spec` uses, so the two gates cannot disagree for reasons
nobody can attribute. `--locate <file>` lays out every *prefix* of one document a
top-level block at a time and marks the row where the running delta moves, cut on
`BlockParser`'s own tiling because cutting on blank lines halves a fence.

**It failed 9 of 35 documents on its first run**, and nineteen distinct causes
came out of it. Roughly: front matter reserving a paragraph per property
(+240pt); a long code line wrapping in Edit and scrolling in Preview (+20pt a
line); a relative `<img>` inside an HTML block that did not resolve in Edit
(−338pt); `<details>` showing its body in Edit and hiding it in Preview; an
inline image inside a link not seating its line box; a list inside a blockquote
with no `li + li`, loose or new-list margins; a blank quote line holding a
constant instead of the collapsed margin; a reference definition counted as one
of an item's two blocks; a table under a list item's text not rendered at all; a
code box inside a list item laid out 32pt too wide and at the document margin; a
listing inside a list item styled as *prose*; a loose list's opening margin paid
once per wrapped line; a blockquote's lazy continuation at the full pane width;
quoted list items indenting once however deep they nested; a `<pre>` in a quote
missing the quote's right padding.

Three things that came out of it are worth more than the list.

**Width is a dimension of coverage, not a configuration.** With all nine
documents fixed at 800pt, a *second* width found six more defects — every one of
them a horizontal error that only becomes a height when something wraps. The gate
runs at 800, 560 and 1200.

**The harness was wrong twice, and both times it read as the editor.** The settle
wait stopped when the laid-out height had moved and then held still for ten
runloop turns, which with two embeds is satisfied by the fast one: any note
holding both a `<div>` and a `![…]` was measured with the HTML block's *source*
on screen and scored at 294pt. It now asks the renderer (`RenderTally`) and waits
a wall-clock quiet period. And `needsBlockRender` had the editor's own blind spot
for a picture inside a link.

**A concealment applied before the cmark overlay is undone by it.** Three
separate defects had that shape — the overlay paints a `.codeBlock` run across a
fenced block's whole body, markers and indent included. `concealNestedFences`
already existed for the reason and nobody had generalised it.

Two of the nineteen were found only by *looking*, at +0.00pt at every width: a
code box inside a numbered step drawn at the document margin, and a fenced
listing inside a list item styled as prose, so a URL in it came out an underlined
link, `**bold**` lost its asterisks and a backticked word grew an inline-code
pill — against a Preview printing all three literally.

### Two more the gate could not see until it was asked wider

Both were found in this final pass, by running the document gate at widths it did
not gate on, and both are the same species: a number that is exact at the width
somebody happened to measure.

**A heading opening a note inside a list item paid its top margin once per
wrapped line.** `- # Foo` is an `<h1>` in an `<li>`, and its `margin-top`
collapses out through the `<li>` and the `<ul>` to a place where nothing is above
it; TextKit drops `paragraphSpacingBefore` on the document's first paragraph, so
the space had been folded into the *line height*. A line height applies to every
**wrapped** visual line. `StyleApplier` styles without knowing the pane's width,
so it measured exact wherever the heading fits on one line and cost a whole
`headingTopGap` per line the pane took away: **+24.01pt at an 800pt pane, +48.01
at 560, +72.01 at 420**. It goes on the fragment now, as `openingMarginAttribute`
— the same mechanism the loose item's own opening paragraph had already been
moved to, which existed by then and had not been carried across. The file's own
comment had called it a KNOWN LIMIT; a known limit with a mechanism sitting next
to it is a to-do.

**Every rendered embed was capped at 900pt wide.** `syncRenderMetrics` ended in
`min(width, 900)` — a number with no comment, no counterpart in the stylesheet
and no gate that reached it. The page caps nothing: `img` is `max-width: 100%`
and a `<table>` grows to the column. So on any pane wider than about 930pt every
picture in Edit was smaller than the same picture in Preview: a 1600×900
screenshot measured **−33pt at a 1000pt pane and −145pt at 1200**, on an
ordinary maximised window, while 800 and 560 both read +0.00. It is the same
shape as `RenderedBlockFragment.imageGap` — a number living in a renderer that
`GFMBoxMetrics` knows nothing about — and the harness had faithfully *mirrored*
the cap, which is how it came to model the defect instead of catching it: both
sides shrank a wide picture to 900pt and agreed with each other about a page that
does no such thing.

The gate now runs documents at 1200 as well, and `--png` on the editor side
**draws** a scaled image rather than returning a bare `NSImage(size:)`. The old
answer was right for a height sweep and wrong for the one flag whose whole
purpose is to be looked at: an empty rectangle is also what a failed load looks
like, so the instrument could not tell "scaled" from "not there".

### Where it ended

Both sweeps, bare and in context:

    672/672 compared, 672 agree, 0 differ by ≥1pt

No `named` clause is printed, because there is nothing left that could print
one: `NamedDivergence.reason()` returns `nil` unconditionally. The denominator
is the corpus, nothing is excluded from it, and no example is excused.

`scripts/render-parity.sh` exits 0 across all three of its gates: the
hand-written sample at 15 configurations (worst per-block drift 0.03pt), the 58
documents at 1200 / 800 / 560, and the chrome check. It also *measures* the
documents at 420 and reports without failing — that width is where a
four-column table stops fitting, so it is the only place the table-overflow
layout is exercised at all, and it is also where the one open break-opportunity
divergence fires. Both failing documents and both deltas print on every run, so
a new shortfall there is a new line rather than a silence; the reasoning, the
discriminator and the three repairs that were measured and reverted are in the
comment above the loop.

`swift test` is **398 tests in 31 suites** (28.9s); the iOS simulator run is
**192 in 13**. macOS Debug, macOS Release and the iOS Simulator all build clean.

**Is this full GFM conformance?** For the geometry the corpus can express, yes:
every one of 672 examples, in both modes, with nothing named and nothing
dropped. For a *document*, nearly: 58 of 58 at three widths, and 56 of 58 at a
fourth, where two notes lose 20pt each to a line-break opportunity TextKit takes
after a solidus and WebKit does not, and one of those two also loses 24pt to a
table that has not finished shrinking. What is not conformance, and is worth
saying in the same breath, is that Preview and Edit still show *different
content* in three places — display maths, a note transclusion in a real vault,
and an export that never takes the note→GFM step at all. Those are features
rather than measurements, and `docs/unimplemented.md` lists each with the
command that reproduces it.

The through-line of the whole effort, from the first wave to this one: **the
scoreboard was wrong in more ways than the code was**, and every time it was
wrong it was wrong in the direction that flattered the editor. Examples dropped
from the denominator, twenty-four never parsed, two different quantities
compared, two fallbacks scored against each other, an appearance gate reading
dark ink on a dark page, a settle wait satisfied by the wrong render, a harness
mirroring the very cap it should have caught, and three divergences excused by
reasons with nothing in them to check. None of those was found by looking harder
at the editor. Each was found by asking what the gate was actually measuring.

### Where it ended

Both sweeps, bare and in context:

    672/672 compared, 672 agree, 0 differ by ≥1pt

No `named` clause, because there is nothing left to print one for. Every section
reads 0 differing, extensions included, and nothing is excluded from the
denominator.

The rest of the gate, on the same tree:

| | |
|---|---|
| `swift test --package-path Packages/NotesEditor` | **398 tests in 31 suites**, ~28.6s |
| the same package on iOS (`xcodebuild test … HN-iPad`) | **192 tests in 13 suites**, TEST SUCCEEDED |
| `./scripts/render-parity.sh` | exit 0 — 15/15 sample configurations (worst per-block drift 0.03pt), documents **58/58 at 1200, 800 and 560**, 420 reported as advisory, chrome parity ok |
| the app | BUILD SUCCEEDED for macOS Debug, macOS Release and the iOS Simulator |

The document gate also *reports* 420pt without failing on it, and that row is
part of the answer rather than a hole in it: it is where a four-column table
stops fitting, so it is the only width at which the overflow layout is exercised
at all, and it is the only width at which the one open, measured divergence
fires. It prints both document names and both deltas every run, so a new
shortfall there is a new line rather than a silence. `docs/unimplemented.md`
carries what those two are, each with the command that reproduces it.

**What the whole effort is a record of: the scoreboard was wrong in more ways
than the code was.** Fifteen examples were dropped from the denominator, 24 were
never parsed at all, the two engines were being asked for different quantities,
the image corpus compared two fallbacks against each other, the appearance gate
was reading dark ink on a dark page, three examples were *excused* by reasons
with nothing in them to check, the harness built its preview without the step the
app takes, kept a second copy of where a page stops, and mirrored a 900pt cap the
page has no equivalent of — so both sides shrank a wide picture and agreed with
each other. Every one of those made the editor look better than it was. And the
last two defects found were found by running the same gate at a width nobody had
asked it for, which is the shortest statement of the lesson: **a measurement is
only evidence about the conditions you measured under.**
