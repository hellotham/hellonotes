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

Full design and rationale: [ui.md](ui.md), which incorporated `layout-architecture.md` on 2026-09-24;
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

## 35 · The screenshots, and the asset that could not be remade (2026-08-29)

Build 13 was submitted three times before its store listing was right. What
went wrong was never the app.

### iPad had one screenshot

Two submissions went out with the iPad tab holding a single stale light-mode
capture, because the check was "does the iPhone tab look right". Screenshots
are per-platform **and** per-display-size, and App Store Connect shows one size
at a time — `0 of 10` and `1 of 10` read identically at a glance. The release
skill now carries the whole grid with expected counts, and the devices that
produce each required size: iPhone 13 Pro Max → 1284×2778, **iPad Pro 13-inch
(M4) → 2064×2752**. The 11-inch gives 1668×2420, which ASC rejects and whose
aspect ratio makes rescaling impossible.

Also learned the expensive way: **screenshots cannot be edited while a version
is Waiting for Review** — the file input is not in the DOM. Getting one wrong
costs a removal from review and a resubmission, so the inventory belongs
*before* submitting.

### The raw macOS captures did not exist any more

The store wanted undecorated screenshots. There were none. `make-screenshots.py`
composites the branded website frames *from* raw window captures — gradient,
caption, rounded corners, drop shadow — and every step is one-way, so a finished
frame cannot be cropped back into a clean screenshot.

The originals had been shot into a session scratchpad in July, fed to the
script, and dropped; the script's own docstring called capturing them "a manual
step" and stopped there. The search that followed is the useful part, because
every plausible hiding place was empty:

| Looked | Found |
|---|---|
| `dist/Screenshots` + `dark/`, `website/src/assets/screens` | all composited |
| every PNG >100k on the machine since August | nothing window-shaped |
| git history — `shot_01..05.png`, deleted in `3a4e1d7` | composited, 1600×1000 |
| ASC Media Manager | composited |
| all 40+ session scratchpads, `/tmp`, `/var/folders` | the `raw/` dir was gone |
| **session transcripts** (1,612 images extracted) | **capped at 1999px** |

That last row is the one worth remembering: **a transcript downscales, so it is
a record and not a backup.** The only route left was re-shooting on the author's
own Mac, against his private vault — the exact cost the files existed to avoid
paying twice. `assets/screenshots-raw/` is now tracked and the script copies its
inputs there.

### Re-shooting them, from the original session's own commands

The method was recovered by reading the July session's transcript rather than
inventing one: Debug build via `relaunch-debug.sh`, window geometry set with
AppleScript, `screencapture -l<windowID>`. A **1280×800pt window captures at
exactly 2560×1600** on a 2× display, so the store size is the window's own
rather than something padded afterwards.

One correction to §15's received wisdom. It says synthetic clicks do not
register in this SwiftUI app; that is true of **coordinate** clicks, but AXPress
on a *named element* works — which is how the inspector toggles
(`click (first button of toolbar 1 whose description is "Outline")`) and every
menu item are reachable. Opening a collection remains the one step nothing
exposes to scripting, and it is why the July session never scripted it either.

### Two defects found while doing it

`make-screenshots.py` read `f"{mode}_{int(num)}.png"` and wrote
`f"{mode}_{num}.png"` — it wants `dark_1.png` and produces `dark_01.png`. A
capture named after the *output* is silently skipped with one `! missing` line
among ten. It now accepts both.

`relaunch-debug.sh` had been broken earlier the same day by a fix to something
else: the guarded `{ pgrep … || true; }` became a bare `pgrep`, which exits 1
when nothing matches, under `set -euo pipefail`. The script aborted with exit 1
and **no output at all** whenever the app was not already running — which reads
as a broken environment rather than as a script deciding there was nothing to
kill.

### The rule that came out of it

Written into CLAUDE.md: *if remaking an asset needs someone's machine, their
vault, or their time, commit it the first time.* And its companion, paid for by
three captures of a private 2,019-note vault taken while checking whether the
vault had switched: **screenshotting to check is capturing.** Verify the loaded
collection by reading `collectionPaths`, never by looking.

---

## 34 · Every note lost its first character (2026-08-29)

Build 12 shipped to review with the iPhone drawing `Transclude` as `ransclude`,
`Below is…` as `ow is…`, and the same bite taken out of every line of every
note. Build 13 is the repair. Marketing version stays 1.3.2.

### What it was

The editor's bottom bar is an `HStack` of `.fixedSize()` menus and fixed-width
buttons, so it **cannot compress**. On a 428pt iPhone its minimum is 512.67pt.
Three SwiftUI facts then compose into the defect:

1. a stack that cannot shrink to the width it is offered reports the width it
   **contains**;
2. a `VStack` takes the width of its widest child;
3. SwiftUI **centres** an oversized subview in its parent.

So the pane, the inline title and the text all became 512.67pt wide and sat at
`(428 - 512.67) / 2 = -42.33`. The navigation bar is not in that stack, so it
stayed perfectly inset at 21pt — which is exactly why the screen looked *almost*
right and the fault read as a text-rendering bug rather than a layout one.

This is the **horizontal form of the viewport rule** the editor already obeys
vertically (§17): report the size you are *offered*, never the size you contain.

### How it was found, after two wrong turns

`MeasuredText` was the obvious suspect and was innocent — its probe reports
`pane=428 kind=compact -> (width: 396.0, centred: false)`, which is correct. A
pixel scan of the simulator then measured the h1's rule at `0.0..336.3` **on
every note regardless of content**, and `396 - 336.3 = 59.7` said the column was
*displaced*, not mis-sized. The two `EditorProbe` frames logged only `top` and
`height` — the axis that was not broken — so they were widened to log `x` and
`width`, and answered `x=-42.33 width=512.67` on the first run.

Three things this cost, worth keeping:

- **The instrument decided the answer.** Two probes existed at exactly the right
  place in the hierarchy and were blind to the failing axis. A probe that
  reports half a rect measures half a bug.
- **`onAppear` is not the settled layout.** Both probes fired mid-presentation
  and reported `width=34` / `height=0`. Only the `onChange(of: mode)` reading was
  the real geometry.
- **A constant across two documents is not content.** The same 336.3 appeared for
  a 168,576-character note and a 22-word daily note, which is what ruled out the
  content-driven reading of the same symptom.

### The fix, and why not the other two

`ViewThatFits(in: .horizontal)` picks the plain row whenever it fits — verified
byte-identical on an 834pt iPad, where all eight trailing controls still show —
and falls back to a horizontal `ScrollView` only where it does not.

Truncating the bar would have been worse than the bug: *a command nobody can
reach is a command that does not exist*. Dropping controls on iPhone would have
broken the cross-platform rule the app is built on.

### The check, and its negative control

`HelloNotesUITests.testTheOpenNoteIsNotClippedOffTheScreen` opens a note on a
compact device and asserts every static text starts at or right of the screen's
leading edge — **left only**, because content scrolled off to the right is
ordinary and content off to the left is this bug.

It closes the gap the UI tests had *named in their own source*: "the editor and
the inspector are not swept … reaching a note takes a step this test did not
model." That admission was accurate, and the defect landed in exactly the space
it described.

Proved by reintroducing the fault and watching it fail:

```
XCTAssertGreaterThanOrEqual failed: ("-32.33") is less than ("0.0")
  - "0 words" starts 32.33pt off the left edge
```

`-32.33` is `-42.33` plus the bar's own 10pt of padding — the predicted number,
not merely a red test.

### It was never only an iPhone bug — 1.3.2's DMG re-cut as build 13

Reported and fixed as an iPhone defect, and that framing was wrong. The bar's
minimum is a property of the *bar*, not of the phone: any container narrower
than it gets the same centring. The Mac's main window cannot reach it —
`ShellMetrics.windowMinWidth` is 860 — but `NoteWindowView` lets a **detached
note window** go to `minWidth: 480`, and 480 < 512.67. So narrowing a note
window on a Mac clipped its text too, about 16pt a side instead of 42, in a
window most people never narrow. That is why it went unreported, not why it
was absent.

So the App Store got build 13 and the download page was still serving build
12 of the same version. Re-cut from the **same archive** the App Store build
came from — the app source was verified byte-identical to the build-13
commit, and an `.xcarchive` is signing-agnostic until export, so the only
difference is `ExportOptions.plist`'s `developer-id` in place of
`app-store-connect`.

| | |
|---|---|
| **DMG** | 1.3.2 **(13)** — universal, notarised, stapled; 39.6 MB, `0156d247…` |
| Replaces | 1.3.2 (12), `0deb43d8…`, published the same day |
| Verified | `accepted / source=Notarized Developer ID`, staple validates offline, `x86_64 arm64`, and `latest` re-fetched and hashed to prove it serves the new bytes |

The tag was not moved and the button's URL did not change: the asset on
`v1.3.2` was replaced, so `releases/latest/download/HelloNotes.dmg` re-points
by itself. `site.ts`'s `version` stayed at 1.3.2 — only `size` and `sha256`
moved, which is the whole shape of a build-level respin.

### Two false alarms, and the check that came out of them

Writing the test produced two reports that were both wrong, and the way each
collapsed is worth more than the test was.

**"A button with no accessibility label."** A dump of the Notes place showed one
with an empty label, and it read as an unnamed control. Dumping *frames* instead
of just labels ended it in one run: the empty element has the **same frame** as
"More actions" and is not hittable. SwiftUI gives a `Menu` two accessibility
elements — the interactive one, which carries the label, and an inert twin for
the `Image` used as its label. It is the only unlabelled button in all four
places, and it is that twin.

**"The iOS editor suite runs 194 of the documented 381 tests."** It runs all
381. The command produces **three** bundle summaries — 169/12, 18/4, 194/13 —
and `tail -3` showed only the last. CLAUDE.md was right the whole time and now
says so out loud, because the next reader will make the same mistake.

What survived is `testEveryReachableControlHasAName`, and only after a negative
control killed the obvious version of it. "No reachable control has an empty
label" **cannot fail**: delete `.accessibilityLabel("More actions")` and SwiftUI
names an `ellipsis.circle` menu "More" by itself. What it does for an icon it has
no name for is fall back to the **SF Symbol's raw name** — swap that image for
`scribble.variable` and the button is announced as `scribble.variable`, aloud, to
someone who cannot see it. That is the real defect class, it fails when
introduced, and it is what the test asserts.

Three checks were written here. The one that shipped is the one that could fail.

---

## 36 · Two ways to back the app, and neither of them gates anything (2026-09-02)

