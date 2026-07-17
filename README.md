# HelloNotes

> **Version 1.0** · A blazing-fast, local-first, native macOS (and iOS) Markdown knowledge base with built-in AI — synced effortlessly via Git.

HelloNotes is a native Apple-ecosystem alternative to Electron knowledge apps like Obsidian and cross-platform editors like Typora. It's built strictly on modern Swift — **AppKit + TextKit 2 + SwiftUI** — prioritising high-FPS text rendering, local `.md` files as the absolute source of truth, and seamless background Git synchronisation. **No proprietary database. Your files in Finder *are* the database.**

## 📚 Documentation
| Doc | What's in it |
|---|---|
| [docs/PRD.md](docs/PRD.md) | Product vision, users, feature requirements, success metrics |
| [docs/architecture.md](docs/architecture.md) | 4-layer architecture + evaluation of every Swift package (alternatives & recommendations) |
| [docs/implementation-plan.md](docs/implementation-plan.md) | Milestone-by-milestone build sequence (0–13) |
| [docs/unimplemented.md](docs/unimplemented.md) | Deferred / not-yet-built items, with reasons and what would unblock each |
| [docs/markdown-engine-strategy.md](docs/markdown-engine-strategy.md) | *(Historical)* How the MarkdownEngine fork first unblocked the editor, before the in-repo `Packages/NotesEditor` rewrite superseded it (M4) |
| [docs/production.md](docs/production.md) | Step-by-step runbook to ship the app to the Mac App Store (copy-paste field values included) |

## ✨ Features (v1.0)

**Local-first, multi-collection**
- No CoreData/SwiftData/iCloud store; your `.md` files are the truth. Open **several collections at once** as a *library*, with a launcher, recents, and saved library sets.
- **Obsidian vault import** — point HelloNotes at a folder of existing vaults and they open as collections, no migration.
- Non-Markdown attachments (PDF, images, CSV…) appear in the tree and open in a native **file viewer** (QuickLook/PDFKit).

**A truly native live editor**
- Live TextKit 2 Markdown styling as you type: headings, emphasis, lists, task lists, tables, footnotes.
- Natively rendered (no browser engine): syntax-highlighted code, **LaTeX math**, **inline Mermaid diagrams**, Obsidian-style **callouts** (collapsible, with icons), dimmed `%%comments%%`, and hidden front matter paired with a typed, editable **Properties** panel.
- **Note transclusion** — `![[Note]]` / `![[Note#heading]]` render as inline cards.
- **View modes**: Edit (live), Preview (read-only), Markdown (source), and Split — plus **⌘F find & replace**, image paste → `assets/`, smart paste (HTML → Markdown), multi-tab and multi-window editing, document statistics, outline with jump-to-heading, and **HTML/PDF export**.
- **Marp slide decks** — notes with Marp front matter get a native slides preview.

**Knowledge graph**
- `[[wiki-links]]` with autocomplete, **aliases**, link-to-heading, backlinks, outgoing links, and unlinked mentions with one-click linking.
- A directional **Graph** view (arrows, focus tracing, whole-collection or N-links-around-a-note scope) and a content-based **Mind Map** of a note's ideas (sections → branches, bullets → leaves, linked notes → jump-off chips).

**Organise & find**
- Full-text search with snippets, Open Quickly (⇧⌘O), nested `#tags` (with autocomplete), bookmarks, daily notes, and templates.

**AI, on your terms**
- On-device **Apple Intelligence** (summarise, suggest tags/links) and an **Ask Library** chat grounded in your notes, with citations.
- An agentic **Assistant** with tools (search, read, edit-with-approval, web search/fetch), skills, and deep research.
- Bring your own model: **local** (Apple Foundation Models, MLX, Ollama, LM Studio) or **your own cloud API key** — Anthropic, Gemini, OpenAI, Mistral, Groq, OpenRouter, xAI (Grok), DeepSeek, Cerebras, Together AI, Perplexity, and Ollama Cloud. Keys live in the Keychain; cloud providers are off until you configure one.

**Seamless Git sync**
- Repo status, init, local commits, opt-in debounced auto-commit (never auto-pushes), user-initiated push/fetch, per-note **version history** (browse & restore), **clone** and **create-remote** with HTTPS token auth, and an in-app git identity.

**Native app polish**
- Full menu bar with keyboard shortcuts, windowed Graph/Mind Map/Assistant/Ask Library surfaces, appearance settings (light/dark, accent colours, text size with Dynamic Type), a launch splash with live build info, and an adaptive iOS/iPadOS companion.

> WebView policy: the *editing path is 100% native TextKit 2*. A `WKWebView` appears in exactly two places — the Marp slides preview, and the iOS read-only Preview (MarkdownEngine is AppKit-only).

