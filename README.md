# HelloNotes

> **Version 1.3.5** · A blazing-fast, local-first, native macOS (and iOS) Markdown knowledge base with built-in AI — synced effortlessly via Git.

HelloNotes is a native Apple-ecosystem alternative to Electron knowledge apps like Obsidian and cross-platform editors like Typora. It's built strictly on modern Swift — **AppKit + TextKit 2 + SwiftUI** — prioritising high-FPS text rendering, plain `.md` files as the absolute source of truth, and seamless background Git synchronisation. **No proprietary database. Your files in Finder *are* the database** — and those files can live locally *or* in Box, Dropbox, OneDrive, Google Drive or iCloud, opened on demand without pulling the whole vault down.

## 📚 Documentation
| Doc | What's in it |
|---|---|
| [docs/PRD.md](docs/PRD.md) | Product vision, users, feature requirements, success metrics |
| [docs/architecture.md](docs/architecture.md) | Current 4-layer architecture + the Swift packages the app links |
| [docs/ui.md](docs/ui.md) | The UI design: the axis-of-abundance rule and the shells, component sizes, the app-drawn chrome, the sizing contract every viewport obeys, and the layout decisions. The window's parts each have their own: [primary sidebar](docs/primary.md), [right panel](docs/secondary.md), [toolbars](docs/toolbars.md), [tabs](docs/tabs.md), [menu bar](docs/menu.md) |
| [docs/unimplemented.md](docs/unimplemented.md) | Production-readiness register — release blockers, deferrals, bugs, tech debt, security, performance, usability & accessibility gaps (from a five-lane audit) |
| [docs/native-roadmap.md](docs/native-roadmap.md) | Forward roadmap for deeper Apple-platform integration (App Intents, widgets, Spotlight…) |
| [docs/cloud-native-roadmap.md](docs/cloud-native-roadmap.md) | Cloud storage: the File Provider path (on-demand files) and the direct-API providers, phase by phase |
| [docs/production.md](docs/production.md) | Step-by-step runbook to ship the app — the App Store (Mac, iPhone and iPad) and the notarised DMG |
| [docs/signing.md](docs/signing.md) | Code-signing & provisioning notes (team, capabilities, entitlements) |
| [docs/xcode-targets-setup.md](docs/xcode-targets-setup.md) | How the Widget / Quick Look extension targets and the App Group were added |
| [docs/website.md](docs/website.md) | The product site — Astro + Tailwind, its site map, GitHub Actions deploy, DMG distribution, and the two URL traps (`base`, custom domain) |
| [CHANGELOG.md](CHANGELOG.md) | What changed in each release, in user-facing terms |
| [docs/implemented.md](docs/implemented.md) | Implementation history — milestones, the editor rewrite, the retired markdown-engine fork, GFM fidelity, HIG pass, and cloud storage |

## ✨ Features (v1.3.5)