> **Superseded in part by [§42](#42--the-one-thing-backing-the-app-buys-2026-09-03).**
> Exactly one thing consults a purchase now — an in-app support request — and
> `noFeatureConsultsAPurchase` is `onlyTheSupportRequestConsultsAPurchase`.
> Everything below about the *products* still holds.

App Review rejected build 14 under **guideline 3.1.2(c)**: the binary sold an
auto-renewable subscription and had no purchase screen at all. The subscription
existed in App Store Connect; nothing in the app had ever mentioned it.

Two products, and they are different *kinds* of thing:

| | Champion | Commercial |
|---|---|---|
| StoreKit type | **Consumable** | Auto-renewable subscription |
| Price | A$50 | A$50 / year |
| Repeatable | yes — "5× Champion" | renews |
| Product ID | `…​.champion.contribution` | `…​.commercial` |

**A non-consumable cannot be bought twice.** A `…​.champion` non-consumable
already existed in App Store Connect from an earlier pass, and the requirement
is that someone can back the app more than once and have it counted. A
non-consumable answers the second purchase with "You've already purchased this",
and App Store Connect will not change a product's type after it is created — so
the repeatable one is a new consumable beside it, which is why the identifier
has a suffix nobody would otherwise choose.

**Counting a consumable is the app's job.** `Transaction.currentEntitlements`
never contains consumables: an entitlement is something you still hold and a
contribution is something you did. So the count is kept, and the naive spelling
loses it. `StoreService` merges **three** sources — `UserDefaults`, iCloud's
key-value store, and `Transaction.all` filtered to the product — and merges them
as a **maximum**, never last-write-wins. A device that has been offline holds a
*stale* number, not an older one, and `CloudPrefs`' generic mirror would happily
push 2 over 3. That is why this one key is deliberately not in `CloudPrefs.keys`.

**The five disclosures are the deliverable.** 3.1.2(c) wants the subscription's
title, its length, its price per period, and working links to the Terms of Use
(EULA) and the privacy policy, *in the binary, on the screen where the purchase
happens*. Each is a labelled element of `SupportSettingsView` and each is
asserted by `SupportContractTests`, because a disclosure deleted in a tidy-up is
the same rejection again six weeks later. The subscription's length is read from
`Product.subscription.subscriptionPeriod` rather than written as a literal, so
it cannot drift from App Store Connect.

**The privacy link had no trailing slash, and that was not a detail.** The site
is an Astro project page: `…/hellonotes/privacy` is 200 and `…/hellonotes/privacy/`
is **404**. A dead policy link on the one screen a reviewer is required to open
is a rejection. It was caught by `curl`, not by reading.

**Nothing is gated, and that is tested.** No feature consults a purchase —
`noFeatureConsultsAPurchase` walks every Swift file outside the store and its own
screen and fails if any of them so much as mentions `hasCommercialLicence` or
`championCount`. A paywall cannot be added by accident. *(§42: one thing does
now — a support request, which is a channel rather than a feature. The test
became an allow-list of three files and still fails for anything else.)*

**A spinner that never stops is a lie.** Run against the live App Store, the
newly created Champion product was simply absent — propagation takes hours — and
the screen drew "Contacting the App Store…" forever, because `load()` finishing
was being treated as "every product arrived". The spinner now belongs to the
*load*; a product still missing afterwards says so and offers Try Again. Found by
running the real screen against the real store on a simulator, which is also how
the Commercial product was confirmed to load, price and period and description
intact, before anything was submitted.

**And the menu that only existed with a keyboard.** `File ▸ Open Default
Collection` is built on iPadOS too — iPadOS builds its menu bar from `.commands`
— but reaching a menu bar needs a hardware keyboard, so on a bare iPad the
command did not exist. It is in `addCollectionItems` now, which all three touch
menus share.

---

## 42 · The one thing backing the app buys (2026-09-03)

§36 ends "and neither of them gates anything". That is no longer true, and the
reason is a promise the listing was making that the app could not keep.

App Store Connect described Champion as offering **"priority support requests"**
— a queue that does not exist anywhere in the product. Nothing ranked one
request above another, because there was no way to make a request at all. Two
ways out: build a queue, or stop promising one. What can honestly be offered is
a *channel*, so there is now an in-app support request, and it is the single
thing a purchase decides.

Everything the app **does** stays included for everyone. The invariant that
enforced that was `noFeatureConsultsAPurchase`, which failed the build if any
file outside the store mentioned an entitlement; it is now
`onlyTheSupportRequestConsultsAPurchase`, with an allow-list of three files that
is meant to stay three. The absolute was easy to police and the boundary is
worth more: a purchase still cannot decide what the app can do.

An allow-list proves nothing about whether the permitted file uses what it
permits, so a second test asserts the gate is *there* — remove it and the
allow-list would go on passing quietly.

**The app sends nothing.** `SupportRequestSection` composes a `mailto:` and
hands it to the user's own mail client, where every word — including the
diagnostics — can be read before it is sent. There is no endpoint and no
account, which is what keeps the "Data Not Collected" privacy answer literally
true. The diagnostics are versions and platform; a test enumerates the things
that must never appear in them (`/Users/`, `.md`, collection names) because a
diagnostic block is exactly where that answer quietly stops being true.

The URL is built with `URLComponents` rather than string-joining: a summary
containing `&` would otherwise truncate the body, and the request would arrive
empty with the sender blamed for it.

**And the purchase screen stopped saying nothing is gated.** It had said
"Nothing on this screen unlocks a feature" for as long as that was true, and a
stale reassurance is worse than none — the same error as the listing's
"priority". What survives is the claim that still holds: every feature is
included for everyone.

Verified on the simulator rather than from the source, which caught something no
test would have: the locked state told the reader the two products were "below"
when they are above it. It names no direction now.

---

## 37 · Nothing runs between two keystrokes (2026-09-02)

> *"THERE IS NO CODE IN THE EDITOR LOOP — apart from capturing a key and
> displaying on screen. NOTHING. Everything else is outside the loop, on
> different threads."*

Typing on an iPad, against a 2,000-note vault in iCloud Drive, could not keep up
— and the lag varied, sometimes locking the keyboard entirely. Varying lag is
the tell: a constant cost is slow, a varying one is *something else running*.

What was running, per keystroke:

- **Two whole-document cmark parses.** `GFMLiveStyle` was asked for the styled
  runs and for the unrendered ranges separately, and each parsed the document
  again. One parse now answers both (`styleInputs`), and the whole-document pass
  came off the keystroke entirely — the overlay shifts for the edit and a
  coalesced refresh follows 120 ms later.
- **Two syscalls per sidebar row**, `fileExists` and a `resourceValues` for the
  cloud badge.
- **iOS spell checking**, whose autocorrection controller blocks on
  `UIKeyboardTaskQueue`'s condition lock.
- **`documents.forgetAll()` on every save.** It hung off
  `.onChange(of: library.allNotes)`, and `Note` is `Hashable` over
  `lastModified` — so *any* save changed the list and dropped every parsed
  document, including the one being typed into. That is also what ejected focus
  after creating a note.
- **Saving, and announcing the save.** A save taken mid-keystroke is already out
  of date, and the announcement was a layout shift.

Measured worst-case per keystroke: **11.90 ms → 0.68 ms** on a 120 KB note, and
108.95 ms → 11.97 ms on a 3.8 MB one. On the device, `onEdit` is 0.00 ms —
78 keystrokes produced 78 log lines and nothing else.

**Three instruments were wrong before any of this was found.**

The existing performance test used a **3.8 MB** document, which is *above*
`gfmOverlayMaxLength` (200,000) — so it took the fast path and could never have
caught the bug it was written for. `keystrokeStaysSubFrameJustUnderTheOverlayCap`
runs at 120 KB now.

The watchdog could not see the stall it existed for: a 250 ms poll and a 300 ms
stack threshold against stalls of 130–300 ms. It is 40 ms and 90 ms.

And the probe added to measure the keystroke cost **225 ms of it**, writing to a
file synchronously on the main actor. Its I/O is on a serial background queue.

**A data-loss path opened while emptying the loop and was caught before it
shipped.** With `scheduleSave()` reduced to a no-op, `model.text = snapshot` no
longer wrote anything, and 67 typed characters never reached disk. The save is
explicit in `landPendingSync()` now, plus a flush on mode change.

---

## 38 · The iPad has its own metrics, and 16 was a macOS number (2026-09-03)

Note text looked small on iPad because it was. The editor's base size was
`16 * textScale` on both platforms — 3pt above macOS's 13pt system font, and
**1pt below** iOS's 17pt `.body`. The reading surface came out smaller than the
app's own sidebar labels: measured 16.1pt body against 15.6pt chrome, where the
Mac has 16 against 13. A constant that encodes a *relationship* to the platform
cannot survive being copied to a platform with different metrics; it inverts.

iOS derives its base from `UIFontMetrics` now, which also closes an
accessibility gap nobody had noticed: **note text never followed the system Text
Size.** The in-app slider drove the editor and Dynamic Type drove only the
chrome, so raising Text Size in Settings grew the sidebar and left the note
exactly as it was.

**Changing it broke Edit ≡ Preview, which is how the real defect surfaced.**
`GFMPage.page` took a *scale* and computed `16 * scale`; `EditorTheme` took a
*size*. Two surfaces deriving one quantity from two sources, agreeing only
because both started at 16 — so the moment the editor moved to 17, Preview kept
rendering at 16. `NoteEditorPane` was passing both at once.

It was found by measuring rather than reasoning: the H1 refused to grow and the
ratio came back 1.022 where 1.063 was predicted. The parity harness could not
have caught it — it runs on macOS, where the coincidence still holds. The page
takes an absolute base in points now, and `GFMPreview` measures at **the theme's
own size**, so divergence is not something a caller can express.

**The sidebar row spent two lines on a note**: the title, then
"2 Sep 2026 at 7:28 am" underneath — 21 characters, wider than the title it
would have sat beside. The date now says the nearest unit that differs (a time
today, "Yesterday", a weekday, a day and month, a numeric date), which fits a
column; and over `ShellMetrics.noteRowTwoColumn` it moves up beside the title.
Width decides, not device. A search row keeps its snippet on a second line —
prose needs the width, a date never does.

The single-line row first came out at **66pt**, taller than the 63.5pt two-line
row it replaced: a `minHeight` on row content is *added* to the List's insets
rather than absorbed. The floor belongs to the List.

**And the tall shell's band became two panes** (`shell-chrome.md` D2a). On an
iPad in portrait the band is 834pt wide and 320pt tall, so one tree spends its
width on nothing and runs out of height in eight rows. D2 — "collections and
folders are one tree" — still holds for a sidebar *column*, where it was written
and where a 220–340pt width leaves room for one list; the band is a
`NavigationStack` in a `VStack`, not column one of a `NavigationSplitView`, so
there is no platform-placed toggle to lose. Both panes derive from
`SidebarTree.roots`, so "in one pane and not the other" is not reachable.

Row heights came down to what the rows contain, measured with
`NSLayoutManager.defaultLineHeight`: a Mac note row is 30pt of text and was
given 42. Deriving a height from content makes every unstated intrinsic size in
the row a clipping hazard, which is why the collection row's close button now
states its symbol size.

---

## 39 · A picture believed rather than checked (2026-09-03)

**Launch stopped noticing changes made while the app was closed.** The startup
walk had been replaced by a read of `CollectionIndexCache`, on the written
reasoning that the watcher would report anything that had moved. It cannot:
`DirectoryObserver` opens its stream at `kFSEventStreamEventIdSinceNow`, so
nothing from before launch is ever delivered — a claim made from reasoning,
contradicted by the line of code it was reasoning about. The cache is not a
directory listing either: it holds one record per *parsed* note, and
`refreshDerived` deliberately skips notes that are not local, so on a
part-downloaded cloud vault it is a strict subset of the folder.

The cache decides the first frame; the folder decides the truth. Paint from the
cache, then verify against disk in the background — and `apply` ignores a
picture identical to the one on screen, so an unchanged folder costs no revision
bump and no outline rebuild.

**Rescan Collection did nothing on a collection that already had notes** — older
than the above, and the reason the only reliable repair was to close the
collection and add it back. `WalkResult.isComplete` is `issues.isEmpty`, so one
directory the walk cannot list marks the whole pass incomplete even though it
drained the frontier and read everything else. That verdict reached a branch
that published only when nothing was on screen yet: a fresh collection has an
empty list, so it published; a populated one discarded the entire pass in
silence.

An incomplete pass merges now, and merges precisely: a pass that started at the
root and drained its frontier visited every directory *except the ones it
names*, so it can tell a deletion from a blind spot.

**And the banner that could not go away.** `StaleReason.scanIncomplete` meant
both "a scan was interrupted" and "a folder could not be read", under one
message that said *"is being re-indexed … until it finishes"*. For the second,
nothing was in progress and nothing ever would be, so the message was untrue and
unclearable. The reasons are separate, and the unreadable one names the folder
and quotes the system's own error — "permission denied" and "no such file" are
fixed in completely different ways. One retry first, because on iOS a listing
can fail purely because the File Provider was not ready.

---

## 40 · A note that could not be read is not an empty note (2026-09-03)

Reported as *"clicking a file that hasn't materialised does nothing — I have to
click again after it materialises."* Two faults, and the second is much worse
than the one reported.

**The tab appeared only after the content did.** `EditorTabs.editor(for:)`
appended the model to `editors` after `await model.open(note)`, and `open`
blocks in the file coordinator until a cloud file arrives — so the click had no
visible effect at all for the length of the download. The editor already knew
how to say it was downloading; it just had to be on screen to say it.

**A failed read became an empty note.** `open` did
`try? FileIO.readString(…) ?? ""`, with a comment claiming the read would
materialise the file on its way past. Sometimes it does. When it does not, `""`
is not a failure — it is an empty document. `lastSavedText` became empty too, so
the first character typed made the buffer dirty against an empty baseline and
the next autosave wrote that over the original.
`FileIO.hasContentAvailable` says this in as many words — *"an editor that opens
one will upload the emptiness back over the original"* — and the editor was the
one place not asking it.

The editor materialises and waits before reading (`FileIO.materialise`, which
polls, because `startDownloadingUbiquitousItem` has no completion handler), and
a buffer that was never loaded is **never written**. The edit is refused, not
discarded: the buffer stays dirty, as it does for every other blocked save.

Demonstrated by removing the guard and watching an hour of work become the
single character `"x"` on disk.

---

## 41 · One folder, two names (2026-09-03)

CI was red for four rounds while this machine was green every time, and the
first two diagnoses were made by reasoning about a machine that could not be
seen. Both were wrong. What settled it was making the test print its own facts:

    root:     /var/folders/…/hn-freshness-…
    prefixes: ["/var/folders/…/hn-freshness-…/"]
    notes:    ["/private/var/folders/…/Note 0.md", …]

**`/var` and `/private/var` are one directory with two names**, and
`standardizedFileURL` does not unify them — it resolves `.` and `..` and stops.
`FileManager.temporaryDirectory` named a collection's root one way while
`contentsOfDirectory(at:)` named every file inside it the other, so no prefix
matched and `relativePath` returned each file's *absolute* path as though it
were relative. The cache stored that, and reopening built
`root.appending(path: "/private/var/…/Note.md")` — a URL for a file that does
not exist.

**The helper meant to cover this covered nothing**, because
`resolvingSymlinksInPath` fails in the direction that surprises you: it
normalises *towards* the short name. Given `/private/var/x` it returns `/var/x`,
not the reverse, so asking it for "the other spelling" of a root already written
as `/var/…` returns the same string. The long form is added by hand now.

**Same notes in a different order is not a change.**
`CollectionIndexCache.notes(for:)` sorts a **Dictionary's** values, and a
dictionary's iteration order depends on the process's hash seed. With distinct
modification dates the sort has something to order by; with a tie it has
nothing, so the same notes came out ordered differently on different runs — and
comparing the two pictures as arrays of `Note` called that a change, republished,
and rebuilt the whole sidebar on every launch. Ties are not exotic: anything
written, copied or checked out in one batch shares a date. A picture is compared
as sets of relative path plus fingerprint now.

**`compactDate` ignored the `now` it was given** — `isDateInToday` asks the
calendar what today is, so a date was "today" according to the machine's clock
rather than the caller's reference. Wrong for anyone whose day rolled over with
the app open.

**And a vault reached through a symlink was not a vault.**
`contentsOfDirectory(at:)` refuses a symlink at the *end* of a path with
ENOTDIR, even when the link points at a good directory — while the `atPath:`
variant does not, and that is the one `Collection.unavailability` uses. So
`~/Notes` pointing into iCloud Drive passed every availability check, reported
itself healthy, and failed its very first listing: nothing was wrong, and
nothing was there. Resolved for the enumeration only; the stored URLs keep the
collection's own spelling, because swapping it would trade one mismatch for
another.

**One test was passing because of a bug.** With absolute paths in the cache,
`notes(for:)` discarded every record as unusable and `activate` fell through to
a synchronous full scan — so
`aCacheHoldingFewerNotesThanTheFolderDoesNotDefineTheCollection` never had to
wait for the asynchronous verification it existed to test. Fixing the cache made
it fail. A green test can be resting on the very defect you are about to remove.

---

## 43 · Six things nobody could see from the other platform (2026-09-03)

Found while shooting store screenshots — which is the point worth keeping: the
screenshots were the first time anybody *looked at* several of these surfaces on
the device that had them wrong.

**The compact shell built its own note row.** `ContentView.noteList` drew title,
cloud badge and `.dateTime.year().month().day().hour().minute()` inline instead
of calling `NoteRowContent`, whose own header says a row that gains a field
gains it on both platforms or neither. So the iPhone was the one surface that
never got the compact date or the responsive two-column rule: it read
"3 Sep 2026 at 12:00 pm" where every other surface read "12:00 pm", and fitted
nine rows where it now fits fourteen. Three implementations of one row is the
defect; the fix is that there is one.

**Every `.popover` in the editor's bottom bar became a full-height sheet on
iPhone.** SwiftUI substitutes a sheet at a compact width, silently, and a sheet
hands its content the whole height — so `referencesPopover`
(`.frame(width: 320).frame(maxHeight: 360)`) drew as a 360pt island floating in
the middle of a 900pt sheet: no title, no grabber, no Done button, nothing
saying it was the Links panel. `showGitPane` alone said
`.presentationCompactAdaptation(.popover)` and alone looked right. The tell was
that one instance of a repeated pattern behaved differently.
`EditorToolbarContractTests.everyPopoverStatesItsCompactAdaptation` counts
popovers against stated adaptations — and had to be taught to ignore comments,
because its first run counted the sentence *describing* the modifier and failed
4-against-5.

**`[[Target|alias]]` showed its target.** The parser put the whole inner text in
one content run, so the editor drew `Examples/Nested Note|example in a subfolder`
where it should read *example in a subfolder*. Resolution never had the bug —
`StyleApplier.baseTitle` splits on the pipe — which is exactly why it survived:
the link always worked. Handing the `target|` prefix back as a marker range is
the whole fix; `StyleSpec` already conceals a wiki link's markers when the caret
is elsewhere.

**The spell checker underlined the app's own vocabulary.** "transclusion",
"blockquotes", "backlinks" and "unstyled" all drew the red misspelling squiggle
— in the bundled manual, which is the first thing a new user reads, and in the
screenshots, where it reads as a typo in the marketing.
`MarkdownVocabulary.ignore(in:)` sets them as *ignored words* on the text view's
own spell-document tag: nothing global, nothing written to the user's
learned-words file. The list was derived by running `NSSpellChecker` over
`DefaultCollection/*.md` with code, math, front matter, link targets, URLs and
tags stripped — not from memory. That scan also reported `colour`, `licence`,
`Organising` and `Summarise` (British spellings, correct, and not flagged by the
dictionary the app runs against) and `frac`, `infty`, `sqrt` (LaTeX inside `$$`,
visible only while the caret is in the block).

**The link graph could not resolve a path.** `LinkGraph.resolution` held titles
and aliases only, so `[[Manual/Collections]]` — five of which `Manual/Index.md`
writes — resolved to nothing: no backlink, no outgoing link, no edge. The graph
window drew the bundled manual as five orphans and reported 14 links where there
are 22. `![[Manual/Collections]]` had transcluded correctly the whole time,
which is the shape of the bug: **two resolvers for one question, and only one of
them fixed.** `CollectionEmbedProvider.pathKeys` moved to
`MarkdownParsing.pathKeys` and both now call it. They also disagreed about
collisions — the graph was last-wins, the provider first-wins — so `[[Index]]`
and `![[Index]]` could name different notes in the same collection. Both are
first-wins now, in three ranks: a title beats another note's alias, and both
beat a path key we derived.

**Ask Your Library showed its answer's Markdown.** `Text(answer)` drew
`**Creating Links:** Typing `[[` allows you to…` exactly like that. The
Assistant did better with `Text(LocalizedStringKey(text))`, the usual SwiftUI
trick, and paid for it twice: that path is `.inlineOnly`, so it discards every
line break and folds a bulleted answer into one paragraph, and it looks
arbitrary model output up in the localisation table on the way past. One
renderer now (`AnswerMarkdown`), used by both — line-based, deliberately not the
editor's document engine, because an answer bubble needs bold, code, links,
bullets and line breaks and nothing else. Its test asserts the emphasis is
*applied*, not merely that the asterisks are gone: a stripper would pass every
other assertion.

### What the screenshots taught, separately from the app

- **A region capture is a screen recording.** `screencapture -R` raised a TCC
  prompt — "requesting to bypass the system private window picker" — which is a
  security dialog to leave alone, and which stole focus, so every keystroke and
  menu click sent afterwards landed nowhere. `-l<windowID>` needs no such grant
  and already includes the window's child windows, so a `.popover` composites
  into the parent's capture with nothing to stitch.
- **A locked screen has no windows.** `CGWindowListCopyWindowInfo` returns
  nothing and System Events counts zero while the session is locked, so a
  healthy app looks like it launched without a window. `ioreg -n Root -d1 -a |
  grep CGSSessionScreenIsLocked` settles it in one command; it was nearly a
  session spent hunting a regression that did not exist.
- **The caret reveals the syntax it is inside**, so it decides what a screenshot
  shows. Front matter draws as raw YAML while the caret is in it and folds away
  when it is not — the first four attempts at the flagship shot all opened on a
  `---` block for that reason alone. The same rule showed the LaTeX source of an
  inline `$…$`, and the backticks of a code span, in three separate captures
  that otherwise looked finished.
- **A light/dark pair must differ only in the theme.** The website cross-fades
  between them, so a different scroll position, a different set of open tabs or
  a caret in a different place all read as a glitch rather than a theme. Two of
  the ten had to be reshot for exactly that: `dark_01` because the caret sat in
  a code span and showed its backticks where its twin did not, and `light_03`
  because it was taken before the front-matter fold was understood.

## 44 · The 3.1.2(c) demonstration, and a word with no space in it (2026-09-03)

App Review asks for two different things about the in-app purchases, and only
one of them is a screenshot.

**`assets/iap-review/support-screen-ipad.png`** is the Guideline 2.1(b) App
Review screenshot — one file for both products, because both appear on the one
screen — retaken against the live App Store so the prices are real. It had to be
retaken anyway: the previous one predates the support-request gate, so it showed
a screen that no longer exists.

**`assets/iap-review/support-flow-ipad.mp4`** is the 3.1.2(c) demonstration, and
it exists because a screenshot cannot show what the guideline actually asks for.
The wording is *functional* links to the Terms of Use and the privacy policy, and
function is not a thing a still image has. So the recording follows both: tapping
Terms of Use loads Apple's standard EULA in Safari, tapping Privacy Policy loads
`hellotham.com/hellonotes/privacy`, and it returns to the app after each. The
other four disclosures — title, length, price per period, and the automatic
renewal sentence — are on screen with live App Store prices.

Following the links is also what found the next defect. The privacy page rendered
**"HelloNotesreads and writes only the folders you explicitly open"** — one word
where there should be two. `privacy.astro` ended a line with the `{APP.name}`
expression and continued the sentence on the next line, and JSX discards the
newline adjacent to an expression, so the two words met. It had been live on the
public privacy policy — the one page a reviewer is required to open — for as long
as the page has existed. The codebase already had the idiom for it (`{' '}`,
used correctly in `manual/organising.astro`); this line simply never got it.

A scan of every `.astro` file for the same shape — an expression at the end of a
line with prose continuing below — found exactly one more candidate, and that one
was already correct. Worth knowing the failure has a shape you can grep for,
because it is invisible in the source: the line looks perfectly normal, and only
the rendered page shows the missing space.

## 45 · 1.3.2 build 20 — both channels, one archive (2026-09-03)

| | |
|---|---|
| **TestFlight** | iOS **and** macOS 1.3.2 (20), uploaded from `ExportOptions-AppStore-{iOS,macOS}.plist` (`destination = upload`, so the export *is* the upload) |
| **DMG** | [v1.3.2](https://github.com/hellotham/hellonotes/releases/tag/v1.3.2) asset replaced — universal, notarised, stapled; 39.8 MB, `f71d5376…` (was 39.6 MB, `0156d247…`) |
| Verified | `spctl` → `accepted / source=Notarized Developer ID`, staple validates offline, `x86_64 arm64`, `1.3.2 (20)` read from *inside* the mounted image |
| Page | `scripts/check-download-page.sh` green against the live site after the deploy |

**One archive, both channels.** `build/HelloNotes.xcarchive` was exported twice —
once with `ExportOptions-AppStore-macOS.plist` for TestFlight, once with
`ExportOptions.plist` (developer-id) for the DMG. Signing happens at export, not
at archive time, so this is not a shortcut: it is the only way to *know* the two
channels carry identical code. Building twice would have produced two binaries
that merely ought to match.

**The version stayed 1.3.2 by instruction, and that has a consequence worth
writing down.** On the App Store side it is unremarkable — builds are numbered,
and 20 supersedes 19. On the direct-download side the version string *is* the
identity: v1.3.2 had already shipped on 2026-08-29 and been downloaded five
times, so `gh release create` would have failed and the asset was replaced with
`gh release upload --clobber`. Two different binaries now answer to "1.3.2", and
the checksum printed on the download page changed under anyone who had verified
the old one. The release body records both checksums and the rebuild date, which
is the only thing that makes the change discoverable to someone holding the
earlier file.

The general rule this leaves: **a build number is free, a version string is a
promise.** Reusing a marketing version is safe exactly where the artefact is
addressed by something else, and lossy where the version is the address.

## 46 · Four reports from an iPad, and what each one really was (2026-09-04)

**The cloud badge outlived the download.** `EditorModel` waits for a dataless
note and then reads it, but `Note.isOnlineOnly` is a value stored when the
folder was walked. Nothing told it the bytes had landed, so the row claimed the
note was still in the cloud while it was open on screen. The remote path had
`adopt(hydrated:)` for precisely this; the iCloud path called nothing.

**The tall shell could not put its band away.** `NavigationSplitView` hands
column one a toggle for free; the tall shell is a `VStack` and was handed
nothing, so 320pt of every portrait iPad went to navigation permanently — the
one shell where what you are reading is the smaller half. Landscape was never
affected: `shellKind` returns `.tall` only when `height > width`, so a landscape
iPad is a column shell and already had its own toggle. Both were checked on the
device rather than reasoned about.

The toggle is a child view (`BandToggle`) rather than an `if` in `ContentView`,
for the reason `SidebarLayout` already documents: `@Environment` resolves at the
position of the view that *declares* it, and `ContentView` sits above
`AdaptiveShell` — so `shell.kind` read there is always `.wide` and the button
would never have appeared. Second instance of that trap in this file.

**A scan said nothing at the one moment it mattered.** `CollectionConditionBar`
was gated on `hasSelection` — "the bar explains the open note" — which is true
of the stale and unavailable cases and exactly wrong for a scan: opening a
collection, before any note is selected, is precisely when it was suppressed.
All that remained was a spinner in the sidebar row, and for a vault that walks
for minutes an indeterminate spinner cannot distinguish progress from a hang,
which is the only question someone waiting has.

It is a progress bar now, showing counts `WalkProgress` had computed all along
and never displayed: items seen, folders read, folders remaining, and the folder
being read. Determinate **only when it can honestly be** — `fraction` is non-nil
solely when a previous complete run measured that tree, so a first scan shows
rising counts against an indeterminate bar rather than inventing a percentage. A
scan that announced itself now also concludes; progress that simply vanishes
reads exactly like a scan that died.

**The Obsidian picker was handed a path spelled the long way.**
`/private/var/mobile/…` where the system says `/var/mobile/…` —
`resolvingSymlinksInPath` normalises towards the short form and never back, so
the `/private` spelling is the one nothing else produces, handed to a picker
that resolves it out of process against a File Provider that knows the other.
`directoryURL` remains a hint rather than an access grant, so this is a
necessary condition rather than a sufficient one.

## 47 · Opening a cloud collection: the class was wrong, not the code (2026-09-04)

`ResumableTreeWalk` has always known it is latency-bound. A source declares how
many listings it can usefully have in flight; `RemoteTreeSource` says six; the
default is **one**, because a real directory listing is a syscall over a warm
cache and overlapping those buys nothing and costs seek contention.

A vault on iCloud Drive, Dropbox or any other Files provider has a *file path*.
So it reaches `LocalTreeSource` and inherited the serial default — while every
listing there is an XPC round trip into the provider's extension, with a network
fetch behind it for a folder not yet enumerated. N folders, N latencies, laid end
to end. The comment on `listingConcurrency` even names this cost — "that is the
whole cost of adding a large cloud folder" — directly above the source that most
cloud folders actually arrive through.

`LocalTreeSource` reports six for a provider-backed root now, detected by path
(`/Library/Mobile Documents/`, `/Library/CloudStorage/`) rather than by asking
the coordinator: the question is asked once per scan and must not itself be a
round trip. An ordinary folder still reports one, which matters —
`theWalkIsCompetitiveWithTheEnumeratorOnARealisticVault` exists because routing
width-1 through the concurrency window once made the local walk about four times
slower.

**And six in flight is still N/6 round trips.** Every provider can return a
subtree in a few paginated requests, so `RemoteStore.listRecursively` asks for
one, defaulting to nil so providers gain it individually:

| Provider | How | ~300 folders |
|---|---|---|
| Dropbox | `list_folder` recursive — the call `changes(since: nil,)` already made for its cursor | 3–4 requests |
| OneDrive | Graph `/delta` walked from the start | a few pages |
| Google Drive | one query for every folder with `parents`, tree built locally, then files 50 parents at a time | ~8 queries |
| Box | **declines** | walks, 6 at a time |

Box is the interesting one, because the right answer was not to implement it.
Its only recursive-shaped call is `/search?ancestor_folder_ids=`, which is
*eventually consistent* — a vault added moments before can come back short. The
walk's output is what the collection then believes it contains, so a listing
that is merely usually complete would silently lose notes: a far worse failure
than a slow open. It declines in the file, with the reason, so the next reader
can tell a decision from an omission.

`RecursiveListingCache` fetches once and answers every `children(of:)` from
memory, deliberately **as a cache rather than a replacement for the walk**:
building the tree straight from a recursive listing would discard checkpointing,
incremental publishing, per-directory fault isolation and resumption, all worth
more on a large interrupted sync than the walk's own bookkeeping. The walk is
untouched; only its expensive step is free.

Measured rather than asserted: a synthetic source with a provider's latency
profile at least halves its wall clock when overlapped, and twenty folders cost
twenty-one listings before the prefetch and one recursive request after, finding
the same hundred files. None of the four network paths has been exercised
against a live account — the evidence is shape and round-trip counts.

## 48 · The submission that could not contain its own purchases (2026-09-04)

1.3.2 was rejected on four guidelines at once, and only one of them was about
the app. The other three were App Store Connect *state* — invisible from the
repository, unmoved by any rebuild, and each one reproducible forever by doing
the obvious thing.

**Guideline 2.1(b) — "one or more of the In-App Purchase products have not been
submitted for review" — was structural and self-perpetuating.** App Store
Connect allows one open review submission per platform, and a version belongs to
exactly one of them. In-app purchases can only be submitted from a **draft**
submission, and a draft refuses to submit while it holds no version: *"To submit
your items for review, add an app version for the selected platform."* Meanwhile
the version page's button reads **Update Review** whenever a submission is
already in flight, and it attaches the version to *that* submission — not to the
draft holding the purchases. So the binary went to Apple, the products stayed
behind, and every resubmission reproduced the rejection exactly.

The button's label is the entire mechanism. Only with no submission open does it
become **Add for Review ⌄**, a dropdown that offers the existing draft by name.
Cancelling the in-flight submission is therefore not a workaround; it is the
only way the version and its purchases can end up in one place. Reply to Apple
*before* cancelling — the message thread belongs to that submission — and put
anything Apple asked to be shown into the version's **Notes** and **Attachment**
fields as well, because those travel with the version and a reply does not.

**Guideline 2.1 — "where is the demo SampleVault" — had been fixed in the app
and on one platform's store listing only.** `DefaultCollection` ships inside the
binary and opens itself on first launch, and the iOS screenshots had been reshot
to show it. The macOS screenshots had not: all ten still showed a sidebar
reading *SampleVault*, a graph window titled *Graph — SampleVault*, and a README
describing a folder no reviewer could find. The correction had been applied to
the platform where the question was asked, not to the one where the picture was
still wrong — and "screenshots updated", true of a set, reads exactly like a
fact about the product.

**The App Review screenshot for an in-app purchase does not accept the sizes app
screenshots accept.** An iPad Pro 11-inch capture (1668 × 2420) was refused; so
was the 13-inch (2064 × 2752). What uploaded was **1284 × 2778**, an iPhone 6.5"
capture. Both files are committed, with the refused sizes written down next to
them, because the only way to learn this rule is to be turned away by the form.

Guideline 5 (China / OpenAI) needed no code either: China mainland is deselected
in Availability, and every OpenAI reference is out of the name, subtitle,
promotional text, description, keywords and screenshots. The app ships no
ChatGPT integration and no OpenAI credentials — the intelligence features default
to Apple's on-device Foundation Models, and a user may point them at a provider
they already hold an account with.

Submitted 2026-09-04: **iOS 1.3.2 (21) as four items** — the version, the
Champion consumable, the Commercial subscription and its subscription group —
and **macOS 1.3.2 (21) as one**, the purchases being app-level and riding the
iOS submission. Both platforms are set to release automatically on approval, so
everything downstream of approval has to be ready before it lands.

## 49 · 1.3.2 build 21 — the direct download catches up (2026-09-04)

The App Store had build 21 in review while `releases/latest` still served build
20, and the gap was not cosmetic: the heading jump, the cloud-open work, the
scan progress bar and the cloud badge fix were all on the store side and none of
them on the download side. Re-cut from the same source, verified and published.

**It stays 1.3.2, and that is the interesting part.** `check-download-page.sh`
compares the site's version against the App Store's with `!=` — an *exact*
match, not "no newer" — once the app is public. 1.3.2 (21) is what is in review,
so a 1.3.3 disk image would have passed every local check today and failed the
moment Apple approved, on a page nobody would think to re-run a checker against.
The version is a promise about which listing the page corresponds to, not a
description of how much has changed since the last download.

The cost is real and worth naming: **three distinct binaries have now been
served as "1.3.2"** — 29 August, 3 September (build 20) and 4 September (build
21). Someone who downloaded on any of those days has a different file, and
"1.3.2" does not distinguish them. The release notes carry a checksum table for
exactly that reason, so a user comparing `shasum` output against the page can
tell "I have an older 1.3.2" from "this download was tampered with" — which is
the only question a checksum is there to answer.

**Order matters and is not a style preference.** Publishing precedes the website
sync because the download button points at
`releases/latest/download/HelloNotes.dmg`; `site.ts` only says what that will
be. Update the page first and there is a window where it prints a checksum for a
file nobody is being served, which reads as a tampered download rather than as a
deploy in progress. Verified by fetching the button's own URL and hashing what
came back, rather than by trusting that the upload worked.

Verified as a user's Mac would: DMG `accepted / source=Notarized Developer ID`,
universal (`x86_64 arm64`), app accepted and **stapled** (`stapler validate`
works offline, which is the case that matters), `LSMinimumSystemVersion` 26.5,
and `CFBundleShortVersionString` 1.3.2 read from inside the mounted image rather
than assumed. 40.0 MB, `0c70b7b0…`.

## 50 · The website catches up with what ships (2026-09-15)

1.3.2 was approved and auto-released on **7 September**, and for eight days the
site kept describing a Mac-only app: titled "Download — HelloNotes for Mac", a
`minOS` of `macOS 26.5 or later`, and not one `apps.apple.com` link anywhere in
`website/src`. The change had been written on 4 September and deliberately held,
because the deploy fires on any push under `website/**` and a store link to an
unapproved app is a broken link on the front page. Approval opened the gate;
merging it was the whole remaining distribution step.

**The held branch was wrong about one thing, and only the live listing could
say so.** It shipped two buttons — "iPhone & iPad" and "Mac App Store" — on the
reasoning that one link cannot serve two stores. It can, because there are not
two: both platforms ship from one App Store Connect record and Apple serves them
as a single product page. `?mt=12`, the legacy Mac-store selector, is **dropped
on redirect**, so both forms resolve to the identical URL. Two buttons to one
destination reads as a defect rather than a choice. One link now, with the copy
naming the devices, and the redirect behaviour recorded beside `APP_STORE` —
because "a Mac link and an iOS link" is a reasonable thing to assume and the
only way to learn otherwise is to follow the redirect.

That is the shape worth remembering: **the branch had been built, reviewed and
verified against everything available at the time, and still carried a wrong
assumption that nothing local could have tested.** Verification before the
dependency exists is necessarily partial; the re-check on the day it goes live
is not ceremony.

Also corrected, both wrong rather than merely narrow: the download page told
first-time users to "choose Open… and pick any folder of Markdown files", which
`DefaultCollection` has not required since it began shipping inside the binary —
the same correction App Review had to be sent — and Support said the
intelligence features "require a Mac with Apple Intelligence", which sends
iPhone and iPad owners looking for a setting they already have.

`APP.minOS` was deleted rather than aliased. It held the Mac floor and nine
places read it; an alias would have compiled and left Mac-only sentences on
pages that now also sell an iPhone app. They did not all want the same answer —
the DMG card still says macOS 26.5, because that channel really is Mac-only.

## 51 · 1.3.3: every AI feature on Foundation Models, and what only running it could show (2026-09-15)

1.3.3 raises the floor to **macOS 27 / iOS 27** and replaces the whole AI layer.
Sixteen bespoke provider integrations — three HTTP wire formats, per-provider
model discovery and context tables, a Keychain of API keys, a hand-written agent
loop — came out (`HelloNotes/LLM/`, ~4,500 lines, and the OpenAI and
mlx-swift-examples packages). What replaced them is one API over the three models
Foundation Models can reach from an app:

| Choice | Model | Where the text goes |
|---|---|---|
| **System** | `SystemLanguageModel` — AFM 3 Core, or Core Advanced on the most capable Apple silicon (the SDK decides; `variant` is read-only). Shown as "System", Apple's own name for it (§51.4) | nowhere |
| **Private Cloud Compute** | `PrivateCloudComputeLanguageModel` — only in a build with Apple's managed entitlement | Apple's servers |
| **MLX** | `MLXLanguageModel` (mlx-swift-lm, pinned by revision — its adapter is in no tag yet) | nowhere |

Settings hold two choices, as before — the Assistant, and the writing tools — plus
creativity and, on models that reason, a thinking level. `IntelligenceMigration`
carries a 1.3.2 install across once: Apple and MLX map across (with the MLX model
id), every other provider maps to On-Device with a one-time notice naming it, the
old keys are removed and **the stored API keys are deleted** — live credentials
for services the build can no longer call. Conversations convert from the old
JSONL to a Foundation Models `Transcript`, text turns only.

**The structure** (`HelloNotes/Intelligence/`):

- `Models/` — `LanguageModels` (the one place a choice becomes a model: availability,
  name, where it runs, context size, reasoning, PCC quota), `TokenBudget`
  (script-aware token estimates and lossless chunking), `MLXModelStore` (a model the
  person names or points at, download with progress, removal, custom
  Hugging Face ids, and **a model folder** — Hugging Face is unreachable from
  mainland China), and `MLXBridge` (downloader and tokenizer, hand-written instead
  of the package's macros so no build needs macro validation skipped).
- `Features/` — `IntelligenceService` (one path for every writing tool), deep
  research (a `@Generable` plan, a session per sub-question, a synthesis that
  reasons deeper where the model can).
- `Assistant/` — a `DynamicProfile` (model, temperature, reasoning, tools, a
  history window, and a tool-call budget that switches tool calling off for the
  next request once spent), the view model, and the transcript store.
- `Tools/` — `nonisolated` Foundation Models tools over a main-actor
  `ToolContext`; five tools on an 8K window, the full set on 16K and above.

Behaviour that changed on purpose:

- **Summaries cover the whole note** — in parts, then the parts — instead of the
  first 4,000 characters.
- **Rewrite refuses input it cannot hold.** The old path trimmed the selection and
  replaced all of it with a rewrite of its beginning, deleting the rest.
- **Link suggestions are a schema**, `anyOf` the candidate titles, so an invented
  title cannot be generated at all.
- **Assistant edits go through `noteDidSave`.** The old tools wrote and rescanned,
  which never uploaded: an Assistant edit in a direct cloud collection was
  overwritten by the next sync.
- **Approvals queue.** Skill descriptions moved out of the instructions into the
  `load_skill` tool's output — they are text from vault files.
- **Research runs on an 8,000-token model.** It was first gated at 16,000, which —
  with Private Cloud Compute not yet available — would have taken Research away
  from every iPhone, iPad and on-device Mac. Tool output already scales to the
  window, so the floor came down, and a real run (`ResearchProbe`) planned two
  sub-questions, read the web and synthesised a correct answer on AFM 3 Core
  Advanced in 30 seconds. AFM 3 Core (4,096) is still refused, with a reason.

**What only running it showed.** The rewrite compiled first time on both
platforms and passed its unit tests, and four defects were still waiting:

1. **Private Cloud Compute without the entitlement crashes the app.** Inside the
   signed app `availability` said `.available`; the first request hit a
   `fatalError` in Foundation Models and took down the test host. The same probe
   as an unsandboxed command-line tool reported the same availability and did not
   crash. So the model is created and offered only under the
   `PRIVATE_CLOUD_COMPUTE` compilation condition, added in the same change as the
   entitlement, with a test that fails if the two disagree (`production.md` §1b-PCC).
2. **The Assistant had no tools.** A profile's `historyTransform` is handed the
   instructions entry as part of the history, and `HistoryWindow` trimmed from the
   latest prompt — dropping the entry that carries the tool definitions. The
   on-device model answered "What are the headings in my Welcome note?" with
   headings the note does not have. Found by the Evaluations suite as a tool-call
   score of 0.33; the unit tests had nothing to say.
3. **Tags from Apple's content-tagging adapter were not tags.** It returned key
   phrases ("bikes along the Kamo river") whatever the schema asked, and its
   guardrail refused a sourdough-baking note. The general model asked for topics,
   with the note's language named in the instructions, returns Chinese tags for a
   Chinese note; normalisation now hyphenates a two-word topic instead of dropping it.
4. **The model makes parallel tool calls** — four in one step, run concurrently —
   which is why the permission broker had to stop denying a second prompt.

Measured on this Mac (AFM 3 Core Advanced, 8,192 tokens): the evaluation suite
(`IntelligenceEvaluationTests` — tags, constrained links, Markdown-preserving
rewrites, a 45,000-character note summarised through parts, and Assistant
trajectories that must read before answering and never edit unasked) passes in
~28s. It is opt-in and local, because it needs Apple Intelligence.

**Build and tooling:** every app `xcodebuild` needs `-skipPackagePluginValidation`
— mlx-swift's `Cmlx` carries an inert `CudaBuild` plugin that fails validation
otherwise — and the scripts, CI and skills pass it. Two Xcode 27 isolation
changes in the editor package (`CodeHighlighting`, `BlockRenderer` now
`nonisolated`). iOS 27 simulators replace the 26.5 ones under the same names.

**Also fixed on the way:** `StoreListingTests` had been failing on every run since
`production.md` stopped carrying the listing copy; the copy for the version being
prepared now lives in `docs/app-store-listing.md`, with new checks that no
third-party AI service is named (Guideline 5) and that Private Cloud Compute is
only listed in a build that can offer it. The listing's support paragraph no
longer says backing "unlocks nothing" — it unlocks the in-app support request.

### 51.1 Review before commit: what ships, what blocks, and what an approval replaces

Three read-only reviews (vault I/O, main-actor, and a second docs fact-check)
plus a scan of the built bundle, all run before the 1.3.3 work was committed.

**What ships.** Removing the providers had not removed their names from the app:
the repository `README.md` had been in the app target's Resources phase since the
first commit — every build on the App Store carried a list of fourteen AI
services and "your own cloud API key" — and the upgrade code kept a table of
those names so a notice could say which one had been retired. Swift type names
and string literals are compiled into the binary, so `OpenAISettingsButton` was
a third. The README is out of the bundle, the notice no longer names the service
(`hasRetiredProvider`), the button is `AISettingsButton`, and
`ShippedContentTests` fails if the Resources phase copies anything but the
bundled collection or if app code or bundled notes name an AI service — both
checked against HEAD, where they fail. The migration's Keychain sweep lists
accounts from the Keychain instead of from the removed table, and is now tested
against the real Keychain, because the listing promises the keys are deleted.
Strings that remain in the binary come from swift-huggingface's Inference
Providers enum ("Groq", "Cerebras", "Together AI"), which the app does not use.

**What an approval replaces.** Four defects in the Assistant's tools, all new in
this rewrite or made reachable by it:

1. *An unreadable note read as an empty one* (`?? ""`), so the approval card for
   deleting or rewriting a note that had not downloaded showed an empty "before",
   and `read_note` told the model the note was empty. `readContents` now
   downloads first (mirror hydration or File Provider materialisation) and throws.
2. *An approved edit could overwrite typing saved while the card was up* —
   clicking Approve in the Assistant's window ends editing in the note's window,
   which saves. `FileIO.replace(_:at:ifContentsEqual:)` compares and writes inside
   one coordinated write; a mismatch refuses the change and tells the model to
   read again.
3. *Open editors were never told.* Routing tool writes through `noteDidSave`
   (for the upload and the index patch) registers them as the app's own, so the
   watcher ignored them, and a tab showing the note saved its stale text back over
   the approved change. 1.3.2 wrote directly and the watcher reported it.
   `Collection.noteChangedOutsideEditor()` sends the watcher's message.
4. *`ChatSessionStore.clear()` lost to a save already writing* and the cleared
   conversation came back. The delete now runs last in the write queue.

**What blocked.** Measured by the main-actor review: the approval card laid out
the whole diff in a plain `VStack` from inside `body` (162 ms at 2,000 lines,
898 ms at 10,000 — `delete_note` and `write_note` diff the whole note); it is now
computed once off the main actor and laid out lazily, capped at 1,000 rows. The
streaming reply redrew about 40 times a second and re-parsed its Markdown from
the first line each time (2 ms at 2 KB, 15 ms at 30 KB); redraws now follow at
most ten times a second with a trailing catch-up, and `AnswerMarkdown.Streaming`
parses only new lines, tested to match the whole-text renderer at every prefix.
Unmeasured but proven by isolation: `FileIO.materialise` inherited the main
actor and polled the provider there every 200 ms for up to a minute (now
`@concurrent`, which fixes the editor's open path too); containment and
existence checks, `SkillStore.refresh`, `NoteComposer.create`'s write and
`Collection.createNote`'s create ran on the main actor; `create_note` awaited a
whole-collection walk for a new folder (`adopt(createdAt:)` now brings the
folder with the note); every tool result waited for its Git commit, which can
queue behind a push; `RemoteMirror.relativePath` hopped to the main thread once
per file of a mirrored collection's scan. `grep_collection`, Ask Library's
retrieval, the relatedness index and skills now skip notes that are not on the
device instead of downloading a cloud vault to answer one question.

Also found: `offMain` violations are **warnings** in this target (Swift 5 mode),
not the compile errors its comment promised — and still hop at runtime.

**The docs.** The second fact-check found seven false claims on the website's AI
manual and privacy page, including that web searches happen only when asked (the
Assistant may search on its own; the engine is DuckDuckGo, and a query can carry
words from notes) and that "→" accepts a suggestion on iPhone. The same web claim
was corrected in `DefaultCollection/Intelligence.md`, the listing, and the
Allow-all tooltip; the README's AI sections describe 1.3.3.

Tests: 497 in 75 suites; the five model evaluations pass unchanged.

### 51.2 MLX, end to end, on a model already on the Mac

MLX had never run before this. It was verified with the model already in the
Hugging Face cache (`mlx_lm.manage --scan`: `mlx-community/gemma-3-27b-it-bf16`,
57.7 GB, on a 128 GB M3 Max) — nothing was downloaded. The evaluation suite
gained `HN_EVAL_MLX_FOLDER`, which loads a model through the same folder path as
"Choose a Model Folder…", and ran against it:

| Evaluation | On-device | Gemma 3 27B bf16 | Qwen3.8 27B 4-bit | Gemma 4 26B A4B 4-bit | Gemma 4 31B 4-bit |
|---|---|---|---|---|---|
| Tags well-formed and on topic | pass | pass | pass | pass | pass |
| Links only from real notes (schema) | pass | pass | pass | pass | pass |
| Rewrites keep links | pass | pass | pass | pass | pass |
| A 45,000-character note summarised whole | pass | pass | pass | pass | pass |
| Assistant reads before answering (tools) | pass | n/a — no tools | pass | pass | pass |
| An approved edit reaches the file | pass (§51.36) | n/a | pass | pass | — |
| Chat without tools doesn't invent notes | n/a | pass | n/a | n/a | n/a |

Whole-suite times, model loading included: Gemma 3 27B bf16 (57.7 GB) 193 s;
Qwen3.8 27B 4-bit 162 s; Gemma 4 31B 4-bit 162 s; Gemma 4 26B A4B (a mixture of
experts, 4 B active) 45 s.

Guided generation is grammar-constrained in the MLX adapter, so the schema-bound
features held on models the app had never seen. **Tool calling works**, in each
model's own dialect — Qwen 3.5's framed JSON and Gemma 4's `<|tool_call>` — and
through the whole change path: asked to change one line of a note, both models
called `edit_note` with arguments they worked out themselves, the approval was
given, and `pears` became `plums` with the rest of the note untouched
(`AssistantEditEvaluation`; until it ran, no model had ever changed a file
through the app's tools — the trajectory evaluation denies every approval).

The first model tried, Gemma 3, surfaced three defects:

1. **A Hugging Face cache snapshot cannot be opened from the sandbox.** Every
   file in `snapshots/<revision>/` is a link into `../../blobs/`, and a folder
   grant does not cover what links point to — `sandbox-exec` with a read grant on
   the snapshot: "Operation not permitted"; on the model's folder: readable. The
   snapshot is the folder that visibly holds `config.json`, so it is what a
   person would pick, and the Debug build (whole-disk read access) could never
   have shown the failure. `MLXModelFolder` now takes the model's folder
   (`models--org--name`), follows `refs/main` to the current snapshot (or the
   newest complete one), refuses a snapshot or a whole cache by layout with a
   message naming the folder to choose, and shows the model by name
   (`gemma-3-27b-it-bf16`, not `models--…`). The Mac footer says where such
   models live.
2. **A model whose chat template has no tools imitated them.** The adapter hands
   tool definitions to the template; Gemma 3's never mentions `tools`, so they
   vanished, and the model — seeing only the tool names in the instructions —
   answered `read_note("Welcome")` in a code block. Nothing ran; the text was the
   reply. (Its template also rejects any turn but user and assistant.)
   `MLXChatTemplate.rendersTools` reads `chat_template.jinja`,
   `chat_template.json` and `tokenizer_config.json`; a model without tools gets no
   `.toolCalling` capability, the Assistant runs chat-only with a notice, the
   tools toggle is disabled, Research explains why it is unavailable, and the MLX
   section of AI settings says so.
3. **Chat without tools described notes it could not see.** Asked for the
   Welcome note's headings, Gemma listed four the note does not have — the
   instructions named the collection and its size, and nothing said the notes
   were out of reach. This applied to every conversation with agent mode off, on
   any model. Instructions without tools now say the notes can't be seen and
   must not be guessed at, and omit the collection; the reply became "I cannot
   access your notes, so I cannot tell you the section headings…". The chat-only
   evaluation first passed *while* the model fabricated — it only checked for
   imitation calls — and now also requires the admission and no heading.

Tests: 506 in 79 suites.

### 51.3 The app suggests no models

The MLX section carried four models — Qwen3 1.7B/4B/8B and Llama 3.2 3B — with a
size and a sentence each, read from the Hub on 15 September 2026 and filtered by
device memory. It was deleted on the 16th, a day later, for the reasons the day
produced:

- **Stale by a generation, immediately.** Checked against the Hub: those four
  were last updated in March and April **2025**. The models actually on the
  machine that week were Qwen3.8 27B and Gemma 4 — 2026 models, none of them on
  the list.
- **Recommended but never run.** Not one of the four had been loaded by anyone
  here; the models that *were* verified were the ones not suggested.
- **The rule was already written.** "A model list is a thing you ask for, never
  a thing you remember" was in this file about the provider layer, and narrowing
  it to context windows during the rewrite is how a remembered list returned.

A live list from the Hub was the alternative — `HubClient.listModels` is linked
and could be filtered by device memory and supported architecture — and was
rejected: it adds a network request to a settings screen, and its only honest
ranking is popularity, which today puts a 2025 Llama and a 1-trillion-parameter
model at the top of `mlx-community`. It also helps a beginner least, while
implying the app vouches for what it lists.

What remains is a Hugging Face model name, a folder, and a link to the
`mlx-community` organisation, under a footer that says plainly that HelloNotes
recommends nothing and that how well a model works is up to the model. Two
things the catalog was carrying quietly are now read from the model itself: the
window is the device's (`MLXModelStore.contextTokens`), and a model whose
weights are larger than a share of this device's memory gets a caution — not a
refusal — once it is on disk. Reasoning went with the list: it has to be
declared before the weights load, nothing readable beforehand says truthfully
whether a model reasons, and declaring it wrongly fails every request.
`ShippedContentTests.noModelIsSuggested` fails if a model id reappears in app
code (it finds the four at the previous commit).

### 51.4 Nothing on iPad only behind a gesture, and one Settings (2026-09-17)

Testing build 22 on an iPad: "there is not an obvious way to access settings",
then "why are there hidden long press menus?", "why is AI settings separate from
Settings?", and — from `fm --help` — "the on-device AFM should just be called
system".

**The split button.** The iPad's leading toolbar item was
`Menu { … } primaryAction: { newNote() }`: tap made a note, *hold* opened New
Folder, Today's Note, Quick Capture, Open Quickly, the collection commands, AI
Settings and Settings. It was one item "because at 744pt this band is also
carrying the tab strip", and it looked exactly like a New Note button. It is
now a New Note button and a visible `…` (More) menu — the shape the phone's
Library already had. The same audit found four commands with **no** visible
route on a regular-width iPad — Assistant, Ask Your Library, New Note from a
Prompt and Graph View, which the Mac keeps in its status bar and the phone in its
AI tab — and they are in that menu now. The menu opens from mid-screen in
portrait and is capped at about 520pt, so Settings sits above the folder and
collection commands (which have visible homes of their own, `+` and each
collection's `…`) rather than below the fold.

**Row menus.** Every `.contextMenu` was checked for a visible twin, which the
HIG requires. Cloud accounts (pencil and sign-out buttons), mind-map nodes (a tap
does the same) and a collection in the sidebar (its `…`) had one. These did
not, and now do:

| Long-press only | Visible route now |
|---|---|
| a note's Rename, Duplicate, Bookmark, Copy Wiki Link, Open in New Window, Reveal, Download, Export ▸, Move to Trash | the open note's menu, from `SidebarMenu.items(for:)` — the row's own list, Move to Trash last |
| a folder's New Note Here, New Folder Here…, Reveal, Move to Trash | `RowActionsMenu` on the row (sidebar and band) |
| a collection in the tall shell's band | `RowActionsMenu`, as the sidebar already had |
| closing a collection on iPhone (a swipe) | `RowActionsMenu` on the Library row |
| Remove from Recents, Delete Library (launcher) | `RowActionsMenu` on each row |

`RowActionsMenu` draws its `…` in `.secondary` and only as wide as the glyph:
in the tint it vanished into a selected band row's highlight, and 44pt wide it
wrapped "DefaultCollection" onto two lines of a 260pt pane. The inspector's
selected tab had the same defect — an accent glyph on `.selection`, which on
iPad is the accent — and drew as a blank pill.

**One Settings.** Settings already had AI on both platforms (the Mac's AI tab,
iOS's AI ▸ Models); "AI Settings…" opened a *second* sheet holding the same
form, because neither a Settings window nor a settings sheet could be opened at a
page. `SettingsPage` makes that possible — stored for the Mac's tab view
(which also restores the last pane, as the HIG asks), pushed on iOS — and every
AI route now opens Settings at AI. The standalone sheet, `IntelligenceSettingsView`,
and `AISettingsButton` are gone. On iOS the Assistant presents Settings over
itself: its old button posted to the shell, which cannot present while the
Assistant is up, so on iPad it had done nothing. ⌘, now opens Settings on iPad
as well (`CommandGroup(replacing: .appSettings)`, iOS branch).

**System.** The picker said "On-Device · AFM 3 Core Advanced", which prompted
"what about AFM 3 Core?" — a choice no app has (`variant` is read-only). Apple's
`fm` tool calls the model `system` ("System model available"), so the app does
too: "System" as an entry, "System model" in a sentence. Two strings still
mentioned "the suggested MLX models" a day after suggestions were removed.

**Found by the suite, not by looking.** `theModelsFolderListsWholeModelsOnly`
failed on `bytes == 64`: `weightsBytes` read each snapshot file's size without
following the link, so every cached model was listed at a few dozen bytes.

**The app opens no windows of its own.** A regular-width iPad opened the
Assistant, Graph, Ask Library and Mind Map as their own window scene, because the
rule was width alone: a canvas wide enough shows a second surface *beside* the
notes. On iPadOS it does not sit beside them — in full-screen apps, and in Split
View, the system puts the new scene where the old one was, and **Done** closed it
and showed the Home Screen with the app still running. Nothing distinguishes
iPad's windowed mode from full-screen (`UIWindowScene.isFullScreen` is Mac
Catalyst only; `sizeRestrictions` is non-nil in both, probed on iPadOS 27).

Taking the windows off iPad alone broke the rule this app is built on —
*"parity between macOS and iPadOS was a hard and unbreakable rule"* — and the
answer was not to give the Mac something the iPad cannot have:
*"parity means macOS should not have windows either (except when the user says
New Window)."* So **no window is opened by the app on either platform**. A
window is what someone asks for by name, and **New Window** and **Open in New
Window** are on both.

**Then the question behind the question.** A sheet was the next answer, and it
was wrong for a different reason: *"they should be panes rather than modals.
That's the app design. An editor should never block editing."* And then: *"why
are you distinguishing between the inspector panels and graph, ask library,
etc.? Aren't these just all panels on the right sidebar?"* They are. **The shell
is collections on the left, the editor in the middle, anything else on the
right**, and the app had been carrying two of everything for a distinction that
does not exist: two enums (`InspectorTab`, `AuxiliarySurface`), two pieces of
state, two chromes — five icon toggles in the Mac's band for one set, a title row
inside the panel for the other, and a third strip on iOS — and two widths.

`SidePanel` is the whole of it: nine cases (Outline, Tags, References,
Properties, History, Mind Map, Graph, Ask Library, Assistant), one stored
choice, one width (360, floor 220, cap 560), and one header inside the panel
carrying all nine as a **strip of icons**, grouped note-then-collection, the
current one tinted. What you can switch to is visible, not behind a tap — the
rule that took the commands out of long-press menus — and below the width nine
icons need, `ViewThatFits` falls back to a pull-down rather than a second
threshold. The band keeps a single toggle.

The panel had its own defect: it was a column only at `.wideInspector` (1400pt)
or a tall shell ≥900pt, so a 1100pt Mac window and an 834pt iPad both fell to a
*modal overlay with the note dimmed behind it*. The arithmetic never required
that — at the 860pt window minimum a 280pt sidebar, the 320pt editor floor and
the 220pt panel floor come to 820. `ShellMetrics.hasPanelColumn` answers it once,
for the shells and for the overlay, and only a canvas with no room for a column
carries the panel over the note. The views that came from windows kept window
habits: the graph and the mind map each demanded `minWidth: 560` and drew past
the edge of the first panel they were put in.

**Every panel drags.** `shell-chrome.md` D7 promised a draggable splitter from
the day the inspector was designed and no code ever drew one, so every panel was
whatever number the shell had written down. `ResizableDivider` stores the width
and clamps it at use, so a narrower window borrows it back rather than
forgetting it; 10pt grab area, a pointer that changes over it, an adjustable
action for VoiceOver, and the band's two panes drag the same way.

**The models on this Mac are simply there.** The models folder was "Not chosen"
until someone pointed a file panel at their Hugging Face cache — a sandboxed app
cannot read `~/.cache/huggingface` — which stood between a person and 23 models
their machine already had. *"You seem to be giving excuses rather than delivering
a seamless user experience."* The app now asks for that folder by name
(`com.apple.security.temporary-exception.files.home-relative-path.read-write`,
still honoured by macOS 27's sandbox profile), so the cache **is** the models
folder: what is there is listed, and a download goes into it rather than a second
multi-gigabyte copy inside the container. Verified against a **Release** build,
because Xcode gives Debug builds the whole disk; the justification for App Review
is in `docs/app-store-listing.md`.

**One model, and the knobs the framework has.** Settings offered a model for the
Assistant and another for the writing tools. With MLX the two could not differ —
one MLX model is loaded at a time — so choosing a different one for either role
silently moved the other, which is the shape of a setting that lies. It is one
choice now (`IntelligenceSettings.model`, carrying whichever role was set on
upgrade): *"we are either using System, or our own model."* What is tunable is
what the framework exposes and nothing invented — temperature (0–2, as
`GenerationOptions.temperature` is; the app had clamped it to 1), `samplingMode`
(Automatic, Greedy, Top-k, Top-p, each with an optional seed for a repeatable
run), `maximumResponseTokens`, and `reasoningLevel` where the model reasons.
They are the Assistant's; the writing tools ask for what each task needs, because
rewriting wants determinism whatever was chosen for conversation.

**And the picker has to be the whole choice.** *"Doesn't allow choosing between
system and loaded mlx models."* It didn't: Apple's model was one entry and MLX
was **one** entry, on the reasoning that only one MLX model loads at a time —
which is a fact about loading, borrowed to settle a question about choosing.
*Which* model lived in the MLX section behind a **Use** button, so the control
labelled *Model* could not express the choice it was named for. On this machine
it was worse than a detour: the remembered model, `mlx-community/Qwen3-4B-4bit`,
had left the Hugging Face cache, so `chosen` resolved to nothing and the entry
rendered **"MLX · MLX"** while four runnable models sat in the folder
unreachable — the cache holds 23 entries, of which those four are language
models the loader registers (`qwen3_5`, `gemma4`, `qwen2`) and the rest are OCR,
layout and embedding models it never could have run.

`ModelOption.mlx(id)` is one entry per model in the folder, `choose` sets the
model *and* the switch to it, and **Use** in the MLX list goes through the same
call — pressed while the picker said System it used to change which model would
run and leave the app answering on System. Two traps came with it, both live
before they were closed: `isAvailable` asked the store, whose availability
describes the model *in use*, so "no model chosen" disabled every entry and
nothing could ever be picked; and the list's tick meant "this is the MLX model
that would run", which it drew while the app was on System.

**The panel that opened in the wrong place.** Build 25 cleared review with the
entitlement gone, and **Access MLX Models…** opened the person's Obsidian vault.
`fileDialogDefaultDirectory` was on the `Form`, and the `fileImporter` was
attached outside it — where it could not see a value that flows inward — so the
panel fell back to wherever the app's last panel had been, and the last folder
this Mac had opened was the vault. Nothing caught it: review passed, the suite
passed, and the code reads naturally either way, because Apple's documentation
says only that the modifier "configures the fileImporter". A probe settled it
rather than an argument — the same importer presented both ways in an
off-screen window, with the `NSOpenPanel`'s own `directoryURL` read in-process:
inside gave `~/Documents`, outside gave `~/.cache/huggingface/hub` (hidden
parent and all). The helper now wraps the importer, the panel carries a line
saying what the folder is for, and `ShellComplianceTests` measures the helper's
argument by balanced parentheses and fails — naming the reason — if the importer
ever leaves it.

### 51.5 The Mac and the iPad draw the same pixels (2026-09-23)

The requirement, in the words it arrived in: *the exact same button layout and
location between macOS and iOS, no deviations; the same font size and layout to
the nearest pixel; pixel, colour and size identical — not similar designs.* The
layout chosen was the iPad's (Search · Sidebar · New Note · More ⋯ | tabs |
Note Actions ⌄ · Panel); the scale and look, the Mac's (13pt text, 28pt
controls and rows, AppKit's colours, with 44pt touch targets drawn nowhere).

**Why the two had never matched.** Almost nothing on screen was the app's own
drawing. The bar was an `NSToolbar` on one platform and a `UINavigationBar` on
the other, built by two different builders; the sidebar was an
`NSOutlineView` on the Mac and a SwiftUI `List` on iOS; settings were a
`TabView` window and a `NavigationStack` sheet; and every text style, system
colour and control resolved to each platform's own numbers under one name —
`.body` 13pt and 17pt, `Toggle` 36×16 and 51×31, a grouped `Form` row 36pt and
44pt, `.secondary` two different greys, `Color.orange` two oranges,
`.borderless` grey on the Mac and accent-tinted on iOS. Two builds of the same
view were two pictures, and no amount of adjusting either could make them one.

**What replaced it.** `UI/Shell/Chrome.swift`, `ChromeRows.swift` and
`ChromeControls.swift`: fixed tokens (the Mac's text-style sizes, read from
`NSFont.preferredFont`; AppKit's colours in both appearances, read from AppKit),
and controls drawn by the app at the Mac's metrics (read from
`NSControl.fittingSize` per control size, and from a `.grouped` `Form` rendered
and scanned pixel by pixel): push/borderless/link button styles, switch and
checkbox, a pop-up, a segmented control, slider, stepper, text fields with
app-drawn placeholders, a grouped form and its sections, a sheet bar, an empty
state, rows with the outline's selection. `chromeDefaults()` makes them the
defaults at every window root, so a control that names no style is already the
app's. The bar, the sidebar tree, the band's two panes, the tab strip, the
status bar, the panel header, Settings (one tab strip over one page, 560×640,
in the Mac's Settings window and the iPad's sheet alike), the compact shell's
tab bar and place bars, every sheet's bar, and every list and form in the app
were rebuilt on them.

**Three differences that fixed numbers did not remove**, each found by
rendering the same scenes on both platforms and comparing the pixels
(`ChromeParityTests` + `scripts/chrome-parity.sh`):

1. *Ink.* With identical sizes, colours and positions, the Mac's text carried
   12.6–19% more ink — macOS font smoothing, which thickens stems and which iOS
   has never done. `Chrome.matchTextRendering()` registers
   `AppleFontSmoothing = 0` in the app's registration domain: in memory, last in
   the search order, so nothing is written and a system-wide choice still wins.
2. *Line boxes.* macOS rounds a line to whole points and iOS to half points —
   11pt is 14.0 and 13.5, 12pt 15.0 and 14.5, 17pt 20.0 and 20.5, 26pt 30.0 and
   31.5 — so a paragraph drifted half a point per line. SwiftUI 26's
   `.lineHeight` fixes it only with a rule whose result needs no rounding. The
   first attempt, `.multiple(factor: 16/13)` (a multiple of the point size),
   passed the first render because the scenes happened to use 11 and 13pt,
   where 16/13 lands on whole points; a matrix over 10–26pt then showed 10pt at
   13.0 against 12.5 and 15pt at 19.0 against 18.5. `.leading(increase: 3)` —
   size plus 3 — is whole for every whole size, measured exact on both, and is
   the Mac's own line at 10–13pt and 17pt, so the Mac barely moved.
3. *Baselines.* At 13pt the natural totals agree (16.0) and the text still sat exactly
   one pixel lower on the Mac — identical ink, centroid +1.000px — because
   macOS rounds the ascent and descent separately. `ChromeLine` centres a line
   on its capitals (baseline minus half the cap height, which is the font's
   own outline) inside a box whose height the app chooses.

A fourth came from the same place as the second: **default stack spacing**.
A `VStack` that names no spacing gets a gap SwiftUI computes from each
platform's rounding of the font — text over a control at 10–17pt is 7, 8, 8, 9,
10, 12 on the Mac and 6.5, 7, 7.5, 8.5, 9.5, 11 on iOS, and no rounding of one
gives the other. The codebase's own convention had every one of 151 vertical
stacks naming its spacing already; the one implicit stack (a scroll view with
two children, in the CSV viewer) now has one, and
`everyVerticalStackNamesItsSpacing` keeps it that way. Horizontal defaults agree
(8pt for every pair measured).

After those, every scene in both appearances agrees within one level in one
channel — rounding — except the anti-aliased tip of one SF Symbol at Δ6. A
negative control (the same render shifted down a pixel) fails the comparison
with 4–7% of pixels at Δ255.

**The whole window, not just its parts.** `scripts/window-parity.sh` puts the
iPad app (simulator, landscape) and the Mac app (a window exactly the iPad's
1210×790pt safe area) side by side with the same settings and the same sample
collection, and compares every pixel with only the traffic lights, the
window's corners and iPadOS's resize grabber masked. Its first run found two
things no scene render could: the Mac's content started 28pt down — a hidden
title bar still reserves its height as a top safe area, so the bar sat under an
empty strip (`contentUnderTitleBar`) — and the sample notes, saved in the same
second, were listed in a different order on each platform, because a date-only
sort leaves ties to a dictionary's hash order (`Note.newestFirst` breaks them by
title, then path, at all ten sort sites).

The same run caught the launch splash as a floating 720×440 window of its own
on the Mac — centred on the screen, lingering 700ms — where the iPad drew it
over the window for 500ms. It is the overlay on both now, and About (which
shows the same splash) is an `AppActions` action, so with several windows open
it appears in the one you are looking at instead of being broadcast to all of
them.

It also cost something, which is recorded so it is not repeated: the first run
launched the Mac app with its open collections overridden to the sample, the
app saved that list, and the backup the script then imported lost the race
with the preferences daemon — the open collections came back as the sample
alone. The files were never touched; the list entry was. A capture session now
saves no collection list at all (`CaptureSession`), and the script only reads
the preferences back to check them.

**What stays the OS's**, deliberately: its window controls (the traffic
lights, for which the bar leaves 78pt when it is the window's top-left corner —
`WindowControls.leadingInset`, the one number that is not the same), and menus,
popovers and alerts once *open*. The buttons that open them are the app's.

**Traps met on the way**, now rules in CLAUDE.md:
- An unstyled `Button` inside a `List` or `Form` drew as a plain row; the same
  button in a drawn list inherits the root's push-button style. Every row,
  card and glyph button says `ChromePlainStyle`.
- Inside menu content `Divider()` is the menu's separator. A mechanical pass
  that turned every `Divider()` into `ChromeDivider()` put views into 25 menus,
  including the whole menu bar.
- Text styles scaled with Dynamic Type; fixed sizes do not. `ChromeTextScale`
  applies one factor from Apple's body-size table to every size, driven by the
  app's Text Size on **both** platforms — the iPad had ignored it, though it
  syncs between devices — with iOS's own Larger Text on top: exactly 1.0 at the
  defaults, where the pixels are compared.
- Four views had no route to the screen: `TagTreeRow` (its tree replaced on
  11 August), `RemoteBrowserView` (browsing became the folder picker in late
  August), an unused `OptionalMeasure`, and a `ChromeBackButton` written this
  morning for sheets that turned out not to need it. The sweep converted one of
  them line by line without being able to tell it was invisible. All four are
  deleted, and the rule is to delete a view in the change that stops showing it.

### 51.6 "Start Here" was blank because the editor saved a copy it made before the note loaded (2026-09-24)

The sample collection's `Start Here.md` was 0 bytes. The file said how: it was
**born** at 07:57:39 on 19 September — created, modified and accessed in the
same second, a new inode, never written since — and its quarantine attribute
named HelloNotes and encoded the same second. So it was not truncated; the app
wrote an empty file over it, atomically (temp file and rename, which is what
`FileIO.write` does). No Claude session ran anything between 21:40 and 22:01
UTC, and the unified log placed it: TestFlight launched build 22 at 07:57:32,
seven seconds before. Seeding was ruled out (it never overwrites, and a copy
keeps the source's date and bytes).

The path: the editor host builds its document from the model's text, and a
tab appears — and its editor with it — *before* the note has loaded, so the
document can be built from nothing. The host pushed the document back into the
model at three moments (the flush hook, the end of editing, the host going
away) on the rule "if they differ, the editor's is newer". If the load lands
without the document being refreshed — the host rebuilt in the same update, say
— that rule turns an empty placeholder into the note's contents, and the next
flush (the window losing focus is enough) saves it. `loadFailure` could not
stop it, because by then the load had succeeded. The editor model, the tabs
and the document store were byte-for-byte unchanged from build 22, so the path
was still open.

`EditorModel.adopt(_:fromLoad:)` now takes the editor's text only if it was
made from the load the model holds now; the host records which load its
document reflects and routes all three pushes through it. `UnloadedNoteTests`
asserts it at the file, with a negative control showing the old push still
wipes the note.

### 51.7 The editor's command bus reached every window (2026-09-24)

Two main windows on the same note — the sample's Organising — and a section
tapped in one window's mind map selected that heading in **both** editors. The
find bar's four messages (`findQuery`, `replaceCurrent`, `replaceAll`,
`clearHighlights`), the heading jump, the match count that answers a find, and
⌘F's toggle were all posted with no address, and every editor in every window
answered them: the only guard was `textView.window != nil`, which every open
editor passes. A stray selection was the visible half. Read from the code,
Replace replaced whatever the *other* editor had selected, and Replace All
rewrote every match in the note open there — saved like any edit, with nothing
on screen in the window that did it. `EditorBusTests` reproduced exactly that
before the fix: one unaddressed Replace All rewrote two editors' notes.

The Format bus did have an address, and it was the defect in another form: the
note's path. Two editors can show one note — two windows, or Open in New
Window, each with a buffer of its own (`NoteWindowView` says so) — so a Bold
meant for one bolded the other's selection too.

So the bus is addressed to the **editor**. `EditorModel.editorID` is a UUID per
model; everything that joins the bus — the live editor, the Markdown pane,
Preview — joins as its editor (`commandBus(editorID:)`), and every poster names
one: the find bar, ⌘F, the Format menu, both outlines, `[[Note#Heading]]`
(addressed to the destination's own editor, as `tabs.editor(for:)` returns it)
and the mind map's section jump. The names are spelled once, in the package
(`EditorBus`). The seven unaddressed names are gone from the app, and so are
`hnFormat(_:documentId:)` and `hnFind(documentId:)`, which nothing posted.

`EditorBusTests` runs on both coordinators — AppKit under `swift test`, UIKit
on the iPad simulator: two editors on the bus, one addressed, the other checked
untouched, for find, the match count, Replace, Replace All, clear and a heading
jump — and each also checks that the addressed editor *did* answer, so none can
pass because nothing works. Its control posts the old way, with no address, and
nothing may answer; before the fix it failed four times, once per editor per
message. `ShellComplianceTests.theEditorBusIsAddressed` holds the app side,
which that test cannot see: no source spells a bus name without its editor, and
the three views join as their editor. Its negative control was run as well — a
probe file with one unaddressed name made it fail, naming the file.

Checked live, two windows on Organising, `DefaultCollection` only: a find typed
in one window's bar selected there and nowhere else; the other window's own
find selected only there; closing one bar cleared only its editor; the
mind-map section selected in its own window while the other kept its selection
through the jump and the clear after it; and ⌘F toggled only the key window's
bar, in both directions. Replace and Replace All were left to the tests — run
live, they write the note.

The note's sheet commands had the same shape, and are addressed now too:
Rewrite or Expand Note (`hnRewriteNote`), Present as Slides and Mermaid
Diagrams (`hnShowSlides`, `hnShowMermaid`) were posted with no address and heard
by every `NoteEditorView`, which set its sheet showing without a question.
Reproduced first, with two windows on Rich Content and Organising: Mermaid
Diagrams chosen in one opened the sheet in both — an empty one over the note
with no diagrams — and one Rewrite opened a rewrite sheet in both, each over its
own note and wired to replace it. After the fix each opened in its own window
only, Rewrite in both directions. Slides could not be tried live — the sample
has no Marp deck, and the menu row appears only for one — but its listener is
the same one line. `theEditorBusIsAddressed` forbids the three unaddressed names
as well, and its negative control failed three times, once per name.

### 51.8 A diagram opens in a real zoom (2026-09-24)

The Mermaid Diagrams command opened a sheet that was not a zoom.
`MermaidPreviewView` was written at noon on 11 July, when the editor could not
yet draw a diagram in a note — by five that afternoon it could — and from
then on it re-rendered every diagram in the note as a bitmap in a fixed
680×560 list, each scaled down to fit: the note's own pictures, smaller. Its
header still said the editor had no way to draw one.

It is gone. Every diagram in a note carries an **enlarge button** in its
top-right corner, in Edit and in Preview, and the button opens
`DiagramZoomView` on that diagram. (A diagram inside a `![[Note]]` card has
none: the card is one picture of another note.) Clicking the diagram itself
still edits it in Edit — reveals its source — as a table or a formula does; in
Preview a click on the picture does nothing. The bar's button and Note
Actions ▸ View Diagram open the same view: in Edit on the diagram the caret is
in, else the nearest, and in Markdown, Split and Preview on the first — only
the live editor tells the zoom where its caret is, which is why the source in
Markdown and Split carries a View diagram button on every diagram's opening
fence (§51.10). The routes to one view carry
one name — **View diagram** on the bar and as Preview's corner button's tooltip
and accessibility label, **View Diagram** in the menu, title case as every
command there is — where they had three: Enlarge diagram, Enlarge Mermaid
diagrams and Mermaid Diagrams. (The corner button in Edit is drawn by the text
and has no label of its own.) The
zoom draws **vectors**, by the renderer the note's
pictures come from (`DiagramDrawing` over BeautifulMermaid's layout), into a
canvas the size of the viewport behind a scroll view that pans an empty frame
of the zoomed size — so 800% is as sharp as 100%, without a layer eight times
the diagram's size in each direction. It opens fitted to the sheet, never above
300% (a small diagram fitted to a sheet would be blown up rather than
enlarged). Pinch and a double-click or double-tap go closer where they point —
the double-click between the true fit (not the opening cap, so a small diagram
does not come back to the size it opened at) and 2.5 times it — and the
controls (10–800%, in steps of 1.25) zoom about the middle of the view; ‹ ›
and the arrow keys page through the note's other diagrams. It
opens by **place** first — two identical diagrams are two diagrams, and the
second's button opens the second — then by source, because Preview has a page
and no offsets; a diagram the note no longer holds (it changed under the press)
opens on its own rather than as some other one.

The button is one drawing with two renderers, like the rest of Edit ≡ Preview:
its size, inset and corner are `DiagramZoomMetrics` in MarkdownCore, which the
editor draws in points and `GFMPage` writes as CSS. In the editor the diagram's
layout fragment draws it, and `NSTextLayoutManager.diagramZoom(at:in:slop:)`
finds it by a `DiagramZoomMark` laid over the collapsed source — an object, not
a string, so two identical neighbours are two attribute runs rather than one.
The platforms take the press differently, each for a measured reason. On the
Mac, `mouseDown` looks before `super`, so a press on the button never moves the
caret. On iPad the link-tap recogniser, which recognises alongside UIKit's by
design, was probed first and acted too late: UIKit's caret tap had already
moved the selection into the diagram, which revealed its source and took the
button away. Refusing UIKit's taps in `gestureRecognizerShouldBegin` did
nothing — the probe showed UIKit never asks. What works is a press recogniser
of no duration whose delegate takes a touch in `shouldReceive` only if it
starts on a button (with 10pt of slop for a fingertip), decided at touch-down
while the button is still drawn, and which recognises alongside nothing, so for
that one touch it excludes the caret tap, the loupe and drags. In Preview the
button is markup `PreviewSuperset` writes beside the picture, carrying the
diagram's source in an attribute; a user script posts a click on it to a
message handler. The attribute is written **on one line** (`&#10;` for each
break): the markup reaches cmark-gfm as a raw HTML block, which ends at a blank
line, and a diagram spaced with blank lines would otherwise cut its own tag in
half and pour its source onto the page.

**Which fences are diagrams is decided once.** The editor drew a fence as a
diagram by its parse; the app listed a note's diagrams — to offer the command
at all, and to page through them — with a regular expression that knew one
spelling; Preview kept a third copy that wanted the info string to be the one
word; and a `![[Note]]` card kept a fourth, which knew backtick fences only. A
`~~~mermaid`, a `` ```Mermaid `` or a `` ```mermaid theme=dark `` was a
picture in the note that had no command and that the zoom could not list, the
last was code in Preview, and the first and last were code in every card that
embedded the note. All four ask `MermaidDiagram.isDiagram(info:)` now — the
first word, in any case, ended by any whitespace, which is where cmark-gfm ends
the language it writes out — and the app lists through
`ParseResult.mermaidDiagrams(in:)`.

Four more defects surfaced on the way, none of them about zooming:

- **A second identical diagram or table was never drawn.** A block render is
  cached by content, and a render in flight turned away a second request for
  the same key; when it landed, only the block that had started it was
  refreshed, and the second — already marked styled — never heard back.
  `blockRendersInFlight` now maps each key to every block waiting on it and
  refreshes them all. `TableEmbedTests.identicalTablesAreBothDrawn` and the
  diagram twin in `DiagramZoomTests` both failed against the old turn-away.
  Three more caches had the same shape — syntax colours, inline maths and
  inline pictures, so a code block written twice kept its second copy
  uncoloured and a formula or a picture repeated in a later paragraph stayed as
  source there — and take the same fix: each maps a key to the blocks waiting
  on it, and the completion refreshes each block once (`waitingBlocks(at:)`).
  `IdenticalRendersTests` failed for all three before the fix (under
  `swift test`) and passes on macOS and on the iPad simulator. Which copy was
  turned away depended on the styling order — the block beside the caret is
  styled first, so for code it was the *first* copy that stayed grey — so each
  test asks for both copies, and first that at least one was drawn. And a
  waiting block was remembered by where it started, which an edit above it
  moved: two paragraphs typed above a table, a listing, a formula or a picture
  while its render was out left the old place inside another block, and the
  render went to nobody. `remapRendersInFlight` moves the waiting places with
  every edit, by the rule folded callouts already used; four more cases in
  `IdenticalRendersTests`, one per cache, each failed first.
- **On iPad, a note the document store handed back drew no chrome at all** — no
  tables, formulas, diagrams, code or callout boxes, bullets or heading rules.
  UIKit lays the text out inside `UITextView(frame:textContainer:)`, and
  TextKit keeps a fragment per paragraph until that paragraph changes, so a
  fragment delegate installed afterwards left an already-styled note in plain
  fragments, which the chrome overlay does not draw. It is installed before the
  view is made. `LiveFragmentTests` failed with the old order in place, listing
  every paragraph laid out in a plain fragment; the trap is in the package's
  AGENTS.md.
- **On iPad, every code block in Edit was an empty grey box.** UIKit does not
  call a fragment's `draw`, so iPad chrome is painted by a view laid over the
  text — and the code band, an opaque fill, was painted there too, over the
  code. Chrome is split into what goes behind the text (code bands, callout
  bands, inline-code pills) and what goes over it (checkboxes, bullets, rules,
  pictures), and the first half is painted by a second view kept at the back.
  The Mac draws the same two halves either side of `super.draw`, which is the
  order it always had. `ChromeUnderTextTests` renders a live editor and looks
  for the code's ink inside its band; it failed "ink 0, band 24000" before the
  split.
- **The Mermaid and Marp bar buttons never appeared on a freshly opened note.**
  Which buttons a note gets was worked out by a task keyed on the note alone,
  which ran once — on the empty placeholder text a tab holds before its note
  loads. It is keyed on the note, its load and its saves — the note menu's own
  key, so the bar and the menu agree about a diagram typed into an open note —
  and runs through `offMain`: finding diagrams is a whole-document parse now,
  and a detached task in this target stays on the main actor.

A concurrency review of all this found nothing on the wrong actor, and three
places where the zoom made the main actor do work in proportion to the note:

- **The button's hit test ran on every click and touch in the editor** and
  asked for the longest run of an attribute that is absent almost everywhere,
  which walks every attribute run in the note — 1–3ms a click at 1MB. It checks
  the point first now; on a diagram the walk stays inside that diagram.
- **The iPad's chrome walk.** Each of the two views over the text's whole
  height walked the layout fragments from the top of the note to the dirty
  rect — a third of a microsecond a fragment, on every keystroke and scroll
  frame. The walk from the top is older; splitting the chrome into a view under
  the text and one over it made it two walks, 7ms a frame near the end of a 1MB
  note. It starts one block above the viewport now, read from the viewport
  controller rather than hit-tested (asking for the fragment at a point can lay
  text out, and laying out during a draw is a known crash).
  `ChromeWalkTests` draws both views near the end of a 4,000-block note: 4,005
  fragments each before, a screenful after, and the code box at the end painted
  both times.
- **Opening the zoom** took the editor's text into the model — a comparison of
  a bridged string, 31–57ms a MB — and parsed it again, 8ms a MB, both on the
  main actor. In Edit it reads the diagrams from the parse the document already
  keeps (`EditorDocument.mermaidDiagrams`, O(blocks)), with the caret from the
  same document, through one hook (`EditorModel.liveDiagrams`, which replaced
  `caretLocation` and `catchUpWithEditor`); elsewhere it parses the buffer
  through `offMain`. `theDocumentListsItsDiagramsFromItsOwnParse` holds the
  incremental parse to a fresh one across an edit.

Tests: `DiagramZoomTests` on both platforms — the button drawn (a pixel test
whose control is an editor no host listens to, which must draw none), hit,
missed, at the end of a note and beside an identical diagram; a click on the Mac
that zooms and leaves the caret where it was; an iPad press taken at
touch-down. `MermaidDiagramsTests` holds the rule across six spellings, the
fences that are not diagrams, order and identical neighbours; its control, the
space-only split the parse first used, fails the two tab-separated spellings.
`DiagramZoomViewTests` in the app: opening by place, by source and alone; the
diagram nearest the caret; every spelling listed (control: the old expression
finds none of them), drawn by Preview (control: Preview's old copy refuses
them) and drawn in a transclusion card (control: the card's old rule refuses
them); Preview's button through cmark whole (control: the same markup with its
line breaks left in is cut); and the zoom's vector drawing matching the note's
picture through a SwiftUI canvas (control: the picture upside down).
`render-parity.sh` never lays out a diagram — its documents hold none, and it
does not go through `PreviewSuperset` — so the box the button needs was
measured on its own: the old markup and the new on the real Preview page in
WebKit, at three picture sizes, one of them scaled down to a 560pt pane. The
paragraph, the picture and the paragraph after it land at the same points to a
hundredth; an inline-block with no line height of its own is exactly as tall as
the picture it holds. The button sits 24pt square, 6pt in from the top and the
right.

Checked live. On the Mac by the accessibility API, not by screen captures:
Preview's button opened the zoom at 237%, zoom in went to 296% and 370%, Fit
came back to 237% and Done closed it, leaving the diagram drawn in the note;
Note Actions ▸ Mermaid Diagrams (View Diagram now) and the bar button opened
it too (the bar button only after the note-kind fix). The button in Edit could not be pressed
there — a synthetic click at a coordinate never reaches an `NSTextView` — so it
is `DiagramZoomTests`' job. On the iPad simulator in landscape, with a finger
(a touch path, not the simulator tool's tap, which arrives as a pointer):
Preview's button opened the zoom; the button in Edit opened it two presses out
of two on the shipping build, and three of three on a probe build (two with a
finger, one with the pointer) that logged the touch taken at touch-down with
the selection untouched; a pinch reached
800%, the cap, anchored on the diagram and still sharp; Fit returned to 237%; a
tap on the diagram itself revealed its source; and code blocks showed their
code. Two earlier presses on the shipping build had missed, aimed from
screenshots of a page that was still moving — it was seen to move 17pt between
two screenshots with nothing touching it — and landed once aimed at a page that
had stopped. A double-tap could not be tried: each simulated touch is a
separate call, further apart than a double-tap allows. Rechecked there after
the review's fixes: the bar button in Preview (the parse off the main actor)
and in Edit (the live document's own list), and the diagram's own button, each
opened the zoom at 237%; and the chrome — callout bands, inline-code pills,
code box, table, diagram, heading rules — was painted scrolling down the note
and back up.

Something older turned up there, and it is not the zoom's: in landscape, a tap
that brings up the software keyboard scrolls the tapped line above the top of
the editor — any line, a table's and a plain paragraph's alike. A probe put it
on scroll-past-end; fixed the same day (§51.9).

### 51.9 Room past the end of a note is room to scroll into (2026-09-24)

The editor lets a note's last line scroll up to the middle of the view, and the
room for that was a bottom **content inset** of half the viewport. A scroll view
keeps what it reveals inside its bounds *less* its insets — UIKit's
`scrollRectToVisible` and AppKit's `scrollRangeToVisible` alike — so the editor
believed the lower half of itself was covered. On both platforms a line already
on screen in the lower half was scrolled up to the middle when revealed: on the
Mac, 754.5 → 1067.5, half of a 626pt view. On iPad the software keyboard's
inset came on top — 313pt of ours and 407pt of the keyboard's against a 626pt
view, a visible band of negative height — and UIKit's own scroll-to-the-caret
overshot it: a table tap moved the offset 869 → 1066 for a caret at y 946, a
paragraph tap 208 → 616 for one at 496, and the tapped line ended 94pt above the
top of the editor. Found in landscape on the `HN-iPad` simulator while checking
the diagram zoom (§51.8); measured with a probe.

The room is now somewhere to scroll *into*. On iPad it is part of the text
container — `textContainerInset.bottom` is the 12pt it always was plus half the
viewport — so it is content, not a covered band, and `contentInset` and the
scroll indicator insets are the system's alone again (the keyboard's included).
On the Mac it is `PastEndClipView`, an `NSClipView` whose `constrainBoundsRect`
lets the bounds go `pastEnd` beyond the document, with no inset of ours at all —
which also leaves `automaticallyAdjustsContentInsets` on, which the toolbar
needs. One trap for anyone measuring this: TextKit 2's `UITextView.contentSize`
is an estimate until the viewport has reached the end of the note — 1,305pt
reported for a note whose last line sits at 2,384 — so the guard below places
the last line mid-view before it measures anything.

`ScrollPastEndTests` (the package, both platforms): a line on screen in the
lower half is not scrolled to; with a 407pt keyboard — given the way SwiftUI's
keyboard avoidance hands it over, as the view controller's bottom safe area — a
covered line comes to rest above it. Each failed before the fix. The guard, that
the last line can still be scrolled to the middle, passes before and after on
purpose: a fix that simply removed the room would pass the rest.

Checked live. On `HN-iPad` in landscape, Rich Content in Edit, "Rendered
natively in the editor as you type…" in the lower half, tapped with a finger:
the keyboard came up and the line stayed on screen above it, scrolled only as
far as it needed. In portrait, on a second iOS 27 iPad simulator with a fresh
install holding only the sample collection: the same line, low in the pane where
the keyboard rises — the tap put the caret on it, above the keyboard. The
borrowed simulator was put back as it was.

### 51.10 A View diagram button on every diagram in the source (2026-09-24)

In Markdown and Split mode the bar's button and the menu opened the zoom on the
first diagram in the note: the source view's caret is nobody's to read, and a
command cannot say which diagram it means anyway. Edit and Preview answer that
with a button on each picture (§51.8), and now the source does too: every
diagram's fence carries the same button at the right of its opening line, and
pressing it opens that diagram. `SourceDiagramButtons` (the app) finds the
diagrams off the main actor after each edit — one search at a time; typing
quickly used to start a whole-note parse per character, since cancelling a
search does not stop its parse — and places a `DiagramButtonView` (the package)
on each fence inside TextKit's viewport, again whenever the view lays out or
scrolls; positions outside the viewport are estimates, and nothing there is on
screen. A press opens its diagram by place, then by source, like every other
route in.

`DiagramButtonView` draws `DiagramZoomButton`, the drawing the editor puts in a
picture's corner, so the button is one picture in every mode, and it is a
button to accessibility named **View diagram**. On the Mac it takes the click
itself, first mouse included, and presses on a mouse-up over it. On iPad it
takes no touches: a control laid on a `UITextView` loses its tap to UIKit's
caret tap, which is what the editor's own button found, so the text view carries
a `DiagramButtonPress` — the same zero-duration press, claimed at touch-down in
`shouldReceive` when a touch starts on a button, recognising alongside nothing.

`DiagramButtonTests` (the package): a button named by its host whose press runs
its action, on both platforms; the Mac view drawing exactly the editor's
button, pixel for pixel, against an empty view that must differ; and on iPad a
touch taken at touch-down and pressed on release — not a touch elsewhere, not
one dragged off before release, not one on a hidden button.
`SourceDiagramButtonsTests` (the app, both platforms): two identical diagrams
and a Swift fence get two buttons, each on its own fence's opening line at the
right, and a press on the second opens the second.

Checked live on `HN-iPad` in landscape, Rich Content. In Markdown mode the
button sat on the `mermaid` fence's line at the right; a finger press opened the
zoom on that diagram at 237%, and after Done the source was where it had been —
no caret placed, no keyboard. In Split mode the same, once the source pane was
scrolled to the fence, and the `swift` fence below it had no button. Typing and
deleting in the Markdown pane afterwards kept the caret at the edit (§51.12).

### 51.11 A diagram is drawn off the main actor (2026-09-24)

Every Mermaid render ran on the main actor — parse, layout, rasterise and the
flip, inside `MainActor.run` in the editor host and on the way into Preview:
3.7, 17.7 and 123ms at 12, 40 and 120 nodes, measured by the concurrency review
the same day.
The reason given was the flip, and it was the only one: BeautifulMermaid's image
path is CoreGraphics throughout and draws its labels into a thread-local
`NSGraphicsContext`, and only the app's `lockFocus` flip needed the main
thread. The flip is a bitmap `CGContext` at the source's own pixel size now, and
`EditorHost.renderMermaid` and `PreviewSuperset.diagram(_:isDark:)` render
through `offMain`. `DiagramZoomViewTests.aDiagramRendersTheSameOffTheMainActor`
draws a diagram on the main actor and off it and compares the pixels, with a
check that something was drawn at all; the orientation is held by the zoom's
vector drawing matching the picture, whose control is the picture upside down.
Formulas and tables stay on the main actor, for different reasons. A formula is
drawn by a view, `MTMathUILabel`, which has to be made there. A table is drawn
into an image, but on the Mac through `PlatformImageKit.image(size:)`, whose
`lockFocusFlipped` is main-thread-only — the limit the diagram's flip had, with
the same way out. And a diagram inside a `![[Note]]` card is still drawn with
the card, on the main actor (unimplemented.md §3).

### 51.12 Saving a note compares nothing on the main actor (2026-09-24)

Letting go of a note — the end of editing, a switch of tab or mode, going to
the background, quitting — carried the editor's copy into the buffer and saved
it, and compared the whole note on the main actor at every step: the copy with
the buffer (`adopt`), the buffer with the file whenever the buffer changed
(`text.didSet`), both again on the way into the save and into the write — and
then it encoded the note to UTF-8 there as well. The copy is the text storage's
string, a bridged `NSString`, and comparing one with a Swift string walks it a
chunk or a character at a time: 82ms for a 2 MB note, one comparison, on this
Mac (the review measured 31–57ms a MB). A probe `NSString` that counts reads of
its characters on the main thread counted 338 in one save of a 94 KB note, and
160,350 — one per character — when the file was checked against the last save
after a change made elsewhere.

**The fifth comparison was the macro's.** `@Observable`'s setter compares the
old value with the new before it notifies, to skip an equal one:
`shouldNotifyObservers` is `lhs != rhs` for an `Equatable` member (checked by
expanding the macro with `-dump-macro-expansions`). So `text = …` compared the
whole note by itself, and so did `lastSavedText = …`, and `LiveBuffer`'s
`text = …` each time the buffer was published to the other scenes — 320,008
reads for two 94 KB publishes. And Markdown and Split mode write the buffer on
every keystroke, so per key there were the setter's comparison, `didSet`'s,
SwiftUI's `onChange(of: editor.text)` comparing the old text with the new, the
source view's `tv.string != text` echo check — a copy and a comparison — and a
diagram-button search.

What replaced them:

- **Dirtiness is a count.** `textGeneration` bumps whenever `text` is set;
  `savedGeneration` is the generation the file holds; `isDirty` is the two
  differing. A count can only err towards dirty — a buffer typed back to what
  the file says — never towards clean, which would be the dangerous way.
- **The one comparison a save needs** — are these bytes the file's already? —
  runs inside the write's `offMain`, beside the UTF-8 encoding, and compares
  bytes (`sameBytes`, a `memcmp`), not `==`. `==` is canonical equivalence, so a
  change that only altered Unicode normalisation — a precomposed é for an e and
  a combining accent — compared equal and was never saved. When the bytes match,
  nothing is written: no new `savedRevision`, no `onSaved`.
- **`reconcileWithDisk` reads the file and compares it off the main actor**, and
  looks again if a load or a write landed while it was reading.
- **`text` and `LiveBuffer.text` are observed by hand** (`access` and
  `withMutation` around an unobserved store), so setting them compares nothing;
  `lastSavedText` and `conflictDiskText` are not observed at all — nothing
  watched them.
- **What follows the text follows its version** — `textVersion`, the editor and
  the generation: the live-buffer `onChange`, and Preview's superset key, which
  hashed the whole note on every render.
- **A settle carries the editor's copy only if it has been edited** since it
  last matched the buffer. `DocumentLoad` records the document's own `revision`
  and the buffer's generation at that moment (`matched`), so a settle with
  nothing typed copies nothing and compares nothing (`carry`), and a cached
  document coming back to its tab is taken as it is when neither side has moved
  (`stillMatches`) — that compared the whole note on every tab switch.
- **The Markdown pane knows its own echo.** Each keystroke goes to the buffer
  and straight back through the binding; the coordinator keeps the string it
  handed over (`shown`), and the very same string coming back compares equal
  from the two strings' storage without a character being read (`differs`).
  Its diagram search runs one at a time.

Found on the way, and fixed with it: a document built while its note was still
loading, if the load landed during the build, was taken as current — typing into
it would have carried the empty document, typing and all, over the note: the
Start Here loss by a narrower door (§51.6). `DocumentLoad(built:at:for:)` brings
it up to date first. And one not fixed here: a write the app made into the
buffer — an accepted tag, link or summary, a property, a whole-note rewrite,
Review Links, a restored version, an inserted template — never reached the live
document in Edit, so typing afterwards carried the document over it. The carry
above stopped a settle with nothing typed from undoing it; §51.15 closes the
rest.

Measured with `MainActorBudgetTests` (opt-in, run alone): the model's save of a
2 MB note — the editor's copy taken, checked against the file, encoded and
written — now costs **0.5ms** of main-thread CPU, where one of the comparisons
it used to make costs 82ms on its own — the control that shows the instrument
can see one — against 5ms for two idle seconds. What a collection does after
the write (`onSaved`: the link graph, search and relatedness indexes, each a
pass over the note on the main actor) is not in that number; it is open
(unimplemented.md §3). In Markdown mode the concurrency review measured the
keystroke path in an optimised build on a 2 MB note: the view's text read after
an edit, 0.003ms; the echo check, too small to measure, where comparing two
bridged copies — what it replaced — took 106ms.

Tests, all failing first where the API already existed: `SaveOffMainTests` —
the whole save reads the editor's copy on the main actor zero times (338
before) and still writes it; a copy that is the file's bytes is not written
again, and one that differs is (50 main-thread reads before); a change of
normalisation is saved (was not); an external change is checked off the main
actor (160,350 reads before) and a file still holding the last save is no
change; publishing the buffer reads nothing on the main actor (320,008 before,
run against the old `LiveBuffer` with everything else fixed); and the control —
the probe does see a comparison made on the main actor, so its zeroes mean
something. `DocumentCarryTests` — a settle carries what was typed, once, and
nothing else, and not a replacement the host made; a document from an earlier
load is still refused; a document built before the load landed is brought up to
date, with its control, the same document matched as built, carrying its
typing over the note. `SourceEditorTests.theEchoOfAKeystrokeIsKnownWithoutReadingTheView`
is new API and could not fail first; its control shows the count sees a read of
the view. All of them pass on macOS and in the `HN-iPad` simulator.

Checked live on `HN-iPad` (§51.10): typing into the Markdown pane and deleting
it again kept the caret at the edit, and the save that followed a switch to
Preview — the buffer dirty, its bytes the file's — left the file untouched, its
date and its hash the same as before.

A file-I/O review of the change found one thing it had broken. With dirtiness a
count, a buffer typed back to what was last saved still reads as dirty, and a
change made elsewhere in that state raised a conflict where the old comparison
had reloaded quietly. Worse, **Keep Mine** then compared the buffer with the
last save, found the same bytes, wrote nothing and called the note saved —
while the file held the other version, which the next check would have loaded
over the screen. Both are closed: `reconcileWithDisk` also asks, off the main
actor, whether the buffer still says what was last written, and takes the
change elsewhere when it does (a buffer that moves while the file is read is an
edit in progress, and gets the conflict); Keep Mine makes the other version the
baseline and marks the buffer dirty whatever it says (`savedGeneration` is
`nil` — the file holds none of ours), so it writes unless the file already
holds those very bytes. A check that spans an
await now notices any change to its baseline, Keep Mine included
(`lastSavedChanges`). `aBufferTypedBackToTheLastSaveTakesAChangeElsewhere` and
`keepingMineWritesMineEvenWhenItIsWhatWasLastSaved` failed against the change
as first written; `keepingMineWritesMine` is the control. The write also hands
back its UTF-8 copy, which becomes the baseline and what `onSaved` gives the
collection, whose link graph, search and relatedness indexes read the whole note
on the main actor after every save — a native string now, not the bridged one.
That work stays where it is (unimplemented.md §3). The same review found two
older ways to lose a note: typing while a note loads, closed in §51.13, and a
cloud mirror evicting an open tab's file, closed in §51.14.

A concurrency review of the whole change found nothing on the wrong actor and
two more things in the code it touched. `text`, observed by hand, had no
in-place accessor, so `editor.text += …` — Insert Template's way — copied the
note to append to it; it has the macro's own `_modify` now
(`anEditInPlaceIsAnEdit`). And, as a hypothesis from reading the host: for a
moment after a tab switch the host holds one tab's document beside the next
tab's model and load, and an end of editing then — the old text view being
removed while first responder — would carry the first note into the second's
buffer and save it over the second's file, every count agreeing because both
tabs are on their first load. HEAD paired them the same way. `DocumentLoad`
keys its match on the editor as well as the counts, and now on the document
itself, so a pair it did not match is refused:
`aDocumentIsCarriedOnlyIntoItsOwnBuffer` failed with B's note holding A's text
before the guard. Whether the pairing happens on a device was never confirmed;
since §51.15 the host does not make it. `aKeptDocumentMatchesUntilEitherSideMoves` holds the
rest of the match: an edit in the document, a write into the buffer, and
another tab's buffer whose count is the same number.

The full runs found one more thing, and it was a test's: `ChromeUnderTextTests`
(§51.8) failed on the Mac at seven in the evening — "no band behind the code".
It looks for the light theme's code band, it never said which theme it wanted,
and the Mac had switched itself to dark at sunset. It pins the light appearance
now on both platforms, and passes in a dark session.

### 51.13 Nothing typed while a note is loading is saved over it (2026-09-24)

The file-I/O review of §51.12 found an older way to lose a note. `willOpen`
locks the buffer the moment a note is chosen — `loadFailure` says it is still
loading, and `performSave` refuses while it does — so that nothing is written
before the content arrives. `open` let go of that lock right after flushing the
note it was leaving: *before* `FileIO.materialise`, which waits up to a minute
for an online-only note, and before the read, which waits as long as the file's
provider holds it. For all of that wait the buffer is not the note. In a new tab
it is the blank the tab starts with; in an editor opened a second time — a retry
from the "couldn't be read" banner — it is the note shown before. The load had
not moved, so `adopt` took the editor's copy with whatever was typed into it,
and the next save — the end of an edit, the app going to the background — wrote
it over the note that was arriving: the Start Here loss (§51.6) by another
door, and, in the reused editor, one note written into another's file. It is in
HEAD; §51.12 did not make it and did not close it.

**Holding a load still, in a test.** The obvious ways do not hold it. An
online-only note cannot be made to wait: `isMaterialized` answers `true` for
anything that is not an iCloud item, so `materialise` returns at once. A named
pipe at the note's path cannot either: `Data(contentsOf:)` refuses a FIFO
outright ("Permission denied"), so the load fails rather than waits. What does
hold it is what a provider does while it materialises a file — a coordinated
write. `FileIO.readData` is a coordinated read and waits behind it, and so does
a coordinated write, which is how the save then went second. That was probed
outside the app before a test was written on it: the read waited, the save
waited, and on release the read took the note that had arrived and the save
wrote the typing over it.

**The lock is its own now.** `loadsInFlight` counts loads under way, from the
moment `open` has flushed the note it is leaving until the loaded text is in the
buffer (a `defer`, so every path through `open` lets go). `performSave` refuses
while any is — silently, since the load replaces the buffer and nothing typed
into a blank was a note — and `reconcileWithDisk` stands aside, since the load
reads the file itself: checked in the wait, the file would be compared with the
baseline of whatever the buffer held before, and anything typed would put a
conflict banner over the note as it arrived (a provider writing the file as it
downloads is exactly what makes the watcher look). Not `loadFailure`: that is
also what puts "couldn't be read" on screen (`UnloadedBanner` shows whenever it
is set and nothing is downloading), and held through every ordinary read it
would flash on each open. A count, so a retry tapped during a load is not
unlocked when the first load finishes. Nothing new appears on screen: the
Downloading banner is where it was, and typing into the blank while a note
loads is replaced by the note when it lands, as it always was — it is just no
longer written anywhere first.

`UnloadedNoteTests`, each holding the note under a coordinated write:
`typingIntoANoteStillLoadingIsNeverSavedOverIt` — a new tab, with its control:
once the load has landed, a save writes; `anEditorOpeningItsNextNoteNeverSavesTheLastOneOverIt`
— a reused editor, saved by a flush as backgrounding does; and
`aChangeSeenWhileTheNoteLoadsIsNotAConflict`. Before the fix the note on disk
became "Typed while it loaded.", the second note's file became the first note,
and a conflict was raised over the note that had just arrived. The tests *await*
the save, the flush and the check rather than timing them. The first version
asked for a refused save to come back within a second, and in a full run —
every test in the target shares the main actor — the save was sometimes simply
not scheduled in time. Now the provider lets go by itself after ten seconds, so
a save queued behind it (the defect) finishes, writes, and fails the test
instead of hanging it, and a refused one returns however busy the main actor
is. Proved again with the lock disarmed: all three failed as above. With it,
the app suite passes (548 tests, twice), and the editor package's (440 on macOS,
421 on the iPad simulator).

### 51.14 A note open in any window is never evicted from a cloud collection's cache (2026-09-25)

The third finding of the §51.12 file-I/O review. A cloud collection — a
`RemoteStore` folder — works from a local mirror bounded at 256 MB: opening a
note downloads it, and past the limit the least recently used bodies are
written back to zero-byte placeholders (`RemoteMirror.evictIfNeeded`), keeping
whatever it is told to keep. `hydrateIfNeeded` said it kept "what was just
opened or what is open in a tab", and `pinnedCachePaths`, whose own comment said
the same, returned the first alone. So opening a note with the cache full
emptied the others open in tabs, under them. On the Mac the collection's root
is the mirror's cache folder, so the file watcher took each eviction for an
external change and `reconcileWithDisk` ran: a clean tab reloaded an empty
note, a tab with edits raised a conflict against "". The provider's copy was
safe — `noteDidSave` will not upload a note that is not hydrated — and that
same rule meant anything typed in the emptied tab was never uploaded, and was
written over at the next download.

Two layers now:

- **Every open note is pinned.** `pinnedCachePaths` adds every note an editor
  holds, in any window, from a weak registry of every `EditorModel` in the
  process (`EditorModel.openNoteURLs`). Each window keeps its own `EditorTabs`
  and a note window a bare editor, and a collection sees none of them, so the
  question is answered where every editor is. Open notes are matched to the
  cache through `CollectionIndexCache.rootPrefixes` — every spelling of its
  path — and never by name: `RemoteMirror.relativePath` answers a URL from
  elsewhere with its last component, which would pin a namesake here. Pinned
  notes can hold the cache over its limit; what is open is what someone is
  looking at.
- **A placeholder is not the note.** Before taking a change, `reconcileWithDisk`
  asks whether the file is a stand-in (`EditorModel.isPlaceholder`, wired
  through `EditorTabs` to `Collection.isPlaceholder(at:)`). The collection asks
  the mirror — `RemoteMirror.isPlaceholder`, a file the manifest knows and has
  not fetched; not simply `!isHydrated`, which a note just created here also
  is — from memory, on the main actor. Whether an iCloud item has downloaded is
  asked beside the read, off it (`FileIO.isMaterialized`); it was asked here
  first, on the main actor, once per open tab per change seen, until the review
  of §51.15 moved it. `FileIO.hasContentAvailable` asks the same question of a
  `Note`, but a `Note` answers for its file as it was when the folder was
  walked, and an editor holds the one it was opened with, so the file is asked
  instead. Nothing in the app evicts an open note any more; this is for
  whatever else ever leaves a stand-in under one.

`OpenTabEvictionTests`, on a mirror with room for one of four notes and tabs
wired to the collection as the shell wires them:
`openingANoteNeverEvictsOneOpenInATab` — two notes open, a third opened and
closed, a fourth opened; before the fix "First" and "Second" went to 0 bytes
under their tabs, and the control is the closed note, which is evicted: the
cache is still bounded. `aNoteOpenInAnotherWindowIsNotEvicted` — one note open
only in another window's tabs, one only in a note window's editor; a pin list
built from the window at hand would lose both. `aPlaceholderUnderAnOpenTabIsNotTakenAsItsText`
— before the fix the clean tab loaded "" and the edited one raised a conflict;
`aRealChangeUnderAnOpenTabIsStillTaken` is its control. With the new pinning
disarmed, both eviction tests failed again, naming the notes open elsewhere.
The app suite passes (552 tests), and the app builds.

Found on the way and not fixed here: a note window's editor is wired to
nothing — no download before it opens, so a placeholder note opens empty there;
no `onSaved`, so its saves are never uploaded, never marked as the app's own
write and never indexed; no `saveBlockedReason` (unimplemented.md §1).

### 51.15 Whose text wins: the editor's copy or the buffer (2026-09-25)

In Edit the live `EditorDocument` keeps its own copy of the note, and the
`EditorModel`'s buffer is what is saved; typing reaches the buffer when the text
settles (§51.12). When the two differed, the host decided which to keep by
comparing them — a bridged string against the buffer, on the main actor — and
took the buffer's side. Three ways to lose work followed, all in HEAD, traced by
review on 2026-09-24 (unimplemented.md §1):

- **Typing was discarded by a tab switch and return.** Nothing ends editing on a
  tab switch. The Mac's tab bar takes no focus and the text view is only
  rebound; on iPad a probe showed the text view removed while first responder,
  with no end of editing at all. So what was typed stayed in the kept document,
  and coming back the host replaced it with a buffer that had never seen it.
  Seen live on `HN-iPad` before the fix: typed into Organising, over to Linking
  and back — the typing gone from the screen, and never in the file. The same
  typing went if the document store let the kept document go first, if the tab
  was pruned (`isDirty` cannot see what was never carried), and under a change
  made elsewhere, which loaded over it silently.
- **A write the app made never reached the document** — an accepted tag, link
  or summary, a property, a rewrite and its Insert Below, Review Links, a
  restored version, Insert Template. Each set the buffer, the note on screen
  never showed it, and the next carry wrote the document, without it, back over
  it.
- **For a moment after a tab switch the host could pair one tab's document with
  the next tab's model**, and an end of editing then would have carried note A
  into note B's buffer. §51.12 made `carry` refuse a pair it had not matched;
  now the host does not make the pair.

**Whichever moved since they last matched wins** (`DocumentLoad.settle`), asked
of the counts alone — the document's `revision`, the buffer's
`textGeneration`, the load:

- only the document moved — typing — so it is carried into the buffer;
- only the buffer moved — a write the app made, or a load — so it replaces the
  document, keeping the caret. `replaceText` clears the document's undo, and
  UIKit's stack lives up the responder chain, so the host resets that too
  (`proxy.resetUndo()`);
- both moved: **a load wins**, since a load is the file's text, and one lands
  over typing only when the person chose Reload — a change elsewhere is a
  conflict now (below). **Otherwise the typing wins.** Every write the app
  makes carries first, so both can only have moved if one did not; and typing
  once replaced is gone from the screen and from every undo stack, where a tag
  or a property can be accepted again;
- a pair this load never matched settles to the buffer: the document belongs to
  another editor, whose own buffer carried it when that editor let go.

What follows from the rule:

- **Switching away carries and saves.** Leaving a note — the host's task
  starting for the next one, and `onDisappear` — carries the document into its
  *own* buffer (`settleOnLeaving`) and saves it. A note switch was always one of
  the four moments a save is taken (§51.12); nothing had marked it.
- **The app's writes go through `EditorModel.applyEdit`**, which carries what is
  on screen first — so the change is made to what the person sees — then writes
  the buffer. The host follows `textVersion`, and the buffer, alone having
  moved, replaces the document. Every write listed above is converted. Reading
  the buffer as the note carries first too (`carryLiveEdits`): a rewrite's
  original, a link review, the outline's jump to a heading.
- **Everything that judges the buffer carries first**: `reconcileWithDisk`, so
  typing on screen is unsaved work and a change elsewhere raises the conflict
  instead of loading over it; `EditorTabs.prune`, so a tab with typing not yet
  carried is kept; and the document store, which carries a kept document into
  its own buffer before letting it go (`forget`, `forgetAll`, eviction).
- **The end of editing names its load.** `onEndEditing` captures the
  `DocumentLoad` beside its document, and carries into that load's own model —
  never the host's model of the moment. The pairing was never seen live (on
  iPad no end of editing fires on a tab switch at all); it is closed either way.
- **The two whole-note comparisons left in `EditorHost` are gone**
  (unimplemented.md §3): the reload's `document.text != editor.text`, and the
  settle of a cached tab shown again.
- **`willFlush` holds its model weakly.** The closure is stored on the model it
  names, so the strong capture kept every model alive after its tab closed —
  and its note in `EditorModel.openNoteURLs` (§51.14), pinned in a cloud cache
  for good.

**The Properties panel, found by the live check.** With the app's writes
reaching the document, a tap into a property field showed two older defects.
The inspector's panel binds straight to the note and writes whatever it is
handed, including the value a field hands back, unchanged, when it gains focus:
rendered again, that rewrote the person's front matter in the panel's style —
`tags: [tour, demo]` became a block list, and was saved — and now also replaced
the note on screen and cleared its undo. (An identical `text` set notifies
since §51.12; the macro's comparison was what had kept it quiet.) And every
row's `Property.id` was a fresh `UUID` per parse, so any change to the note made
every row a new one and SwiftUI tore down the field being typed in: on iPad a
tap on a field never kept the keyboard, because the write on focus changed the
note and the field went with it. `EditorModel.setProperties` is the panel's one
way in, from the inspector and from the note window's popover, and writes
nothing when the values are already the note's (`FrontMatter.applyingChanges`,
one read of the block — the one `applying` makes anyway). A row's identity is
its key; a key written twice by hand is still two rows. (The panel writing the
note at every keystroke is the review's first finding, below.)

`WhoseTextWinsTests`, with the model and document wired as the host wires them,
all failing first but one: `typingSurvivesATabSwitchAndReturn` ("the typing was
replaced on the way back", "the typing never reached the buffer", "switching
away did not save it"); `anAppWriteReachesTheDocumentAndSurvivesTyping` ("the
tag never reached the document on screen", "typing on took the tag away
again"); `aChangeElsewhereWhileTypingIsAConflictNotAReload` (loaded silently,
and the typing on screen replaced); `pruningKeepsATabWithTypingNotYetCarried`;
`forgettingAKeptDocumentCarriesItsTypingFirst`;
`whenBothMovedWithoutALoadTheTypingWins` ("the buffer does not hold what is on
screen"); `settlingComparesNothingOnTheMainActor` (48 main-thread reads of the
buffer in one settle); `handingBackUnchangedPropertiesChangesNothing` (the buffer
moved, the document was replaced, the front matter rewritten); and
`aPropertyKeepsItsIdentityWhenItsValueChanges`. `whenBothMovedALoadWins` guards
the other half of the policy and passed before, and
`aChangedPropertyReachesTheDocumentAndStays` is the properties' control.

Checked live on `HN-iPad`. Typed into Organising, then tapped Linking's tab: the
file held the typing the moment the tab changed, and it was still on screen on
the way back. Then typing in the body, a tap into the priority field — which
kept the keyboard now, and wrote nothing: the file byte for byte as before —
two digits there, more typing in the body, and away to another note: the file
held `priority: 250` and both typings, and so did the screen on the way back.

**What the concurrency review found.** The settle itself was clean — no
comparison of two notes anywhere in it, and every save it starts goes to the
model its document was matched with, after the carry it depends on — but the
paths around it were not, and two of the defects were this change's:

- **Every character typed in a Properties field replaced the note on screen.**
  With the app's writes reaching the document, the inspector's panel — bound
  straight to the note, `onPropertiesChanged: {}` — made each keystroke a full
  parse and restyle of the note, its undo cleared, and six reads of its front
  matter. The rows are a draft now (`PropertyDraft`), which is the contract
  `PropertiesEditor` always stated: typing changes the draft, and Return,
  leaving the field, a toggle, or a property added or removed commits it,
  through `setProperties`. The draft follows the note by its text version: when
  the body moves, what is being typed stays; when the front matter changes
  under it, the note's rows win; and when a tab switch leaves an edit unwritten,
  it is written into *its* note, not lost and not written into the next. Two
  more things came with it. **Add item** stopped writing an empty `- ""`, which
  parsed back as no item, so in the inspector the new row vanished before
  anything could be typed in it; it now opens a field and commits when that is
  left. And clearing a number and typing a new one no longer turns it into a
  quoted string: the empty value in between is never written.
- **A note open in two windows shared one document.** The store is the app's
  and its key named the note, not the editor, so the second window was handed
  the first's document and load: settling it replaced what the first window had
  typed, and took the load, so the first window's end of editing carried into
  the second's buffer. The key names the editor (`EditorDocumentStore.Key`).
- **`reconcileWithDisk` asked the file provider on the main actor** — §51.14's
  placeholder check called `FileIO.isMaterialized` there, once per open tab per
  change seen, and changes arrive when the provider is busiest. The main actor
  asks only the mirror's manifest now (`isPlaceholder`); iCloud is asked beside
  the read, off it.
- **Whole-note work older than this change, on the paths it touched.** The
  inspector took the note as a `String`, so SwiftUI compared it with itself at
  every redraw of the shell — 206ms for a 2 MB note, the review measured, once a
  keystroke in Markdown mode — and `OutlineView` the same one level down; both
  take a `NoteText` now, compared by version. Review Links' guard compared the
  reviewed text with the current one; it compares text versions
  (`LinkReviewFlow.apply(_:reviewed:now:to:)`). And reading a note's properties
  split the whole note and counted its characters (`FrontMatter.block(in:)`); it
  reads the front matter and stops — which also closed a way to lose text:
  counting took `\r\n` for two characters, so a property written back cut a
  letter off the start of the body for each CRLF line in the front matter.
- **Switching mode saved nothing.** The host's `onDisappear` carried the typing
  and discarded the model it was carried into, so a switch to Preview left it
  unsaved until the next flush; it saves now, as leaving for another note does.
  The debounce state the host still declared — a task never assigned, a pending
  sync set and landed in the same call — is gone.

**Two more, found by the live check of those fixes.** The caret: a write the
app makes lands in the front matter, above a caret in the body, and the replace
put the caret back at its old offset — seven characters short, for a priority
of 250 in a note whose tags the panel wrote back as a list — so the next
keystrokes went into the middle of a word (" AFTER" landed inside "DRAFTBODY").
A caret in the body now moves with the body (`DocumentLoad.caret`), asked of the
two front matters alone. And a crash: switching notes with a new tag still being
typed trapped with an index out of range. The draft had moved to the next tab
(its note still loading, so no rows), and the field, handing its text back as
it ended editing, read its row through `ForEach($properties)`'s binding — by the
index it used to have. Where the next note had a row there, the text would have
gone into the other note. Rows are read and written by identity now, a note's
fields go with it (`.id` of the editor), and the rows take no write from a field
of a note they no longer belong to.

More tests, failing first where the API existed: `PropertiesPanelTests` —
reading a note's properties made 1,330,504 main-thread reads of a 165 KB note
against 554 for its front matter alone (`readingPropertiesReadsOnlyTheFrontMatter`),
and the CRLF note came back as `…---\nody starts here.\n`
(`writingAPropertyKeepsTheBodyWhateverTheLineEndings`); `PropertyDraft` is new
API, and its three tests have a control — a change to the front matter under the
rows is what they show. In `WhoseTextWinsTests`,
`aNoteOpenInTwoWindowsKeepsADocumentForEach` — against the host's key as it was,
"the second window replaced the first window's typing" and "the first window's
document now carries into the second window's buffer" — and
`aWriteAboveTheCaretKeepsItsPlaceInTheBody`, "the caret moved -7 characters
within the body", with a caret in the front matter as its control.
`LinkReviewFlowTests` state the guard in versions, and a new one refuses another
note's editor whatever its count says.

Checked live again on `HN-iPad`, on the final build: typing in the body, `250`
typed into the priority field, then a tap back into the body — the field
committed as it was left, and " AFTER" landed after "DRAFTBODY"; **Add item**
opened a field, "live" typed into it, and a switch to Linking with that field
still being edited: no crash, Linking's properties untouched (its file dated as
it was), and Organising's file held `tags: tour, demo, live`; then typing, a
switch away and back — the file held it, and so did the screen. The app suite
passes (571 tests), the editor package's (440 on macOS, 421 on the iPad
simulator), the iOS interface tests (12 of 13; the window-parity capture is
opt-in and skips), and the app builds.

Found on the way and not fixed here: a note opened straight into Edit shows its
front matter unfolded — the load replaces the empty document the tab was built
with and puts its caret back, 0, inside the front matter; HEAD's reload did the
same (unimplemented.md §6). `EditorDocument.make` and `replaceText` parse the
whole note on the main actor — `make` is `async` and never leaves it — against
the package's own rule that a whole-document pass is made once, off it (§3).
And `willOpen` and `open` still ask the file provider on the main actor
(`FileIO.hasContentAvailable`), as the reconcile did (§3).

### 51.16 While a conflict is open, only Keep Mine writes the note (2026-09-25)

Found by the file-I/O review of §51.12, and in HEAD. `reconcileWithDisk`
raises the banner when the note changed elsewhere while the buffer holds edits,
and keeps their version (`conflictDiskText`) — and then nothing respected it.
`performSave` never looked at `hasConflict`, so the next settle — the end of
editing, a tab switch, the app going to the background — wrote the buffer over
theirs, as if Keep Mine had been chosen. A Reload after that took theirs into
the buffer and called it clean while the file held mine: theirs was never
written back, and the next look at the file loaded mine again, without a word.
The website's manual promised the app "will not silently discard either one";
it did, both ways.

- **A save writes nothing while a conflict is open**, and the buffer stays
  dirty. Nothing new is said: the banner says it.
- **Keep Mine is the one way mine reaches the note.** It carries what is on
  screen first — the typing the live editor holds that the buffer has not yet
  taken — makes theirs the baseline, and writes.
- **A save writes only over the file it last saw**
  (`FileIO.replace(_:at:ifBytesAre:)`, bytes compared inside the write claim).
  It replaced whatever was there, so a change made elsewhere since the last
  look was written over at the next save — and a save already past its
  guards when a conflict was raised put mine over theirs under the banner,
  its bookkeeping marked the buffer clean, and the next look at the file,
  finding our write, ended the conflict and dropped theirs. Now a save that
  finds the file moved writes nothing, stays dirty, and looks at the file,
  which raises the conflict at once.
- **Reload takes theirs; both resolutions wait for a write in flight**
  (`writeInFlight`), so a write's bookkeeping, unconditional after its await,
  cannot land on the baseline a resolution sets. And a choice made is the one
  taken: the banner's buttons wait while one is under way
  (`isResolvingConflict`) — both used to wait on the same write, and whichever
  resumed first won.
- **An open conflict never takes a change silently.** A buffer typed back to
  the last save looks clean, so a newer change arriving under the banner was
  loaded into the buffer while the banner still held the older theirs, and
  Reload then put the older back. It is the same conflict with a newer theirs.
- **Letting go of a buffer that holds a conflict keeps mine beside the note.**
  A flush that may be the buffer's last — the app quitting; iOS leaving the
  foreground, after which the app can be ended without a word; a tab or a note
  window closing, or a main window with all its tabs; an editor opening
  another note — neither writes mine over theirs nor drops it. Mine goes into
  "Title (conflicted copy 2026-09-25).md", the name the cloud mirror already
  gives the copy it keeps, created beside the note by
  `FileIO.createConflictedCopy` — atomically, through a hidden staging file
  renamed into place with `RENAME_EXCL`, so it never writes over a file
  already there ("… 2", "… 3" after it) and a quit cut short leaves no half
  of one. One per conflict, made in its turn on the save's write queue — two
  let-gos at once (iOS drains for resigning active and again for each change
  of scene phase) made two — and re-checked when its turn comes. A later
  let-go brings that copy up to date, unless it no longer holds what was
  written there (someone changed it: it is theirs) or an editor has it open
  (what it holds would be saved over it from the older mine); then mine gets
  a copy of its own. The collection hears of it as of a save (`onSaved`), so
  it is a note in the sidebar at once. The note keeps theirs, and an editor that
  survives the let-go — an iPad app coming back — still shows the banner; the
  copy stays whatever is chosen, a note like any other, the person's to
  delete. A flush that keeps the buffer — a switch of mode, a rename or a move,
  the Mac going to the background, which is not suspension — writes nothing
  anywhere while a conflict is open (`EditorModel.flush(lettingGo:)`;
  `TerminationGuard`'s hooks say which: false for the Mac's scene-phase drain,
  true for quit and for iOS's resign-active). A copy that cannot be written is
  a save failure, on the banner, and nothing drops the buffer then: the tab
  stays open (`EditorTabs.close`), and an editor asked to open another note
  keeps this one (`flush` says whether mine is safe). A rename or a move of a
  note with a conflict open is refused until it is chosen — the tab would
  keep the old path, and Keep Mine would write mine there.

**Why a copy.** Every other answer makes the choice for the person or loses the
text: writing mine to the note is Keep Mine; keeping it in memory loses it at
quit, and whenever iOS ends a backgrounded app; an app-private store would need
a way back to the note that does not exist. A copy beside the note survives
the process, syncs like any note, and leaves both versions where the person
will look.

**The review.** The file-I/O and concurrency reviews of the change as first
written found the save's blind write at the root of three ways it could still
lose a version — the write landing over theirs, the look after it ending the
conflict, a let-go then finding nothing dirty to keep — and more around it,
all fixed above: the newer change taken under an open conflict, the two
copies, a copy landing after its conflict ended and being recorded against the
next, a main window's tabs dropped at close with no let-go, a tab closed by
the index it had before its flush (the wrong tab, or a trap when closed
twice), a failed copy followed by a close or a switch, a copy updated under an
editor showing it, rename and move with a conflict open, and the order of two
choices. Three reached past the editor. In a cloud collection, **every
complete sync deleted every note made on this device and not yet on the
provider** — `RemoteMirror.pruneLocalItems` removed each `.md` the provider's
listing lacked, so new notes and conflicted copies alike — and now removes
only a note the manifest knew. The mirror's own conflicted copy of theirs was
written to the same-day name blind, over any copy already there, the editor's
copy of mine included; it goes through `createConflictedCopy` too. And the
quit handshake's five-second deadline bounded nothing: a task group returns
only once every child has, so ⌘Q waited on a wedged provider as long as it
liked; whichever of the drain and the deadline finishes first now replies.

`ConflictSaveTests`, failing first where the API already existed:
`aSaveWhileAConflictIsOpenWritesNothing` ("a save while the conflict was open
wrote mine over theirs", "mine was marked saved"); `reloadingLeavesTheirsInTheFile`
(the file held mine after Reload, and "the next look at the file put mine
back"); `lettingGoKeepsMineBesideTheNote` ("letting go wrote mine over theirs",
"mine was not kept anywhere"); and the two real callers,
`closingATabWithAConflictKeepsMine` and `openingAnotherNoteKeepsMine`, each of
which wrote mine over theirs. The copy's contract is new API —
`aCopyIsKeptCurrentAndNeverWrittenOverAnEdit`,
`aCopyNeverReplacesAFileAlreadyThere` — and `keepingMineKeepsWhatIsOnScreen`
failed with the carry disarmed ("Keep Mine left out what was on screen").
Controls: `keepingMineIsHowMineLands`, which passed before and after, and
`aFlushThatKeepsTheBufferWritesNothingAnywhere`, the let-go rule's. For the
review's findings, each failing with its fix disarmed and passing with it:
`aSaveNeverWritesOverAChangeItHasNotSeen` ("the save wrote over a change it had
not seen", "the change the save found was not raised"),
`aNewerChangeUnderAnOpenConflictIsNeverTakenSilently`,
`twoLetGosAtOnceKeepOneCopy`, `aCopyOpenInAnEditorIsNotWrittenUnderIt`,
`aTabThatCannotKeepMineStaysOpen`, and in `RemoteMirrorTests`
`aCompleteSyncKeepsANoteMadeHere` (with a note the provider did delete as its
control) and `aConflictedCopyNeverReplacesOneAlreadyThere`.

The write in flight across the raising of a conflict could not be held still
for a test — probed outside the app, a coordinated read asked for after a
waiting coordinated write is queued behind it — and needs none now: whichever
way it falls, the write compares with the file inside its claim. Not tested:
the window's close, the quit deadline and the single choice, which live in
views and the app delegate.

The app suite passes (590 tests, twice), and the app builds for macOS and for
the iPad simulator (TerminationGuard's iOS half is compiled only there).

Found on the way and not fixed here: a note created locally in a cloud
collection is still never uploaded — the mirror's manifest learns of files
only from the provider's listings, so `noteDidSave` takes a new one for a
placeholder and refuses it; a conflicted copy kept in such a collection shares
that, kept on the device and no longer deleted (unimplemented.md §8b). Only
the most recently opened main window's tabs are checked when the folder
changes — `Library.onExternalChange` is one closure, and each window's `.task`
reassigns it — so the others raise their conflicts only when they next save
(unimplemented.md §1).

### 51.17 A save's index work is parsed off the main actor (2026-09-26)

After every write, `Collection.noteDidSave` patched the collection's indexes
on the main actor, each patch a pass over the whole note: its aliases three
times (once to ask whether they had changed, once for the link graph, once for
search), its wiki-links twice, its headings, its tags, and — with a
relatedness index built — its retrieval text. §51.12 took the whole-note
comparisons out of the save and left these in, and the save's budget could
not see them: `savingALargeNoteBarelyTouchesTheMainActor` saves a model no
collection listens to.

Measured first. `MainActorBudgetTests.savingALargeNoteInACollectionBarelyTouchesTheMainActor`
saves a 2 MB note in a 200-note collection whose link graph, search and
relatedness indexes are built, through an editor wired as the shell wires one
(`onSaved` → `noteDidSave`), and counts main-thread CPU until the indexes have
the save and the search aggregates have been rebuilt after it: **158 ms**
before, against a 100 ms budget and 0.3 ms for the save alone; **4.5–4.8 ms**
after (two runs). Its control, `parsingALargeNoteOnTheMainActorIsSeen`, makes the same
parse on the main actor and reads 129–145 ms, so a small number is the save's
and not the instrument's blindness. Both are opt-in like the rest of the file
(`TEST_RUNNER_HN_BUDGET_TESTS=1 ./scripts/run-tests.sh
-only-testing:HelloNotesTests/MainActorBudgetTests`, run alone).

- **Parsed once, off the main actor.** `Collection.SavedNoteIndex` is
  everything the patches need — `CollectionIndexCache.parse` (headings, tags,
  aliases, links) and, only when a relatedness index has been built,
  `RetrievalText.prepare` — made inside `offMain`. The main actor applies it
  through overloads that take the parsed values:
  `LinkGraph.updateNote(url:title:aliases:outgoing:)`,
  `CollectionSearchModel.updateNote(_:headings:tags:aliases:)` and
  `updateRelatedness(url:title:prepared:)`. The ones taking text stay, for
  `adopt(createdAt:)`, which indexes an empty note.
- **Only the newest save of a note is applied.** Synchronous, the patches
  happened in the order they were asked for; off the actor, parses finish in
  whatever order they finish, and an older one landing last put the older
  links and tags back. Each save takes a number from one collection-wide count
  (`saveSerial`), and a parse is applied only if its number is still the
  note's newest (`savesToIndex`). One count, never reset: the first draft
  numbered saves per note and cleared the number once applied, so the next
  save was 1 again — and a parse still running from the earlier 1 passed for
  it, and was applied over it. Found while writing the tests.
- **A note that has left while its save was parsed is not put back.** Deleted,
  moved, or removed by something else and seen by a walk: search inserts an
  entry for a note it does not have, so the note was back in search — and so
  in Open Quickly, whose items are built from search's entries — and the link
  graph resolved its aliases to a file that was not there.
- **The rest is decided when the patch lands, not when the save did.** The
  in-flight rebuild is cancelled then: a rebuild takes each note's record from
  the cache while the file's size and date still match it, a save does not
  change the date the collection holds, so one begun while the note was being
  parsed took its *old* record — and, landing after the patch, put the old
  links back. And whether the aliases changed is asked of the index then, just
  before it is patched; asked after, the answer is always no.
- `savesBeingIndexed` counts the saves still being parsed — what something
  that must see a save in the indexes waits for (the tests do). Nothing else
  changed: the cloud upload gate, `adopt(createdAt:)` for a note missing from
  the list (still synchronous, and O(1)), and the debounced rebuild after an
  alias change.

`SaveIndexingTests`, each failing with its guard disarmed and passing with it:
`anOlderSaveThatLandsLastIsNotApplied` (the note's links came back as the
older save's), `aSaveStillParsingAfterANewerOneLandedIsNeverApplied` (the same,
with the number per note put back), `aNoteThatLeavesWhileItsSaveIsParsedIsNotPutBack`
(its alias resolved to the removed file, and search still held it),
`aRebuildBegunWhileASaveIsParsedDoesNotPutTheOldLinksBack` (with the cancel
moved back to the moment of the save, the old links returned) and
`aChangedAliasReachesTheNotesThatLinkByIt` (with the question asked after the
patch, no backlink ever appeared). `aSaveReachesEveryIndex` is the positive
control: links, aliases, tags, headings and the relatedness index all have the
save. Two of the tests check that they set up what they claim to — that the
save was still being parsed when the note left, or when the third save began —
and say so when it was not.

**The concurrency review found two things the change broke, both in rename.**
A rename rewrites `[[links]]` in the notes the link graph says link to the
renamed one, and the shell flushes every tab just before it renames — so a link
typed a moment earlier was in a save still being parsed, the graph did not know
it, and it was left naming a note that no longer exists. And the flushed save's
patch, landing during the rename's own rebuild, cancelled it, so the renamed
note was never indexed under its new name. Synchronous, the patch had landed
before the rename began. **What reads the indexes to act on the vault now
waits for the saves before it** (`Collection.savesIndexed()`, a continuation
the last landing parse resumes, after its patch): `renameNote`, and
`moveItem`, whose scan and rebuild the same flush can cancel. The review also
found that a note deleted while its save was parsed and made again at the same
path was given the old save — `forget`, `adopt(renamed:)` and
`adopt(createdAt:)` now drop a save still being parsed for the path — and that
every applied save rebuilt the embed provider's name map, titles and paths
that a save does not change: **23 ms of main-thread CPU per save** at 2,000
notes (the budget test now runs at that size: 26.7 ms with it, 3.5 ms
without). It is gone, and so are the two text-taking `updateNote` overloads,
whose last caller indexed an empty note.
`aRenameRewritesALinkSavedJustBeforeIt`, `aRenameIsIndexedWhenASaveIsParsedAcrossIt`
and `aNoteMadeAgainWhileItsOldSaveIsParsedIsNotGivenIt` each failed before and
pass now.

The app suite passes (599 tests in 89 suites), and the app builds for macOS
and for the iPad simulator. On the way,
`duplicateNote`'s `offMain` closure captured a `var` (a warning in Swift 5
mode, an error in 6); it captures a constant.

Found on the way and not fixed here, both in HEAD and reproduced by a probe:
a save does not change the date the collection holds for the note (only an
alias change restats it, so that rows do not jump), so **a later rebuild from
the cache reverts an earlier save** until the next walk — a note saved with a
new link lost it when another note's changed alias rebuilt the indexes; and
**a save's patch cancels whatever rebuild is in flight, and nothing runs it
again** — another note's alias rebuild (a link by the new alias never became
a backlink), a delete's, a walk's (unimplemented.md §1). The review added two
more, not reproduced: a rebuild checks for cancellation once, before it loads
the link graph, and then loads search whatever happens; and a save made while
the relatedness index is being built is not in it (§1, §3; all four are fixed
in §51.22). Also pre-existing,
on the main actor after a save in a cloud collection: the upload's read of the
note and the mirror's manifest, encoded and written whole (§3).

### 51.18 Split mode follows typing at a pause (2026-09-26)

Found by review on 2026-09-24 (unimplemented.md §3). The Markdown pane writes
the buffer on every keystroke — cheap since §51.12 — and everything that
followed the buffer followed it there, on the main actor. In Split mode each
key re-ran a body whose `GFMPreview(markdown:)` initialiser rendered the whole
page with cmark-gfm, and hashed the page twice to decide whether to load it;
restarted a task that walked every line of the note (`PreviewSuperset`, then
`@MainActor` throughout), ran `GitHubMarkdown.prepare`, and drew every Mermaid
diagram again — off the main actor, but uncached, and not stopped by the
task's cancellation. With the inspector open, the Outline analysed the note
and parsed it in full for its headings, in `body`, and the Tags tab collected
its tags there. Measuring found two more readers of the buffer on the typing
path: the shell read the note (`activeEditor?.noteText`) to hand it to the
inspector, inside the `AdaptiveShell` slot, so the shell's body re-ran per
keystroke; and `NoteEditorView` keyed its `LiveBuffer` publish on the
buffer's version, so the note column — and the pane inside it, whose closures
SwiftUI cannot compare — redrew on every key.

**Measured first**, in `MainActorBudgetTests` (opt-in, run alone):
`typingInSplitModeBarelyTouchesTheMainActor` hosts `NoteEditorView` in Split
mode beside `NoteInspector` on the Outline, fed as the shell feeds it, with a
694 KB note of prose, headings, lists, a table, code, two diagrams and some
maths, and types 20 characters into the real source text view, 80 ms apart.
**Before: at least 700 ms of main-thread CPU per keystroke.** At least,
because the harness then counted only the redraws: inside a `@MainActor`
test a turn of the run loop runs no main-actor task — no `.task`, no timer,
no hop back from `offMain` (probed: a task created before a second's turn had
not started when it ended) — and an `await` runs tasks but no run loop, so
SwiftUI does not redraw. The harness now turns the run loop and awaits in
small steps, and takes off its own cost (73 ms of CPU per idle two seconds),
measured on the same schedule with nothing typed. **After: 1.6 ms per
keystroke**, where typing into Markdown mode alone costs 2.5 ms; Preview is
handed no page while typing and one when it pauses, and catching up costs
24 ms. The control, `typingIntoAPaneThatRendersEveryKeyIsSeen` — a pane whose
body renders the page per key, as Preview's did — costs 22 ms a keystroke and
is handed 20 pages, so the harness sees a redraw and the count sees a page.
With the settle disarmed, the test fails at 10.8 ms a keystroke against the
Markdown pane's 3.2.

- **One settle, in the model.** `EditorModel.settledText` is the text as of
  the last pause in typing, with its version (`NoteText`, compared by
  version). The Markdown pane writes through `typed(_:)`, which settles
  `settleDelay` (300 ms) after the typing stops; anything else — a load, an
  app write, the live editor's text carried in — settles at once, and so does
  a flush, editing having stopped. Preview, the inspector, the Outline popover
  and `LiveBuffer` follow it; the live editor in Edit mode still follows the
  buffer, whose document it holds.
- **Preview is built off the main actor** (`NotePreview`). Keyed on the
  settled version, the page's style (`GFMPreview.PageStyle`: the theme's size,
  the accent its links take, the palette for light or dark), and what embeds
  resolve to. The superset pass runs off the main actor (`@concurrent`) and
  hops back only for what must be drawn there — a formula, whose renderer lays
  out a view, and an embed's card, which the provider draws — each once:
  diagrams and formulas are kept by source as the tags they became
  (`PreviewSuperset.rendered`, 16 MB, oldest first), and a card's tag by the
  image the provider hands back. A cancelled pass stops at the next line.
  Then the note → GFM step and cmark-gfm, in `offMain`
  (`GFMPreview.page(_:style:)`).
- **The web view is told which page it is handed** (`pageID`): a redraw
  hands the same page over again and is told by its number, where it hashed
  the whole page — twice — to find out. A page without one is hashed once.
- **The shell does not read the buffer.** `NoteInspector` takes the editor and
  reads its settled text itself, so a pause redraws the panel and nothing
  else; the Outline's analysis and the Tags tab's collection run in tasks
  keyed on the version, off the main actor, and keep their last answer while
  the next is made.

Edit ≡ Preview: the page built from a style is byte-for-byte the page the
preview built before (`aPageBuiltFromItsStyleIsThePageThePreviewShows`), and
`render-parity.sh` passes — 58 of 58 documents at 1200, 800 and 560pt, the two
known at 420, chrome parity ok.

`SettledTextTests` (a keystroke waits for the pause, typing that goes on does
not settle, anything else settles at once, a flush settles);
`PreviewSupersetTests`' `aDrawnDiagramIsKept`, `aKeptDiagramIsNotDrawnAgain`,
`aKeptFormulaIsNotDrawnAgain` and `aCancelledPassDrawsNothing`; and in the
package `GFMPreviewPageTests` (the page built from a style, a style that
changes with what it draws, a page loaded once per number) — each failing
with its guard disarmed and passing with it. Seen on the HN-iPad simulator in
Split mode: typed into the source, the preview's heading and the outline
caught up once the typing stopped — and, deleting in two bursts, both showed
the text of the pause between them while the source was already past it.

The app suite passes (609 tests in 90 suites), the editor package on macOS
(247/24, 178/14, 18/4) and on the iPad simulator (228/22, 178/14, 18/4), the
iOS interface tests (13, the opt-in window-parity capture skipped), and the app
builds for both.

Found on the way and not fixed here: a new page starts at the top, so a
preview scrolled down to a diagram went back to the note's first line when
typing paused — seen on the simulator. It went back at every keystroke before
this; keeping the scroll position across a load is unimplemented.md §4.

**The concurrency review found three things, and a regression.** A
transclusion card was still PNG-encoded on the main actor — kept there on the
belief that a platform image is not `Sendable`, which it is (the review
type-checked one in a `Sendable` struct against both SDKs); a standalone probe
put a card 400pt tall at 30–46 ms and one 8,000pt tall at 680 ms, and a note
with more than 32 embeds emptied the card cache mid-pass, so every pause
encoded every card again. Cards and formulas are encoded off the main actor
now, and kept in the one cache. That cache evicted the oldest *stored* first,
and a pass visits a note's constructs in document order, so a note whose
images outgrew the budget evicted each before the next pass reached it and
every pass drew everything again; it is evicted by pass now — entries the
oldest passes used go first, never one the storing pass has used — and counts
its keys (a key carries the whole diagram it names). The Suggest Tags command,
which switches to the Tags tab in the same update, found nothing collected and
parsed the note on the main actor; and the Suggest button handed the model
whatever the tab showed — after a switch of tab, the last note's tags. Both
resolve the tags in the task that asks, for this version, off the main actor.
The regression was mine: the pane stayed empty until the whole page was built
— every diagram not drawn yet, every embed's read — where the old initialiser
had drawn a plain page at once; and after a switch of tab it showed the last
note's page for as long. With nothing of the note's on screen, the page
without the superset comes first now, and the whole page after it, not loaded
again when the two are the same. `RenderedTagsTests` — a pass that outgrows
the budget finds everything next time, room is made from the oldest passes,
keys count, a card is kept for the image it was drawn from — each fails with
its part disarmed.

The harness took its baseline while the first page was still being built
(the card is drawn on the main actor the first time), which subtracted that
from the typing and put the net at nothing. It waits for the window to go
quiet now, and says so if the baseline was not idle; the note carries a
transclusion, as the review asked; and the run loop is turned from a
synchronous helper, since running it from an `async` context is an error in
Swift 6. **Measured again: 1.5 ms of main-thread CPU a keystroke in Split mode
with the Outline open**, where the Markdown pane alone costs 2.6 ms; 32 ms
catching up at the pause, with one page handed over. The app suite passes (623
tests in 92 suites) and the app builds for macOS and the iPad simulator.

Deliberately not done: typing that never pauses — a held key, dictation —
defers Preview and the inspector until it does; a settle is a pause.

### 51.19 A note window's editor is wired as a tab's (2026-09-26)

Found 2026-09-25 while fixing cloud-cache eviction (§51.14). `NoteWindowView`
made a bare `EditorModel` and opened its note itself, where a tab's editor came
from `EditorTabs.editor(for:)`: told where a save goes (`onSaved` →
`Collection.noteDidSave`), when a note has arrived (`onBecameAvailable`), when
a write must be refused (`saveBlockedReason`) and what is a stand-in
(`isPlaceholder`), and given a cloud note's bytes before it was read
(`prepareToOpen` → `Collection.hydrateIfNeeded`). A note window got none of
it. A cloud note still a placeholder in its collection's cache opened empty
there, and what was typed was written over the placeholder, never uploaded,
and replaced at the next download; its saves were never registered as the
app's own writes — so the watcher reported them to the tabs as changes made
elsewhere — never indexed and never uploaded; and a save into a collection
whose folder had gone was not refused.

- **One wiring, for both** (`EditorWiring`). `wire(_:)` sets an editor's hooks
  from a lookup of its note's collection — `init(library:)` in the app, a
  closure in a test — and `open(_:in:shown:)` opens a note as every editor
  opens one: its identity first (`willOpen`, so a banner can say it is
  downloading), then `shown`, where a tab puts itself on screen, then the note.
  `EditorTabs` holds one (`wiring`, asked when used, so a tab opened before
  the shell sets it is wired the moment it does) in place of its five closures,
  and `ContentView.wireTabs` sets it. `NoteWindowView` loads its note through
  `NoteWindowView.load(_:into:wiring:)`, which wires and opens exactly as a tab
  does — and shows the note, with its banner, while it downloads, where it
  showed "Note Unavailable" until the load was done.
- **Fetching is part of opening** (`EditorModel.prepareToOpen`, awaited inside
  `open` before the file is read), so every open fetches: the first, and the
  banner's Try Again, which read the file again without fetching anything.
- **A placeholder is not the note.** Found while wiring: when the fetch fails —
  the provider cannot be reached — `open` read the placeholder as an empty
  note, in a tab and a note window alike, and what was typed into it was
  written over the placeholder, refused by the upload (which does not upload a
  note it has not downloaded), and written over in turn by the next download.
  `open` now asks the collection (`isPlaceholder`) and leaves such a note
  unloaded: the buffer takes no write, the banner says it could not be
  downloaded, and Try Again fetches. The note's cloud badge comes off only when
  it has arrived — the empty file standing in for it answered as present, and
  `onBecameAvailable` took the badge off a note still in the cloud.

`NoteWindowWiringTests` shows each gap through the window's own path
(`NoteWindowView.load`) beside the same case through a tab wired as the shell
wires one — the controls, which passed before and pass now:
`aCloudNoteOpensInANoteWindowWithItsText`, `aSaveInANoteWindowReachesItsCollection`
(on the provider, and in the link graph), `aNoteWindowDoesNotWriteIntoAFolderThatHasGone`
and `aNoteWindowAsksItsCollectionAboutItsNotes` (a stand-in, and the badge) each
failed before; and `aCloudNoteThatCannotBeFetchedIsNotOpenedEmpty` failed
before in a note window and in a tab alike (the note opened empty, the typing
reached the placeholder, Try Again read it without fetching, the badge came
off). Disarmed one part at a time: without the wiring, the refusal, the
questions and the upload fail; without the fetch before the read, the text;
without the placeholder check, the failed fetch. `OpenTabEvictionTests` wires
its tabs with the shell's wiring now — it had copied two of the closures by
hand — and opens its note window through the window's path.

Not fixed here: nothing reconciles a note window's editor when its file
changes elsewhere — it is in no window's tabs, and `Library.onExternalChange`
is one closure (unimplemented.md §1, with the other main windows' tabs).

The app suite passes (619 tests in 91 suites, on a second run: the first had
`AgentToolTests.anApprovedEditIsNotMadeOverTextSavedWhileItWaited` give up
after 5 s waiting for its approval card, and it passed alone three times — it
waits 30 s now, and a card that never comes fails all the same), and the app
builds for macOS and the iPad simulator.

### 51.20 A note opens with its front matter folded (2026-09-26)

Seen on the `HN-iPad` simulator on 25 September: a note opened straight into
Edit showed its front matter unfolded — `---`, `title:`, `tags:` in monospace
between the inline title and the first heading (Linking and Intelligence in
DefaultCollection) — where the same note switched to Edit from Preview kept it
folded. Front matter is source the reader never sees, folded until a caret goes
into it (`EditorDocument.frontMatterRange`).

**Why.** `EditorHost.settleWithBuffer` keeps the caret across a replacement of
the document's text: it read `document.selectedRange` before the replace and
put it back afterwards through the proxy. And `selectedRange` reads `{0, 0}` for
a document nobody has put a caret in. A new tab's document is built before
`open` has loaded its note — the tab is on screen first, so it can say the note
is downloading — so when the note arrived, the host put back a caret that had
never been there: at 0, in the front matter it had just loaded, and the
document, told a caret had arrived, opened it. Confirmed with a probe on
`HN-iPad` (the host's build, the settle, `replaceText`, and every selection the
view and the document were told of, through `EditorProbe`; removed since). By
then the placeholder path no longer showed the symptom as reported:
`DocumentLoad.caret` (§51.15, added an hour after the sighting) moves a caret at
or past the old body's start along with the body, and an empty document's body
starts at 0 — so the made-up caret landed at the body's start instead, on the
blank line under the front matter, which opened: a line's gap (26pt at the
default size) between the title and the first heading that the same note from
Preview does not have. And every other replacement of a document nobody had
clicked into still unfolded it, because there the old text had front matter and
0 is inside it: a tag accepted, a property changed in the panel, the note
reloaded after a change made elsewhere.

- **A caret nobody placed is not a caret at 0** (`EditorDocument.caret`). It is
  `nil` until a selection is reported (`selectionDidChange` — the view's, or a
  command's that places one), and `nil` again once the text is replaced
  wholesale, which takes the caret with the text it was in.
- **The settle puts back only a caret the document had.**
  `DocumentLoad.settleWithBuffer` returns the replacement and where its caret
  goes, asked before the replace; the host resets undo and puts back the caret
  it names, if it names one. A caret someone placed is kept as it was: in the
  body it moves with the body (§51.15); in the front matter it stays, and the
  front matter stays open around it. One host serves both platforms, so the Mac
  has the fix too.
- `EditorDocument.isFrontMatterFolded` says whether the front matter is drawn
  folded — read from the font on the first line inside the fences, where the
  package's own fold test looks — so a host, or a test, can ask what a note
  opened looking like.

`FrontMatterStaysFoldedTests` builds each document as the host builds one,
settles it as the host settles it, and puts back the caret as the proxy does.
Run first against the old behaviour (the new API in place, `caret` answering
`selectedRange`): `aNoteOpenedStraightIntoEditOpensAsItDoesFromPreview` failed
("a caret was put at {65, 0} in a note nobody had clicked into"), and
`anAppWriteLeavesAnUntouchedNoteFolded` and `aReloadLeavesAnUntouchedNoteFolded`
failed with the front matter unfolded — the reported symptom, reproduced without
a simulator. The controls passed before and pass now:
`anAppWriteKeepsACaretInTheBody` (the negative control — an app write keeps a
caret that is in the body, moved with it), `aCaretInTheFrontMatterKeepsItOpen`
and `aCaretPutInWhileTheNoteLoadedGoesToTheBody`. In the package,
`UnplacedCaretTests` holds the document to it — no caret when built or
replaced, one when told of a selection, at 0 as much as anywhere, and a caret at
0 opens the front matter (the control for `isFrontMatterFolded`) — and asks each
platform's text view whether it invents one: a note loading under it, and on the
Mac the one view re-bound to the next tab's note, report no caret, while a click
or a tap is reported (the control). Those failed first only because the old
answer always had a caret; they are the check that neither UIKit nor AppKit's
own `setSelectedRanges` fix-ups, which `MarkdownTextView` reports to its
document, make one up.

Live on `HN-iPad`, portrait, with the simulator's preferences naming
DefaultCollection alone and no cloud cache: Syncing switched from Preview to
Edit as the baseline; Linking and Intelligence opened straight into Edit —
folded, each first heading exactly where Syncing's is (a line lower before the
fix); a property added to Intelligence in the panel and removed again, without
a tap in the note — folded throughout; and a tap at the top of the text, which
put the caret in the front matter, opened it. Nothing had been saved to the
note; the file was checked against a copy taken first.

Not fixed here, and fixed since in §51.26: adding or removing a property
re-rendered the whole block in the panel's style (`FrontMatter.splicing`), so
keys nobody touched changed shape — `tags: [tour]` became a block list when
`status` was added. §51.15 stopped the rewrite only when nothing changed; a
change now rewrites its own key's lines and no others.

The app suite passes (629 tests in 93 suites); the editor package passes on macOS
(249 in 25, 178 in 14, 18 in 4) and on the iPad simulator (230 in 23, 178 in 14,
18 in 4); the app builds for macOS and the iPad simulator.

### 51.21 What changes in a cloud collection reaches the provider (2026-09-27)

Found by reading the code on 25 September, and reproduced before anything was
changed: a note made in a cloud collection — one opened through a provider's own
API (Dropbox, Box, Google Drive, OneDrive) and mirrored into a cache
(`RemoteMirror`) — was never uploaded. `RemoteMirror.upload` updated only a
record its manifest already had, the manifest learns of files from the
provider's listings alone, and the save gate asked `isHydrated`, which is false
for a path the manifest has never seen: every save of a new note was refused,
with the message meant for a placeholder — "hasn't been downloaded … yet, so it
wasn't uploaded. Open it first."

Reproducing it found the rest of the same shape. The provider had no call to
move a file or to make a folder. A rename or a move changed the mirror alone:
the provider kept the old name, the manifest kept its record under it — a note
not yet downloaded came back under the old name at the next full sync, and one
downloaded stayed recorded as a download no longer there — and every save under
the new name was refused like a new note's. A copy of a note not yet downloaded
was a copy of its empty placeholder. A folder made here existed here alone, and
a note put in it could not follow on Box or Google Drive, which file a note only
into a folder they already have. A deleted note left its record behind, still
"downloaded", so trimming the cache wrote an empty file back at its name. Links
a rename rewrites, the copy of mine an editor keeps beside a note (§51.16) and a
picture pasted into a note were written to this device's copy alone. And quick
capture into a note not yet downloaded appended to its placeholder: the note
became the appended line, and the next download put the note back over it.

- **Move and make a folder, on every provider** (`RemoteStore.move(from:to:)`,
  `createFolder(path:)`). Dropbox: `files/move_v2` and `files/create_folder_v2`,
  never `autorename`. Box: a `PUT` of the item's name and its parent's id, and
  `POST /folders`. Google Drive: a metadata `PATCH` that trades parents
  (`addParents`/`removeParents`), and a file of the folder type. OneDrive: a
  `PATCH` of the name and the parent's id — an item reference's path is
  read-only in Graph, so the destination folder's id is asked for first — and a
  child `POST` with a `folder` facet that fails on a clash. A move keeps the
  item's identity on the provider — its history, its sharing — which an upload
  under the new name and a delete of the old would not. Box and Drive move their
  cached ids with it.
- **The gate asks whether the file is a placeholder** (`isPlaceholder`), not
  whether the manifest says it was downloaded — which a note made here never
  was. `isHydrated(localURL:)` now means "anything but a placeholder", which
  also stops the app offering to download a note made here and counting it
  among those a search cannot see. The mirror refuses a placeholder too, as the
  last line of defence.
- **A first upload** makes the folders above the file that the provider lacks,
  checks the name — another device may have put a file there since the cache
  last looked: the same bytes are this upload's own, whose answer was lost on
  the way back, and are recorded; anything else is kept beside mine as a
  conflicted copy, here and on the provider, and reported ("was also made on
  …") — then records the file, so it is an ordinary note from then on. The
  conflicted copy the mirror keeps of *theirs* in any conflict goes up too: on
  this device alone, theirs was lost everywhere else once mine took the name.
- **Changes take turns, in the order they were made** (`sendSave`, `sendMove`,
  `sendDelete`, `sendFolder`, and `changesSent()` to wait for them). New Note,
  its title typed — a rename — and its first words saved arrive as one note
  under its name, never two; two saves of one note no longer race each other's
  revision check. A save sends the bytes it wrote, so a rename whose turn comes
  after the upload's cannot take them from under it. Syncs take their turns
  among the changes (`syncMetadata`, `refresh`), because they read the record
  the changes write.
- **A walk applies what it found to the record as it stands when it ends**, and
  **leaves alone what a change made here is waiting to take away** (`walk`). It
  wrote back the record it began with, so a note downloaded while a walk was
  under way — a large account's walk takes a while, and the collection is open
  throughout — went back to "placeholder": its saves were refused from then on,
  and its next open downloaded it again over whatever was typed. And a note
  renamed here while a walk listed its folder came back as a placeholder under
  the old name. A walk now removes only records the provider stopped having —
  unchanged here since it began, and no change waiting on them — and only their
  files, where the old prune took every unlisted `.md` the manifest had known of;
  and a record of a download whose file has gone becomes a placeholder again
  rather than hiding the note. The delta refresh reads the record after its
  request, and deletes a local file only where the provider had one.
- **Until a move has its turn**, the manifest — the provider's record — still
  has the note under its old path, and a question about it at its new one (is it
  a placeholder; download it; is it in the cache's placeholder list) is asked of
  the old (`recordedPath`). Eviction leaves such a note alone.
- **What was made here and never sent goes up at the next refresh**
  (`sendUnsent`, after `Collection.refreshFromProvider`): a note made while the
  provider could not be reached, an upload that failed. Only once a walk has
  listed the whole folder (`RemoteManifest.lastCompleteSync` — optional, so a
  manifest written before it still decodes): before that, a file here with no
  record may be one the provider has and the walk has not reached.
- **The collection reports every change it makes in the cache**: `createNote`
  (uploaded as it is made, empty), `duplicateNote` (a placeholder downloaded
  first, or no copy), a daily note (`note(atRelativePath:creatingWith:)`), a
  pasted picture (`EditorModel.onFileMade`, wired by `EditorWiring`),
  `createFolder`, `renameNote`, `moveItem`, `deleteNote` and `deleteFolder`;
  `append` downloads a placeholder before appending, or appends nothing. The
  notes a rename's link rewrite writes are taken as saves (`noteDidSave`) —
  indexed with their new links, uploaded — and the open editors are told, as
  CLAUDE.md asks of every write made outside an editor: a tab showing one would
  have saved its old text back over the new link.
- The eager `syncDown`, which nothing in the app calls, records what it
  downloads, so an upload after it is an ordinary one.

`CloudCollectionChangesTests` drives the collection as the app does, against a
provider as strict about folders as Box and Google Drive, which issues a revision
per write and can be unreachable or hold a listing part-way through a walk. Run
against the old code, 21 of its then 24 cases failed — among them
`aNoteMadeHereReachesTheProviderWhenItIsSaved` (refused, and the wrong message),
`aNewNoteNamedAtOnceArrivesUnderItsName`, `aCopyOfANoteNotYetDownloadedCarriesItsText`,
`aNoteMadeInAFolderMadeHereReachesTheProvider`, `aDeletedNoteLeavesNothingBehind`,
`appendingToANoteNotYetDownloadedKeepsItsText`,
`aNoteDownloadedWhileASyncWalksStaysDownloaded` and the rename cases; the two
controls passed, and pass now — `aNoteDownloadedFromTheProviderStillUploads`, and
`aPlaceholderIsStillNeverUploaded`, the "never upload a file we never downloaded"
guard. One passed that should not have: after a *downloaded* note's rename a sync
did not bring the old name back — because the manifest went on claiming the
download, a hidden note of its own — so it now checks the record, and a note not
yet downloaded as well. Three cases changed shape once syncs took turns: a walk
paused mid-way now releases before the test waits for the changes, and the
rename-while-walking case holds the root's listing, so the walk lists the old
name after the rename was made here and before the provider has it. Disarmed one
at a time, each mechanism fails its own case: without the walk leaving waiting
changes alone the old name comes back as a placeholder; without the merge a note
downloaded mid-walk becomes a placeholder again; without the rewrite taken as a
save the provider keeps the old link. `ProviderMoveAndFolderTests` pins the new
requests for all four providers, as this codebase pins every provider call it
cannot run against a live account; the store fakes in the other suites gained the
two calls.

What a failure leaves: a move the provider refuses (a name taken there, the
provider out of reach) is reported and leaves the note moved here; its old name
stays on the provider, and the new one goes up with the next save or refresh, so
the provider holds both until one is deleted — nothing is lost. A folder whose
making fails is made on the way when a note is saved into it.

**Review round.** A file-I/O review found no read or write of note content
outside `FileIO`, and three ways to lose it around placeholders; a concurrency
review found five kinds of main-actor work and four more defects. Each defect was
reproduced by a test that failed first, then fixed:

- **A download landing during a rename emptied the note.** An open begun under
  the old name, whose bytes arrived while the rename's turn was out asking the
  provider, wrote them under the name the note had left and recorded the
  download; the record, moved with the rename, then called the empty placeholder
  at the new name the note — it opened empty, and its first save put that over
  the provider's copy. A download is now written only where the note is now, over
  its stand-in, with no move or delete made here taking it elsewhere
  (`aDownloadLandingDuringARenameNeverEmptiesTheNote`).
- **What the provider never received is marked, and nothing replaces it**
  (`RemoteManifest.Entry.unsent`, optional so an older record decodes). A save
  marks its record at once; an upload that lands clears it. Trimming the cache
  emptied mine kept after a conflict, and an edit whose upload failed — gone
  everywhere (`trimmingTheCacheNeverEmptiesWhatWasNotSent`). A walk that saw the
  provider's copy change made such a note a placeholder again — the edit refused
  from then on, then downloaded over (`anEditWhoseUploadFailedSurvivesTheNextSync`,
  and `aNoteSavedWhileASyncWalksAndChangedElsewhereKeepsBoth` for a save made
  mid-walk); the upload's own check keeps both. A record the provider stopped
  having keeps its file when unsent, and the file goes up again as made here. The
  catch-up resends every unsent record, not only files without one.
- **A file here with content and no record is left for its upload.** A note made
  offline under a name another device used meanwhile was recorded by the next
  refresh as the provider's placeholder — refused, skipped by the catch-up, and
  downloaded over, keeping no copy of mine. Its upload now meets theirs and keeps
  both (`aNoteMadeOfflineUnderANameMadeElsewhereKeepsBoth`).
- **A move is reported before the file moves** (`willMove`, then `sendMove` or
  `cancel`): a walk that listed the old name in the moment between put an empty
  placeholder back there, which the catch-up would have uploaded as a new note.
- **A rename the provider refuses keeps the note.** The file has moved here, and
  the record follows it still naming where the provider has it — so it stays the
  note, a placeholder opening from there, where it had become a new, empty note
  under the new name; a later save or refresh asks for the move again
  (`reconcileName`); and a walk or a delta never takes the other item at that
  name for this one, or its deletion for this one's
  (`aRenameTheProviderRefusesKeepsTheNote`).
- **One mirror per cache** (`RemoteMirror.open`): adding a cloud folder already
  open made a second, and the two wrote over each other's manifest
  (`aCacheHasOneMirror`; `Library` is not driven by a test because it saves the
  collection list into the test host's — the person's — preferences).
- **A collection from before sends what was made offline**: its manifest has a
  delta cursor, taken only at the end of a complete walk, and no record of that
  walk, so the catch-up never ran for it (`aCollectionFromBeforeSendsWhatWasMadeOffline`).

The main actor:

- **The manifest is written elsewhere** (`ManifestWriter`, one per cache, newest
  record first; a load waits for writes on their way). It was encoded and written
  whole at every change — 22 ms at 10,000 entries — and this change had made
  every upload, move, folder and delete one
  (`recordingAChangeDoesNotWriteTheManifestOnTheMainActor`: under 3 ms, and on disk).
- **Listings parse their dates with `Date.ISO8601FormatStyle`** (`RemoteDate`):
  `ISO8601DateFormatter` was 126 ms of a 2,000-entry Dropbox page, and the
  plain formatter returned nil for a date with fractional seconds
  (`providerDatesAreReadInEveryShape`; 3 ms for the same 2,000 dates, measured).
- **The waiting changes are worked out once per change** (`waitingSources`), not
  followed back for every file a walk lists — 152 ms a 2,000-file batch with 50
  moves waiting.
- **A walk deletes the files of dropped records away from the main actor**, and
  never one changed since the walk began.
- **A rename's rewritten notes are saved as a batch** (`notesDidSave`), the notes
  looked up once rather than searched for per note.
- Daily notes (`note(atRelativePath:creatingWith:)`) are created off the main
  actor, as `createNote` is: the collection may be an iCloud folder.

Disarmed one at a time, each of these fails its own test; the walk's rule for an
unsent record first passed disarmed — the record changed after the walk began,
and a record changed since then already wins — which is what
`anEditWhoseUploadFailedSurvivesTheNextSync` was written to cover.

Not fixed here, and recorded in unimplemented.md: listings from Box, Google Drive
and OneDrive carry no revision, so the conflict check on a note the provider has
works on Dropbox alone (a clash with a note *made* elsewhere is found by name on
all four); the new calls have not been run against live accounts; a rename does
not rewrite links in notes not yet downloaded, whose links the index cannot know;
a save's index patch cancels a full rebuild in flight without restarting it,
found while testing the link rewrite (fixed in §51.22); the listings themselves are still parsed on
the main actor, and a pasted picture is still written there.

The app suite passes (673 tests in 95 suites), and the app builds for macOS and
the iPad simulator.

### 51.22 A save and a rebuild of the indexes no longer undo each other (2026-09-28)

Two defects §51.17 found and left (unimplemented.md §1), each reproduced first
by a test:

- **A rebuild from the index cache reverted every save before it.**
  `refreshDerived` takes each note's record from `CollectionIndexCache` while
  the record matches the note's size and date *as `notes` holds them* — and a
  save leaves those alone, because restating the note re-sorts the list and
  bumps `revision`, the sidebar's rebuild (only an alias change restated it).
  So until the next walk, any rebuild put a saved note's pre-save links, tags
  and aliases back: a note saved with `[[New]]` linked to `Old` again when
  another note's changed alias rebuilt the indexes 800 ms later.
- **A save's patch cancelled the rebuild in flight, and nothing ran it again.**
  The cancel was the guard against the first defect, for a rebuild that had
  read the note before the save — and it threw away whatever that rebuild was
  for: an alias change's (a link by the new alias never became a backlink), a
  delete's (`forget` rebuilds to drop the note, which went on answering to its
  alias), a walk's (what it found never reached the indexes).

**What a save patches is kept until a rebuild has read the note from disk
since** (`Collection.KeptSave`: the headings, tags, aliases and links — not the
retrieval text). A rebuild reads the notes a save has patched, and the ones
whose save is still being parsed, from disk rather than from the cache: their
files are written already, since a save is written before it is indexed, and
numbered (`saveSerial`) before the rebuild takes its snapshot. When it lands,
on the main actor, what it read that way lets the kept record go — it is the
save, or something newer made elsewhere, which must win — and every kept
record it did not read is applied over what it did (`withKeptSaves`), so a
save during the rebuild is part of it. A save that lands while `search.load`
is being computed was patched into the index `load` then replaces, so it is
patched in again after it (`patchesLanded`); the link graph, loaded before the
wait, has it. Nothing cancels a rebuild now but a newer one (`deriveTask`); the
alias change's delayed rebuild has its own handle (`aliasRebuild`), which a
rebuild begun later makes unnecessary. `restat` is gone — the alias rebuild
reads the note from disk like any other — so a changed alias no longer jumps
the note to the top of the list, and `SavedNoteIndex.byteCount`, which only it
read, went with it. The rebuild's reads are in `offMain` now — which runs at
its caller's priority, so the rebuild's task asks for the `.userInitiated` the
`Task.detached` it replaces ran at.

The direction was to keep the record *until a walk that began after the save
had re-read the note*. A walk changes the size and date `notes` holds, and the
rebuild after it misses the cache and reads the note — but a rebuild whose
snapshot came before the walk and lands after it would lose the save if the
record went when the walk landed, so the letting-go had to be tied to a
rebuild anyway. Tied to the rebuild's own read, it needs no account of walks
(which overlap, resume from a checkpoint, or merge a subtree), and an edit made
elsewhere after the save wins at the next rebuild rather than after the next
walk. It costs one read per note saved since a rebuild last landed. And the
cache stays coherent: it is keyed on the size and date `notes` holds, so after
that read it holds the saved record under exactly the key every later rebuild
looks it up by — until a walk changes the key and the note is read again.

Found on the way, and fixed with it:

- **A note made while a rebuild ran was dropped by it.** `adopt(createdAt:)`
  patches the indexes as a save does, and a rebuild begun before the note
  existed landed without it: `[[Fresh]]` did not resolve and it was not offered
  as a link until something rebuilt again. It is kept like a save, and put
  first among the rebuild's records, where the newest note stands in `notes` —
  a link resolves to the first note of its name.
- **The search index's deferred fold undid a rebuild.** A patch folds the
  aggregates — tags, tag tree, link targets, Open Quickly — 250 ms later, from
  the entries it saw; a rebuild landing in between replaced the entries, and
  the fold then put the older picture's tags back over them. Replacing the
  entries cancels a waiting fold (`CollectionSearchModel.apply`); a patch made
  while the rebuild computed is the caller's to make again, which
  `refreshDerived` does.
- **A rebuild replaced by a newer one no longer loads search after it** (the
  two computations finish in either order): `load` and `refreshDerived` check
  for cancellation after the wait, as §51.17's review asked.
- **A save made while the relatedness index was being built never reached
  it.** Until the build lands there is no index, so a save prepared no
  retrieval text and changed nothing, and a note the build had already read
  stayed as it was read until the index was dropped — a delete likewise. Saves
  and deletes made during the build are kept (`relatednessPending`) and applied
  before the index is published, and the build publishes it itself: published
  by the caller, which resumes later, a save landing in between would have been
  kept for an index that had stopped taking them. A build dropped while it ran
  (`invalidateRelatedness`, the Rescan command) neither takes the next build's
  changes nor becomes the index (`relatednessGeneration`); before, it was
  published anyway.
- `moveItem` no longer waits for the saves before it: it waited because a
  save's patch cancelled the move's rebuild. `renameNote` still does — its
  link rewrite reads the graph.

`SaveIndexingTests`, each with a control, and each failing before its fix in
the iteration that is not the control:
`aRebuildAfterASaveKeepsWhatWasSaved` (the first probe: `A` linked to `Old`
again; the control walks first, which reads the new size and date, and kept
the save before the fix too), `aSaveDoesNotCancelTheRebuildAnAliasChangeAskedFor`
(the second: no backlink, where the control has one),
`aSaveDoesNotCancelTheRebuildADeleteAskedFor` (the deleted note still resolved
by its alias and was in search), `aSaveDoesNotCancelTheRebuildAfterAWalk` (a
link the walk found never reached the graph),
`aNoteMadeWhileARebuildRunsStaysInTheIndexes` (failing with the saves kept and
the create not), `aRebuildIsNotUndoneByTheFoldASaveLeftWaiting` (with the
fold's cancel taken out, the tags were the older picture's; since the review
below the fold also takes its snapshot late, either guard alone holds it, and
the test fails only with both out), and
`aSaveMadeWhileRelatednessIsBuiltReachesIt`. The slow rebuilds are made the
way §51.17's are — two hundred notes changed on disk, so a rebuild re-reads
them all — and the tests that need one in flight say so when it was not.

**The suite is serialized now** (`@Suite(.serialized)`, as `GitServiceTests`
is, for the same reason: contention, not a deadlock). What it tests is the
order in which work lands, and the new tests make rebuilds slow on purpose —
side by side, one test's rebuild was another's main-actor contention, and under
the full suite `aNoteThatLeavesWhileItsSaveIsParsedIsNotPutBack`'s check that
its save was still being parsed when the rebuild landed failed twice while
passing alone: the scan and rebuild it waits for are main-actor work, the
parse is not. Serialized, the suite takes about 19 s alone.

Budgets, run alone: a 2 MB save in a collection is 4.6 ms of main-thread CPU,
as before (§51.17). A forced rebuild of 2,000 notes read 51 ms here, and
51–53 ms with the old `refreshDerived` put back and measured the same way,
back to back — that probe is noisy (its idle control read 6–38 ms in the same
runs) and earlier sessions logged 10–63 ms.

**The concurrency review found three things in the change**, all fixed:

- **A rebuild replaced by a newer one still wrote the index cache, and could
  write it last.** A rebuild cannot be stopped once it is reading, and its
  write came after it had finished. If the older one had taken a saved note's
  pre-save record from the cache while the newer one read the save from disk
  and let the kept record go, the older write, landing last, made the pre-save
  record the cache's answer for the note until a walk changed its date. Each
  rebuild is numbered as it begins (`CollectionIndexCache.rebuildNumber()`, one
  count for the process, so a collection opened again goes on counting), and a
  cache is never written by a rebuild older than the last one that wrote it —
  checked and written under one lock. A rebuild that knows it has been replaced
  does not write at all. `anOlderRebuildNeverWritesTheCacheOverANewerOne`
  fails with the check taken out (the older records stood); an unnumbered write,
  which a test uses to seed a cache, always lands.
- **The saves re-applied after search was loaded were a pass over the
  collection each** — and the search index's own patch was too, on every save:
  `updateNote` found the note's entry with a linear search, and every patch in
  a burst copied the whole entry array, because the fold the patch before had
  scheduled held a snapshot of it through its 250 ms wait. A rename's rewrite
  saves one note per backlink, so a burst is ordinary. Measured by a new budget
  test, `patchingSearchInABurstBarelyTouchesTheMainActor` — every note of a
  2,000-note index patched, as for a note every other note links to: **415 ms**
  of main-thread CPU before, **9–13 ms** after, and 187 ms and 269 ms with
  either of the two changes alone, both over the 100 ms budget. The fold takes
  its snapshot when it runs, and the index keeps each note's position
  (`positionByURL`, computed off the main actor with the rest of a rebuild), so
  a patch is O(1). The saves re-applied after a load go through
  `updateNotes`, folded once, with the collection's notes looked up in one
  map.
- A note the rebuild did not see was given its relative path — a symlink
  resolution of the collection's root, on the main actor — for a record
  nothing reads, since the cache was written before it. It is left empty.

And from the pre-existing findings, the ones in code this change touched: the
relatedness build reads the vault in `offMain` rather than a `Task.detached`
(which worked only because `RelatednessDocument`'s memberwise initialiser
happened to be nonisolated; it is declared `nonisolated` now), it stops reading
when the index is dropped — a detached read went on through the whole vault,
seconds of coordinated I/O on iCloud — and a caller that was waiting for a
dropped build asks again instead of getting that build's index. `moveItem`
drops a save still being parsed for the moved note, as `forget` and a rename
do. `BoxStore`'s path caches use scoped locking (`withLock`) — an `NSLock`'s
`lock()` and `unlock()` in an async function is an error in Swift 6, and
§51.21 had added four more of them.

**A second review, of those fixes, found three holes in the numbering**, all
fixed:

- **The main actor waited for cache writes.** A rebuild takes its number on
  the main actor, and the number came from the counter behind the same lock
  the write held across the file replacement — so beginning a rebuild while
  another wrote its cache (any collection's) blocked the main thread for the
  write. The counter is an `Atomic` of its own now; the lock is taken only off
  the main actor.
- **Rescan was not a barrier.** It deleted the cache on the main actor without
  touching the numbering, so a rebuild still reading — numbered above anything
  written — wrote the deleted cache back when it finished; if the forced
  rebuild was then replaced before its own write, its replacement trusted the
  old records again. Removing the cache now takes a number under the lock and
  bars every rebuild numbered before it, and a rebuild reads the cache under the
  same lock (`loadForRebuild`), so one numbered after the removal cannot have
  read what it removed. Rescan cancels the rebuild in flight, and the removal
  moved off the main actor, into `rebuildFromScratch`.
  `aRebuildBegunBeforeARescanCannotWriteTheCacheBack` fails without the bar.
- **A failed write was counted as written.** The number was recorded before
  the write, so a failed one barred every older rebuild — and the rebuild whose
  write failed still let its saves go, though the cache held the notes' old
  records. The number is recorded after a write succeeds, `save` says whether it
  wrote, and a rebuild lets a save go only when its write did
  (`RebuildRecords.cached`); until then the next rebuild reads the note again.
  `aFailedCacheWriteIsNotCountedAsWritten` makes a write fail by putting a
  directory where the file goes — and its negative control first passed with
  the guard taken out, because **`cacheURL(for:)` answered differently with the
  directory there**: `appendingPathComponent(_:)` without `isDirectory:` stats
  the path to decide, so the URL gained a trailing slash, and the two writes
  were counted under two keys. It passes `isDirectory: false` now — which also
  takes a system call off every caller, `activate` on the main actor among them
  — and the test fails with the guard out, as it should.

GoogleDrive's path caches were moved to scoped locking too — §51.21 had added
three bare `lock()`/`unlock()` pairs there, as in `BoxStore`.

The app suite passes (685 tests in 95 suites, about 24 s — the serialized
`SaveIndexingTests`, 20 of them, are most of it), the main-actor budgets pass
run alone (a 2 MB save in a collection 4.0–4.6 ms, the 2,000-patch burst
9–13 ms), and the app builds for macOS. One budget run failed
`typingInSplitModeBarelyTouchesTheMainActor` at 614 ms of settling — Split mode
and Preview, no collection involved — and passed at 20 ms and 5 ms run again. Left for a separate pass: isolation warnings in code this
change did not touch — `LinkProposals`, `MainActorWatchdog`, and `BoxStore`'s
token refresh — and the providers running on the main actor, which the second
review measured the reach of (unimplemented.md §3).

### 51.23 Preview keeps its place across pages (2026-09-28)

Seen on the HN-iPad simulator on 26 September (unimplemented.md §4): in Split
mode, with the preview scrolled down to Rich Content's diagram and table,
typing one character in the source brought the preview back to the note's
first line once typing paused. Every page `NotePreview` builds is handed to
`GFMWebView.load`, which replaces the document (`loadHTMLString`) — and a new
document starts at the top. §51.18 made it once per pause rather than once per
keystroke; in Preview it happened at every change made under the note (an app
write, a reload).

- **The page says where it is scrolled to.** `PreviewScrollRelay` is a
  `WKScriptMessageHandler` beside `DiagramZoomRelay` — installed once per web
  view, holding the coordinator weakly — and the page's script posts
  `window.scrollY` from a scroll listener, at most once a frame, with the
  page's number. The coordinator keeps it (`PreviewScrollMemory`).
- **Each page is told where it opens before it is parsed**, not scrolled there
  after it has loaded: a document-start user script carries the page's number
  and offset, written into the web view's content controller just before
  `loadHTMLString` (WebKit removes user scripts only all at once, so all of them
  are put back each time). The page scrolls itself there as soon as it has been
  parsed — before it is drawn, where a navigation delegate's `didFinish` comes
  after the page has been drawn at the top — and again at `load`, for a picture
  with no size of its own, which grows the page, unless the reader has scrolled
  it since. The superset's diagrams, formulas and cards carry their sizes, so
  for those the first scroll is already exact.
- **The page's own scroll is not reported.** The plain page `NotePreview` shows
  first for a note, before its diagrams are drawn, is shorter; scrolled to an
  offset it cannot reach, it would have reported how far it got as where the
  reader was, and the whole page that follows would have opened there.
- **A report counts only for the page on screen.** A message still on its way
  from the page before — the last frame of a scroll, a switch of tab — would
  otherwise be taken for the new page's. And a page handed over again (every
  redraw of the pane hands over the page it has) takes no new number, or the
  page on screen would stop counting.
- **A note this preview has not shown opens at the top; one it has, where it
  was left** — a tab switched away from and back to, in the same pane. An offset
  belongs to the note it was measured in, and carried to another it points at
  nothing in particular. Notes are told apart by the editor the preview answers
  heading jumps for (`commandBus(editorID:)`), which it already had, so the app
  changes nothing. A change of mode builds a new preview, which opens at the top,
  as before. The memory keeps the 64 notes used most recently.

`GFMPreviewScrollTests` (11, in `MarkdownEditorTests`). A `WKWebView` never
finishes loading under `swift test` or XCTest, so what they test is what can
be: which page opens where, what each load is told, what a report means — and
the page's own script, run in JavaScriptCore against a model of the browser's
frame (a scroll event is dispatched when a frame is drawn, then the frame
callbacks asked for so far). Each guard was taken out once and its test failed:
without the suppression of the page's own scroll, three; without the page
check on a report, `aReportFromAPageSinceReplacedIsNotTaken`; with a load that
is skipped taking a number anyway, `eachPageIsToldWhereItOpens`; without the
reader-moved check at `load`, `aPageIsScrolledAgainWhenLoadedUnlessTheReaderMovedIt`.

Seen working on the HN-iPad simulator (DefaultCollection only), with the
preview probe on (`HN_PREVIEW_LOG`): Rich Content in Split, the preview
scrolled down to the diagram and the table, one character typed — after the
pause the probe logged the new page, one byte longer, `opening at 696.0`, and
0.4 s later its first glyph at −683.5 (the 12.5pt inset, 696 scrolled). Scrolled
on to the Code section and typed again: `opening at 1016.0`, and the screenshot
after the pause is the one before it, pixel for pixel. The keyboard, coming up
the first time, moved the page itself — the pane shrank from 681 to 361pt —
before any new page; a page opens where the one before it was when it was
replaced, which is what the reader was looking at.

The editor package's tests pass on macOS (260/26, 178/14, 18/4: 456 in 44) and
on the iPad simulator (241/24, 178/14, 18/4: 437 in 42), the app suite passes
(685 tests in 95 suites), and the app builds for macOS and the iPad simulator.
The page builder did not change — the scripts are the web view's, not the
page's — so `render-parity.sh` was not run.

### 51.24 Every open window hears about a change on disk (2026-09-28)

Found by the vault-I/O review on 25 September (unimplemented.md §1). When an
open collection changes on disk — another app, a sync, a `git pull` — its
watcher tells the library, and the library called `onExternalChange`: a single
closure on the app-wide `Library`, which each main window's `.task` set to
reconcile that window's tabs and revalidate its selection. So the main window
opened last was the only one told. Every other main window's tabs were never
reconciled — a change made elsewhere was neither loaded into a clean tab nor
raised as a conflict in a dirty one, until a save of theirs found the file
changed and refused to write over it (§51.16). And a note window's editor, in
no window's tabs, was never told at all: wired as a tab is since §51.19, its
save raised the right conflict — but only then, not when the change arrived.

- **One observer per window.** `Library.observeExternalChanges(of:_:)` keys a
  handler by the object the window keeps its editors in — a main window's
  `EditorTabs`, a note window's `EditorModel` — and `collectionChangedOnDisk()`,
  which every collection's watcher calls now, tells them all. A main window's
  handler reconciles its tabs and revalidates *its own* selection, as the
  closure did; a note window's reconciles its editor.
- **From when the window appears to when it goes.** Each subscribes in
  `onAppear` and stops in `onDisappear`, beside its `TerminationGuard` hook — a
  note window on every appearance rather than once with its load, so one that
  comes back is told again.
- **Held weakly.** The owner is handed to the handler rather than captured by
  it, and the library holds it weakly: a window that goes without saying so is
  not kept alive by being told about changes, and is let go at the next one.
  (Its `TerminationGuard` hook still holds it until `onDisappear` removes both.)
- How each window subscribes is the view's own static function
  (`ContentView.observeExternalChanges`, `NoteWindowView.observeExternalChanges`),
  which the tests call — the pattern `NoteWindowView.load` set for loading.

`ExternalChangeTests`: a real change on disk, reported by the collection's own
watcher to the library as `Library.open` has it. The library opens nothing
itself — `persist()` would write the test's folder into the app's collection
list, and in the hosted test bundle `UserDefaults.standard` is the app's own.
Written first, against the single closure (the seams extracted without a change
in behaviour): `aChangeOnDiskReachesEveryWindowsEditor` — two main windows and
a note window; the first window's tab not reloaded nor its selection
revalidated, and the note window not reloaded — and
`aChangeOnDiskRaisesEveryWindowsConflictWhenItArrives`, the same with unsaved
typing: no conflict in the first window or the note window, and nothing written
over the change. The main window opened last reloaded and raised its conflict
in both, before as after: the control. With the registry:
`aWindowThatHasClosedIsNotTold`, which fails with `stopObservingExternalChanges`
made a no-op, and `theLibraryKeepsNoWindowAlive`, which fails with the owner
held strongly.

**The concurrency review found the weak hold held nothing for a main window**,
and three more things, all fixed:

- The main window's handler took `revalidate: { actions.revalidateSelection() }`
  — and `actions` is a value built from the whole view, whose state holds the
  tabs, so the handler held the tabs the library held weakly, and the test
  passed only because it handed in `{}`. The handler now takes the selection as
  a binding (`$selectedNoteID`, one value of the window's state), the library
  weakly, and the tabs from the library; `theLibraryKeepsNoWindowAlive` builds
  the binding as the shell does and fails with the handler holding the tabs.
- Revalidating a selection searched every note for it, once per open window
  per change (`library.allNotes.contains`); it looks it up now
  (`ShellActions.revalidate`, `Library.note(id:)`).
- A note window registered its `TerminationGuard` hook once, with its load,
  and removed it at every disappearance, so a window that came back was no
  longer saved at quit; it registers in `onAppear` beside its observer. And a
  window that comes back catches up — a change made while it was gone is looked
  at as it starts listening (`aWindowThatComesBackCatchesUp`, which fails
  without it); the look captures its window weakly, as the handler does.
- **A buffer let go whose own save found a change was lost.** Older than this
  change, and on the paths it drives: `EditorModel.flush(lettingGo:)` asked
  whether a conflict was open only before saving, and a save that finds a
  change it has not seen raises one itself and writes nothing — so the flush
  said the buffer was saved, and a tab or window closing, or the app quitting,
  dropped it: what was typed was gone, and no conflicted copy kept. It asks
  again after the save now (`ConflictSaveTests.aBufferLetGoWhoseSaveFindsAChangeKeepsMineBesideTheNote`,
  failing before; its control, the same flush not letting go, writes nothing
  anywhere).
- A note window loads its note before refreshing the repository's status, and
  does not wait for it: a `git status` walks the whole working tree, and until
  it had the window said "This note could not be opened".

Recorded, not fixed (unimplemented.md): a window closing removes its
`TerminationGuard` hook before the last save it stands in for has landed, and a
reconcile that loads a note whose load had failed leaves it marked failed.

The app suite passes (695 tests in 97 suites, with §51.25's), `ShellContractTests`
pass, and the app builds for macOS and the iPad simulator.

### 51.25 The Markdown pane saves when editing stops (2026-09-28)

Found by the concurrency review of §51.18 (unimplemented.md §1). Edit mode
writes a note when editing stops: the live editor's end of editing
(`onEndEditing`) lands the document in the buffer and saves it
(`EditorHost.landSync`), and nothing else writes — a text change schedules no
save (`EditorModel.scheduleSave` is empty on purpose: a save during typing is
out of date by the next character, and on a File Provider volume it can hold
the main thread as long as the provider takes). The Markdown pane — Markdown
mode, and Split mode's source — had no end of editing at all: `SourceEditor`'s
text view, an `NSTextView` on the Mac and a `UITextView` on iOS, handed each
keystroke to the buffer (`EditorModel.typed`) and never said when editing
stopped. So what was typed there was written only at the next flush — a switch
of note, mode or app, a tab closing, quitting — and lost to a crash before one.
Clicking into the sidebar or another pane wrote nothing.

- **The pane's end of editing is Edit mode's.** `SourceEditor` takes an
  `onEndEditing` — `textDidEndEditing` on the Mac, `textViewDidEndEditing` on
  iOS, both sent when the text view gives up first responder — re-seated on
  every update with the text binding, because the view outlives a switch of tab.
  The pane passes `Task { await editor.save() }`: the save `landSync` ends with,
  through the same model, not a second way to write. Typing still writes
  nothing.

`SourceEndEditingTests` hosts `NoteEditorView` in a window as
`MainActorBudgetTests` does — the mode in a defaults suite of its own, since
the app's preferences are the person's — and types through the real text view.
`endingEditingInTheMarkdownPaneWritesTheNote`, in Markdown and in Split, failed
in both before: what was typed reached the buffer, typing wrote nothing, and
leaving the pane wrote nothing either. Its controls passed before as after:
Edit mode's end of editing writes, and so does an explicit flush. The test
bundle builds for iOS too, so the same tests run on the iPad simulator, where
the save is `textViewDidEndEditing`'s. On the way:

- Split there failed in the test itself, twice. It picks side by side or
  stacked in a `GeometryReader`, and first the test typed into a text view from
  an arrangement already replaced — it waits for the settled one, in a window,
  and for it to take first responder. Then, in a window taller than wide, the
  keyboard coming up made the pane wider than tall, Split went side by side,
  and the text view that had the keyboard was made again without it: a defect
  of Split's own on iPad, recorded in unimplemented.md §7. The test's window was
  wider than tall, where Split is side by side with the keyboard or without it,
  until §51.29 fixed Split and put it back to taller than wide.
- The Edit-mode control crashed the test host twice — the app, which a hosted
  test runs in — before it was given the `EditorDocumentStore` the live
  editor's host reads from its environment; SwiftUI stops the process for a
  missing environment object. Only the test's own notes were open.

The app suite passes (695 tests in 97 suites), the three tests pass on the iPad
simulator, the iOS interface tests pass (13, one skipped), and the app builds
for macOS and the iPad simulator.

### 51.26 A property change rewrites its own key and no other (2026-09-29)

Seen on the HN-iPad simulator on 26 September and left open by §51.20: adding
`status` to Intelligence.md in the Properties panel, whose front matter is
`title: Intelligence` and `tags: [tour]`, wrote `tags` back as a block list —
and removing `status` again did not put it back. `EditorModel.setProperties`
goes through `FrontMatter.applyingChanges`, which since §51.15 returns nil when
nothing changed; anything else went to `splicing`, which replaced the whole
block with `render(properties)`, the panel's own style. So every key changed
shape whenever any key changed. Written as tests before anything was changed,
the whole-block rewrite:

- turned every flow list into a block list — every note `DefaultCollection`
  ships writes `tags:` as one;
- dropped hand-chosen quoting (`'single'` became bare), blank lines, key
  indentation and comments. A comment with a colon in it was worse than
  dropped: it was read as a key named `# …` and offered in the panel as one;
- destroyed a value written over several lines whenever *another* key changed:
  `summary: >` and its lines became `summary: ">"`, and a line of that text
  with a colon in it became a key of its own;
- did not see a block saved with CRLF endings at all. `isFence` trimmed spaces
  and not the CR, so `---\r` was no fence: the panel showed no properties for
  a note whose front matter the editor folds (`BlockParser.isDashFence` allows
  the CR), and a property added there went into a second block above it.

What changed, in `FrontMatter`:

- **A key at a time.** `splicing` walks the block's keys with the lines each
  was read from. A key whose property is unchanged keeps its lines byte for
  byte; a changed one is written in their place at its indentation, a list in
  the style it was written in (a flow list stays one unless an item holds a
  comma, which the flow form cannot read back; a block list keeps its items'
  indentation); a removed one takes its lines with it; an added one goes after
  the last key, in the panel's style. Comments, blank lines, the fences and the
  order of the keys are the file's. Keys are matched by `Property.id`, in
  order, so a hand-written repeat is still two rows. `applying` goes the same
  way, so the suggestions do too: an accepted tag makes `tags: [tour, demo,
  focus]`, and a summary replaces the summary's line and nothing else.
- **A key's lines are all of its value.** A `|` or `>` block's text, a value
  wrapped onto a deeper line, a flow list broken across lines, and a block list
  past a blank line or a comment between its items are read as one value — one
  line, as the panel shows a value and the app writes one — and a change or a
  removal takes all of them. Counted as the key's line alone, the rest would
  stay behind as lines of nothing, which YAML reads into the key above them. A
  deeper `key: value` is still a key of its own, read flat as the panel always
  has, and a change to it is written at its own depth.
- **A comment is not a key, a CR is not part of a value, and `---\r` is a
  fence**, as it is to `BlockParser`. A line written in place of another takes
  its CR; an added line takes the opening fence's.

The rules the suggestions keep are unchanged: a value starting with `[` is
quoted (`summary: "[[Linked]] from here"`), a scalar is one line, and a
flow-list item holding `[`, `]`, `{` or `}` is quoted too.

`FrontMatterSpliceTests` (19) writes into a hand-made block — a comment, a
quoted value, a flow list, a block list, a blank line, single quotes, a key
order of its own — and asks that adding, removing, changing or renaming one key
leave every other line byte for byte, and that the changed key read back
through `properties(in:)`. Twelve of its first fourteen failed before the
change; the two that passed are the control (the panel's rendering of the same
properties is not the block as written, so "left as it was" asks something of
the splice) and removing every key, which removes the block, as before. Four
more, about values over several lines and a key under another, were written
against the new splice and three failed it — removing `description` left
`  wrapped onto the next line.` behind — before a key's lines were made all of
its value; the fourth, the nested key, passed because a changed line already
kept its indentation. The last test runs every note `DefaultCollection` ships
(eleven have front matter): a property added and removed gives the note back
byte for byte, and each key changed in turn reads back as that change alone,
moves no line of the body and rewrites no other line. Negative controls,
temporary edits reverted after: with unchanged keys written again anyway and no
key given the lines its value goes on over, ten tests failed — eight on lines
that should have been left as they were, and both multi-line tests on the
value; with the old whole-block rewrite put back, the shipped-notes test failed
37 of its expectations.
`WhoseTextWinsTests.aWriteAboveTheCaretKeepsItsPlaceInTheBody` had measured the
old rewrite — the body moved seven characters for a priority of 250, five of
them the tags written as a block list — and asks for the two it moves now.

Checked on the HN-iPad simulator with the app's preferences naming
`DefaultCollection` alone and no cloud cache — read from the app container's
own preferences file: `simctl spawn … defaults` reads another domain, and
there showed no collections at all. `status` added to Intelligence.md in the
panel was written as one line, `status: ""`, under `tags: [tour]`; removed
again, the file was byte for byte the copy taken first (the same SHA-1), and
the copy was put back with its date. On the way: nothing was on disk until the
app went to the background, because a property change is written only at the
next flush — recorded in unimplemented.md §1.

The app suite passes (714 tests in 98 suites), and the app builds for macOS and
the iPad simulator.

### 51.27 A table's picture shows its cells as the page does (2026-09-29)

Seen on the HN-iPad simulator on 26 September, in DefaultCollection's
Intelligence.md: the table of actions — `| Ask Library (**⇧⌘J**) | … |`,
`` | Summarise Note | … `summary:` … | `` — showed its raw `**` and backticks in
Edit, where Preview showed bold and code. Edit draws a table as a picture in
place of its concealed source, and the app's `TableImageRenderer` drew every
cell as `NSAttributedString(string: cell)`: the source. The grid was measured by
`GFMTableGeometry.cellText`, which understood code spans and nothing else — so
code was *measured* without its backticks and *drawn* with them, a column
holding a link was as wide as its destination, and a squeezed one wrapped at
words the page never shows.

- **A cell is its rendered text, measured and drawn as one value.**
  `GFMTableGeometry.cellText` reads a cell with the editor's own inline pass —
  `StyleSpec.inlineRuns`, public now, the runs the editor lays over this very
  cell while the table's source is showing — and sets it with the editor's own
  mapping from a role to fonts and colours, caret-away (`StyleApplier.apply`,
  internal now). No second parser. What the editor conceals is not drawn at
  all: a picture has no caret to reveal it for, a concealed marker keeps a
  sliver of advance, and its `/`s and spaces would be places to break a line
  the page never breaks. Code keeps `code`'s padding as kerning — after its
  last character, and before its first on a no-break space too small to see,
  standing where the backticks were (kerning on a zero-width space is dropped:
  measured). `GFMTableGrid` carries each cell's text (`cells`) and where its
  lines break (`cellLines`), and the row heights are counted from those lines.
- **The picture is the package's** (`GFMTableImage`), beside the geometry it
  draws from, and draws exactly the geometry's lines: each in a line box of the
  row's font centred in the line as CSS centres it (a strut keeps a line of
  nothing but code from rising), code in the live editor's pill, a cell with
  fewer lines than its row in the middle of it (`vertical-align: middle`), all
  under the appearance asked for, so the styled text's dynamic colours resolve
  for it. A wrapped cell had been drawn by `draw(in:)`, which breaks where
  TextKit likes and at the font's own line height. `TableImageRenderer` is the
  app's entry point now: its text size, and the person's accent, which colours a
  link in a cell as Preview colours one — `EditorHost` passes it, and the
  document the picture is drawn for is already keyed on the accent.
- **The parity harness draws the real picture.** It had returned a blank image
  of the grid's size: right for a height, and an empty box beside Preview's
  `<table>` in every `--png` dump.

Found by the document gate once a table of long, marked-up cells was in it
(`36-table-inline-markup.md`, new — no gated table had had more than code in
its cells) — and true of plain text as much as of Markdown: a plain copy of the
same table diverged by the same −47.93pt at 560pt and +24.07 at 420.

- **An over-wide table shares its width as WebKit does** (`AutoTableLayout`).
  GitHub's stylesheet makes an over-wide table exactly the pane's width
  (`display: block; width: max-content; max-width: 100%`); every column starts
  at its minimum, and the whole width, minimums included, is shared in
  proportion to each column's maximum, left to right, none below its minimum,
  as boxes with their padding and border. It shared only the space above the
  minimums, in proportion to how much each could give: a wider first column
  than the page's, and two rows that wrapped in Preview and not in Edit.
- **A line's trailing space hangs**, as CSS hangs it: it counts neither
  towards whether a line fits nor towards the narrowest a column can be.
  Counted, `Summarise ` was a column's minimum, a space wider than the page's,
  and at 420pt the cell beside it wrapped a line the page did not.
- **A header cell whose column declares no alignment is centred**, as the page
  centres a `th`, and a declared `:--` is not; `GFMTableLayout` keeps what the
  delimiter row declared (`declaredAlignments`, nil for `---`). No height could
  see it; the pictures did.

`GFMTableInlineMarkupTests` (10, run on macOS and on the iPad simulator): a
link, a wiki link with and without an alias (escaped in a table: an unescaped
pipe divides the cell even inside `[[…]]`), strikethrough and an escaped `*`
measure exactly as the plain text they render as, natural and squeezed; bold,
italics and code are measured in their own faces; the tour note's row; what a
cell is drawn from — no markers, the page's faces, no link — and its column as
wide as that; the lines drawn are the lines counted; the picture is the size
the geometry reserved; and the two squeezing rules. Against the old code three
of the first four failed and the fourth — a plain table's natural widths, the
control — passed, as it still does. `TableImageMarkupTests` (5, pixels, in the
app): a link, a wiki alias and an escaped `*` are drawn as the plain text's
ink; `**word**` is the semibold header's ink; code sits in GitHub's pill; a bare
header is centred and a declared one is not; and a dark table is drawn in light
ink, the control, which passed throughout — every other test failed before its
fix. `GFMTableLayoutTests.aPlainDelimiterDeclaresNoAlignment` too. Negative
controls, each a temporary edit reverted after: counting the trailing space
again and restoring the old distribution each failed its test, and measuring
cells as their source again put the new document +96.13pt out at 560pt and at
800 — the gate sees the defect this fixes.

Compared with a run before any change: `render-parity.sh` passes with its
fifteen sample runs and its chrome check unchanged; the document gate at 420,
560, 800 and 1200pt moved **no** existing document's height, Edit or Preview;
the new one agrees at all four (+0.13pt); and at 420 the advisory list is the
same two documents (the break after `/`). Looked at with `--png`, not only
weighed: the tour note's table at 800pt has every line of ink at the same
height on both sides (8 lines a column, 0px apart at 2×), and the squeezed new
table has the same lines per column at 560 and 420 with a uniform 1px offset at
2× — sub-pixel placement, identical for the plain table, within the gate's point.

Checked on the HN-iPad simulator, the app's own preferences naming
DefaultCollection alone and no cloud cache: Intelligence.md in Edit draws its
table as Preview does — semibold keys, code in pills, centred headers. The
note was not written (its bytes and date matched a copy taken first), and the
editor was put back in Preview.

Not fixed here, and recorded in unimplemented.md §6: Preview's rewrite of an
aliased wiki link inside a table keeps the escaping backslash in the target;
`<br>`, inline maths and images in a cell; GitHub's `tabular-nums` on tables.
And the harness's Preview is built with GitHub's link blue, not the theme's
accent, so link colours differ in its dumps — not in the app, where both
surfaces take the person's accent.

The app suite passes (719 tests in 99 suites); the editor package passes on
macOS (270 in 27, 179 in 14, 18 in 4) and on the iPad simulator (251 in 25, 179
in 14, 18 in 4); the app builds for macOS and the iPad simulator.

### 51.28 A full build reports no isolation warnings (2026-09-29)

The concurrency review of §51.22 reported four sites; a full build found
twenty-four. This target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
in the Swift 5 language mode, so an unannotated type or extension member is
`@MainActor`, and reaching one from nonisolated code is a warning rather than
Swift 6's error. What the warning means at runtime depends on the call — probed
with this target's flags: an `async` call hops to the main actor, one hop per
call; a synchronous one cannot hop, and simply runs where it is, unchecked. A
warning prints only when its file compiles, so every source of the app and its
extensions was touched and built — 27 warnings on macOS, 24 of them concurrency
— and then the same for the iPad simulator, which found one more that only an
iOS branch contains. Fixed without changing what anything does:

- **Data read off the main actor is `nonisolated`.** `LinkCandidate` and
  `LinkProposal` (the link scan read `LinkCandidate.names`, a computed member
  of what was a main-actor type); the watchdog's `Duration.milliseconds` and
  `.seconds`, read by the nonisolated `MainActorWatchdog` and its sampler
  thread; `String.stableHash`, which names a walk checkpoint's file from the
  walk; and SmartPaste's `isBold`, `isItalic` and `isMonospaced`, pure font
  predicates passed as function values (`font.map(isBold)`), as `isOrdered`
  already was. All synchronous, all pure: they ran off the main actor before,
  unchecked, and run there now as declared.
- **`offMain`, not `Task.detached`**, in `Collection.linkProposals` —
  `Task.detached` governs priority and cancellation, never isolation, here.
- **Box's and OneDrive's token refresh run on the main actor, explicitly.**
  `RefreshCoordinator.refresh` takes a `@Sendable` closure, which is
  nonisolated, and in it each Keychain read and write and each of the store's
  own account names was an implicit hop to the main actor. The exchange is
  `{ @MainActor in … }` now: one hop instead of four, the network awaited off
  it, and the Keychain work where it already ran — and where Dropbox's and
  Google's refresh, plain methods of their store, do it. The review checked the
  single-flighting with a copy of the coordinator: five concurrent 401s, one
  exchange, one token for all five, and the main actor free during the wait.
- **Captured state crosses by value.** RemoteMirror hands `offMain` the files
  to remove as `[gone]` rather than the `var`; DictationController's transcript
  task takes its own `[weak self]` rather than reading the handler's; and the
  large-folder prompt's answer is a closure that resumes the continuation,
  rather than `continuation.resume(returning:)` stored as a plain function,
  which dropped its `@Sendable` and `sending`.
- **Scoped locking in async code.** `CollectionEmbedProvider.image(forName:)`
  took its `NSLock` with `lock()` and `unlock()`, which Swift 6 refuses in an
  `async` function; `withLock` holds it for the same statements.
- **iOS only: `WebAuthAnchor`'s scene ranking.** The local function `rank`,
  declared inside the sort's closure, was nonisolated there and read the
  main-actor `UIWindowScene.activationState`; it is declared in the
  `@MainActor` method's body now.
- **Hardening, clean before and one computed member away from a race.**
  `CollectionSearchModel`'s folds — `load(pairs:)`, the rebuild
  `scheduleAggregateRebuild()` schedules, and `contentResults`' reads — ran in
  `Task.detached` over `Entry`, `Derived`, `QuickOpenItem` and `TagNode`, all
  unannotated and so `@MainActor`, and clean only because the folds touched
  nothing but stored properties. The four are `nonisolated` (`QuickOpenItem`
  declares `Sendable` itself now, which main-actor isolation had supplied), and
  the three folds use `offMain`, as `refresh(from:)` in the same model already
  did. The content search also stops building its note dictionary twice on the
  main actor per query. The folds' fixed `.utility` / `.userInitiated`
  priorities are gone, and that changes nothing measurable: each detached task
  was awaited at once by a `.userInitiated` task, and awaiting a task escalates
  it — probed, a detached `.utility` task awaited so ran at `.high` from its
  first instruction, `basePriority` still `.low`. `offMain` runs at the caller's
  priority, which is where they already ran.

One correction to the project's own rules came out of it: `OffMain.swift` and
AGENTS.md said a main-actor call inside an `offMain` closure "still hops at
runtime". It does not — the body is synchronous — and a probe built with this
target's flags read a main-actor member there with `pthread_main_np() == 0`.
So a warning inside `offMain` is a data race in waiting, not a stall; both say
so now.

The `swift-concurrency-reviewer` found nothing wrong in the change. What it found
beside it, in the files touched, is recorded in unimplemented.md: a cloud
collection's walk runs on the main thread (`RemoteMirror.walk` awaits a plain
`nonisolated async` function from a `@MainActor` closure — probed, not yet
measured on a provider), the providers' `list` does too with no warning at
all, a vault's availability check lists its root on the main actor, Open
Quickly scores on it, the transclusion card's section and drawing run there
and the provider's lock guards nothing, a second large-folder prompt could
leak the first's continuation, and every fold builds a tag tree nothing shows.

Left, being neither isolation nor concurrency: a deprecation
(`installTap(onBus:…)`, VoiceCapture.swift) and two unused results
(EditorHost.swift). Fifteen other `Task.detached` blocks remain in the app, each
clean at this build.

A full rebuild now reports those three warnings and no others, on macOS and for
the iPad simulator. The app suite passes (719 tests in 99 suites), and so do
the main-actor budgets on their own (`TEST_RUNNER_HN_BUDGET_TESTS=1`, 13 tests).

### 51.29 Split keeps the keyboard, and every rule keeps up with the pointer (2026-09-29)

Split mode chose its arrangement in a `GeometryReader` — side by side when the
pane is at least as wide as it is tall, stacked when not — as two branches of
an `if`: an `HSplitView` or a `VSplitView` on the Mac, an `HStack` or a
`VStack` on iPad. So the source editor in one branch was a different view from
the source editor in the other, and crossing square made both panes again. On
an iPad in portrait with the band hidden the pane is taller than wide, and the
keyboard is what crosses it: its 340pt come off the pane's height, the pane is
wider than tall, the source's text view is made again without the keyboard,
the keyboard goes, and the pane is taller than wide again. Split could not be
typed in there at all. On the Mac a window resized across square did the same
to whatever was being typed (unimplemented.md §7, found by §51.25's test).

**One container whose layout changes.** `AdaptiveSplit` (UI/AdaptiveSplit.swift)
lays the same two panes and one rule out with `AnyLayout(HStackLayout(spacing:
0))` or `AnyLayout(VStackLayout(spacing: 0))`: an `AnyLayout` changes how its
children are placed without changing which children they are, so the text
view, its first responder and its caret survive the flip. The rule is the
app's own on both platforms, as `ResizableDivider` is — the `HSplitView` it
replaces on the Mac was AppKit's divider, which is also why its swap for a
`VSplitView` could not keep the panes. It has a 10pt grab area, the resize
cursor on the Mac (turned on its side when the panes are stacked), and an
adjustable action for VoiceOver. It keeps the floors the split views gave each
pane, 180pt wide side by side and 120pt tall stacked, clamped at use so a pane
too small for two floors shares what it has. The first pane's size is kept as a
*share* of the room rather than in points, so a drag means the same thing after
the flip: dragged to 60% of the height in portrait, the rule came up at 60% of
the width when the keyboard turned the panes side by side. On iPad, Split's
panes can be dragged for the first time; the `HStack`/`VStack` had no divider.

The tests came first. `SplitArrangementTests` hosts the real `NoteEditorView`
in Split, on both platforms, and takes the keyboard in its source:
`crossingSquareKeepsTheSourcesTextView` resizes the window from 1200×800 to
taller than wide and back, and `theKeyboardComingUpKeepsTheSourcesTextView`
(iOS) lets the keyboard come up in an 800×1200 window — stacked until it does —
and types. Each expects the same `SourceTextView` instance (`===`), still first
responder, and on iOS a keyboard that stayed. Each also checks that the
arrangement really changed — the source under 60% of the window's width side by
side and over 90% stacked, the panes stacked before the keyboard arrived — so a
test that never crossed square cannot pass. With the old `if`/`else` put back
inside `AdaptiveSplit`, both failed on macOS and on the iPad simulator. Two
things about the iPad half: the resize test's tall window is 600×1200 there, so
it stays taller than wide once the keyboard is kept, and each test waits for
any keyboard left by the one before to go, which otherwise made the next one
start side by side. `AdaptiveSplitTests` holds the arithmetic — side by side
from square, each floor along each axis — and on the Mac drags the rule with
mouse events through a window: 200pt dragged is 200pt moved, and the rule stops
at both floors. SourceEndEditingTests' iOS window is back to 800×1200, taller
than wide, the shape §51.25 had to avoid.

**Looked at on HN-iPad, portrait, band hidden:** Split stacked; a tap in the
source brought the keyboard up, the panes went side by side, the keyboard
stayed, and four typed characters landed in the source and in the preview.

**Every rule followed the pointer at half speed.** Dragging the new rule with a
finger in that same session moved it 60pt for 100. A `DragGesture` measures in
`.local` by default — the space of the view it is on — and a rule is the thing
that moves: each step was measured from where the step before had already put
it, so the rule gave back what it had just moved. The Mac test had passed
because it sent its ten mouse events back to back, and nothing was laid out
until the button was up. Sent with the run loop turned between them, as a real
mouse's arrive between frames, it failed: 200pt dragged, 100 moved.
`ResizableDivider` — the pattern Split's rule was built from, under the
sidebar, the right panel, the band's two panes and History's list — and
History's `StackedSplit` had the same shape, and `RuleDragTests` measured the
same half for each: 100 of 200. Each drag is measured now in a space that stays
where it is: the split's own named coordinate space for `AdaptiveSplit` and
`StackedSplit`, which own their container, and the window's (`.global`) for
`ResizableDivider`, which has no container of its own. On HN-iPad afterwards a
100pt drag moved the rule 100.3pt stacked and 100.0pt side by side with the
keyboard up, measured from full-resolution captures. The test harness,
`MouseDrag` in RuleDragTests.swift, is shared with `AdaptiveSplitTests`;
`StackedSplit` lost its `private` so a test can host it.

History still chooses between two branches — an `HStack` with a
`ResizableDivider`, or `StackedSplit` — but by a fixed width, which a keyboard
does not change, and it holds no text view; it is left as it is.

The app suite passes (726 tests in 102 suites), as do the layout contract
(9 tests), chrome parity (16 scenes, none past noise) and the iOS interface
tests on HN-iPhone (12 cases; the window-parity capture is opt-in and skipped).
On the iPad simulator `SplitArrangementTests`, `SourceEndEditingTests` — in its
window taller than wide — and `AdaptiveSplitTests` pass: 7 tests in 3 suites.
The app builds for macOS and for the iPad simulator.

### 51.30 A property changed in the panel is written when it is committed (2026-09-29)

`EditorModel.setProperties` is the Properties panel's one way into a note (§51.15),
from the inspector — `ContentView`'s `onPropertiesChanged` — and from the note's
popover, `NoteEditorView.applyProperties`. It changed the buffer and nothing
else, and a text change schedules no save (§51.25), so a property added, edited
or removed reached the file only at the next flush — a switch of note, mode or
app, a tab closing, quitting. A crash before one lost it, and until then nothing
else reading the vault saw it. Seen on the HN-iPad simulator: `status`, added
to Intelligence.md, was not on disk five seconds later, and was written when the
app went to the background (unimplemented.md §1).

**The panel's commit ends with the editor's own save.** `setProperties` ends
with `Task { await save() }`, as the Markdown pane's end of editing does, so
both callers — which already handed it their rows — write without a line of
their own, including the rows the inspector hands back for a note a tab switch
left. It is the model's save, not a second way to write, so its rules come with
it: nothing over an open conflict (§51.16), nothing while a note is loading,
nothing for a note that could not be read. §51.15's rule stands: rows the note
already holds are no change (`FrontMatter.applyingChanges` returns `nil`), and no
change is no write — `applyEdit` now says whether it changed the note, and the
save follows only a change. That matters when the note holds typing not yet
written: a commit that saved whatever it was handed would write that, on a field
merely gaining focus.

The tests came first, in `PropertiesPanelTests`: `aCommitIsWrittenWithoutAFlush`
— a property added, edited and removed — failed for each, the commit in the note
and not on disk after two seconds, and so did
`aCommitWritesTheTypingOnScreenWithIt`, with the editor wired as `EditorHost`
wires it: the typing on screen is carried and written with the property. The
controls passed before as after: `aFlushWritesACommit` (the same commit and a
flush is on the disk, so the file is read as it is written), and
`anUnchangedCommitWritesNothing`, which fails when the commit's save is made
unconditional — tried, and put back. The first full run failed the typing test:
every main-actor test in that stretch of the suite took about four and a half
seconds, the rest of the suite holding the main actor, and a two-second wait by
the clock ran out before the save had had its turn. The wait is ten seconds, as
the suite's other waits for a write allow (`SaveIndexingTests`,
`ExternalChangeTests`).

**Looked at on HN-iPad**, Intelligence.md in Preview, the app never leaving the
foreground: in the popover, Add wrote `status: ""` within a second, typing
`draft` wrote nothing, and Return wrote `status: draft`; in the inspector,
`-inspector` typed and Return wrote `status: draft-inspector` a second later,
and the row's remove button took the line away, leaving the note byte for byte
as it was (§51.26 writes only the key that changed). The note was put back with
`cp -p`, date and all.

Found beside it, from the code: every other write the app makes through
`applyEdit` — a tag, a link or a summary accepted, the link review, a rewrite, a
version restored from History, a template — has the same shape, written only at
the next flush. Recorded in unimplemented.md §1.

The app suite passes (730 tests in 102 suites, twice), the app builds for macOS
and for the iPad simulator.

### 51.31 The tests leave nothing in the person's preferences (2026-09-29)

The hosted tests run inside the app's sandbox, so a defaults suite made the
usual way — `UserDefaults(suiteName: "name")` — is `Library/Preferences/name.plist`
in the person's own container, beside com.hellotham.HelloNotes.plist. Five
kinds of test made one per run under a new UUID: `IntelligenceMigrationTests`
and `SupportContractTests` cleared the domain afterwards, which empties the
plist to 42 bytes and keeps it, and the MLX picker test, `MainActorBudgetTests`
(`hn-budget`) and `SourceEndEditingTests` (`hn-end-editing`) never cleaned up
at all. By this morning the Mac's container held 424, 144, 58, 50 and 65 of
them, accumulating since 2 September, and the HN-iPad simulator's 47 — and
`SplitArrangementTests` (§51.29) cleared a fixed-name suite and left its file
too.

**A file there cannot be deleted for good.** Probed in the test host on both
platforms: clearing a domain leaves its plist, and deleting the plist was
undone by cfprefsd, which writes a domain when it chooses — seconds later
(1.1s, 2.2s and ten seconds as the probes loaded it), and in one run minutes
later: eighteen files, deleted and watched for three seconds without
returning, were all back as empty plists by the next run, on the Mac and on
the simulator alike. A `synchronize()` after the delete brought the file back
a second later, and so did a late write; waiting before the delete, or after
the clear, did not help. Only a delete with nothing pending stayed gone — and
that leaves cfprefsd holding the domain's values, which a suite of the same
name would inherit.

**So a scratch suite never goes there.** `ScratchDefaults`
(HelloNotesTests/ScratchDefaults.swift) is a Swift Testing trait —
`@Test(.scratchDefaults)`, then `ScratchDefaults.suite(label)` anywhere in the
test, the test's own helpers included (it is found through a task local). A
suite is named by an absolute path, and `UserDefaults(suiteName:)` given one
keeps the domain's plist at that path: each test's suites are in a folder of
its own in the temporary directory, and when the test ends — however it ends —
their domains are emptied and the folder is deleted. A late write finds no
folder to land in, and cfprefsd makes none (watched for twelve seconds on both
platforms); the scope checks the folder is gone. The folder is named for the
test (`hn-defaults.<Suite>.<test>`), not the run, so a test that dies before
its cleanup leaves one folder, which its next run empties and removes; a suite
is emptied when first asked for, since cfprefsd may still hold what the last
run wrote. The cases of a parameterized test run at once under one name, so a
second takes `-2`. Nothing of it reaches Library/Preferences at all.

It is used in all six places: the four migration tests (one with two suites,
`used` and `unused`), the MLX picker test, `SupportContractTests`, the budget
suite's and `SourceEndEditingTests`' `host` on both platforms (a suite per
mode), and `SplitArrangementTests`. Two suites are left as they were, opt-in and
named once: the evaluations' `HelloNotesEvaluations`, a static that the whole
evaluation run shares, so there is no per-test end to clean up at; and
`HelloNotesResearchProbe`. Each leaves one file, whatever the number of runs.

On the way: the trait's `provideScope` must be `@concurrent`, and so must its
closure. This target builds with approachable concurrency, which makes a plain
`async` function `nonisolated(nonsending)`, and Xcode reported only "does not
conform to protocol 'TestScoping'" at a call site. `swiftc -typecheck` with the
target's upcoming features gave the full note: the closure parameter's type.

`ScratchDefaultsTests` came first, against a stub that kept the suites in
Library/Preferences as the tests did. `aScratchSuiteLeavesNothingInPreferences`
runs a body as the trait runs a test and looks two ways. The suite's plist
must reach the test's own folder, which only a suite named by a path can
write to. Nothing carrying the test's tag may be created or rewritten in
Library/Preferences — its name is fixed, so a leftover may be a rewrite —
when the test ends or three seconds later, and the folder must be gone. The
first version looked only at Library/Preferences, and with the suites put back
there it passed: cfprefsd wrote their plists ten seconds after the test had
ended. The control, `clearingADomainLeavesItsFileAndTheCheckSeesIt`, clears a
domain as the tests did and finds the empty plist it leaves, in a folder of its
own, because a control file in Library/Preferences would be the very leftover
this removes, and could not be deleted. `aRunThatDiedLeavesOneSuiteAndTheNextStartsClean`
failed with the stub too: the last run's value came through.

The app suite passes (733 tests in 103 suites), and so do the budget suite
(13, both typing tests with it) and the converted suites on HN-iPad (32 in 6).
Each run's container was listed by name and date before and 20–30 seconds
after: nothing new and nothing rewritten in Library/Preferences on either
platform but the app's own plist, which the host app writes itself, and no
folder left in the temporary directory. The leftovers already there were
listed and, asked, the person had them deleted by exact name: the 788 of the
five kinds (741 on the Mac, 47 on the simulator, each prefix + UUID + `.plist`),
both `hn-split-arrangement-tests` plists, the evaluations' two on the Mac, and
the probes' own — 830 files in all, none of them com.hellotham.HelloNotes.plist.
None had come back a minute later; the Mac's Library/Preferences holds the
app's own plist and three of the system's, the simulator's the app's alone.

**Found on 2026-10-08: the test host crashed after the budget suite passed.**
"HelloNotes quit unexpectedly" — the Debug build, as the test host, with
`No Observable object of type EditorDocumentStore found` on the main thread
while XCTest reported the finished run. The Split typing test hosts
`NoteEditorView` in a window of its own and stores the editor's mode in the
test's scratch suite; the window was closed and kept, and the view in it
outlived the test. When the test ended, `ScratchDefaults` emptied the suite,
the view's `@AppStorage` mode fell back to its default, Edit, and `EditorHost`
asked for an `EditorDocumentStore` — which the app's root provides and the
test's window never had. Before this section the suite was never emptied, so
the mode never changed under a closed window. Now the view leaves the window
on every way out of `typingCost`, and `host` gives it the document store, so
its environment is the app's in every mode, not only in the one the test
chose. Taking it out of its window does not release it — a check that it was
gone failed after a second of the run loop turning, with the view still alive
— so the whole environment is what makes it safe. The budget suite passes
(15), and the host's output holds no fatal error and no crash was reported.

### 51.32 A vault's availability is checked off the main actor (2026-09-29)

`Collection.unavailability(of:)` says why a vault's folder cannot be read —
`.missing` when it is not there, `.permissionDenied` when it is there and cannot
be listed — and to say the second it lists the root with
`contentsOfDirectory(atPath:)` (the `atPath:` form on purpose: the `at:` form
refuses a symlink at the end of the path). It was already `nonisolated`, but its
two callers ran it synchronously on the main actor: `recheckAvailability`, which
Retry and Relocate go through, and the watcher's `.rootChanged` handling. On a
File Provider or iCloud volume a listing can be a blocking XPC call, so the app
would wait on the provider exactly when the folder was in doubt (unimplemented.md
§3; found by the review of §51.28, inferred from the code rather than measured).

**Both look off the main actor** — `await offMain { Collection.unavailability(of: root) }`
— with the same reasons from the same function. `CollectionState.UnavailableReason`
is `nonisolated`, being made on the pool thread and handed back. Moving the look
made it an `await`, and an `await` is somewhere other work gets in; the look had
been one synchronous step, and the rest of this is keeping it as good as one:

- **Events and rechecks take turns.** `inTurn` runs each after the one before
  it: a watcher event (`receive` → `handle`, now `async`) and a recheck's look
  and verdict (`lookAgain`), whole and in the order they came — as they ran
  when nothing could come between them. The recheck's scan and index rebuild
  follow its turn, as they followed its synchronous step. Without the queue an
  `.unmounted` reported during a root change's look was handled first and then
  overwritten with the look's `.missing`, and one reported during a recheck's
  look was overwritten with its `.ready`; both were measured, not supposed.
- **A recheck under way is joined.** Try Again can be pressed again now that
  the app is not blocked, and each press queued a look of its own — one after
  another on a stalled provider, every event behind them waiting. A second
  recheck answers with the one pending; only the first scans.
- **A closed collection hears nothing.** `deactivate()` marks it closed first:
  a turn that starts or lands after that makes no verdict, reports no change
  and starts no walk — closing gives up the folder's security scope, and the
  look used to be over before anything could close it — and a reconcile
  scheduled just before closing is cancelled. `activate()` clears the mark.

The tests came first, in `CollectionAvailabilityTests`. No timing can say where
a test folder's listing ran — it takes microseconds; a File Provider's is the
one that blocks — so `unavailability(of:)` tells a probe
(`Collection.availabilityProbes`, keyed by folder path so parallel tests hear
only their own; empty outside tests) whether it ran on the main thread.
`aRecheckLooksAtTheFolderOffTheMainActor` and
`aRootChangeLooksAtTheFolderOffTheMainActor` failed first, hearing their looks
on the main thread; the second also checks the conclusions are the old ones (a
readable folder reconciled with its state untouched, a gone one `.missing` and
reported). A recheck looks twice, since the scan it starts checks the folder
too, so they ask that every look was off the main thread. The control,
`theProbeHearsALookMadeOnTheMainActor`, makes the look from main-actor code as
the callers did and hears it as such. With the probe holding a look open:
`anEventAfterARootChangeIsHandledAfterIt` and
`anUnmountDuringARecheckIsNotOverwritten` (the recheck, queued first, answers
`true` and the unmount after it stands — what the synchronous code did),
`aRecheckUnderWayIsJoinedNotRepeated` (three rechecks, one look; three before),
and `aLookThatLandsAfterClosingSaysNothing` (both paths). Each was seen to fail
with its fix taken out: the queue not waiting, the recheck outside it, the
closed checks removed, the looks back on the main actor.

The `swift-concurrency-reviewer` ran twice. The first pass confirmed nothing
listed on the main actor any more and found the ordering hole above — a recheck
outside the event chain — with a test that failed on that code exactly as it
traced; the revision is what closed it. The second pass found the rest (the
join, a closed collection's scan, `activate` clearing the mark, and one
sentence the queue needs: a turn must never wait for a turn, or it waits for
itself), and a Swift 6 typecheck of the change with a negative control found
nothing. Accepted: an event queued behind a slow root-change look waits for it,
so the self-write windows (12s and 15s) can call our own autosave external after
a look slower than that — the old main-actor block delayed it the same way.

The app suite passes (740 tests in 103 suites), and so does the budget suite
(`TEST_RUNNER_HN_BUDGET_TESTS=1`, 13 tests). The app builds for macOS and for
the iPad simulator with no warning in Collection.swift.

Recorded in unimplemented.md rather than changed here: the main-actor bookmark
work that Try Again and Relocate do before the recheck, and the launch-time
resolution and look in `Library.restore()` (§3); a walk's verdict, older than a
recheck that has just succeeded, landing after it — as it could before (§1);
and `ResumableTreeWalk.run` wanting `@concurrent`, and `FileWatcher`'s `deinit`,
which Swift 6 would refuse (§11).

### 51.33 A table's aliased wiki link names its note in Preview (2026-10-08)

In a table an alias's pipe has to be escaped — `[[Examples/Nested Note\|an alias]]`
— or it divides the cell, even inside `[[…]]`. Edit read the link right: its
table unescapes a cell's pipes before the inline parser sees the cell
(`GFMTableLayout.cells`), so the target is `Examples/Nested Note`. Preview did
not. `NoteMarkdown.prepare` rewrites wiki links on the raw line, before
cmark-gfm has seen any table, and its pattern stops at the pipe, so the table's
escape stayed in the target: `[an alias](Examples/Nested%20Note%5C)`, a note
whose name ends in a backslash (unimplemented.md §6, measured 2026-09-29 while
adding the table document in §51.27). The text shown was right on both
surfaces, and the document gate could not see the difference — it measures
heights, and a destination has none — though `36-table-inline-markup.md` holds
exactly this link.

**On a table's lines, the rewrite drops the escape with the pipe.** Which lines
those are is asked of `BlockParser`, in the parse `prepare` already made to
find the front matter, because the editor lays out what the parser calls a
table and nothing else: a line with pipes in it is not a table row unless the
parser says so. There, an aliased link's or embed's target loses the backslash
before its pipe (`NoteMarkdown.target`). Only an odd run of backslashes escapes
the pipe — an even one is escaped backslashes, and stays — because that is how
the editor's table reads a row. An alias's own escaped pipe
(`[[Note\|either\|or]]`) stays escaped, or the rewritten link would divide the
cell the original did not, and a picture sized in a table,
`![[picture.png\|300]]`, names the picture. Outside a table nothing unescapes
the pipe and the editor reads `[[Note\|alias]]` as a link to `Note\`, so
Preview still does: whether `\|` should split an alias there is a question for
both surfaces at once.

The tests are in `NoteMarkdownTests` (GFMRender), and five failed first:
`aTablesAliasedLinkNamesTheNote`; `aTablesAliasedLinkReachesTheRendererWhole`,
through cmark-gfm — one link, in its own cell, the row still two cells wide;
`theEditorFollowsTheSameNote`, which reads the row through
`GFMTableLayout.cells` and `InlineParser` as Edit does and asks that Preview's
decoded destination be Edit's target; `aTablesSizedEmbedNamesThePicture`; and
`anAliasesOwnEscapedPipeStaysEscaped`. The control,
`outsideATableTheBackslashIsReadAsTheEditorReadsIt`, keeps the backslash
outside a table — including on a line with pipes in it that the parser does
not call a table — and passed before the change and after it.

The editor package passes on macOS (473 tests: 270/27, 179/14, 24/4) and on the
iPad simulator (454: 251/25, 179/14, 24/4). `render-parity.sh` passes: 59 of 59
documents agree at 1200, 800 and 560pt, and the 420pt listing names only the
known two. The app suite passes (740 tests in 103 suites).

Found on the way and recorded in unimplemented.md rather than changed here:

- **Following an aliased link in Edit makes a note named after the whole link**
  (§1). The editor hands the resolver the link's whole content,
  `Roadmap|the plan`, and `WikiLinkNavigation.split` takes off a `#heading` and
  nothing else, so nothing is found — measured in a probe, where `Roadmap`
  resolved to the note and `Roadmap|the plan` to nothing. Read from the code,
  not run: the main window's call leaves `createOnMiss` at its default, so
  `createNote(title:)` then makes `Roadmap|the plan.md` (it did — fixed in
  §51.35).
- **A table's `\|` is read into the target everywhere else that reads a wiki
  link** (§1): the link graph, a rename's rewrite of the links to the renamed
  note, the mind map, `ComposedNote`, Preview's transclusions, and Edit's
  broken-link colour outside a table.
- **Edit's table and Preview's split a row differently at `\\|`** (§6).
  Measured with a probe: `| a \\| b |` is two cells in Edit, `a \` and `b`, and
  one in Preview, `a | b`. `GFMTableLayout` reads an even run of backslashes as
  escaped backslashes and the pipe after them as a divider; cmark-gfm lets a
  backslash directly before a pipe escape it, whatever comes before. Three
  backslashes agree. `NoteMarkdown.target` follows the editor's reading and
  moves with it.
- **A link clicked in Preview is not followed to its note** (§6; read from the
  code, not tried). Preview's web view has no navigation delegate, so the
  destination this change corrects is not one the app follows yet.

### 51.34 A cloud collection's walk runs off the main actor (2026-10-08)

Mirroring a cloud folder walked it on the main thread. `RemoteMirror.walk` is
the mirror's, reached through `inTurn`'s `@MainActor` closure, and it awaited
`ResumableTreeWalk.run`, a plain `nonisolated async` function — which under
approachable concurrency runs where its caller is. So every batch's work did
too: per file a path worked out and normalised, the records looked up, and up
to three syscalls. The listings started there as well: the stores were
main-actor, as everything unannotated is in this target, so a store's `list`
read its token from the Keychain and parsed its page on the main thread. No
warning said any of it (unimplemented.md §3, two entries; probed in the review
of §51.28, never measured).

**Measured first.** `MainActorBudgetTests.mirroringACloudFolderNeverBlocksTheMainActor`
mirrors 2,000 notes in 100 folders from `MockRemoteStore` into an empty cache
and counts the main thread's CPU across `syncMetadata()`: **0.973 s**, against
the suite's 100 ms budget (its idle control read 0.005 s). Now **0.0014 s**.
The control, `aCloudWalksWorkOnTheMainActorIsSeen`, runs the walk's own
accumulator over the same listings on the main actor, where the walk ran, and
is seen at 0.24–0.26 s: the small number is the walk having moved, not the
instrument missing it. Both check the walk did its work — 2,003 records, and
the last placeholder on disk.

**The walk.** `walkProvider` is `@concurrent`, so it runs on the pool whoever
calls it, and does all of the walk: the listings, `WalkFindings.add` per
directory, the progress reports, the records it did not list, and the cursor a
complete walk takes — asked before `walk` reads the record back, as it was.
`walk` stays the mirror's: it snapshots the record, awaits the helper, and
applies what came back on the main actor by the rules it had — a record
changed here since the walk began is kept, only a complete walk prunes, and
only what is unchanged and not waiting on a change made here. What comes back
is only what differs from the record the walk began with; applying every
listed item was 10 ms of main-actor work at 20,000 files with nothing changed.
`WalkFindings` is `nonisolated`, as is everything it calls: `DropboxPath`, the
progress and outcome types, `RemoteTreeSource`, and static forms of
`isMisplaced` and `remotePath(forRelative:)`.

**What the walk asked the main actor, it asks a lock.** Two per-file
questions read main-actor state: whether a change made here is waiting to take
the path (`isWaitingToGo`), and, before a placeholder was written, whether the
record had changed since the walk began. On the main actor nothing could come
between such a question and the write it allowed. The waiting paths are
`WaitingToGo` now — a `Mutex` the mirror updates as changes are reported, under
which the walk asks about each file and makes its folder or placeholder, in one
step, as the batch was. The second question is gone: a placeholder is written
only where there is no file, and whatever changes a record during a walk — a
download landing, a save marking it unsent, the cache being trimmed — leaves a
file there, or is a change reported before its file goes. And a placeholder is
an exclusive create now (`.withoutOverwriting`): `createFile` replaced a file,
so a download or a save landing between the check and the write was emptied.

**A delete is reported before its file goes.** A rename always was
(`willMove`). A delete went the other way — the file to the Trash, then
`sendDelete` — which was safe only because nothing ran between the two on the
main actor: a walk away from it that found the file gone and no delete waiting
would take the download for lost, put an empty placeholder back at the note's
name, and that would go up as a note made here.
`sendDelete(of:removing:failed:)` reports the delete and then removes the file
itself, away from the main actor (on iOS an app's folder has no Trash, and a
folder of 2,000 notes is 2,000 removals), and reports nothing if the removal
throws. `deleteNote` and `deleteFolder` delete through it, and a local
collection's delete goes off the main actor too; `Trash` is `nonisolated`.

**The stores.** `RemoteStore` and its conformers — Box, Dropbox, OneDrive,
Google Drive and the demo store — are `nonisolated`, so a listing runs where it
is called: in a walk, on the pool. A page is parsed in `offMain`, so one parsed
for a change made on the main actor (an upload lists the note's folder before
and after) is parsed off it too. Drive's change feed, which names ids, was
placed by searching both id caches for each change — changes × ids, on the main
actor's turn, 181 ms for 2,000 changes against 20,000 ids — and is placed from
one map now, built off the main actor once per refresh. Box's and OneDrive's
token refresh were `@MainActor` only because the Keychain and the stores'
properties were (§51.28); neither is now. Dropbox's and Drive's, plain methods
that ran wherever the 401 was met — an upload's turn is the main actor's — go
through a `RefreshCoordinator` too now: away from the main actor, and one at a
time. The demo store keeps its files behind a lock, since a walk lists six
folders at once.

**The tokens** (`TokenCache`, behind `RemoteTokenStore`). Every request read
its access token from the Keychain — an XPC round trip to `securityd`, six at a
time during a Box walk. Each account's token is now read once and kept, with
every write: only the app compiles the file, and every write goes through
`setToken`, a refresh's included. The concurrency review found the first
version wrong three ways, each fixed and tested against a keychain of the
test's own (`TokenCacheTests`): it remembered any failed read as "signed out" —
a locked keychain then refused every request until the app quit, and "sign in
again" signs out first, deleting the good tokens — so only a missing item is
remembered now; it forgot a token whose Keychain write failed, and a refresh
token Box or OneDrive has just rotated is the only valid one, so the token is
kept in memory whatever the write does, and an item is updated in place rather
than deleted and added again; and it held its lock across the Keychain calls,
so a main-actor read of one account waited on another's XPC call, and now no
Keychain call is made under the lock a read takes — a read made outside it is
kept only if nothing was written meanwhile. Its second review found two more:
one lock serialised every account's writes, so a write waited on another
account's Keychain call (each account has its own now — a test with that lock
shared again fails); and a Keychain that could not be read still reached the
browser as `notAuthenticated`, which offers to sign in again, which signs out
first — it is `keychainUnavailable` now, shown as what it is.

**A download outlives a walk of a provider whose listing names no revision.**
A walk keeps a note downloaded only if the provider says it is unchanged, and
it asked by revision alone — which Box's and Drive's listings do not carry (nor
the demo store's). So every walk of such a folder made every download a
placeholder again, its bytes left in place: a note open in an editor had its
saves refused ("hasn't been downloaded… open it first"), and opening it again
downloaded the provider's copy over what was typed. A walk of a cache with
downloads is a folder added again, which is how a closed cloud collection comes
back. Where neither the listing nor the record names a revision, the same size
and date are the provider's word now (`WalkFindings.isUnchanged`). Older than
this change, and found by its second review.

The tests, beside the budget pair and `TokenCacheTests`, are in
`CloudCollectionChangesTests`. `aNoteDeletedWhileASyncWalksStaysDeleted`
deletes a note while the walk waits on the provider's root: no placeholder
back, no record, and deleted on the provider.
`aWalkPassesOverANoteWhoseDeleteIsWaiting` drives `WalkFindings` itself: a note
gone with nothing reported is put back as a placeholder (the repair a damaged
cache needs, and the control), one whose delete is waiting is passed over.
`aDeleteIsReportedBeforeItsFileGoes`: the removal runs with the delete already
waiting, off the main thread, and one that throws reports nothing and deletes
nothing on the provider. `aWalkRecordsOnlyWhatChanged`, and Drive's
`theChangeFeedIsPlacedFromOneMapOfIds`. `aDownloadOutlivesAWalkOfAProviderWithoutRevisions`
walks the demo store twice around two downloads, one changed on the provider
between: it failed first — the unchanged note recorded `hydrated: false` with
its bytes on disk — and the changed one, the control, is a placeholder again.
`TokenCacheTests` has eight, `aLockedKeychainDoesNotAskToSignInAgain` among them
(with its control, a rejected token that does ask). The walk's other cases while
it is under way — a note made, downloaded, renamed, or saved and changed
elsewhere — pass unchanged. Of the rest, only the budget test could fail first:
they exercise new API, and the delete during a walk passes on the old code too,
the delete completing whole while the walk waits — the gap it closes lies
between two synchronous main-actor calls, which no test can stop in.

Checked: macOS and the iPad simulator build with no new warning; the app suite
passes (756 tests in 104 suites) and so does the budget suite on its own (15).
A Swift 6 typecheck of the app module — the target's own flags with
`-swift-version 6` — reports no error in any file this touches; with
`nonisolated` taken off `writePlaceholder` it reports the call in
`WalkFindings`, and a deliberate type error in RemoteMirror.swift is reported.
The first such run said the module was clean and had checked almost nothing:
without `-continue-building-after-errors` the driver schedules no job after
the first that fails, and the module has 16 Swift 6 errors of its own in seven
other files, so a deliberate type error went unreported until the flag was
added (AGENTS.md says so now). The `vault-io-reviewer` passed it: the cache is
in the app's container, which no file provider manages, so its placeholders
and folders are written raw as before — and coordinating them under the lock
would make a rename or a delete on the main actor wait on `NSFileCoordinator`.
The `swift-concurrency-reviewer` failed the first version for the three token
defects, a main-actor cost in applying the walk, the delete's removal on the
main actor and Drive's change feed — all fixed above — and for older work on
the same paths, recorded below. Its second pass passed those fixes and found
the shared write lock, the browser's sign-in and the revisions, fixed above;
what it still fails is recorded below, by decision.

Running the budget suite whole found its test host crashing after the run, from
§51.31's change, which is fixed and recorded there.

Recorded in unimplemented.md rather than changed here: a refresh with no
cursor yet, which for Dropbox and OneDrive replays the whole folder on the main
actor and for Box and Drive keeps a cursor no walk earned (§1); a note made here
and still empty during a walk, under a name the provider was given elsewhere,
taken for the provider's placeholder (§1); a download written over a revision
the walk had moved past (§1); the delta's per-entry work, the download's write
and the cache's trimming on the main actor (§3); each account's first Keychain
read of a launch, on the main actor (§3); token refreshes single-flighted per
store rather than per account (§1); Box's and Drive's listings, which still name
no revision, so a change there with the same size and second goes unseen and an
upload checks no conflict (§1); and the Swift 6 errors in seven files (§11).

### 51.35 Following an aliased wiki link opens its note, and makes none (2026-10-08)

Clicking or tapping `[[Roadmap|the plan]]` in Edit did not open Roadmap. The
editor hands over everything between the brackets — `wikiTargetAttribute`
holds the link's whole content, on both platforms — and
`WikiLinkNavigation.split` took off a `#heading` and nothing else, so the
resolver looked for a note named `Roadmap|the plan`, the link graph and the
title match found none, and the main window, which creates what a link names
(`createOnMiss`), made `Roadmap|the plan.md` and opened that; a note window
did nothing. `[[Note#Part|see]]` reached the note and looked for a heading
named `Part|see`, and an aliased web link opened its address with the alias in
it. All the while the link was drawn as found: the editor colours a link by its
name alone (`StyleApplier.baseTitle`). The tour had it too — Start Here links
the manual as `[[Manual/Index|user manual]]`, and following it from Edit made
`Index|user manual.md` in the Manual folder (unimplemented.md §1, found by
probe while fixing §51.33).

**The alias comes off first.** `withoutAlias` takes what a link names up to
its first `|`, and without the backslash that escapes that pipe in a table's
row — the editor reads a table's cells raw, so a tap there hands over
`Note\|alias` — by the rule Preview reads a table's aliased link by (§51.33):
an odd run of backslashes escapes the pipe, an even one is backslashes and
stays. `split` takes the heading off what is left and trims the name, as the
editor does for the colour, so following a link goes where its colour says;
`resolve` asks about a web address after taking the alias off too. A link to a
note that does not exist still makes it — the note it names.

The tests are in `WikiLinkNavigationTests`, and all four failed first:
`splitsTheAliasOffFirst` (an alias, a heading and an alias, a bare anchor and
an alias, a table's escaped pipe and an even run that is not one, and a name
with spaces round it); `anAliasedLinkReachesItsNoteAndMakesNone`, through the
resolver with create-on-miss on, which reaches Roadmap and its heading four
ways and asserts the folder holds Roadmap alone — it held three notes more,
`Roadmap|the plan.md`, `Roadmap\|the plan.md` and ` Roadmap | the plan .md`;
the control,
`anAliasedLinkToNothingMakesTheNoteItNames`, where a missing `[[Brand New|the
alias]]` makes `Brand New.md` (it made `Brand New|the alias.md`); and
`anAliasedWebLinkOpensItsAddress`. The suite's earlier eight pass unchanged.
The app suite passes (760 tests in 104 suites), and the app builds for macOS
and the iPad simulator.

The odd-run rule now has two copies — `NoteMarkdown.target` for Preview and
`withoutAlias` for following — which is one more reason for the single
MarkdownCore rule unimplemented.md §1 asks for (a table's `\|` is still read
into the target by the link graph, a rename's rewrite, the mind map,
`ComposedNote`, transclusions and Edit's colour), and the question of `\|`
outside a table is still open for every surface: following
`[[Note\|alias]]` written outside one now reaches `Note`, while Edit colours
it as `Note\`. Nothing else turns a link's text into a note's name: the other
callers of `createNote(title:)` are capture, the Assistant's tool, the composer
and the self-test.

### 51.36 Every open defect in the backlog, before 1.3.3 (2026-10-08 – 10-09)

The brief was "fix all issues before release", scoped to **every open 🟠/🟡 entry
in `docs/unimplemented.md` that is a defect in code** — data safety, correctness,
main-thread stalls, Swift 6 errors, missing tests — leaving features, and
anything that needs a device or a live account, to be listed. Each fix below was
written test-first where a test could see it, and each test was checked against
the defect it names: the fix reverted by hand, the test watched fail, the fix put
back. Where a check needed a second check (a type-check that can read clean
because it checked nothing, a pixel scanner that can find no ink), that check
was planted first. Several entries turned out to rest on a wrong premise, and
three new defects were found on the way; both are said where they occur.

#### Cloud collections

- **A refresh with no delta cursor walks** (unimplemented.md 🟠). A cursor is
  taken only at the end of a complete walk, so its absence means no walk has
  listed the whole folder — one stopped by a refused folder, a cancelled add, a
  quit. Asked for changes with no cursor, Dropbox and OneDrive answered with
  every entry, applied one by one on the main actor (0.32 s for 2,000), and Box
  and Drive with an empty position that was kept, so the folder the walk missed
  was never listed and the next refresh recorded a complete walk that never
  happened. `RemoteMirror.applyChanges` now walks instead; a walk runs off the
  main actor, prunes only when complete and takes its own cursor when it is
  (`DeltaRemoteStore.latestCursor`). Tests: `aRefreshWithNoCursorWalks`,
  `aRefreshNeverRecordsAWalkThatDidNotComplete`, and a budget test for the
  refresh after an incomplete walk.
- **A note made here and still empty is never taken for the provider's
  placeholder** (🟠). A new note is created empty and queues its first upload,
  so until that turn it had no record, and a walk or a delta that found the
  provider holding an item of the same name — two devices' "Untitled", today's
  daily note made on the phone — recorded it as a placeholder: its uploads
  refused, its typing downloaded over. What comes up is now reported before the
  file exists (`WaitingToGo`, beside what goes away), the walk, its apply and
  `applyChanges` pass it over, and the upload's turn clears it.
- **A download is recorded only at the revision it read.** `hydrate` read the
  bytes and marked the record downloaded without asking whether a walk had
  recorded a newer revision meanwhile; the next save then passed the conflict
  check and wrote over the provider's newer copy. It retries while the
  revision moves (`sameRevision`), and stages the bytes off the main actor
  (`FileIO.stage`), putting them in place with one coordinated rename
  (`FileIO.putInPlace`).
- **Token refreshes are single-flighted per account**, not per store:
  `RefreshCoordinator.byAccount`. Two collections on one Box or OneDrive account
  each spent the same single-use refresh token, and the loser's save failed with
  `invalid_grant`. The token cache is read again after an exchange fails (a
  token rotated by another process), and a refresh in flight at sign-out writes
  nothing back (`TokenCacheTests`).
- **Every provider's listing names the content's revision**: Box's `etag`,
  Drive's `headRevisionId` (not `version`, which metadata moves) and OneDrive's
  `eTag`, which its parser read and `$select` left out. Without them no save
  could tell a note had changed elsewhere since it was downloaded. Live runs
  against the providers are still for a person with accounts (unimplemented.md
  §8b).
- **The self-test removes what it leaves through the mirror**
  (`DiagnosticSelfTest.removeLeftover`); removed from the cache alone, the next
  walk put an empty placeholder back on the provider's behalf.
- **A large-folder prompt over an unanswered one answers the first**
  (`Library.openChecking`): replaced unanswered, the first caller waited
  forever.
- **Off the main actor**: the manifest is decoded once, at launch, and handed
  to the mirror (`RemoteMirror.open(…manifest:)`); eviction reads each
  download's last use there and asks each candidate again before writing; the
  scan folds the manifest into placeholders and sizes inside the walk
  (`dehydratedRelativePathsIfMoving`); `sendUnsent`'s path comparison runs
  there; the account's first Keychain read of the launch is warmed there; and a
  cancelled walk no longer waits for its head listing — for three providers the
  whole account's recursive prefetch (`ResumableTreeWalk.outcome(for:)` awaits
  under a cancellation handler; `ConcurrentTreeWalkTests`).
- **A walk's verdict cannot land over a recheck that just succeeded**
  (`Collection.recoveries`): a stuck walk's late `.permissionDenied` stood over
  Try Again's `.ready`, and a clean walk never cleared it.
- **A change seen during a walk asks for one more pass** instead of cancelling
  it (`reconcileIsWalking`, `rescanWhenIdle`): a cancelled walk keeps nothing,
  so changes through a long walk of a big vault kept it from ever finishing
  (`CollectionAvailabilityTests`).
- **`syncDown` and `pruneLocalItems` are gone**, with the four progress fields
  only they wrote. The eager sync lost its last caller to `syncMetadata`. Its
  tests guarded rules that ship — a failed subfolder costs its subtree, an
  incomplete or cancelled pass drops nothing, an unreadable root is not an empty
  folder, progress only climbs, an edit uploads — so they were ported to
  `syncMetadata` rather than deleted (`RemoteMirrorTests`; with both of the
  walk's deletion gates removed, two of them fail). The test of non-Markdown
  files skipped is obsolete: the mirror carries every file.

#### What reaches the file, and when

- **Every app write is a commit** (unimplemented.md §1). A tag, link or
  summary accepted, the link review, a rewrite, a restored version and a
  template changed the buffer and reached the file at the next flush;
  `EditorModel.applyEdit` now ends with the model's own save (`AppWriteTests`).
- **The Assistant edits an open note in its editor** (`ToolContext`,
  `openEditor`): the diff is made from what is on screen, unsaved typing
  included, and the change is made there and saved by the editor's own save,
  only if the screen still says what was read. Written to the file, it met the
  typing as a change made elsewhere. The inspector's "link this mention" does
  the same (`MentionLinker`), falling back to a conditional replace and telling
  the open editors (`AgentToolTests`, `MentionLinkTests`).
- **Closing a window waits for its save** (`FlushRegistry`): ⌘W then ⌘Q during
  a slow coordinated write ended the process with the save unfinished, because
  the hook came off before the flush began (`FlushRegistryTests`).
- **A reconcile that loads a note whose load failed clears the failure**, and
  `open` does not replace a buffer a refused flush left unsaved — it keeps it,
  or raises a conflict (`UnloadedNoteTests`, `ConflictSaveTests`). A tab whose
  save was refused stays open with its edit (`EditorTabs.close`).
- **Opening a note asks the file provider off the main actor**
  (`EditorModel.willOpen`/`open`), and `EditorModel.init` adds itself to the
  weak table inside an autorelease pool: the table's `add` autoreleases, so an
  editor outlived its owner until the run loop drained
  (`ExternalChangeTests.anEditorGoesWithItsLastOwner`).
- **Rename, duplicate and move ask whether a name is taken off the main
  actor**, as `createFolder` makes its folder there; on a File Provider's
  folder each is a round trip.

#### Wiki links: one rule

`MarkdownCore.WikiLinkSyntax` is what a link names, for every reader: the alias
begins at the first `|`, and an odd run of backslashes before it is the escape a
table's row needs (`[[Note\|alias]]`), not the target's. Preview and following a
link dropped the backslash; the link graph, a rename's rewrite, the mind map, a
composed note, Preview's transclusions and Edit's colour kept it and named
`Note\`. Edit's table and Preview's agreed on a row only until `\\|`:
`GFMTableLayout` now scans a row as cmark-gfm does. A link clicked in Preview
follows the app's navigation (`hellonotes-wiki:` on both surfaces,
`PreviewLinkRelay`): the web view had no navigation delegate, so a wiki link went
nowhere and a web link replaced the preview. And Preview redraws when a note it
transcludes changes: the revision now travels with the cards
(`CollectionEmbedProvider.revision`), where Preview had been handed a revision
that was always 0 on the main window's path (`WikiLinkSyntaxTests`,
`GFMTableLayoutTests`, `NoteMarkdownTests`, `WikiLinkColourTests`,
`PreviewLinkTests`, `EscapedAliasLinkTests`, `TransclusionRedrawTests`).

#### The editor's parser

**Incremental parsing converges** (🟠, deferred until now as "the parser every
other feature sits on"). The walk stopped only where nothing at all was open,
which in prose is almost nowhere — a blank run is open between paragraphs, the
item above between items — so a keystroke near the top of a note of paragraphs
re-walked it to the end: 4,496 lines a keystroke in a 1,500-paragraph note.
It now stops where it stands exactly where the old walk stood: the same block
open, started at the same line past the edit, and the same list item behind it
(`BlockBuilder.resumption`), the old walk's state read off the block before the
candidate. Every shape of note settles within 3–7 lines; a keystroke on 1 MB is
0.32 ms in Release. Two older bugs, both incremental-differs-from-full, were
found by the stronger fuzz the change needed: the walk started knowing nothing
above it, so `- a`, a blank line and `    - foo` was an item in full and a code
block the moment anyone typed on its last line (`itemBefore`); and the
classifier measured an empty item's content column (`*` or `1.` alone) by
reading past the end of its line into a buffer still holding the line
classified before. Tests: `IncrementalConvergenceTests` (16 shapes, structural
edits, two targeted), the prose-and-lists fuzz over four seeds, and
`anEmptyItemsColumnDoesNotDependOnTheLineAbove`; four controls, each caught.

#### A table's picture, and spec #31

- **`<br>` breaks a cell's line**, at its natural size and squeezed, and the
  row grows by a line; a trailing `<br>` starts no line, an opening one leaves
  an empty one, as on the page. Other inline tags are not drawn —
  `H<sub>2</sub>O` is "H2O", where the picture drew eleven characters of
  source. Figures are tabular, as GitHub's `table { font-variant: tabular-nums }`
  has them. And a cell's text sits where the page puts it: each line was
  centred on `size().height`, which rounds the font's extent up (19 for the
  system font at 16pt against the 18 both engines lay a line on), so every
  cell's baseline was half a point high — measured at 2× against WebKit before
  and after, pixel-identical now. Tests in `GFMTableInlineMarkupTests`
  (`aBreakTagBreaksTheCellsLine`, `aBrokenCellWrapsEachLineOnItsOwn`,
  `otherInlineTagsAreNotDrawn`, `figuresInATableAreTabular`,
  `aCellsBaselineIsWhereThePageDrawsIt`, which draws at 4× on both platforms),
  and a document for the gate (`37-table-breaks-and-figures.md`, −143.84pt with
  `<br>` turned off). Maths and pictures *inside* a cell are still drawn as
  their source; drawing them is new work and is listed as such.
- **Spec #31**, `- Foo` / `- * * *`, stood 24pt taller in Edit, bare and in
  context — and in the committed tree too: macOS 27's WebKit collapses an
  `<hr>`'s bottom margin out of a `<li>`, which is what CSS 2.1 says it does
  (the `display: table` pseudo-elements sit *inside* the rule and seal
  nothing). The kept margin and its attribute are gone, and an item-closing
  rule leaves its margin to `BlockBoxes.gapBetween`, which already exported it.
  Both sweeps are 672/672 again. The lesson is in the package's CLAUDE.md:
  re-run both sweeps after an OS bump.
- **The harness's pictures are cropped to whole points**: a fractional crop
  shifted the editor's capture by up to half a point, and read as a table drawn
  a pixel low when it was not.

#### Heading jumps wait for their editor

A jump is kept for its editor (`EditorBus.requestHeadingJump`) and shown by the
first surface of it that is ready (`HeadingJumpListener`: the editor's text view
when it reaches a window, Preview when its page finishes loading, the Markdown
pane). Following `[[Note#Heading]]` waited a fixed 350 ms for the new tab and a
tab that took longer scrolled nowhere; and a timer cleared a "highlight" 1.2 s
after every jump — there was none, a jump leaves a caret — collapsing whatever
selection there was by then and dropping the find bar's query. Both timers are
gone (`HeadingJumpTests` in the package and the app).

#### The window, the bar and the menus

The UI defect registers (ui.md §12, primary.md §12, secondary.md §9,
toolbars.md §14, menu.md §8, tabs.md §2.5) had their defects fixed; each fix
carries its register's item number in a comment. Among them: one stored value
for the sidebar's visibility (a relaunch showed the sidebar under a bar saying
Show Sidebar); the rail follows the focus when its collection closes; New Note
goes to the band's folder only while the band shows; a collection row says what
the sidebar's rows say; every divider is named for what it sizes; the
inspector's commands run when it appears holding one; a note's views say so
with no note open; Escape closes the panel only where it covers the note; an
attachment opens in the viewer, never an editor tab; editors follow a renamed or
moved note, keeping caret and undo (`EditorDocumentStore.documentMoved`);
closing a collection closes its tabs by every route; Open Quickly searches the
sidebar's collection and is ⇧⌘O; the palette closes before a command that puts
something over it; About and Acknowledgements work with no window open
(`WindowRequest`); a note found in Spotlight has an intent to open it
(`OpenNoteFromSearchIntent` — the system's half wants a live check on a device);
values the shell published and nothing read are gone. Design questions those
registers also hold — the tab bar's redesign, column widths — are features and
stay listed.

#### Main-actor work

Off the main actor now: Open Quickly's scoring (about 20,000 items a query), the
Tags view's counts (folded with the index — 40 ms at five tags a note), the
mind map's layout, Properties' front matter (no further than the editor folds),
the transclusion cards' reads (with a bounded cache, `BoundedCache`), a pasted
picture's write, launch's bookmark resolution and Try Again's and Relocate's
(`Bookmark` is `nonisolated`), and `EditorDocument.make`'s whole-document parse,
which was `async` in name only. The budget suite holds the first of them.

#### Security

**The web tools' address check holds against DNS rebinding.** `validate`
resolved the host and URLSession resolved it again to connect, so a short-lived
answer could be public for one and `169.254.169.254` for the other.
`WebGuard.load` reads the body whole and checks the address every connection
was made to (`URLSessionTaskMetrics`) before any of it reaches the model
(`WebGuardTests`). Every fetch the web tools make goes through it.

#### Concurrency and Swift 6

The app type-checks as Swift 6 with no errors (it had 16, and this work added
four, all fixed): `ResumableTreeWalk.run` is `@concurrent` — a plain
`nonisolated async` function runs where its caller is, and a walk called from
the main actor listed folders on it (`aWalkCalledFromTheMainActorWalksOffIt`,
which probes the listing); `FileWatcher` and the iOS `DirectoryPresenter` are
`nonisolated`, since a `deinit` calls `stop()`; the accent's colour maths is
`nonisolated`, since a dynamic colour resolves wherever it is drawn; the two
regex caches are `nonisolated(unsafe)` over a thread-safe `NSCache`;
`URLRouter.scheme`, `StoreService`'s listener task and `RailPlaceStorage` say
what they are; and `VisionAlt` decodes a pasted picture off the main actor,
through `FileIO`. A deliberate error planted in a file under review was
reported, so the clean run checked what it says.

#### Git

**Push has a Stop.** SwiftGitX's push ends in `git_remote_push(remote, nil,
nil)`: no options, so no callback through which a cancel can reach libgit2 —
which is why Clone, whose SwiftGitX call installs one, could always stop and
Push could not, and why Create's Stop could stop everything but the push it
ends in. `GitPush` is the same push written against libgit2 (SwiftGitX's own
dependency, pinned to one version), with callbacks that answer "stop" once the
task is cancelled; `GitService.push` runs it on a cancellable runner, the pane
offers Stop while it runs, and Create pushes through it too. What no callback
can stop is a connect that never completes. `GitPushTests` pushes to a real bare
repository and stops one; with callbacks that never stop, the stopped push
completes and the test fails. The Git suite runs on a two-note vault instead of
a copy of the sample vault each test.

#### The Assistant, on Apple's model

`AssistantEditEvaluation` asks for a one-line change, approves it and reads the
file. It had only ever run on two MLX models; §51.2's table has a dash for the
on-device model. On the on-device model it failed every time, for three reasons,
each found only after the one before it was fixed:

- **Its setup filled no search index.** `collection.scan()` lists the notes and
  indexes nothing; in the app the index is filled by the rebuild that opening a
  collection starts. So `search_notes` found no Shopping note, and the model
  said so. The setup now fills the index, as the trajectory evaluation's always
  did.
- **The tool had the same blind spot in the app.** The index holds only notes it
  has read: none until that rebuild lands, and never a note that hasn't
  downloaded. So a note `list_notes` showed was "not matched" by its own name.
  `search_notes` now also matches titles from the collection's own list
  (`searchFindsANoteByTitleTheIndexHasNotRead`).
- **The model asked for approval in words.** Told that "the person approves
  every change", it read the note and replied "Please confirm this is correct",
  four requests out of four. It never called `edit_note`, so a requested change
  took two approvals, or none. The instructions and the tool descriptions now
  say that calling the tool *is* the request: the app shows the change and saves
  it only if the person approves.
- **It restated the lines around the change.** Calling the tool now, it sent
  `- pears` to replace and `- apples\n- plums\n- flour` as the replacement, four
  times in five: the surrounding lines were in one argument and not the other.
  The note gained a second "apples" and a second "flour", and the evaluation
  still passed, because it checked only that "apples" and "flour" were there. It
  now checks the whole note.
  Rewording the argument guides changed nothing (four in five again). So
  `edit_note` now treats lines its replacement restates on *both* sides of the
  match as context, not as text to add (`EditReplacement`). One side alone is
  written as given, because that is also how an insertion looks; only whole
  lines count; and the person still approves what results. Tests:
  `EditReplacementTests` (four) and
  `anEditThatRestatesItsSurroundingsChangesOneLine`; with the change reverted,
  three of them fail.

With all of these fixed, every evaluation passes three runs out of three on the
on-device model (18 of 18), including the trajectory evaluation's "never edits
unasked". The research probe completes: a plan, two sub-questions and a
write-up, in 42 s.

The evaluations and the probe both named their defaults suites the old way, and
`HelloNotesEvaluations.plist` was sitting in the container's Library/Preferences.
Both now keep their settings out of the person's preferences, and
`noTestNamesASuiteThatLivesInPreferences` scans the tests for that pattern.

#### Tests and the suite

- **The test host opens no window** (`Scene.suppressedUnderTests`): every run of
  the suite opened the main window on the person's screen and took focus
  (`TestHostTests`; without the change it reports `main-AppWindow-1`).
- **The tag tree is gone**: every index fold built one, and nothing showed it.
- The flows the backlog asked smoke tests for are covered end to end through the
  real services — external changes (`ExternalChangeTests`, `ConflictSaveTests`,
  `WhoseTextWinsTests`), rename with its links (`EscapedAliasLinkTests`,
  `CollectionFileOperationTests`, `TabsFollowMovesTests`), Git commit and push,
  and an approved Assistant edit (`AgentToolTests`) — and the data-safety paths
  §1 named have theirs.
- **Stale**: Open Quickly on iOS was already fixed; and "the universal slice is
  verified by hand" has no slice to verify — at a macOS 27 deployment target
  Xcode 27 builds `arm64` alone, and macOS 27 runs only on Apple silicon. The
  release runbook says so; the website's "Apple silicon & Intel" belongs to
  1.3.2 and changes with 1.3.3's site.

#### Found by the final checks

- **The iOS build crashed the compiler.** Making the iOS `DirectoryPresenter`
  `nonisolated` (above) left `accommodatePresentedSubitemDeletion(at:)` written
  as `async throws`, and SILGen crashed emitting its Objective-C thunk. The
  class is iOS-only, so no macOS build, test or type-check could see the crash;
  the interface tests' build did. It now implements the completion-handler
  form, as its sibling `accommodatePresentedItemDeletion` does.
- **The test bundle stopped building for iOS.** `PanelRequestTests`, new in this
  work, imported AppKit without a platform guard. On iOS it now hosts its panel
  in a UIKit window, and it passes on the iPhone simulator.
- **No commit could be made where the account has no name.** When neither Git
  Settings nor any Git configuration gives an identity, a commit is signed with
  the account's name. The iOS simulator's account has none, so libgit2 refused
  every commit ("Signature cannot have an empty name or email").
  `GitService.fallbackIdentity` never returns an empty name
  (`GitIdentityTests`), and `GitPushTests`, which failed on iOS for exactly this
  reason, now pass there.
- **Warnings.** In app code, the Release build is down to one warning:
  dictation's tap API, deprecated in 27. It is recorded in unimplemented.md §11,
  because its replacement takes a different buffer range and needs a microphone
  to test. These warnings were settled:
  - Vision's request handed to its queue (`nonisolated(unsafe)`, with a comment
    saying why).
  - `RemoteMirror.defaultCacheLimit`, a constant used as a default argument.
  - Two deliberate discards in `DocumentLoad`.
  - Three in the package that predated this work.

  Four Swift 6 warnings remain: `SpotlightSearch`'s `finishOnce`,
  `DiagnosticSelfTest`'s quit, `CommandPalette`'s block and `Chrome`'s
  `capRatio`. Each is a main-thread callback or a constant the compiler cannot
  see through, and none is a race at runtime.

#### Verification (2026-10-09, on the final tree)

| Check | Result |
|---|---|
| App suite (`run-tests.sh`) | 830 tests in 124 suites, pass |
| Editor package, macOS | 506 in 51 (289/31, 191/16, 26/4), pass |
| Editor package, iOS (`HN-iPad`) | 487 in 49 (270/29, 191/16, 26/4), pass |
| iOS interface tests (`HN-iPhone`) | 13 cases: 12 pass, and the opt-in window-parity capture skips |
| This work's new suites, on iOS | PanelRequest, HeadingJump, AgentTool, EditReplacement, ScratchDefaults, GitPush, GitIdentity: pass |
| Model evaluations, on-device, three runs | 18 of 18 |
| Research probe | pass, 42 s |
| Main-actor budget suite | 17, pass |
| Spec sweeps, bare and `PARITY_CONTEXT=1` | 672/672 each |
| `render-parity.sh` | ok: 5 sizes × 3 widths; 60/60 documents at 1200, 800 and 560; at 420 the known two only; chrome ok |
| `chrome-parity.sh` | 16 scenes ok, worst Δ6 on 0.003% |
| Swift 6 type-check | 0 errors; a planted error reported, in each of two files |
| Release, macOS | builds; app and its three extensions are arm64 only |
| Release, iOS (generic device) | builds; arm64 |

One gate was not run: `window-parity.sh`. It quits the person's running app and
relaunches it, and a cloud collection restored from `remoteCollectionCaches`
would be in the capture.

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
