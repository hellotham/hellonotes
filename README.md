# HelloNotes (Project Name: NoteLens)

> A blazing-fast, local-first, native macOS (and eventually iOS) Markdown knowledge graph, synced effortlessly via Git.

## 🎯 Intent and Purpose
HelloNotes is designed to be a native Apple ecosystem alternative to Electron-based knowledge management apps like Obsidian. It is built strictly on modern Swift, prioritizing 120 FPS text rendering, local-first file directories as the absolute source of truth, and seamless, invisible Git synchronization. 

Instead of treating the Mac as an afterthought, HelloNotes utilizes AppKit and TextKit 2 to deliver a true, tactile macOS experience, featuring live Markdown toggling, bidirectional linking, and native performance.

## ✨ Core Features
*   **Local-First Architecture:** No proprietary databases (no CoreData/SwiftData). Your `.md` files in Finder *are* the database.
*   **Seamless Git Sync:** Background, non-blocking commits and pulls directly to GitHub/GitLab using in-process Swift concurrency.
*   **TextKit 2 Editor:** A native AppKit editor that dynamically toggles between "Source Code" mode (`**bold**`) and "Live Preview" mode (Rich Text) based on cursor position.
*   **Bidirectional Knowledge Graph:** Asynchronous parsing of `[[wiki-links]]` to build an instantaneous backlink index.
*   **Native Mermaid Diagrams:** Renders complex `.mermaid` code blocks directly into native SVGs/CoreGraphics—no WebViews allowed.

---

## 🏗️ Architectural Blueprint

To ensure scalability from macOS to iOS, the codebase follows a strict **4-Layer Architecture** avoiding the "share everything" SwiftUI trap.

1.  **Core / Domain (Pure Swift):** Handles Git file-system syncing (`SwiftGitX`) and background AST text parsing (`swift-markdown`). Agnostic to any UI.
2.  **State Management:** Uses the modern Swift `@Observable` macro exclusively. A global `WorkspaceIndexer` tracks file directories and provides unified state.
3.  **Shared UI Components:** Reusable buttons, markdown token styling modifiers, and text view wrappers.
4.  **Platform-Specific Shells:**
    *   `#if os(macOS)`: Utilizes `NavigationSplitView` for a classic 3-column desktop layout (Sidebar, Notes List, Editor).
    *   `#if os(iOS)`: Utilizes `NavigationStack` for a push-based mobile interface.

---

## 📦 Tech Stack & Swift Packages

This project relies on Swift Package Manager (SPM) and strict Native Apple Frameworks. **Zero WebViews or Electron runtime dependencies.**

### Native Apple Frameworks
*   `SwiftUI` (App lifecycle and layout routing)
*   `AppKit` / `TextKit 2` (High-performance text layout via `NSTextView`)
*   `UniformTypeIdentifiers` (System-level recognition of `.md` files)

### Open-Source Swift Packages
Add these dependencies in Xcode via **Project Settings > Package Dependencies**:

1.  **AST Parser:** `https://github.com/swiftlang/swift-markdown.git`
    *   *Purpose:* Apple's official background parser for GFM (GitHub Flavored Markdown) and AST tree generation.
2.  **TextKit 2 Renderer:** `https://github.com/nodes-app/swift-markdown-engine.git`
    *   *Purpose:* The native AppKit `NSTextView` wrapper optimized for SwiftUI, enabling live markdown token rendering.
3.  **Git Engine:** `https://github.com/ibrahimcetin/SwiftGitX.git`
    *   *Purpose:* The modern Swift async wrapper for `libgit2`. Replaces older broken packages to allow safe background commits and pulls.
4.  **Mermaid Diagrams:** `https://github.com/lukilabs/beautiful-mermaid-swift.git`
    *   *Purpose:* Parses Mermaid syntax into native SVGs instantly without loading a browser engine.

---

## 🚀 Development Setup (Xcode + AI Agent)

This repository is optimized for **Agentic Coding** using Xcode 26+ and Claude Code / Claude Desktop. 

### 1. Initialize the Workspace
```bash
# Clone or create the directory
mkdir HelloNotes && cd HelloNotes
git init
curl -s [https://raw.githubusercontent.com/github/gitignore/main/Swift.gitignore](https://raw.githubusercontent.com/github/gitignore/main/Swift.gitignore) -o .gitignore