**Local-first, multi-collection**
- No CoreData, SwiftData or database; your `.md` files are the truth (settings sync through iCloud's key-value store — never a note). Open **several collections at once** as a *library*, with a launcher, recents, and saved library sets. The first launch opens **DefaultCollection**, the bundled tour and user manual; File ▸ Open Default Collection brings it back.
- **Obsidian vault import** — point HelloNotes at a folder of existing vaults and they open as collections, no migration.
- Non-Markdown attachments (PDF, images, CSV…) appear in the tree and open in a native **file viewer** (QuickLook/PDFKit).

**A truly native live editor** (the in-repo [`Packages/NotesEditor`](Packages/NotesEditor))
- Live TextKit 2 Markdown styling as you type: headings, emphasis, lists, task lists, tables, footnotes — with Obsidian/Bear-style **caret-driven concealment** (move the caret into a construct and its Markdown source is revealed for editing).
- Natively rendered (no browser engine): syntax-highlighted code, **LaTeX math**, **inline Mermaid diagrams**, Obsidian-style **callouts** (collapsible, with icons), dimmed `%%comments%%`, and hidden front matter paired with a typed, editable **Properties** panel.
- **Note transclusion** — `![[Note]]` / `![[Note#heading]]` render as inline cards.
- **GitHub-identical Preview** — the read-only Preview renders through **cmark-gfm** (the same engine GitHub uses) + GitHub's own CSS, proven by 672/672 GFM-spec conformance and byte-parity with the GitHub Markdown API. The live editor's styling is driven by the same engine.
- **View modes**: Edit (live), Preview (read-only), Markdown (source), and Split — plus **⌘F find & replace**, image paste → `assets/`, smart paste (HTML → Markdown), multi-tab and multi-window editing, document statistics, outline with jump-to-heading, and **HTML/PDF export**.
- **Marp slide decks** — notes with Marp front matter get a native slides preview.

**Knowledge graph**
- `[[wiki-links]]` with autocomplete, **aliases**, link-to-heading, backlinks, outgoing links, and unlinked mentions with one-click linking.
- A **Graph** of each note's links in and out (arrows, focus tracing, and a link or two further if you like), in the panel beside the note, and a **Mind Map** of the links across the whole collection — its most-connected notes as branches, every other linked note under the branch it is closest to, the links the tree has no line for dashed across it — in a tab of its own.

**Organise & find**
- One collapsible **sidebar** holding every place: **Recents** and **Bookmarks** pinned above each open collection, which expands into its own folder tree, with the collection's tools — **Mind Map**, **Assistant**, **Git** — as rows above it and a `+` for folders and collections. Apple Notes' account-then-folders arrangement, in the window's one collapsible column. Where the window is *taller than it is wide* — an iPad in portrait — that navigation becomes a band across the top and splits into two panes, Finder-style: folders on the left, the notes inside the selected one on the right. Both are the same tree; the band is simply too wide and too short for one list. See [docs/shell-chrome.md](docs/shell-chrome.md).
- A **right panel** answering "what is this note, and what touches it?" — Summary & Outline · Tags · Links · Properties · History · Graph, reopening on its last-used view. The views are chosen from an icon strip in the panel's own header, which becomes a pull-down when the panel is narrow. The **bar over the note** is three buttons — `+` (New Note, Today's Note, New Note from a Prompt, Quick Capture, Dictate to Daily Note), search and Settings — then your tabs, the note's own actions and Show/Hide Panel.
- The note's title is shown **inline above the body as its H1** and renamed in place, which renames the file and rewrites every `[[wiki-link]]` to it; the caret crosses between title and body as one flow.
- Full-text search with snippets across every open collection — **Search Notes** (⌥⌘F) opens its field in the search button's place for as long as the search lasts — Open Quickly (⇧⌘O), `#tags` with autocomplete (`/` is allowed in a name) **and front-matter `tags:` — both spellings count, so an Obsidian vault's tags are visible here**, bookmarks, daily notes, and templates.

**AI, on your terms — and where you'd look for it**
- **Filed by what it acts on, not by the fact a model made it.** Summarise Note, Suggest Tags, Suggest Links and Rewrite live in the **Note** menu beside Rename and Duplicate, and each answer lands in the panel view that already owns that kind of information — summary in Summary & Outline, tags in Tags, links in Links. **Accepting one writes a property, never your prose** — `tags:`, `related:`, `summary:` — so it is visible in Properties and removable there, and a `related:` link is still a real link the graph sees. A **command palette** (⇧⌘P) runs anything by name, generated from the same command surface the menu bar is, so a command that goes missing from it is a test failure.
- **Review Links** (⇧⌘L) walks a note's unmade links one at a time — **Link / Skip / Never** — showing the phrase in its sentence and the target's opening lines. "Never" persists per collection, stored outside the vault so it never reaches a shared repo. Needs no AI at all: it is an exact scan of your own text.
- **New Note from a Prompt** (⌃⌘N) writes a note, or researches a question on the web and lands the cited synthesis *as a note* — connected to what you already have, since every `[[link]]` the model returns is verified against the collection and the invented ones are unwrapped to plain text. You read the whole draft before the file exists.
- **Suggest as I type** *(off by default)* — ghost text after the cursor, ⌥⇥ to accept (or tap it, on iPhone and iPad). On-device only, and never part of the note until accepted: it is drawn, never stored, so it cannot reach a save, the index or a Git diff.
- An **Assistant** *(experimental)* that answers from your notes and shows the notes it read, in a tab beside them (⇧⌘A). With **Use my notes** on it searches them — by their words, by section, and to the end of a long note — reads what it finds, and can search the web (and, on a model with a 16K window, fetch web pages and run deep research), with skills; off, it answers from the model alone and reads nothing. It never changes a note: no edits, no approvals. Select text and choose **Ask the Assistant** to ask it about a passage; a conversation that outgrows the model's window has its earlier messages summarised so it can go on.
- **All of the above run on iPhone and iPad too** (the command palette opens from the
  menu bar, so on iPad). iPad carries the menu bar and its shortcuts, file tabs, and the
  right panel as a resizable column beside the note — an editor never blocks editing, so
  only a window as narrow as a phone carries the panel over the note. Formatting lives in
  **the system's own bar above the keyboard** — the floating shortcuts row on iPad, an
  accessory bar on iPhone — so it costs the app no screen space, appears with a hardware
  keyboard too, and shows whenever there is a cursor rather than following the view mode.
