# HelloNotes — Architecture & Technology Evaluation

> Status: **v1.0 release candidate** · Last updated: 2026-07-13 · Companion to [PRD.md](PRD.md) and [implementation-plan.md](implementation-plan.md)
>
> **Post-v0.1 addendum (2026-07-13).** The shipped code has evolved past the names below:
> - **Renames:** the single "vault" became a **collection** inside a multi-collection **Library**. `WorkspaceIndexer` → `State/Collection.swift` (+ `State/Library.swift`, `LibrariesStore`, `RecentsStore`); `VaultSearchModel` → `CollectionSearchModel`; `Core/VaultTree` → `Core/CollectionTree`; `UI/VaultTreeRow` → `UI/NoteOutlineList`; `VaultWikiLinkResolver` → `CollectionWikiLinkResolver`; `VaultEmbedProvider` → `CollectionEmbedProvider`. Note windows key on `NoteRef` (not `URL`), and a `MindMapRef` window group exists alongside.
> - **New layer: `HelloNotes/LLM/`** — providers (Anthropic, Gemini, OpenAI-compatible, MLX, Apple Foundation Models) as `Sendable` Core-tier adapters, plus State-tier `@MainActor @Observable` models (`LLMSettings`, `AssistantModel`, `SkillStore`, `PermissionBroker`) and an agent runtime (tools, skills, deep research, permission broker). API keys live in the **Keychain** (`LLMKeychain`); chat transcripts persist as JSONL under Application Support (`ChatSessionStore`) — the only app data written outside the collection folders and UserDefaults.
> - **WebView exceptions:** the guiding principle below ("zero WebViews") now excepts the optional rendered Preview/Split mode (`UI/MarkdownWebView.swift`) and Marp slides (`UI/SlidesView.swift`). The editor remains native TextKit 2; the file viewer uses QuickLook/PDFKit (native).
> - **New dependencies** not in the table below: `OpenAI` (client used by the OpenAI-compatible provider), `mlx-swift` + `Tokenizers`/`Hub` (local models). Git operations are FIFO-serialized inside `GitService` (task chaining), not via a Swift `actor`.

This document describes the software architecture of HelloNotes and evaluates the third-party Swift packages the app depends on. For each capability we consider the realistic alternatives, then give a recommendation. As of **v0.1**, all packages below are resolved **and linked**, and the 4-layer architecture is fully in place across macOS and iOS; this document reflects the shipped design.

---

## 1. Architectural overview

