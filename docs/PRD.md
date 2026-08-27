# HelloNotes — Product Requirements Document

> Product name: **HelloNotes** · Status: **v1.3.2** (version bumped in a 2026-08-25
> doc-currency pass; content below was spot-checked, not re-verified line-by-line —
> see `docs/implemented.md`'s "Current status" for what shipped after v1.3) ·
> Last substantively updated: 2026-08-16 · Owner: Chris Tham

---

## 1. Overview

HelloNotes is a **native, local-first Markdown knowledge base for the Apple ecosystem** — a fast, tactile alternative to Electron apps like Obsidian and cross-platform editors like Typora. Notes are plain `.md` files in a folder ("the vault"); that folder is the single source of truth. It can sit on local disk *or* in a cloud provider's folder (Box, Dropbox, OneDrive, Google Drive, iCloud), where files stay online-only until opened — either way it's still just files you own. There is no proprietary database and no cloud lock-in. Synchronisation happens invisibly through Git.

The product bet: a knowledge tool built on **AppKit + TextKit 2 + SwiftUI** can deliver editing latency, scroll performance, and OS integration that web-tech competitors structurally cannot, while keeping the user's data in an open, portable, greppable format they fully own.

This document defines the product vision, the users, the feature set shipped in **v1.0** (the original v0.1 MVP plus the post-MVP feature areas), and what remains on the roadmap. Technical design lives in [architecture.md](architecture.md); the build history lives in [implemented.md](implemented.md).

## 2. Problem statement

Knowledge workers who write in Markdown face a trade-off today:

- **Obsidian** is powerful and local-first, but Electron-based: heavy memory use, non-native text handling, and a plugin ecosystem that trends toward complexity.
- **Typora / Vellum** offer a beautiful focused writing experience, but are single-document-centric and weaker as a linked *knowledge base*.
- **Bear / Apple Notes** are native and fast, but store notes in opaque databases — the user does not own portable files, and Git-based versioning is impossible.
- **VS Code + Markdown** is developer-friendly but is a code editor, not a writing environment.

No tool today combines: **(a)** genuinely native macOS performance and feel, **(b)** plain-files-on-disk ownership, **(c)** first-class Git sync, and **(d)** a linked knowledge graph (`[[wiki-links]]` + backlinks).

## 3. Target users & personas

| Persona | Description | Primary need |
|---|---|---|
| **The Developer-Writer** (primary) | Engineers who keep technical notes, design docs, and daily logs in Markdown and already live in Git. | Native speed, code-block fidelity, Git sync they trust, files they can `grep`. |
| **The Researcher / PKM enthusiast** | Academics and note-takers building a "second brain" of interlinked notes. | Wiki-links, backlinks, math, fast search across a large vault. |
| **The Obsidian refugee** | Users who value local-first but want native performance and OS integration. | Import an existing vault of `.md` files and have it "just work". |

**Anti-persona:** users who want a hosted, collaborative, real-time multiplayer doc (Notion/Google Docs). HelloNotes is single-user, local-first, async-sync.

## 4. Goals & non-goals

### Product goals
1. **Own your data** — every note is a human-readable `.md` file; the vault is a normal folder that works with Finder, Git, and any other tool.
2. **Native performance** — sub-frame typing latency; smooth scrolling on large documents; low memory footprint.
3. **Frictionless capture & edit** — open the app, land in a note, type. Auto-save; never lose work.
4. **Linked thinking** — `[[wiki-links]]` and backlinks make the vault a graph, not a pile of files.
5. **Invisible sync** — Git commits/pulls happen in the background without the user thinking about Git.

### Non-goals (explicitly out of scope)
- No proprietary storage: **no CoreData, no SwiftData, no iCloud document store.**
- No WebViews / Electron / embedded browser in the *editing path* (Mermaid, math, code, callouts, and transclusions all render natively in the editor). The read-only **Preview** and the **Marp slides** preview do use a `WKWebView` — the Preview intentionally renders through cmark-gfm for GitHub-identical output — but the live editor itself never does.
- No real-time collaboration or hosted backend.
- No plugin runtime in the MVP (extensibility is a deliberate later question, à la Vellum's "pure editor" stance).
- No proprietary sync service — sync is the user's own Git remote.

## 5. Product principles
1. **The file system is the truth.** UI state is a projection of disk; disk is never a projection of a hidden DB.
2. **Native or nothing.** If a feature would require a WebView, we find the native path or defer it.
3. **Fast is a feature.** Latency and jank are bugs.
4. **Portable by default.** A user must be able to walk away with their folder and lose nothing.
5. **Progressive disclosure.** Simple by default; power features stay out of the way until summoned.

## 6. Competitive reference — Vellum
[Vellum](https://github.com/wzzc-dev/vellum) (a Rust/gpui Typora-style editor) is a strong reference for the *editing experience* we want to match natively. Features we draw from it:

- Live WYSIWYG Markdown with a source ⇄ preview toggle.
- File tree in the sidebar with sort options (name, natural, modified time), rooted at each open collection.
- Multi-tab editing in one window.
- Workspace-wide search (incl. hashtags) and "Open Quickly" for files/headings.
- Native Mermaid, math, code highlighting, tables, task lists, footnotes.
- Auto-save, command palette, find/replace, front-matter panel, external-change detection.

Where we **diverge**: HelloNotes adds the *knowledge-graph* layer (wiki-links + backlinks) and *Git sync* that Vellum intentionally omits, and targets the Apple-native stack rather than Rust/gpui.

## 7. Feature requirements

Priority: **P0 = MVP**, **P1 = fast-follow**, **P2 = roadmap**. **v1.0 shipped P0–P2** across the board on macOS, plus the post-MVP feature areas in the status box (see [implemented.md](implemented.md) for the build history).

> ### ✅ Implementation status — v1.0 (shipped)
>
> *v1.1 changed no feature scope.* It reshaped the shell — collections and
> folders became one tree in a single collapsible sidebar — and fixed defects;
> see [CHANGELOG.md](../CHANGELOG.md). The list below is still the feature set.
> **Library & files:** a **multi-collection library** (several vaults open at once) with launcher, recents, and saved library sets; **Obsidian vault import**; persistent security-scoped bookmarks; Markdown indexing; create/rename (with link rewrite)/duplicate/delete (to Trash); nested folder tree with sort + **drag-and-drop moving** + empty-folder creation; external-change detection + conflict handling; image paste → `assets/`; **smart paste** (HTML → Markdown); non-Markdown attachments (PDF/image/CSV/other) in a native **file viewer**.
> **Editor:** live TextKit 2 Markdown (bold/italic/code, headings, lists, task lists, quotes, tables, footnotes), **view modes** (Edit / native read-only Preview / Markdown source / Split), debounced atomic autosave + saved indicator, syntax-highlighted code, LaTeX math, **inline native Mermaid**, Obsidian-style **callouts** (collapsible, iconed) + `%%comments%%` + hidden front matter, **note transclusion** `![[Note]]`/`![[Note#heading]]`, **⌘F find & replace**, **scroll-to-heading** (outline, links, search), multi-tab editing, open-in-new-window, document statistics, outline, HTML/PDF export, editable typed **properties**, **Marp slide decks**, and a full **Format menu**.
> **Knowledge graph:** `[[wiki-links]]` (clickable, create-on-miss) with **autocomplete**, **aliases**, **link-to-heading** completion, backlinks + **outgoing links** + **unlinked mentions** (one-click link), a directional **Graph** view (arrowed edges, click-to-trace focus, whole-collection or around-a-note scope), and a content-based **Mind Map** of a note's ideas.
> **Search & nav:** title filter, full-text search with snippets, Open Quickly (⇧⌘O) over notes/headings/aliases, tags + **nested tags** tree + **tag autocomplete**, **bookmarks**, **daily notes** + **templates**.
> **AI (optional):** on-device Apple Intelligence (summarise / suggest tags / suggest links), **Ask Library** retrieval chat with citations, an agentic **Assistant** (tools incl. web search/fetch, note editing behind explicit approval, skills, deep research), and pluggable providers — local (Apple, MLX, Ollama, LM Studio) or the user's own cloud key (Anthropic, OpenAI-compatible, Gemini). Keys in the Keychain; no developer backend.
> **Git:** repo status, init, local commit, opt-in auto-commit (never auto-pushes), push/fetch, per-note **version history** (browse + restore), **clone** + **create-remote** with HTTPS token auth (Keychain), in-app git identity.
> **Platform:** macOS adaptive shell (width/aspect-driven; see layout-architecture.md) with full menu bar, windowed Graph/Mind Map/Assistant/Ask Library, appearance settings (theme/accent/text size), launch splash with build info; iOS/iPadOS runs the same shell sharing Core/State, with the full four view modes.
> **System integration** *(added 2026-07-19/20 — [native-roadmap.md](native-roadmap.md))*: App Intents (`NoteEntity` + Siri/Shortcuts), Spotlight donation, a recent-notes **widget**, **Quick Look** preview + thumbnail extensions, menu-bar quick capture + global hotkey, `hellonotes://` URL scheme, Services menu, state restoration, TipKit, on-device dictation (SpeechAnalyzer) and Foundation Models `@Generable`.
> **Cloud storage** *(added 2026-07-20/21 — [cloud-native-roadmap.md](cloud-native-roadmap.md))*: a vault folder may live in **Box, Dropbox, OneDrive (personal/business), Google Drive or iCloud** via Apple's File Provider layer, with files kept **online-only until opened** (coordinated I/O + dataless-aware indexing); or an account can be connected **directly over its own API** (four built-in clients, no vendor SDKs) and promoted to a first-class collection in the sidebar.
> **Deferred** (engine walls / roadmap): create-on-miss from an in-editor muted link click, git pull/merge + conflict UI, richer iOS editor — see [unimplemented.md](unimplemented.md).

### 7.1 Vault & file management
- **P0** Select a vault folder; remember it across launches (security-scoped bookmark).
- **P0** List/browse `.md`, `.markdown`, `.mdown` files in the vault.
- **P0** Create a new note; rename; delete (to Trash, not hard-delete).
- **P1** Nested folder tree with expand/collapse and sort (name / modified).
- **P1** Detect external file changes and reconcile (reload / conflict prompt).
- **P2** Drag-and-drop and paste images into a configurable asset folder.

### 7.2 Editor (the core)
- **P0** Open a note into a live TextKit 2 Markdown editor (`Packages/NotesEditor`).
- **P0** Live inline formatting (bold/italic/code), headings, lists, task lists, quotes.
- **P0** Auto-save edits back to the file (debounced), with an unsaved/saved indicator.
- **P0** Syntax-highlighted fenced code blocks (HighlighterSwift, GitHub theme).
- **P1** Inline and block **LaTeX** math (SwiftMath, rendered to images).
- **P1** Source ⇄ live-preview toggle; find/replace within a note.
- **P2** Tables editing UX, footnotes, front-matter panel.

### 7.3 Knowledge graph
- **P1** Parse `[[wiki-links]]`; click to navigate (create-on-miss).
- **P1** Backlinks panel: "notes that link here", computed asynchronously.
- **P2** Tags (`#tag`) index and filtering.
- **P2** Local graph view.

### 7.4 Search & navigation
- **P0** Filter the note list by title.
- **P1** Full-text workspace search.
- **P1** "Open Quickly" fuzzy finder for files and headings (⌘O / ⌘P).
- **P2** Multi-tab editing.

### 7.5 Git sync
- **P1** Detect that the vault is (or can be) a Git repo; show status.
- **P1** Background auto-commit on a debounce; manual "Sync now".
- **P2** Push/pull to a remote; surface and resolve merge conflicts.

### 7.6 Rendering (native, no WebView)
- **P1** Mermaid diagrams rendered natively (beautiful-mermaid-swift).
- **P1** Math (SwiftMath). **P0** Code highlighting (HighlighterSwift).

### 7.7 Platform
- **P0** macOS 15+ **adaptive shell** — one width- and aspect-driven layout, not a fixed 3-column split.
  See [docs/layout-architecture.md](layout-architecture.md) and [docs/wireframes.html](wireframes.html).
- **P2** iOS/iPadOS uses the **same shell**, sharing the Core/State layers — device identity is never
  consulted, because Stage Manager makes it meaningless (an iPad window can be 320pt or 1600pt wide).

## 8. Key user stories (MVP)
1. *As a new user,* I pick a folder of Markdown files and immediately see them listed, so I can start working with my existing notes.
2. *As a writer,* I click a note and type; formatting renders live and my changes save automatically, so I never think about saving or lose work.
3. *As a developer,* I paste a code block and it's syntax-highlighted natively, so my technical notes are readable.
4. *As a returning user,* I reopen the app and my vault and last note are still there, so I resume instantly.
5. *As a note-keeper,* I create and delete notes from within the app, and the changes are reflected as real files in Finder.

## 9. UX overview

The shell follows the **axis of abundance**, not the device. Full design in
[docs/layout-architecture.md](layout-architecture.md); wireframes for every size in
[docs/wireframes.html](wireframes.html).

| Available space | Shell | Navigation lives |
|---|---|---|
| `width ≥ 1400` | Wide + inspector | left rail · list · right inspector |
| `width ≥ 960` | Wide | left rail · list |
| `width ≥ 600`, taller than wide | Tall | a band across the top |
| `width 600–960`, landscape | Two | list column; library retracts to an overlay |
| `width < 600` | Compact | bottom tab bar + retracting mini-note strip |

**The two rails.** The left rail answers *"where is it?"* and holds **places only** — a Library place, then
one row per open collection, with Git pinned at the bottom. It is a 64pt switcher, and its selection scopes
the note list to that collection's folder tree; commands, bookmarks and recents are library-wide and live in
the Library place instead. The right **inspector** answers *"what is this, and what touches it?"* — tabbed
**Outline · Tags · References · Properties · History**.

**Priority under pressure:** `text > switching > list > library > references > properties`. Navigation
yields first; the note is the last thing to shrink and the last to disappear.

**Panes and tabs are one job at two sizes.** Where there is width, a pane can be split so two notes sit
side by side (manually — never automatically). Where there is not, **tabs** are the way to switch, so they
become *more* important as the screen shrinks, not less. Switching is never removed.

**Reading is not editing.** Reading holds a fixed, centred measure (default 80 characters), because line
length decides reading comfort. Editing **fills the pane, left-aligned — the VS Code model** — because a
fixed column inside a 3200pt pane is 17% of the display, and a Markdown editor should use the workspace it
was given. Tables, code, Mermaid, math and images always take the full pane width.

## 10. Success metrics
- **Performance:** typing latency < 16 ms (60fps) on a 5k-word note; vault scan of 1,000 notes < 300 ms.
- **Reliability:** zero data-loss incidents in auto-save across a test corpus (crash/kill during edit → file intact).
- **Fidelity:** a round-trip open → edit → save produces a byte-diff limited to the user's actual change (no reformatting of untouched content).
- **Adoption proxy:** an existing Obsidian vault opens and is fully browsable/editable with no migration step.

## 11. Constraints (from project rules)
- Target: **macOS 15+ / Swift 5.10+ / Xcode 26**; multiplatform-ready.
- State via the **`@Observable` macro only** (no `ObservableObject`/`StateObject`).
- **No CoreData/SwiftData** — the file system is the source of truth.
- Git via **SwiftGitX** (async/await).
- Every code change must compile clean (0 errors) before it's considered done.

## 12. Open questions
1. **Preview model:** ✅ *Resolved (v1.0)* — always-live inline styling remains the default, joined by explicit view modes (Edit / native read-only Preview / Markdown source / Split).
   ✅ *Width model (v1.1)* — **Reading** uses a fixed centred measure (default 80ch, user-configurable);
   **Editing** and **Source** fill the pane left-aligned, with an optional wrap *guide* line (off by
   default) rather than a hard column. Blocks always take the full pane width.
2. **Auto-commit cadence:** ✅ *Resolved* — opt-in debounced auto-commit plus a manual Commit/Sync; never auto-pushes.
3. **Wiki-link create-on-miss:** ✅ *Resolved (v0.1)* — new linked notes are created in the vault root. (Configurable location is a possible later refinement.)
4. **Extensibility:** *Open* — still holding Vellum's "pure editor" line; no plugin surface in v1.0. (AI "skills" — Markdown instruction notes in the collection — cover part of this space without a plugin runtime.)
5. **iOS timing:** ✅ *Largely resolved* — Core/State are platform-agnostic and shared; iOS ships as a browse/preview/plain-text-edit companion. A rich iOS editor remains future work (see [unimplemented.md](unimplemented.md)).
6. **Heading navigation & embeds:** ✅ *Resolved (v1.0, in the `Packages/NotesEditor` editor)* — scroll-to-heading works everywhere (outline, `[[Note#heading]]`, search) and `![[transclusion]]` renders inline cards; see [implemented.md](implemented.md).
