# HelloNotes

> **Version 1.3.2** · A blazing-fast, local-first, native macOS (and iOS) Markdown knowledge base with built-in AI — synced effortlessly via Git.

HelloNotes is a native Apple-ecosystem alternative to Electron knowledge apps like Obsidian and cross-platform editors like Typora. It's built strictly on modern Swift — **AppKit + TextKit 2 + SwiftUI** — prioritising high-FPS text rendering, plain `.md` files as the absolute source of truth, and seamless background Git synchronisation. **No proprietary database. Your files in Finder *are* the database** — and those files can live locally *or* in Box, Dropbox, OneDrive, Google Drive or iCloud, opened on demand without pulling the whole vault down.

## 📚 Documentation
| Doc | What's in it |
|---|---|
| [docs/PRD.md](docs/PRD.md) | Product vision, users, feature requirements, success metrics |
| [docs/architecture.md](docs/architecture.md) | Current 4-layer architecture + the Swift packages the app links |
| [docs/layout-architecture.md](docs/layout-architecture.md) | The shell: the axis-of-abundance rule, component sizes, the sizing contract every viewport obeys, and the settled layout decisions ([wireframes](docs/wireframes.html)) |
| [docs/unimplemented.md](docs/unimplemented.md) | Production-readiness register — release blockers, deferrals, bugs, tech debt, security, performance, usability & accessibility gaps (from a five-lane audit) |
| [docs/native-roadmap.md](docs/native-roadmap.md) | Forward roadmap for deeper Apple-platform integration (App Intents, widgets, Spotlight…) |
| [docs/cloud-native-roadmap.md](docs/cloud-native-roadmap.md) | Cloud storage: the File Provider path (on-demand files) and the direct-API providers, phase by phase |
| [docs/production.md](docs/production.md) | Step-by-step runbook to ship the app to the Mac App Store |
| [docs/signing.md](docs/signing.md) | Code-signing & provisioning notes (team, capabilities, entitlements) |
| [docs/xcode-targets-setup.md](docs/xcode-targets-setup.md) | How the Widget / Quick Look extension targets and the App Group were added |
| [docs/website.md](docs/website.md) | The product site — Astro + Tailwind, its site map, GitHub Actions deploy, DMG distribution, and the two URL traps (`base`, custom domain) |
| [CHANGELOG.md](CHANGELOG.md) | What changed in each release, in user-facing terms |
| [docs/implemented.md](docs/implemented.md) | Implementation history — milestones, the editor rewrite, the retired markdown-engine fork, GFM fidelity, HIG pass, and cloud storage |

## ✨ Features (v1.3.2)

**Local-first, multi-collection**
- No CoreData/SwiftData/iCloud store; your `.md` files are the truth. Open **several collections at once** as a *library*, with a launcher, recents, and saved library sets.
- **Obsidian vault import** — point HelloNotes at a folder of existing vaults and they open as collections, no migration.
- Non-Markdown attachments (PDF, images, CSV…) appear in the tree and open in a native **file viewer** (QuickLook/PDFKit).

**A truly native live editor** (the in-repo [`Packages/NotesEditor`](Packages/NotesEditor))
- Live TextKit 2 Markdown styling as you type: headings, emphasis, lists, task lists, tables, footnotes — with Obsidian/Bear-style **caret-driven concealment** (move the caret into a construct and its Markdown source is revealed for editing).
- Natively rendered (no browser engine): syntax-highlighted code, **LaTeX math**, **inline Mermaid diagrams**, Obsidian-style **callouts** (collapsible, with icons), dimmed `%%comments%%`, and hidden front matter paired with a typed, editable **Properties** panel.
- **Note transclusion** — `![[Note]]` / `![[Note#heading]]` render as inline cards.
- **GitHub-identical Preview** — the read-only Preview renders through **cmark-gfm** (the same engine GitHub uses) + GitHub's own CSS, proven by 648/648 GFM-spec conformance and byte-parity with the GitHub Markdown API. The live editor's styling is driven by the same engine.
- **View modes**: Edit (live), Preview (read-only), Markdown (source), and Split — plus **⌘F find & replace**, image paste → `assets/`, smart paste (HTML → Markdown), multi-tab and multi-window editing, document statistics, outline with jump-to-heading, and **HTML/PDF export**.
- **Marp slide decks** — notes with Marp front matter get a native slides preview.