HelloNotes uses a strict **4-layer architecture** so that the macOS app today and the iOS app later can share everything except the platform shell. Data flows in one direction: the file system is the source of truth, the Core layer reads/writes it, State projects it as observable values, and the UI renders State.

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 4 — Platform Shells                                   │
│    macOS: NavigationSplitView (3 columns)                    │
│    iOS:   NavigationStack (push)          [#if os(...)]       │
├─────────────────────────────────────────────────────────────┤
│  Layer 3 — Shared UI Components                              │
│    Editor host (MarkdownEngine), note list rows, backlinks   │
│    panel, search field, status/sync indicators               │
├─────────────────────────────────────────────────────────────┤
│  Layer 2 — State Management  (@Observable)                   │
│    WorkspaceIndexer (vault + notes), EditorModel (open doc,  │
│    autosave), LinkGraph (wiki-links/backlinks), GitService   │
├─────────────────────────────────────────────────────────────┤
│  Layer 1 — Core / Domain  (pure Swift, UI-agnostic)         │
│    VaultStore (FileManager + security-scoped bookmarks),     │
│    MarkdownParsing (swift-markdown AST), GitEngine           │
│    (SwiftGitX), FileWatcher (DispatchSource/FSEvents)        │
└─────────────────────────────────────────────────────────────┘
             ▲                                   │
             │  reads/writes                     │ observes
             └──────────  File System (the vault, .md files)
```

**Rules that keep the layers honest**
- Layer 1 imports **no SwiftUI/AppKit** (except where a package forces it) — it is unit-testable in isolation.
- Layer 2 is the only place that holds mutable app state, and it uses the **`@Observable` macro exclusively** (no `ObservableObject`).
- Layers 3–4 never touch `FileManager` or Git directly; they call into State.
- Long-running work (scan, parse, Git, file-watch) runs off the main actor and hands results back via `@MainActor`.

## 2. Concurrency model
- The app adopts Swift structured concurrency (`async/await`, `Task`).
- **@Observable models are `@MainActor`.** They spawn detached work for scanning, parsing, and Git, then mutate observable state back on the main actor.
- Autosave is **debounced** (write coalesced ~500 ms after the last keystroke, plus a flush on note-switch / app-resign / termination) to avoid write amplification and data loss.
- Git operations are serialized through a single actor (`GitService`) so commits/pulls never overlap.

## 3. Data model (Core / State)
- `Note` — value type: `id` (== `fileURL`), `title`, `fileURL`, `lastModified`.
- `WorkspaceIndexer` — the selected vault root URL plus its security-scoped bookmark, and the scanned `[Note]`.
- `EditorModel` — in-memory editing buffer: `text`, `isDirty`, `lastSavedText`, `savedRevision`, plus conflict state; debounced atomic autosave. `EditorTabs` holds one per open note.
- `LinkGraph` — resolves link targets through **titles and `aliases:`**, indexed **by note URL**: `backlinksByURL`, `outgoingByURL`, and a `resolution` map (title/alias → URL). Rebuilt asynchronously on change.
- `VaultSearchModel` — an in-memory cache of note text, headings, tags, and aliases powering full-text search, Open Quickly, the tag tree, link candidates, and unlinked mentions.
- Pure Core value/logic types: `TagTree`, `MentionScanner`, `TemplateExpander`, `FrontMatter` (typed YAML properties), `GraphLayout` (force-directed), `DocumentStatistics`, `MarkdownExport`, `VaultTree`, `FuzzyMatch`.

## 4. Persistence strategy
- **No database.** Note content lives in `.md` files.
- **Security-scoped bookmarks** persist vault access across launches (sandbox-friendly), stored in `UserDefaults`. On launch we resolve the bookmark, call `startAccessingSecurityScopedResource()`, and re-scan.
- Lightweight UI preferences (last-opened note, sort order, sidebar width) live in `UserDefaults` / `@AppStorage` — these are *caches*, never the source of truth.

## 5. Package evaluation

The guiding principle from the project rules: **native Apple frameworks first, no WebViews in the editing path, async/await.** (See the addendum above for the two scoped WebView exceptions added post-v0.1: rendered Preview and Marp slides.) Below, each capability is evaluated against alternatives.

### 5.1 Markdown editor / live renderer  ⟶ **MarkdownEngine** ✅ (installed)
The heart of the app: a live TextKit 2 editor that styles Markdown as you type.

| Option | Notes | Verdict |
|---|---|---|
| **`swift-markdown-engine` (MarkdownEngine)** | Native **TextKit 2** `NSTextView` bridged to SwiftUI via `NativeTextViewWrapper`; live inline styling, tables, task lists, code-block buttons, **wiki-link** hooks (`isWikiLinkActive`, `onLinkClick`), image-paste hook, scroll-away header, per-document undo. Ships optional bridges for code highlighting and LaTeX. | **Recommended.** Purpose-built for exactly this app; matches the "native, live, TextKit 2" mandate. |
| MarkdownUI | Excellent **read-only** renderer (SwiftUI). No editing. | Rejected — preview-only. |
| Down / Ink / cmark wrappers | Parse/convert to HTML or attributed string; no live editor. | Rejected — not an editor. |
| Hand-rolled TextKit 2 editor | Full control, but months of work to reach parity (inline styling, undo, tables, code blocks). | Rejected for MVP; MarkdownEngine already solves it. |

**Status (v0.1):** `MarkdownEngine`, `MarkdownEngineCodeBlocks`, and `MarkdownEngineLatex` are linked to the macOS target (with a `platformFilters = (macos)` filter so the iOS target — where MarkdownEngine is unavailable — still builds). The editor also uses the engine's inline-token bus for `[[wiki-link]]` autocomplete (`onInlineSelectionChange` / `pendingInlineReplacement`).

### 5.2 Markdown AST parsing (links, headings, tags)  ⟶ **swift-markdown** ✅ (installed)
Used by the Core layer for structural parsing that the editor doesn't give us — extracting `[[wiki-links]]`, headings (for "Open Quickly"), and `#tags`.

| Option | Notes | Verdict |
|---|---|---|
| **`swift-markdown`** (Apple / swiftlang) | Official GFM parser over `cmark-gfm`; stable `Markup` AST; maintained by Apple. | **Recommended.** Authoritative, already a transitive/declared dependency. |
| Ink (JohnSundell) | Fast, pure-Swift, but Markdown→HTML, no rich AST. | Rejected — no AST for link/heading extraction. |
| Direct cmark-gfm C API | Maximum control, C ergonomics. | Rejected — swift-markdown wraps it cleanly. |

### 5.3 Git engine  ⟶ **SwiftGitX** ✅ (installed)
| Option | Notes | Verdict |
|---|---|---|
| **`SwiftGitX`** | Modern **async/await** wrapper over `libgit2`; Swift-native types; actively maintained. | **Recommended** — mandated by project rules and fits the concurrency model. |
| SwiftGit2 / ObjectiveGit | Older, callback/blocking or Obj-C; libgit2 too. | Rejected — dated ergonomics. |
| Shell out to `/usr/bin/git` | Zero deps, trivial. But brittle (parsing porcelain), needs Git installed, sandbox-hostile. | Rejected for the core; may be a debugging fallback. |

### 5.4 Code-block syntax highlighting  ⟶ **HighlighterSwift** ✅ (installed, via bridge)
| Option | Notes | Verdict |
|---|---|---|
| **HighlighterSwift** (highlight.js core, native rendering) | Plugs into MarkdownEngine via `MarkdownEngineCodeBlocks` → `HighlighterSwiftBridge`; auto light/dark themes; broad language coverage. | **Recommended** — first-party bridge already exists. |
| Splash | Beautiful, but **Swift-only** highlighting. | Rejected — need many languages. |
| Custom tree-sitter | Best-in-class, heavy integration cost. | Deferred (P2). |

### 5.5 Math rendering  ⟶ **SwiftMath** ✅ (installed, via bridge)
| Option | Notes | Verdict |
|---|---|---|
| **SwiftMath** | Native LaTeX math typesetting (no WebView); plugs in via `MarkdownEngineLatex` → `SwiftMathBridge`. | **Recommended** — native, first-party bridge. |
| iosMath | Obj-C predecessor of SwiftMath. | Rejected — SwiftMath supersedes it. |
| KaTeX in WebView | Violates the no-WebView rule. | Rejected. |

### 5.6 Mermaid diagrams  ⟶ **beautiful-mermaid-swift** ✅ (installed)
| Option | Notes | Verdict |
|---|---|---|
| **beautiful-mermaid-swift** | Parses Mermaid → native rendering (uses `elk-swift` for graph layout); **no browser engine**. | **Recommended** — only native option; satisfies the no-WebView rule. |
| mermaid.js in WKWebView | Full Mermaid support but a WebView. | Rejected (rule). Kept in mind only as an emergency fallback for unsupported diagram types. |

### 5.7 File-change watching  ⟶ **native (no package)** ✅
| Option | Notes | Verdict |
|---|---|---|
| **`DispatchSource` (vnode) / `FSEvents`** | OS-level; zero deps; battle-tested. | **Recommended** — Core `FileWatcher` wraps FSEvents for the vault directory. |
| Third-party watchers | Unnecessary dependency. | Rejected. |

### 5.8 Fuzzy search / "Open Quickly"  ⟶ **native for MVP** ✅
| Option | Notes | Verdict |
|---|---|---|
| **Hand-rolled subsequence/fuzzy match** | A few hundred lines; fine for a personal vault. | **Recommended** for MVP. |
| Full-text index (SQLite FTS / custom) | Needed only at very large scale. | Deferred (P2) — and even then, an *index cache*, never the source of truth. |

## 6. Dependency summary

| Package | Capability | Status | Linked to app target? |
|---|---|---|---|
| swift-markdown-engine (`MarkdownEngine`) | Live TextKit 2 editor | Resolved | **Yes (macOS only)** |
| ↳ `MarkdownEngineCodeBlocks` | Code highlighting bridge | Resolved | **Yes (macOS only)** |
| ↳ `MarkdownEngineLatex` | Math bridge | Resolved | **Yes (macOS only)** |
| swift-markdown | GFM AST parsing | Resolved | **Yes** |
| SwiftGitX | Git async engine | Resolved | **Yes** |
| beautiful-mermaid-swift (`BeautifulMermaid`, `MermaidPlayground`) | Native Mermaid | Resolved | **Yes** |
| HighlighterSwift | Highlighting (via bridge) | Resolved (transitive) | Via bridge |
| SwiftMath | Math (via bridge) | Resolved (transitive) | Via bridge |
| elk-swift, swift-cmark, libgit2, swift-collections | Transitive deps | Resolved | Transitive |

> **v0.1 note:** MarkdownEngine is macOS-only (AppKit/TextKit 2), so its three products carry a `platformFilters = (macos)` build-file filter; the iOS target links everything else (SwiftGitX, swift-markdown, beautiful-mermaid) and uses a plain-text editor. This keeps a single multiplatform target building for both OSes.
>
> **Fork:** MarkdownEngine is consumed from our fork [`ChristineTham/swift-markdown-engine`](https://github.com/ChristineTham/swift-markdown-engine) (branch `hellonotes-patches`, based on upstream `0.8.0`) so we can land editor fixes upstream can't yet give us — starting with a scroll-to-range fix that makes the outline jump-to-heading work. Rationale, per-limitation plan, and Apple Intelligence notes: [markdown-engine-strategy.md](markdown-engine-strategy.md).

## 7. Module map (target code, v0.1)

| Layer | File | Responsibility |
|---|---|---|
| 1 Core | `Core/MarkdownParsing.swift` | swift-markdown AST → headings; regex → wiki-links, tags, **aliases**; front-matter, Mermaid blocks |
| 1 Core | `Core/FrontMatter.swift` | Parse/serialize typed YAML properties (text/number/checkbox/date/list) |
| 1 Core | `Core/TagTree.swift` | Build the nested `#parent/child` tag tree |
| 1 Core | `Core/MentionScanner.swift` | Detect unlinked mentions; wrap a mention as a `[[link]]` |
| 1 Core | `Core/TemplateExpander.swift` | Expand `{{date}}`/`{{time}}`/`{{title}}`; daily-note filenames |
| 1 Core | `Core/GraphLayout.swift` | Deterministic force-directed graph layout |
| 1 Core | `Core/DocumentStatistics.swift`, `Core/MarkdownExport.swift` | Word/char/reading stats; Markdown → HTML |
| 1 Core | `Core/VaultTree.swift`, `Core/FuzzyMatch.swift`, `Core/FileWatcher.swift`, `Core/ImagePaste.swift` | Folder tree, fuzzy match, FSEvents watcher, image paste → assets |
| 2 State | `WorkspaceIndexer.swift` | Vault selection, scan, CRUD, bookmark persistence |
| 2 State | `State/EditorModel.swift`, `State/EditorTabs.swift` | Open document + debounced autosave + conflicts; one editor per tab |
| 2 State | `State/LinkGraph.swift` | Alias-aware backlinks / outgoing links / resolution, by URL |
| 2 State | `State/VaultSearchModel.swift` | Cached text/headings/tags/aliases → search, Open Quickly, tag tree, mentions |
| 2 State | `State/GitService.swift` | SwiftGitX status/commit/push/fetch + note version history |
| 2 State | `State/BookmarksStore.swift` | Per-vault bookmarks (UserDefaults) |
| 3 UI | `UI/NoteEditorView.swift` | Hosts `NativeTextViewWrapper`; toolbar; references, properties, autocomplete overlays |
| 3 UI | `UI/PropertiesEditor.swift`, `UI/OutlineView.swift`, `UI/WikiLinkCompletionList.swift` | Editable properties, outline+stats popover, `[[…]]` completion |
| 3 UI | `UI/NoteHistoryView.swift`, `UI/GraphView.swift`, `UI/NoteWindowView.swift` | Version history, graph, standalone note window |
| 3 UI | `UI/OpenQuicklyView.swift`, `UI/VaultTreeRow.swift`, `UI/TagTreeRow.swift`, `UI/EditorTabBar.swift`, `UI/MermaidPreviewView.swift`, `UI/EditorExport.swift`, `UI/VaultWikiLinkResolver.swift` | Palette, tree rows, tag tree rows, tabs, Mermaid preview, HTML/PDF export, link resolver |
| 4 Shell | `HelloNotesApp.swift` | App entry; main `WindowGroup` + `WindowGroup(for: URL.self)` (note windows) |
| 4 Shell | `MacContentView.swift` | 3-column macOS shell |
| 4 Shell | `iOSContentView.swift` | Adaptive `NavigationSplitView` (iPhone/iPad) |

## 8. Testing strategy
- **Core is unit-tested** without UI: vault scan on a temp directory, CRUD, parser link extraction, autosave round-trip (write → read → byte-compare).
- **Data-loss tests:** simulate app-resign / termination mid-edit → assert file matches buffer.
- **Build gate:** every increment compiles with 0 errors/0 warnings via `xcodebuild` (or the Xcode MCP build check) on the macOS destination before merge.

## 9. Risks & mitigations
| Risk | Mitigation |
|---|---|
| MarkdownEngine API churn (early-stage package) | Pin the resolved version; isolate usage behind `NoteEditorView`. |
| Autosave data loss | Debounce + flush-on-transition; write to temp then atomic replace; unit tests. |
| App Sandbox blocks arbitrary vault access | Security-scoped bookmarks; user-selected folder grants scope. |
| Large vault scan jank | Off-main enumeration; incremental updates via FileWatcher. |
| Mermaid coverage gaps in native renderer | Render supported diagram types; degrade gracefully to source for unsupported ones. |