## 🏗️ Architecture at a glance
A strict **4-layer architecture** keeps macOS and iOS sharing everything but the shell:
1. **Core / Domain** (pure Swift) — Markdown/front-matter/tag parsing, mention scanning, templates, graph & mind-map layout, statistics, export, Marp, Obsidian import, file watching. UI-agnostic, unit-tested.
2. **State** — the `@Observable` macro *exclusively*: `Library` → `Collection`s (scan, CRUD, bookmarks), `EditorModel`/`EditorTabs`, `LinkGraph`, `CollectionSearchModel`, `GitService` (FIFO-serialized), `AppearanceSettings`, stores for recents/libraries/credentials.
3. **Shared UI** — editor host, note tree, references panel, graph/mind map, assistant, viewers.
4. **Platform shells** — `NavigationSplitView` shells for macOS and iOS/iPadOS behind `#if os(...)`.

The **LLM layer** (`HelloNotes/LLM/`) follows the same split: `Sendable` provider adapters + agent tools at the Core tier; `@MainActor @Observable` models (`LLMSettings`, `AssistantModel`, `SkillStore`, `PermissionBroker`) at the State tier. Chat transcripts persist as JSONL under Application Support; API keys in the Keychain.

Full detail, data flow, and concurrency model: [docs/architecture.md](docs/architecture.md).

## 📦 Tech stack & Swift packages
Swift Package Manager, native Apple frameworks first.

**Apple frameworks:** SwiftUI · AppKit / TextKit 2 · Vision (image alt-text) · PDFKit / QuickLook · Security (Keychain) · libgit2 (via SwiftGitX)

**Packages** (see [architecture.md §5](docs/architecture.md#5-package-evaluation) for the evaluation of each vs its alternatives):

| Package | Role |
|---|---|
| [swift-markdown-engine](https://github.com/ChristineTham/swift-markdown-engine) (fork, `hellonotes-patches`) | Live TextKit 2 Markdown editor + code/LaTeX bridges; the fork adds scroll-to-range, inline diagrams, find/replace, tag tokens, callouts/comments/front-matter styling ([why & how](docs/markdown-engine-strategy.md)) |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | Apple's GFM AST parser (links, headings, tags, HTML export) |
| [SwiftGitX](https://github.com/ibrahimcetin/SwiftGitX) | Async/await Git engine over libgit2 |
| [beautiful-mermaid-swift](https://github.com/lukilabs/beautiful-mermaid-swift) | Native Mermaid diagram rendering |
| [mlx-swift](https://github.com/ml-explore/mlx-swift) + swift-transformers | Local LLM inference on Apple silicon (MLX provider) |
| OpenAI (client) | OpenAI-compatible provider transport |
| HighlighterSwift · SwiftMath | Code highlighting & math, via the MarkdownEngine bridges |

## 🚀 Build & run
Requirements: **macOS 15+**, **Xcode 26+** (Swift 5.10+).

```bash
git clone https://github.com/hellotham/hellonotes.git
cd hellonotes

# Open in Xcode (SPM dependencies resolve automatically on first open)
open HelloNotes.xcodeproj

# …or build from the command line (a shared scheme is committed)
xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes -destination 'platform=macOS' build

# unit tests
xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes -destination 'platform=macOS' -only-testing:HelloNotesTests test
```

Run the **HelloNotes** scheme, then click **Open…** and choose any directory of Markdown files — or point it at the bundled [`SampleVault/`](SampleVault/), whose notes demonstrate callouts, diagrams, math, transclusion, wiki-links, tags, slides, daily notes, and templates.

## 🗂️ Project layout
```
HelloNotes/            App sources (synchronised Xcode group)
  ├─ Core/             Layer 1 — pure logic: parsing, front matter, tags,
  │                     mentions, templates, layouts, stats, export, Marp,
  │                     Obsidian import, smart paste, build info
  ├─ State/            Layer 2 — @Observable models (library/collections,
  │                     editor/tabs, link graph, search, git, appearance,
  │                     bookmarks/recents/credentials)
  ├─ LLM/              AI layer — provider adapters (Anthropic, OpenAI-compat,
  │                     Gemini, MLX, Apple), agent runtime (tools, skills,
  │                     permissions, deep research), settings & chat stores
  ├─ UI/               Layer 3 — shared views (editor, tree, references,
  │                     graph, mind map, slides, viewers, assistant, splash)
  ├─ MacContentView    Layer 4 — macOS 3-column shell
  ├─ iOSContentView    Layer 4 — iOS/iPadOS adaptive shell
  └─ HelloNotesApp     App entry (main window + auxiliary window scenes)
docs/                  PRD, architecture, implementation plan, production
HelloNotesTests/       Unit tests (52)
SampleVault/           Demo collection used by docs & screenshots
HelloNotes.xcodeproj/  Project (SPM dependencies, shared scheme)
```

## 🤝 Contributing / working rules
Project conventions live in [CLAUDE.md](CLAUDE.md): macOS 15+ / Swift 5.10+ / Xcode 26; `@Observable` only (no `ObservableObject`/`StateObject`); no CoreData/SwiftData; Git via SwiftGitX; every change must build clean (0 errors) before it's done.

## 📄 License
See [LICENSE](LICENSE).
