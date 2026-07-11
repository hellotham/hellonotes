# HelloNotes (working name: NoteLens)

> A blazing-fast, local-first, native macOS (and eventually iOS) Markdown knowledge base, synced effortlessly via Git.

HelloNotes is a native Apple-ecosystem alternative to Electron knowledge apps like Obsidian and cross-platform editors like Typora. It's built strictly on modern Swift — **AppKit + TextKit 2 + SwiftUI** — prioritising high-FPS text rendering, local `.md` files as the absolute source of truth, and seamless background Git synchronisation. **No WebViews. No proprietary database. Your files in Finder *are* the database.**

## 📚 Documentation
| Doc | What's in it |
|---|---|
| [docs/PRD.md](docs/PRD.md) | Product vision, users, MVP scope, roadmap, success metrics |
| [docs/architecture.md](docs/architecture.md) | 4-layer architecture + evaluation of every Swift package (alternatives & recommendations) |
| [docs/implementation-plan.md](docs/implementation-plan.md) | Milestone-by-milestone build sequence |

## ✨ Core features (target)
- **Local-first** — no CoreData/SwiftData/iCloud store; your `.md` files are the truth.
- **Live TextKit 2 editor** — Markdown styles as you type (bold, headings, lists, tables, task lists), with native syntax-highlighted code blocks and LaTeX math.
- **Knowledge graph** — `[[wiki-links]]` with an asynchronous backlink index.
- **Seamless Git sync** — background, non-blocking commits/pulls via async Swift.
- **Native Mermaid** — diagrams rendered without a browser engine.

See the [PRD](docs/PRD.md) for the full, prioritised feature list.

## 🚦 Current status
Early development. Implemented so far:
- ✅ Vault selection (`NSOpenPanel`) + Markdown indexing; persists across launches.
- ✅ macOS 3-column shell (`NavigationSplitView`).
- ✅ **Editing MVP (Milestone 1):** live MarkdownEngine editor, debounced atomic auto-save, create/delete notes, searchable list.
- ✅ **Knowledge graph & math (Milestone 2):** clickable `[[wiki-links]]` (existing vs broken), a backlinks panel, native LaTeX, and syntax-highlighted code.
- ✅ **Search & navigation (Milestone 3):** full-text search with snippets, "Open Quickly" (⌘O) fuzzy finder over notes & headings, and live external-change detection (FSEvents).
- ✅ **Folder tree & polish:** a real folder tree with sort options, a `#tags` sidebar filter, and open-note conflict handling (silent reload / keep-mine).
- ✅ **Git sync (Milestone 4):** repo status, initialize, local commit, opt-in auto-commit, and user-initiated push/fetch via SwiftGitX.
- ✅ **Native rendering (Milestone 5):** image paste → `assets/` folder, a front-matter panel, and native Mermaid diagram preview (no WebView).
- 🚧 Next: the iOS `NavigationStack` shell (Milestone 6); then pull/merge & an in-app git identity.

Roadmap and milestones: [docs/implementation-plan.md](docs/implementation-plan.md).

## 🏗️ Architecture at a glance
A strict **4-layer architecture** keeps macOS and iOS sharing everything but the shell:
1. **Core / Domain** (pure Swift) — file-system vault access, `swift-markdown` AST parsing, `SwiftGitX` Git engine. UI-agnostic, unit-tested.
2. **State** — the `@Observable` macro *exclusively* (`WorkspaceIndexer`, `EditorModel`, `LinkGraph`).
3. **Shared UI** — editor host, note rows, backlinks/search components.
4. **Platform shells** — `NavigationSplitView` (macOS) / `NavigationStack` (iOS) behind `#if os(...)`.

Full detail, data flow, and concurrency model: [docs/architecture.md](docs/architecture.md).

## 📦 Tech stack & Swift packages
Swift Package Manager, native Apple frameworks, **zero WebView/Electron dependencies**.

**Apple frameworks:** SwiftUI · AppKit / TextKit 2 · UniformTypeIdentifiers · libgit2 (via SwiftGitX)

**Packages** (see [architecture.md §5](docs/architecture.md#5-package-evaluation) for the evaluation of each vs its alternatives):

| Package | Role |
|---|---|
| [swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine) | Live TextKit 2 Markdown editor (`NativeTextViewWrapper`) + code/LaTeX bridges |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | Apple's GFM AST parser (links, headings, tags) |
| [SwiftGitX](https://github.com/ibrahimcetin/SwiftGitX) | Async/await Git engine over libgit2 |
| [beautiful-mermaid-swift](https://github.com/lukilabs/beautiful-mermaid-swift) | Native Mermaid diagram rendering |
| HighlighterSwift · SwiftMath | Code highlighting & math, via the MarkdownEngine bridges |

## 🚀 Build & run
Requirements: **macOS 14+**, **Xcode 26+** (Swift 5.10+).

```bash
git clone https://github.com/ChristineTham/hellonotes.git
cd hellonotes

# Open in Xcode (SPM dependencies resolve automatically on first open)
open HelloNotes.xcodeproj

# …or build from the command line
xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes -destination 'platform=macOS' build
```

Run the **HelloNotes** scheme, then click **Select Vault Folder** and choose any directory of Markdown files.

## 🗂️ Project layout
```
HelloNotes/            App sources (synchronised Xcode group)
  ├─ Core/             Layer 1 — vault, parsing, git (UI-agnostic)
  ├─ State/            Layer 2 — @Observable models
  ├─ UI/               Layer 3 — shared views
  ├─ MacContentView    Layer 4 — macOS shell
  ├─ Note.swift        Core model
  └─ WorkspaceIndexer  Vault state
docs/                  PRD, architecture, implementation plan
HelloNotesTests/       Unit tests
HelloNotes.xcodeproj/  Project (SPM dependencies)
```

## 🤝 Contributing / working rules
Project conventions live in [CLAUDE.md](CLAUDE.md): macOS 14+ / Swift 5.10+ / Xcode 26; `@Observable` only (no `ObservableObject`/`StateObject`); no CoreData/SwiftData; Git via SwiftGitX; every change must build clean (0 errors) before it's done.

## 📄 License
See [LICENSE](LICENSE).
