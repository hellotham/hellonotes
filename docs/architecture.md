# HelloNotes — Architecture & Technology Evaluation

> Status: **v1.0 (shipped)** · Last updated: 2026-07-13 · Companion to [PRD.md](PRD.md) and [implementation-plan.md](implementation-plan.md)

This document describes the software architecture of HelloNotes and evaluates the third-party Swift packages the app depends on. For each capability we consider the realistic alternatives, then give a recommendation. As of **v1.0**, all packages below are resolved **and linked**, and the 4-layer architecture is fully in place across macOS and iOS; this document reflects the shipped design.

---

## 1. Architectural overview

HelloNotes uses a strict **4-layer architecture** so that the macOS and iOS apps share everything except the platform shell. Data flows in one direction: the file system is the source of truth, the Core layer reads/writes it, State projects it as observable values, and the UI renders State. The AI stack (`HelloNotes/LLM/`) follows the same split — `Sendable` value-type adapters at the Core tier, `@MainActor @Observable` models at the State tier.

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 4 — Platform Shells                                   │
│    macOS: NavigationSplitView (3 columns) + window scenes    │
│    iOS:   adaptive NavigationSplitView    [#if os(...)]       │
├─────────────────────────────────────────────────────────────┤
│  Layer 3 — Shared UI Components                              │
│    Editor host (MarkdownEngine), note tree, references       │
│    panel, graph / mind map, slides, file viewer, assistant,  │
│    launcher, splash                                          │
├─────────────────────────────────────────────────────────────┤
│  Layer 2 — State Management  (@Observable)                   │
│    Library → Collections (scan/CRUD/watch), EditorModel /    │
│    EditorTabs, LinkGraph, CollectionSearchModel, GitService, │
│    AppearanceSettings, LLMSettings / AssistantModel          │
├─────────────────────────────────────────────────────────────┤
│  Layer 1 — Core / Domain  (pure Swift, UI-agnostic)         │
│    CollectionFile/Tree, MarkdownParsing (swift-markdown      │
│    AST), FrontMatter, layouts, Marp, Obsidian import,        │
│    FileWatcher (FSEvents), LLM provider adapters             │
└─────────────────────────────────────────────────────────────┘
             ▲                                   │
             │  reads/writes                     │ observes
             └────  File System (collections of .md files)
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
- Git operations are **FIFO-serialized inside `GitService`** (each operation chains behind the previous via task chaining on the main actor, with the blocking libgit2 work detached) so commits/pushes/fetches never overlap on a repository.
- LLM streaming runs in `Sendable` provider structs over `URLSession.bytes` inside `AsyncThrowingStream` — fully off-main; the `@MainActor` `AssistantModel` consumes the stream and publishes UI state.

## 3. Data model (Core / State)
- `Note` — value type: `id` (== `fileURL`), `title`, `fileURL`, `lastModified`. `CollectionFile` is its non-Markdown sibling (PDF/image/CSV/other) for the file viewer.
- `Library` — the open **collections** (multi-vault), focus tracking, restore-on-launch, and cross-window open requests. `Collection` — one folder: root URL + security-scoped bookmark, scanned `[Note]`/`[CollectionFile]`, CRUD (create/rename-with-link-rewrite/duplicate/delete-to-Trash), folder ops, and the FSEvents watcher. `LibrariesStore`/`RecentsStore` persist saved library sets and recents.
- `EditorModel` — in-memory editing buffer: `text`, `isDirty`, `lastSavedText`, `savedRevision`, plus conflict state; debounced atomic autosave. `EditorTabs` holds one per open note.
- `LinkGraph` — resolves link targets through **titles and `aliases:`**, indexed **by note URL**: `backlinksByURL`, `outgoingByURL`, and a `resolution` map (title/alias → URL). Rebuilt asynchronously on change.
- `CollectionSearchModel` — an in-memory cache of note text, headings, tags, and aliases powering full-text search, Open Quickly, the tag tree, link candidates, and unlinked mentions.
- `GitService` — per-collection status/commit/push/fetch/history; `GitCredentials` (Keychain HTTPS tokens) and `GitHostAPI` (clone / create-remote) support hosting integration.
- LLM tier: `LLMSettings` (providers/models/keys via `LLMKeychain`), `AssistantModel` (agent loop over `AgentRunner` + `ToolRegistry`), `SkillStore` (skills parsed from notes), `PermissionBroker` (explicit approval for mutating tools), `ChatSessionStore` (JSONL transcripts under Application Support), `IntelligenceService`/`NoteIntelligence` (summarise/suggest).
- Pure Core value/logic types: `TagTree`, `MentionScanner`, `TemplateExpander`, `FrontMatter` (typed YAML properties), `GraphLayout` (force-directed) + `LayoutRelaxation` (collision avoidance), `DocumentStatistics`, `MarkdownExport`, `CollectionTree`, `FuzzyMatch`, `MarpSlides`, `ObsidianVault`, `SmartPaste`, `VisionAlt`, `BuildInfo`.

## 4. Persistence strategy
- **No database.** Note content lives in `.md` files.
- **Security-scoped bookmarks** (`com.apple.security.files.bookmarks.app-scope`) persist collection access across launches (sandbox-friendly), stored in `UserDefaults`. On launch we resolve each bookmark, call `startAccessingSecurityScopedResource()`, and re-scan.
- Lightweight UI preferences (last-opened note, sort order, appearance, editor mode) live in `UserDefaults` / `@AppStorage` — these are *caches*, never the source of truth.
- The only app data written outside collections and `UserDefaults`: **API keys and git tokens in the Keychain**, and **assistant chat transcripts** as JSONL under Application Support (per collection, atomic writes).

## 5. Package evaluation

The guiding principle from the project rules: **native Apple frameworks first, no WebViews in the editing path, async/await.** Two scoped `WKWebView` exceptions exist in v1.0 — the Marp slides preview (`UI/SlidesView.swift`) and the iOS read-only Preview (`UI/MarkdownWebView.swift`; MarkdownEngine is AppKit-only). The macOS Preview mode is the native engine in read-only mode. Below, each capability is evaluated against alternatives.

### 5.1 Markdown editor / live renderer  ⟶ **`Packages/NotesEditor`** ✅ (shipped)
The heart of the app: a live TextKit 2 editor that styles Markdown as you type.

> **Note (M4):** this section originally evaluated and adopted the
> `swift-markdown-engine` fork. That fork unblocked the editor through M3 and was
> then **replaced by the in-repo `Packages/NotesEditor` rewrite and removed** at
> M4. Mentions of "MarkdownEngine" below are the historical evaluation; the
> shipped editor is `Packages/NotesEditor` — see [editor-rewrite.md](editor-rewrite.md).

| Option | Notes | Verdict |
|---|---|---|
| **`Packages/NotesEditor`** (in-repo) | Native **TextKit 2** `NSTextView`/`UITextView`; live inline styling, tables, task lists, callouts, wiki-link/embed hooks, caret-driven concealment, per-document undo, plus a cmark-gfm Preview. | **Adopted (v1.0).** Greenfield rewrite; owns the full editor + GFM parity in-repo. |
| `swift-markdown-engine` (MarkdownEngine) fork | Native TextKit 2 editor consumed as a package; first unblocked the editor with host patches. | Superseded — used through M3, **removed at M4** in favour of `Packages/NotesEditor`. |
| MarkdownUI | Excellent **read-only** renderer (SwiftUI). No editing. | Rejected — preview-only. |
| Down / Ink / cmark wrappers | Parse/convert to HTML or attributed string; no live editor. | Rejected — not an editor. |
| Hand-rolled TextKit 2 editor | Full control, but months of work to reach parity (inline styling, undo, tables, code blocks). | Rejected for MVP; MarkdownEngine already solves it. |

**Status (v1.0):** the editor is the in-repo `Packages/NotesEditor` package (`MarkdownCore` + `MarkdownEditor` + `GFMRender`), linked to both the macOS and iOS targets; `[[wiki-link]]` autocomplete is driven by its inline-context bus (`onInlineContext` / `EditorProxy`). *(The `MarkdownEngine*` fork products this section once described were removed at M4.)*

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

### 5.9 LLM providers (v1.0)  ⟶ **protocol + adapters, no LLM framework** ✅

A single `LLMProvider` protocol (streaming chat + tool calls) with five `Sendable` adapters: **Apple Foundation Models** (on-device, macOS 26+ gated), **MLX** (`mlx-swift` local inference, models via `Hub`/`Tokenizers`), **OpenAI-compatible**, **Anthropic**, and **Gemini** (hand-rolled SSE over `URLSession.bytes`, no SDK lock-in). The one **OpenAI-compatible** adapter serves eleven providers that differ only by base URL and a couple of headers — OpenAI, Mistral, Groq, OpenRouter, **xAI (Grok)**, **DeepSeek**, **Cerebras**, **Together AI**, **Perplexity**, and **Ollama** (both the local server and the hosted **Ollama Cloud**) plus LM Studio — so `ModelCatalog` (the data-driven `ProviderKind` enum) is the *only* thing that changes to add another; `ProviderFactory` dispatches on `kind.wire`, never on the kind itself. API keys live in the Keychain (`LLMKeychain`); cloud providers are off until the user configures one. The agent runtime (`AgentRunner` + `AgentTool` registry + `PermissionBroker`) keeps mutating tools behind explicit user approval. Frameworks like LangChain-style abstractions were rejected — the protocol is ~100 lines and owns its wire formats.

## 6. Dependency summary

| Package | Capability | Status | Linked to app target? |
|---|---|---|---|
| `Packages/NotesEditor` (`MarkdownCore`, `MarkdownEditor`, `GFMRender`) | In-repo live TextKit 2 editor + cmark-gfm parity | Resolved | **Yes** |
| swift-cmark (`gfm` branch) | GFM rendering (Preview) + spec/AST parity | Resolved | **Yes** (via GFMRender) |
| swift-markdown | GFM AST parsing + HTML export | Resolved | **Yes** |
| SwiftGitX | Git async engine | Resolved | **Yes** |
| beautiful-mermaid-swift (`BeautifulMermaid`, `MermaidPlayground`) | Native Mermaid | Resolved | **Yes** |
| OpenAI | OpenAI-compatible provider transport | Resolved | **Yes** |
| mlx-swift (`MLXLLM`, `MLXLMCommon`) | Local LLM inference (Apple silicon) | Resolved | **Yes** |
| swift-transformers (`Tokenizers`, `Hub`) | Tokenizers + model downloads for MLX | Resolved | **Yes** |
| HighlighterSwift | Code-block highlighting (`CodeHighlighterAdapter`) | Resolved | **Yes** (direct) |
| SwiftMath | Math rendering (`MathImageRenderer`) | Resolved | **Yes** (direct) |
| elk-swift, swift-cmark, libgit2, swift-collections | Transitive deps | Resolved | Transitive |

> **Editor:** the live editor is the in-repo `Packages/NotesEditor` package — `MarkdownCore` (incremental block/inline parser + style spec), `MarkdownEditor` (TextKit 2 `NSTextView`/`UITextView`), and `GFMRender` (cmark-gfm for GitHub-identical Preview + spec/API parity). It builds for both macOS and iOS. The earlier `ChristineTham/swift-markdown-engine` fork that first unblocked the editor was **removed at M4** once this greenfield rewrite reached parity; see [editor-rewrite.md](editor-rewrite.md). Historical rationale for the fork: [markdown-engine-strategy.md](markdown-engine-strategy.md).

## 7. Module map (target code, v1.0)

| Layer | File | Responsibility |
|---|---|---|
| 1 Core | `Core/MarkdownParsing.swift` | swift-markdown AST → headings; regex → wiki-links, tags, **aliases**; front-matter, Mermaid blocks |
| 1 Core | `Core/FrontMatter.swift` | Parse/serialize typed YAML properties (text/number/checkbox/date/list) |
| 1 Core | `Core/TagTree.swift`, `Core/MentionScanner.swift`, `Core/TemplateExpander.swift` | Nested tag tree; unlinked mentions → `[[link]]`; `{{date}}`/`{{time}}`/`{{title}}` + daily-note names |
| 1 Core | `Core/GraphLayout.swift`, `Core/LayoutRelaxation.swift` | Deterministic force-directed layout; AABB collision separation (graph + mind map) |
| 1 Core | `Core/DocumentStatistics.swift`, `Core/MarkdownExport.swift` | Word/char/reading stats; Markdown → HTML |
| 1 Core | `Core/CollectionTree.swift`, `Core/CollectionFile.swift`, `Core/FuzzyMatch.swift`, `Core/FileWatcher.swift`, `Core/ImagePaste.swift` | Folder tree, attachment model, fuzzy match, FSEvents watcher, image paste → assets |
| 1 Core | `Core/MarpSlides.swift`, `Core/ObsidianVault.swift`, `Core/SmartPaste.swift`, `Core/VisionAlt.swift`, `Core/BuildInfo.swift` | Marp deck parsing; Obsidian vault discovery; HTML→Markdown paste; Vision alt-text; splash build metadata |
| 2 State | `State/Library.swift`, `State/Collection.swift`, `State/LibrariesStore.swift`, `State/RecentsStore.swift` | Multi-collection library, per-collection scan/CRUD/watch/bookmark, saved libraries, recents |
| 2 State | `State/EditorModel.swift`, `State/EditorTabs.swift` | Open document + debounced autosave + conflicts; one editor per tab |
| 2 State | `State/LinkGraph.swift`, `State/CollectionSearchModel.swift` | Alias-aware backlinks/outgoing/resolution; cached text/headings/tags/aliases → search, Open Quickly, mentions |
| 2 State | `State/GitService.swift`, `State/GitCredentials.swift`, `State/GitHostAPI.swift` | FIFO-serialized status/commit/push/fetch + history; Keychain HTTPS tokens; clone/create-remote |
| 2 State | `State/AppearanceSettings.swift`, `State/BookmarksStore.swift`, `State/NoteIntelligence.swift` | Theme/accent/text-size; per-collection bookmarks; Apple Intelligence actions |
| LLM | `LLM/LLMProvider.swift`, `LLM/Adapters/*` | Streaming provider protocol; Apple / MLX / OpenAI-compatible / Anthropic / Gemini adapters |
| LLM | `LLM/AssistantModel.swift`, `LLM/Agent/*` | Agent loop; tools (collection CRUD/search, web search/fetch), skills, deep research, permission broker |
| LLM | `LLM/LLMSettings.swift`, `LLM/LLMKeychain.swift`, `LLM/ChatSessionStore.swift`, `LLM/ModelCatalog.swift`, `LLM/IntelligenceService.swift` | Provider/model config; Keychain keys; JSONL transcripts; model catalog; summarise/ask services |
| 3 UI | `UI/NoteEditorView.swift` | Hosts `NativeTextViewWrapper`; view modes; find/replace; references, properties, autocomplete overlays |
| 3 UI | `UI/PropertiesEditor.swift`, `UI/OutlineView.swift`, `UI/WikiLinkCompletionList.swift`, `UI/FindReplaceBar.swift` | Editable properties, outline+stats, `[[…]]`/`#tag` completion, ⌘F bar |
| 3 UI | `UI/GraphView.swift`, `UI/MindMapView.swift`, `UI/NoteHistoryView.swift`, `UI/NoteWindowView.swift`, `UI/AuxiliaryWindows.swift` | Directional graph, idea mind map, version history, standalone note window, window scenes |
| 3 UI | `UI/NoteOutlineList.swift`, `UI/TagTreeRow.swift`, `UI/EditorTabBar.swift`, `UI/OpenQuicklyView.swift`, `UI/LauncherView.swift` | Folder/note tree, tag rows, tabs, palette, collection launcher |
| 3 UI | `UI/SlidesView.swift`, `UI/FileViewerView.swift`, `UI/MermaidPreviewView.swift`, `UI/MarkdownWebView.swift`, `UI/EditorExport.swift` | Marp slides, attachment viewer, Mermaid gallery, iOS preview, HTML/PDF export |
| 3 UI | `UI/CollectionWikiLinkResolver.swift`, `UI/CollectionEmbedProvider.swift`, `UI/NoteTranscluder.swift`, `UI/MermaidDiagramRenderer.swift` | Link resolution, `![[embed]]` cards, transclusion rendering, inline diagram renderer |
| 3 UI | `UI/Assistant/*`, `UI/LibraryChatView.swift`, `UI/IntelligenceView.swift` | Assistant chat + edit approval + LLM settings; Ask Library; Intelligence sheet |
| 3 UI | `UI/AppCommands.swift`, `UI/AppearanceSettingsView.swift`, `UI/GeneralSettingsView.swift`, `UI/GitSettingsView.swift`, `UI/CloneRepositoryView.swift`, `UI/NewRepositoryView.swift`, `UI/SplashScreenView.swift`, `UI/iOSSettingsView.swift` | Menu bar, preferences tabs, git identity/hosting, splash/About, iOS settings |
| 4 Shell | `HelloNotesApp.swift` | App entry; main window + `NoteRef`/`MindMapRef` window groups + Graph/Ask/Assistant windows + Settings |
| 4 Shell | `MacContentView.swift` | 3-column macOS shell |
| 4 Shell | `iOSContentView.swift` | Adaptive `NavigationSplitView` (iPhone/iPad) |

## 8. Testing strategy
- **Core is unit-tested** without UI (52 tests across parsing, front matter, tags, mentions, templates, layouts, stats, export, git, Obsidian import, smart paste, agent tools, skills): vault scan on a temp directory, CRUD, parser link extraction, autosave round-trip (write → read → byte-compare).
- **Data-loss tests:** simulate app-resign / termination mid-edit → assert file matches buffer.
- **Build gate:** every increment compiles with 0 errors/0 warnings in app sources via `xcodebuild` on the macOS destination before merge; iOS must also build.

## 9. Risks & mitigations
| Risk | Mitigation |
|---|---|
| MarkdownEngine API churn (early-stage package) | Pin the resolved version; isolate usage behind `NoteEditorView`. |
| Autosave data loss | Debounce + flush-on-transition; write to temp then atomic replace; unit tests. |
| App Sandbox blocks arbitrary vault access | Security-scoped bookmarks; user-selected folder grants scope. |
| Large vault scan jank | Off-main enumeration; incremental updates via FileWatcher. |
| Mermaid coverage gaps in native renderer | Render supported diagram types; degrade gracefully to source for unsupported ones. |