- **AI on Apple Foundation Models, and nothing else** — on a model named for where it runs. **Local (Apple)** is Apple's on-device model (AFM 3 Core or Core Advanced, whichever the hardware runs); **Cloud (Apple)** is Apple's server model on Private Cloud Compute, in App Store builds only (Apple doesn't provision its entitlement for Developer ID, so never the DMG); **Local (*model name*)** is an open **MLX** model you download, plugged into Foundation Models through its `LanguageModel` protocol. One **Default model** in Settings ▸ AI serves everything, the Assistant's menu can pick another for one conversation, and its answers and suggestions say which model made them. When Cloud (Apple)'s daily allowance is used up, Local (Apple) does the work until it resets. No third-party AI services and no API keys; keys stored by earlier versions are deleted on upgrade.
- **Every feature fits the model's window.** Apple's models are asked for their context size (an MLX model is given the device's: 16,384 tokens on the Mac, 8,192 on iPhone and iPad), and each feature sizes what it sends to fit — a long note is summarised in parts rather than cut off, a rewrite too large to return whole is refused rather than truncated, and the Assistant sends the recent turns that fit, with the earlier ones summarised, while the whole conversation stays on screen.

**Cloud storage — two ways, no lock-in**
- **Open a cloud folder like any other** (recommended). Box, Dropbox, OneDrive (personal *and* business), Google Drive and iCloud Drive all surface through Apple's **File Provider** layer, so their folders are just paths — point HelloNotes at one and it works. Files stay **online-only until you open them**: all vault I/O is `NSFileCoordinator`-coordinated so a cloud file materialises on demand, and indexing deliberately **skips un-downloaded notes** rather than dragging your whole vault local. Online-only notes get a cloud badge, a "N online-only" status, per-note **Download / Remove Download**, and a provider label; Git is guarded on cloud folders (auto-commit off) since libgit2 needs real local objects.
- **Or connect an account directly** — no provider app required. Built-in **Dropbox, Box, Google Drive and OneDrive** clients (plain `URLSession`, no vendor SDKs) browse the provider's own API in a folder picker, and **Open** promotes a folder to a first-class collection in the sidebar: it mirrors into a local cache that reuses the entire normal pipeline (scan, index, backlinks, editor), and saves upload back automatically. OAuth uses PKCE where the provider supports it; tokens live in the Keychain and credentials stay in a git-ignored `Secrets.xcconfig`.
- **Both live in one screen** — `File ▸ Open Collection ▸ from Cloud…` opens **Manage Cloud Collections**: the cloud collections you already have (removable, without deleting a thing), the ways to add another, and your accounts. **Several accounts per service** are first-class — a personal *and* a work OneDrive each keep their own credentials, are named whatever you call them, and can each supply as many collections as you like. Which route applies is answered rather than asked: on macOS the app reads the installed provider clients and names them.

**Seamless Git sync**
- Repo status, init, local commits, opt-in debounced auto-commit (never auto-pushes), user-initiated push/fetch, per-note **version history** (browse & restore), **clone** (cancelable) and **create-remote** with HTTPS token auth, and an in-app git identity.

**Deep system integration**
- **Siri & Shortcuts** — `NoteEntity` App Intents (open, create, append, search) with an `AppShortcutsProvider`, so notes are scriptable from Shortcuts and callable by voice.
- **Spotlight** — notes are *donated* to the system index, so ⌘Space finds them and deep-links straight back (stale entries are retracted on rename/delete).
- **Widgets** — a recent-notes widget in all three sizes, fed by an App Group snapshot; in the medium and large sizes every row deep-links to its note, and the small one opens the most recent.
- **Quick Look** — native `.md` preview *and* thumbnail extensions, so Markdown renders in Finder's Space-bar preview and as file icons.
- **Quick capture** — **Quick Capture** (⌃⌘K) adds a line to today's note on both platforms; on the Mac a `MenuBarExtra` does it without switching apps, and a system-wide **⌃⌥⌘N** brings HelloNotes forward on a new note.
- **URL scheme** — `hellonotes://note?…` / `collection` / `search` / `new` / `daily`, the shared entry point behind Shortcuts, Spotlight and widget taps.
- **Dictation** (⌃⌘D) — on-device `SpeechAnalyzer` transcription straight into the daily note; **Writing Tools** and inline prediction are wired into the editor (plain-text only, so rewrites can't corrupt Markdown).
- Services menu ("New HelloNotes Note from Selection"), state restoration, and an Icon Composer app icon.

**Native app polish**
- Full menu bar with keyboard shortcuts (⌘, opens Settings on iPad too), a note tree the app draws in source-list style — the same on the Mac and the iPad — with the collection's commands beside it, the Mind Map and the Assistant as tabs beside your notes, appearance settings (light/dark, accent colours, text size), a launch splash with live build info, and an adaptive iOS/iPadOS companion.
- Accessibility: VoiceOver labels throughout, and a **headings rotor** in the editor on both platforms.

> WebView policy: *typing is 100% native TextKit 2*. A `WKWebView` appears only in read-only rendering — the GFM **Preview**, the **Marp slides** preview, and, in Edit, an off-screen render of a raw HTML block, drawn as an image while the caret is elsewhere so that Edit shows what Preview shows — never where you type.

**Free, and what backing it adds**
- Every feature is included for everyone. Two voluntary products — **Champion** (a one-off contribution, repeatable and counted) and **Commercial** (an annual licence for using it at work) — and the only thing either unlocks is an **in-app support request**, which is a channel to the person who makes it rather than a faster queue. `SupportContractTests` fails if anything else starts consulting a purchase.
- The support request composes a message and hands it to your own mail app; HelloNotes sends nothing itself and includes nothing about your notes — only the app's version and build, the platform and OS version, and which support you have.

## 🏗️ Architecture at a glance
A strict **4-layer architecture** keeps macOS and iOS sharing everything but the shell:
1. **Core / Domain** (pure Swift) — Markdown/front-matter/tag parsing, mention scanning, templates, graph & mind-map layout, statistics, export, Marp, Obsidian import, file watching, **coordinated file I/O** (`FileIO` — every vault read/write goes through `NSFileCoordinator`, so on-demand cloud files materialise instead of failing), and the **direct-API cloud clients** (`Core/Remote`). UI-agnostic, unit-tested.
2. **State** — the `@Observable` macro *exclusively*: `Library` → `Collection`s (scan, CRUD, bookmarks, index cache), `EditorModel`/`EditorTabs`, `LinkGraph`, `CollectionSearchModel`, `GitService` (FIFO-serialized), `AppearanceSettings`, stores for recents/libraries/credentials.
3. **Shared UI** — editor host, note tree, references panel, graph/mind map, assistant, viewers.
4. **Platform shells** — one `AdaptiveShell` for both platforms, chosen by the **axis of abundance** (width and aspect) rather than device identity, so a Mac window and an iPad of the same size lay out identically and Stage Manager stops being a special case. It places three slots: the **sidebar** (collections and folders in one tree), the editor pane, and the **right panel**. `ContentView` — one struct for both platforms — supplies the slots. Every viewport in the tree obeys a **sizing contract** — a window onto content reports the size it is *offered*, never the size it *contains* — asserted by `ShellContractTests`. See [docs/layout-architecture.md](docs/layout-architecture.md).

The **editor** is a separate local SPM package, [`Packages/NotesEditor`](Packages/NotesEditor) — `MarkdownCore` (incremental block/inline parser + style spec), `MarkdownEditor` (TextKit 2 `NSTextView`/`UITextView`), and `GFMRender` (cmark-gfm for the GitHub-identical Preview + spec/API parity).

The **Intelligence layer** (`HelloNotes/Intelligence/`) is built on the Foundation Models framework: `LanguageModels` resolves the chosen model (on-device, Private Cloud Compute or MLX) and names it by where it runs, `IntelligenceService` and `DeepResearch` run the writing tools and research, and the Assistant is a `LanguageModelSession` driven by a dynamic profile over the collection's read-only tools (`ToolContext`) — it searches and reads notes and looks things up on the web, and nothing it is offered changes a note. Chat transcripts persist as Foundation Models `Transcript` JSON under Application Support.

Full detail, data flow, and concurrency model: [docs/architecture.md](docs/architecture.md).

## 📦 Tech stack & Swift packages
Swift Package Manager, native Apple frameworks first.

**Apple frameworks:** SwiftUI · AppKit / TextKit 2 · Foundation Models · Vision (image alt-text) · PDFKit / QuickLook · Security (Keychain) · libgit2 (via SwiftGitX)

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
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) (`MLXFoundationModels`) + [mlx-swift](https://github.com/ml-explore/mlx-swift) | Open models on Apple silicon, as a Foundation Models `LanguageModel` |
| [swift-transformers](https://github.com/huggingface/swift-transformers) + [swift-huggingface](https://github.com/huggingface/swift-huggingface) | Tokenizers and Hugging Face Hub downloads for MLX models |

## 🚀 Build & run
Requirements: **macOS 27+**, **Xcode 27+** (Swift 5.10+). iOS/iPadOS **27+**.

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

# …or build from the command line (a shared scheme is committed). Every app
# xcodebuild needs -skipPackagePluginValidation: mlx-swift's Cmlx target carries a
# build-tool plugin (inert on Apple platforms) that a command line cannot trust.
xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes -destination 'platform=macOS' -skipPackagePluginValidation build

# app unit tests — through the script, never a bare `xcodebuild test`: the bundle is
# hosted by the app, so the script quits a running HelloNotes first and cleans up after
./scripts/run-tests.sh

# editor package tests (GFM conformance, live-editor fidelity, parser fuzz) — on the Mac,
# and on iOS, which `swift test` never builds (make an iPad simulator named HN-iPad first)
swift test --package-path Packages/NotesEditor
(cd Packages/NotesEditor && xcodebuild test -scheme NotesEditor-Package -destination 'platform=iOS Simulator,name=HN-iPad')

# Release build — run this too before shipping (see the note below)
xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes -destination 'generic/platform=macOS' -configuration Release -skipPackagePluginValidation build
```

> **A green Debug build does not imply Release compiles.** Optimizer-only failures
> exist: a Swift SIL-inliner crash once broke *every* Release build (and therefore
> any archive/DMG) while Debug stayed clean. Run the Release build after substantial
> changes — and if a build fails with **no `error:` line**, suspect a compiler crash
> and grep the full log for `While running pass`, which names the offending function.
> Details and the debugging recipe: [docs/production.md §1h](docs/production.md).

Run the **HelloNotes** scheme: the first launch opens the bundled [`DefaultCollection/`](DefaultCollection/) — a tour of the app and its user manual. Open any folder of Markdown files with **File ▸ Open…**, or the repo's [`SampleVault/`](SampleVault/), whose notes demonstrate callouts, diagrams, math, transclusion, wiki-links, tags, slides, daily notes, and templates.

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
  ├─ Intelligence/     AI layer on Foundation Models — models (on-device,
  │                     MLX), writing tools and research, the Assistant
  │                     (profile, tools, skills), settings & chats
  ├─ UI/               Layer 3 — shared views (editor host, tree, references,
  │                     graph, mind map, slides, viewers, assistant, splash)
  │   └─ Shell/        Layer 4 — the layout contract (ShellContract), the
  │                     arrangement (AdaptiveShell), the compact shell, the
  │                     inspector, and the app-drawn chrome (Chrome*)
  ├─ ContentView       Layer 4 — the slots for AdaptiveShell, one struct
  │                     for both platforms
  └─ HelloNotesApp     App entry (main window + auxiliary window scenes)
Packages/NotesEditor/  Live editor package (MarkdownCore, MarkdownEditor, GFMRender)
website/               Product site — Astro 7 + Tailwind 4 → hellotham.com/hellonotes
Config/                Secrets.example.xcconfig (template); Secrets.xcconfig is git-ignored
docs/                  PRD, architecture, roadmaps (native + cloud), production, history
HelloNotesTests/       App unit tests
DefaultCollection/     The bundled tour and user manual (in the app; the screenshots' source)
SampleVault/           A sample collection, used by the tests
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
shipping a build means publishing a release — the ~30 MB disk image is deliberately kept out of
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
- **Keyboard shortcuts in the manual come from the source, not from memory** — `AppCommands.swift`,
  the other `.keyboardShortcut(` calls, and the editor's own key handlers. Grep for a binding before
  documenting it; a first pass invented two that don't exist.
- **`og:image` must live in `public/`, never `src/assets/`.** Processed assets get
  content-hashed filenames that change on re-export, and social crawlers cache by URL — this
  shipped broken once, 404ing on every page while the build stayed green.
- **`light-dark()` takes colours, not values.** Wrapping a whole gradient in it is invalid and
  silently renders gradient-filled text transparent — put it on each stop.
- **Mind JSX whitespace.** Astro applies JSX rules to any element containing an expression, so a
  newline between text and an inline `<a>` eats the space. 28 of these shipped; use `{' '}`.

## 🤝 Contributing / working rules
Project conventions live in [CLAUDE.md](CLAUDE.md): macOS 27+ / iOS 27+ / Swift 5.10+ / Xcode 27; `@Observable` only (no `ObservableObject`/`StateObject`); no CoreData/SwiftData; Git via SwiftGitX; every change must build clean (0 errors) before it's done.

## 📄 License
See [LICENSE](LICENSE).