**Knowledge graph**
- `[[wiki-links]]` with autocomplete, **aliases**, link-to-heading, backlinks, outgoing links, and unlinked mentions with one-click linking.
- A directional **Graph** view (arrows, focus tracing, whole-collection or N-links-around-a-note scope) and a content-based **Mind Map** of a note's ideas (sections → branches, bullets → leaves, linked notes → jump-off chips).

**Organise & find**
- One collapsible **sidebar** holding every place: **Recents** and **Bookmarks** pinned above each open collection, which expands into its own folder tree. Apple Notes' account-then-folders arrangement, and the reason the window has exactly one show/hide control — see [docs/shell-chrome.md](docs/shell-chrome.md).
- An **inspector** answering "what is this, and what touches it?" — Outline · Tags · References · Properties · History, reopening on its last-used tab. Its five tabs are selected from the toolbar directly above it (Pages' `Format`/`Document` pattern), so the panel itself carries no chrome.
- The note's title is shown **inline above the body as its H1** and renamed in place, which renames the file and rewrites every `[[wiki-link]]` to it; the caret crosses between title and body as one flow.
- Full-text search with snippets (cross-collection by design, from an always-expanded field beside the sidebar — ⌥⌘F), Open Quickly (⇧⌘O), nested `#tags` (with autocomplete), bookmarks, daily notes, and templates.

**AI, on your terms — and where you'd look for it**
- **Filed by what it acts on, not by the fact a model made it.** Summarise Note, Suggest Tags, Suggest Links and Rewrite live in the **Note** menu beside Rename and Duplicate, and each answer lands in the inspector tab that already owns that kind of information — summary in Outline, tags in Tags, links in References. A **command palette** (⇧⌘P) runs anything by name, generated from the same command surface the menu bar is, so a command that goes missing from it is a test failure.
- **Review Links** (⇧⌘L) walks a note's unmade links one at a time — **Link / Skip / Never** — showing the phrase in its sentence and the target's opening lines. "Never" persists per collection, stored outside the vault so it never reaches a shared repo. Needs no AI provider at all: it is an exact scan of your own text.
- **New Note from a Prompt** (⌃⌘N) writes a note, or researches a question on the web and lands the cited synthesis *as a note* — connected to what you already have, since every `[[link]]` the model returns is verified against the collection and the invented ones are unwrapped to plain text. You read the whole draft before the file exists.
- **Suggest as I type** *(Mac, off by default)* — ghost text after the cursor, ⌥⇥ to accept. On-device only, and never part of the note until accepted: it is drawn, never stored, so it cannot reach a save, the index or a Git diff.
- **Ask Library** — retrieval chat grounded in your notes, with citations you can jump to. An agentic **Assistant** with tools (search, read, edit-with-approval, web search/fetch), skills and deep research.
- **All of the above run on iPhone and iPad too**, except the palette and typing suggestions.
  iPad carries the menu bar and its shortcuts, file tabs, a keyboard format bar, and the
  inspector over the note rather than beside it — an iPad is never wide enough for a third
  column, and a threshold that decides whether a panel *may* open is a threshold that hides it.
- Bring your own model: **local** (Apple Foundation Models, MLX, Ollama, LM Studio) or **your own cloud API key** — Anthropic, Gemini, OpenAI, Mistral, Groq, OpenRouter, xAI (Grok), DeepSeek, Cerebras, Together AI, Perplexity, and Ollama Cloud. Keys live in the Keychain; cloud providers are off until you configure one. Features declare what they *need* and providers declare what they *offer*, so Settings can say plainly which model is doing what and what it cannot hold.

**Cloud storage — two ways, no lock-in**
- **Open a cloud folder like any other** (recommended). Box, Dropbox, OneDrive (personal *and* business), Google Drive and iCloud Drive all surface through Apple's **File Provider** layer, so their folders are just paths — point HelloNotes at one and it works. Files stay **online-only until you open them**: all vault I/O is `NSFileCoordinator`-coordinated so a cloud file materialises on demand, and indexing deliberately **skips un-downloaded notes** rather than dragging your whole vault local. Online-only notes get a cloud badge, a "N online-only" status, per-note **Download / Remove Download**, and a provider label; Git is guarded on cloud folders (auto-commit off) since libgit2 needs real local objects.
- **Or connect an account directly** — no provider app required. Built-in **Dropbox, Box, Google Drive and OneDrive** clients (plain `URLSession`, no vendor SDKs) browse and edit over the provider's own API, and **"Open as Collection"** promotes an account to a first-class collection in the sidebar: it mirrors into a local cache that reuses the entire normal pipeline (scan, index, backlinks, editor), and saves upload back automatically. OAuth uses PKCE where the provider supports it; tokens live in the Keychain and credentials stay in a git-ignored `Secrets.xcconfig`.

**Seamless Git sync**
- Repo status, init, local commits, opt-in debounced auto-commit (never auto-pushes), user-initiated push/fetch, per-note **version history** (browse & restore), **clone** (cancelable) and **create-remote** with HTTPS token auth, and an in-app git identity.

**Deep system integration**
- **Siri & Shortcuts** — `NoteEntity` App Intents (open, create, append, search) with an `AppShortcutsProvider`, so notes are scriptable from Shortcuts and callable by voice.
- **Spotlight** — notes are *donated* to the system index, so ⌘Space finds them and deep-links straight back (stale entries are retracted on rename/delete).
- **Widgets** — a recent-notes widget in all three sizes, fed by an App Group snapshot; every row deep-links to its note.
- **Quick Look** — native `.md` preview *and* thumbnail extensions, so Markdown renders in Finder's Space-bar preview and as file icons.
- **Menu-bar quick capture** — a `MenuBarExtra` jots a line into today's daily note without switching apps, plus a system-wide **⌃⌥⌘N** that brings HelloNotes forward on a new note.
- **URL scheme** — `hellonotes://note?…` / `collection` / `search` / `new` / `daily`, the shared entry point behind Shortcuts, Spotlight and widget taps.
- **Dictation** — on-device `SpeechAnalyzer` transcription straight into the daily note; **Writing Tools** and inline prediction are wired into the editor (plain-text only, so rewrites can't corrupt Markdown).
- Services menu ("New Note from Selection"), state restoration, TipKit hints, and an Icon Composer app icon.

**Native app polish**
- Full menu bar with keyboard shortcuts, a native source-list note tree, windowed Graph/Mind Map/Assistant/Ask Library surfaces, appearance settings (light/dark, accent colours, text size), a launch splash with live build info, a **first-run welcome**, and an adaptive iOS/iPadOS companion.
- Accessibility: VoiceOver labels throughout, a **headings rotor** in the editor on both platforms, and Reduce Motion support.

> WebView policy: the *editing path is 100% native TextKit 2*. A `WKWebView` appears only in read-only rendering surfaces — the macOS/iOS GFM **Preview** and the **Marp slides** preview — never in the editor itself.

## 🏗️ Architecture at a glance
A strict **4-layer architecture** keeps macOS and iOS sharing everything but the shell:
1. **Core / Domain** (pure Swift) — Markdown/front-matter/tag parsing, mention scanning, templates, graph & mind-map layout, statistics, export, Marp, Obsidian import, file watching, **coordinated file I/O** (`FileIO` — every vault read/write goes through `NSFileCoordinator`, so on-demand cloud files materialise instead of failing), and the **direct-API cloud clients** (`Core/Remote`). UI-agnostic, unit-tested.
2. **State** — the `@Observable` macro *exclusively*: `Library` → `Collection`s (scan, CRUD, bookmarks, index cache), `EditorModel`/`EditorTabs`, `LinkGraph`, `CollectionSearchModel`, `GitService` (FIFO-serialized), `AppearanceSettings`, stores for recents/libraries/credentials.
3. **Shared UI** — editor host, note tree, references panel, graph/mind map, assistant, viewers.
4. **Platform shells** — one `AdaptiveShell` for both platforms, chosen by the **axis of abundance** (width and aspect) rather than device identity, so a Mac window and an iPad of the same size lay out identically and Stage Manager stops being a special case. It places three slots: the **sidebar** (collections and folders in one tree), the editor pane, and the **inspector**. `MacContentView` and `iOSContentView` supply the slots. Every viewport in the tree obeys a **sizing contract** — a window onto content reports the size it is *offered*, never the size it *contains* — asserted by `ShellContractTests`. See [docs/layout-architecture.md](docs/layout-architecture.md).

The **editor** is a separate local SPM package, [`Packages/NotesEditor`](Packages/NotesEditor) — `MarkdownCore` (incremental block/inline parser + style spec), `MarkdownEditor` (TextKit 2 `NSTextView`/`UITextView`), and `GFMRender` (cmark-gfm for the GitHub-identical Preview + spec/API parity).

The **LLM layer** (`HelloNotes/LLM/`) follows the same split: `Sendable` provider adapters + agent tools at the Core tier; `@MainActor @Observable` models (`LLMSettings`, `AssistantModel`, `SkillStore`, `PermissionBroker`) at the State tier. Chat transcripts persist as JSONL under Application Support; API keys in the Keychain.

Full detail, data flow, and concurrency model: [docs/architecture.md](docs/architecture.md).

## 📦 Tech stack & Swift packages
Swift Package Manager, native Apple frameworks first.

**Apple frameworks:** SwiftUI · AppKit / TextKit 2 · Vision (image alt-text) · PDFKit / QuickLook · Security (Keychain) · libgit2 (via SwiftGitX)

**Packages** (see [architecture.md](docs/architecture.md) for how each is used):

| Package | Role |
|---|---|
| [`Packages/NotesEditor`](Packages/NotesEditor) (in-repo) | Live TextKit 2 Markdown editor (`MarkdownCore` + `MarkdownEditor`) and GitHub-identical Preview (`GFMRender`) |
| [swift-cmark](https://github.com/apple/swift-cmark) (`gfm` branch) | cmark-gfm — GitHub's own GFM engine, for the Preview + spec/API parity (via `GFMRender`) |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | Apple's GFM AST parser — used in Core for headings, export, and Marp splitting (not editing) |
| [SwiftGitX](https://github.com/ibrahimcetin/SwiftGitX) | Async/await Git engine over libgit2 |
| [beautiful-mermaid-swift](https://github.com/lukilabs/beautiful-mermaid-swift) + [elk-swift](https://github.com/lukilabs/elk-swift) | Native Mermaid diagram rendering + ELK layout |
| [HighlighterSwift](https://github.com/smittytone/HighlighterSwift) | Code-block syntax highlighting (GitHub theme, matching the Preview) |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) | Native LaTeX math rendering (no WebView) |
| [mlx-swift](https://github.com/ml-explore/mlx-swift) + [swift-transformers](https://github.com/huggingface/swift-transformers) | Local LLM inference on Apple silicon (MLX provider) |
| [OpenAI](https://github.com/MacPaw/OpenAI) | OpenAI-compatible provider transport |

## 🚀 Build & run
Requirements: **macOS 26.5+**, **Xcode 26+** (Swift 5.10+). iOS/iPadOS **26.5+**.

```bash
git clone https://github.com/hellotham/hellonotes.git
cd hellonotes

# Optional — only for the direct-API cloud providers (Dropbox/Box/Drive/OneDrive).
# The app builds and runs fine without this; those providers just report
# "not configured" until you add your own keys. See the file's comments for the
# console walkthrough for each provider.
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig

# Open in Xcode (SPM dependencies resolve automatically on first open)
open HelloNotes.xcodeproj

# …or build from the command line (a shared scheme is committed)
xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes -destination 'platform=macOS' build

# app unit tests
xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes -destination 'platform=macOS' -only-testing:HelloNotesTests test

# editor package tests (GFM conformance, live-editor fidelity, parser fuzz)
swift test --package-path Packages/NotesEditor

# Release build — run this too before shipping (see the note below)
xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes -destination 'generic/platform=macOS' -configuration Release build
```

> **A green Debug build does not imply Release compiles.** Optimizer-only failures
> exist: a Swift SIL-inliner crash once broke *every* Release build (and therefore
> any archive/DMG) while Debug stayed clean. Run the Release build after substantial
> changes — and if a build fails with **no `error:` line**, suspect a compiler crash
> and grep the full log for `While running pass`, which names the offending function.
> Details and the debugging recipe: [docs/production.md §1h](docs/production.md).

Run the **HelloNotes** scheme, then click **Open…** and choose any directory of Markdown files — or point it at the bundled [`SampleVault/`](SampleVault/), whose notes demonstrate callouts, diagrams, math, transclusion, wiki-links, tags, slides, daily notes, and templates.

## 🗂️ Project layout
```
HelloNotes/            App sources (synchronised Xcode group)
  ├─ Core/             Layer 1 — pure logic: parsing, front matter, tags,
  │                     mentions, templates, layouts, stats, export, Marp,
  │                     Obsidian import, smart paste, index cache, build info,
  │                     coordinated file I/O (FileIO), cloud-provider detection
  │   └─ Remote/       Direct-API cloud: RemoteStore protocol + Dropbox/Box/
  │                     GoogleDrive/OneDrive clients, RemoteMirror (cloud
  │                     account → local mirror → first-class collection)
  ├─ State/            Layer 2 — @Observable models (library/collections,
  │                     editor/tabs, link graph, search, git, appearance,
  │                     bookmarks/recents/credentials)
  ├─ LLM/              AI layer — provider adapters (Anthropic, OpenAI-compat,
  │                     Gemini, MLX, Apple), agent runtime (tools, skills,
  │                     permissions, deep research), settings & chat stores
  ├─ UI/               Layer 3 — shared views (editor host, tree, references,
  │                     graph, mind map, slides, viewers, assistant, splash)
  │   └─ Shell/        Layer 4 — the layout contract (ShellContract), the
  │                     arrangement (AdaptiveShell), the collection tree,
  │                     the inspector, the compact shell
  ├─ MacContentView    Layer 4 — the macOS slots for AdaptiveShell
  ├─ iOSContentView    Layer 4 — the iOS/iPadOS slots for the same shell
  └─ HelloNotesApp     App entry (main window + auxiliary window scenes)
Packages/NotesEditor/  Live editor package (MarkdownCore, MarkdownEditor, GFMRender)
website/               Product site — Astro 7 + Tailwind 4 → hellotham.com/hellonotes
Config/                Secrets.example.xcconfig (template); Secrets.xcconfig is git-ignored
docs/                  PRD, architecture, roadmaps (native + cloud), production, history
HelloNotesTests/       App unit tests
SampleVault/           Demo collection used by docs & screenshots
HelloNotes.xcodeproj/  Project (SPM dependencies, shared scheme)
```

## 🌐 Product site
**<https://hellotham.com/hellonotes/>** — landing page, feature tour, screenshots, download,
an eight-section online user manual, and about / privacy / support pages. Published by
**Hello Tham** (<https://hellotham.com>). Built from [`website/`](website/) with **Astro 7 +
Tailwind 4** (the CSS-first `@tailwindcss/vite` plugin; there is no `tailwind.config.js` — the
palette lives in an `@theme` block in `src/styles/global.css`).

```bash
cd website
npm install
npm run dev      # http://localhost:4321/hellonotes/  (note the base path)
npm run build    # static output → website/dist
```

It deploys on every push to `main` that touches `website/`, via
[`.github/workflows/deploy-website.yml`](.github/workflows/deploy-website.yml) (`withastro/action` →
`actions/deploy-pages`). Pages is in **GitHub Actions** mode — nothing is committed to a
`gh-pages` branch.

The **download button points at the latest GitHub Release**, not at a file in the site, so
shipping a build means publishing a release — the 35 MB disk image is deliberately kept out of
git history. `src/lib/site.ts` holds the version, size and SHA-256 the download page prints,
and must match the attached artefact.

The site follows your system appearance and can be pinned **Auto / Light / Dark** from the nav.
Every colour is a semantic token declared once as `light-dark(<light>, <dark>)` in
`src/styles/global.css` — there are no colour literals anywhere else. Screenshots are shot
**twice**, light and dark, composited by
[`scripts/make-screenshots.py`](scripts/make-screenshots.py) and registered in
`src/lib/screens.ts`; they follow whichever appearance the site is showing.

Three things to know before editing it — the first two fail *silently* (the build succeeds and
only the live site is wrong). See [docs/website.md](docs/website.md):
- It's a **project page** under `base: '/hellonotes'`, so build internal links and asset paths
  with the `href()` helper in `src/lib/paths.ts` rather than hard-coding the prefix.
- `site` is the **custom domain** (`hellotham.com`), inherited from the `hellotham.github.io`
  user-site repo — so this repo needs no `CNAME`, and canonical/OG URLs must not point at
  `github.io`, which merely redirects.
- **Keyboard shortcuts in the manual come from `AppCommands.swift`, not from memory.** Grep for
  a binding before documenting it; a first pass invented two that don't exist.
- **`og:image` must live in `public/`, never `src/assets/`.** Processed assets get
  content-hashed filenames that change on re-export, and social crawlers cache by URL — this
  shipped broken once, 404ing on every page while the build stayed green.
- **`light-dark()` takes colours, not values.** Wrapping a whole gradient in it is invalid and
  silently renders gradient-filled text transparent — put it on each stop.
- **Mind JSX whitespace.** Astro applies JSX rules to any element containing an expression, so a
  newline between text and an inline `<a>` eats the space. 28 of these shipped; use `{' '}`.

## 🤝 Contributing / working rules
Project conventions live in [CLAUDE.md](CLAUDE.md): macOS 26.5+ / iOS 26.5+ / Swift 5.10+ / Xcode 26; `@Observable` only (no `ObservableObject`/`StateObject`); no CoreData/SwiftData; Git via SwiftGitX; every change must build clean (0 errors) before it's done.

## 📄 License
See [LICENSE](LICENSE).
