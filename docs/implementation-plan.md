# HelloNotes — Implementation Plan

> Status: **Draft v1** · Last updated: 2026-07-11 · Companion to [PRD.md](PRD.md) and [architecture.md](architecture.md)

Milestone-based build sequence. Each milestone ends with a **green build** (`xcodebuild … build` → 0 errors) and, where noted, tests. Priorities map to the PRD (P0 = MVP).

---

## Milestone 0 — Foundation ✅ (done)
- `Note` model; `WorkspaceIndexer` (`@Observable`) with vault scan + `NSOpenPanel`.
- 3-column `MacContentView`; `WindowGroup` app entry with env injection.
- Project builds clean on macOS.

## Milestone 1 — Editing MVP (v0.1)  ← **this pass**
Goal: **select a vault → open a note → edit with live Markdown → auto-save to disk → create/delete notes.**

| # | Task | File(s) | Acceptance |
|---|---|---|---|
| 1.1 | Link `MarkdownEngine` + `MarkdownEngineCodeBlocks` products to the `HelloNotes` target | `project.pbxproj` | Target compiles with `import MarkdownEngine`. |
| 1.2 | `EditorModel` (`@Observable`): load file text, dirty tracking, **debounced autosave** (atomic write), flush on note-switch/termination | `State/EditorModel.swift` | Edits hit disk ≤1s after typing stops; kill-mid-edit leaves file intact. |
| 1.3 | `NoteEditorView` hosting `NativeTextViewWrapper` with the code-highlight bridge; saved/unsaved indicator | `UI/NoteEditorView.swift` | Typing renders live; code blocks highlight. |
| 1.4 | Wire selection: selecting a note in col 2 loads it into the editor in col 3 | `MacContentView.swift` | Clicking a note shows its content, editable. |
| 1.5 | File ops on `WorkspaceIndexer`: `createNote(title:)`, `deleteNote(_:)` (to Trash), rescan | `WorkspaceIndexer.swift` | New note appears in list & Finder; delete moves to Trash. |
| 1.6 | Sidebar actions: "New Note", title filter field | `MacContentView.swift` | New note button works; filter narrows the list. |
| 1.7 | Persist vault via **security-scoped bookmark**; restore on launch | `WorkspaceIndexer.swift` | Relaunch reopens the last vault automatically. |
| 1.8 | Build gate + smoke test of autosave round-trip | tests | 0 errors/0 warnings; round-trip test passes. |

**MVP done-when:** open an existing folder of `.md` files, edit any note with live formatting and code highlighting, changes auto-persist, and new/deleted notes reflect on disk — all reopening cleanly on relaunch.

## Milestone 2 — Knowledge graph & math (v0.2)  ✅ (done)  [P1]
- ✅ Added `MarkdownEngineLatex` + `Markdown` (swift-markdown) to the target.
- ✅ `Core/MarkdownParsing` extracts `[[wiki-links]]` (regex), headings (swift-markdown AST), `#tags` (regex).
- ✅ `LinkGraph` (`@Observable`): async backlink index, rebuilt off-main on note-set / save changes.
- ✅ Backlinks panel in the editor column; navigation between linked notes.
- ✅ LaTeX rendering (SwiftMath bridge).
- ✅ Wiki-link click → navigate. **Required a `VaultWikiLinkResolver`**: MarkdownEngine only makes a `[[Name]]` clickable when a `WikiLinkResolver` reports the target `exists`. The resolver reports existence only (empty `id`) so the editor never rewrites `[[Name]]` → `[[Name|id]]` — files stay byte-for-byte intact. Existing targets are underlined/clickable; unknown targets render muted.
- Follow-ups: create-on-miss by clicking a muted link (the package doesn't fire the callback for non-existent targets); incremental (per-note) graph updates instead of full rebuilds; `#tags` index UI.

## Milestone 3 — Search & navigation (v0.2–0.3)  ✅ (mostly done)  [P1]
- ✅ Full-text workspace search: the list matches note titles *and* bodies, with a snippet per hit (`VaultSearchModel` caches contents off-main).
- ✅ "Open Quickly" fuzzy finder (⌘O) over note titles + headings (`FuzzyMatch`, `OpenQuicklyView`); Return opens the top hit.
- ✅ External-change detection via `Core/FileWatcher` (FSEvents) → auto re-index on external edits / git pulls / Finder ops.

### Deferred items — follow-up pass ✅
Completed after the initial M2/M3 passes:
- ✅ **Folder tree with sort options** (`Core/VaultTree`, `UI/VaultTreeRow`): the note list is a real folder tree with expand/collapse; sort by name or modified time (folders first).
- ✅ **`#tags` filter** (M2): tags indexed in `VaultSearchModel`; a sidebar TAGS section filters the list to a tag; "All Notes" clears it.
- ✅ **Open-note conflict handling** (`EditorModel.reconcileWithDisk`): when the open note changes on disk, a clean buffer silently reloads; an unsaved buffer raises a "Reload / Keep Mine" banner instead of clobbering edits.

Still deferred, with rationale:
- **Scroll-to-heading** when opening a heading hit — MarkdownEngine exposes no public scroll-to-range API, so a heading hit currently opens the note at the top.
- **Create-on-miss by clicking a muted `[[link]]`** — MarkdownEngine doesn't fire the link callback for non-existent targets; needs a different hook.
- **Incremental (per-note) index/graph updates** — the current full rebuild is correct and fast for target vault sizes; optimize when large-vault profiling warrants it.

## Milestone 4 — Git sync (v0.3)  ✅ (mostly done)  [P1]
- ✅ `State/GitService` (`@Observable`) over SwiftGitX; blocking libgit2 calls run off the main actor.
- ✅ Repo status in the sidebar (branch, clean / N-changed); **Initialize Repository** (explicit — never auto-creates `.git`).
- ✅ Local **Commit** (stages all, commits) + opt-in debounced **auto-commit** (local only; never auto-pushes).
- ✅ **Push** / **Fetch** wired as user-initiated actions (Sync menu).
- **Notable fix:** a GUI-launched app can't resolve the user's global `~/.gitconfig`, so `git_commit_create_from_stage` had no signature and commits failed silently. `GitService.ensureCommitIdentity` now writes a commit identity into the repo's **local** config (from global if readable, else the macOS account name), so commits always succeed.

Still deferred, with rationale:
- **Pull / merge** — SwiftGitX exposes `fetch` and `push` but no merge, so a true pull isn't available yet; Fetch updates refs and the user merges externally.
- **Remote auth** — push/fetch rely on libgit2's configured credentials (SSH agent / stored tokens); the app doesn't manage credentials (and must not, per safety rules). Push was implemented but not exercised against a real remote.
- **Real git identity UI** — commits currently fall back to the OS account identity when global config is unreadable; a proper in-app git-identity setting is a follow-up.
- **Conflict-resolution UI** for merge conflicts (P2).

## Milestone 5 — Native rendering polish (v0.3+)  ✅ (mostly done)  [P1/P2]
- ✅ **Image paste → asset folder** (`Core/ImagePaste`): a pasted image is saved as a PNG in an `assets/` folder beside the note, and a relative `![](assets/…)` link is inserted — notes stay plain text referencing real files.
- ✅ **Front-matter panel** (`MarkdownParsing.frontMatter` + `NoteEditorView`): leading `---` YAML is shown as a key/value summary above the editor.
- ✅ **Native Mermaid** (`UI/MermaidPreviewView` + beautiful-mermaid): a Diagrams toolbar button renders the note's ```mermaid blocks as native images — no WebView. (Fixed a Core Graphics origin flip so diagrams display right-way-up.)
- Tables & footnotes already render live via MarkdownEngine.

Still deferred, with rationale:
- **Inline Mermaid in the editor** — MarkdownEngine exposes no custom code-block render hook, so diagrams preview in a sheet rather than rendering inline. Inline would require an upstream feature or a fork.
- **Hiding raw front matter in the editor** — MarkdownEngine renders the `---` block as text; the panel is an additional summary. Suppressing the raw block needs an editor hook we don't have.

## Milestone 6 — iOS shell (v0.4)  ✅ (done)  [P2]
- ✅ Made the app build for iOS: MarkdownEngine is macOS-only, so its three products are now linked with a `platformFilters = (macos)` filter in the project; the iOS build links SwiftGitX / beautiful-mermaid / swift-markdown (all iOS-capable) but not MarkdownEngine.
- ✅ `iOSContentView` — a push-based `NavigationStack`: vault selection via `.fileImporter` (folder), a searchable note list, and a note detail screen. Shares `Note`, `WorkspaceIndexer`, and `EditorModel` with macOS.
- ✅ iOS editor is a plain-text `TextEditor` (MarkdownEngine's TextKit 2 editor is AppKit-only) backed by the **same** `EditorModel` load / dirty / debounced-autosave logic.
- ✅ Security-scoped resource access for the sandboxed iOS file system (`startAccessingSecurityScopedResource` on vault open/restore).
- Verified in the iOS Simulator: pick a folder → notes list → open a note → edit → autosave persists to disk.

iOS scope note: macOS-only features (live styling / code / math via MarkdownEngine, FSEvents watching, Open Quickly, folder tree, tags, Git UI, image paste, Mermaid preview) are not on iOS yet — it is a browse / read / plain-text-edit companion for now. A richer iOS editor (UITextView / TextKit 2) is a future milestone.

### iPadOS layout ✅
- The iOS shell is a single adaptive `NavigationSplitView` (replacing the earlier `NavigationStack`): a **two-column** list + editor on iPad (and iPhone landscape / regular width), automatically **collapsing to a single-column push stack** on iPhone. One code path serves iPhone, iPad, and iPhone-in-landscape.
- Verified in both simulators: on iPad, selecting a note opens it in the right-hand editor while the list stays visible on the left; on iPhone, the same selection pushes to a full-screen editor with a back button. Editing autosaves to disk on both.

---

## Sequencing notes
- **1.1 is the gate** for everything else in Milestone 1 — without linking the MarkdownEngine products, the editor can't build.
- Keep new Core/State/UI types in subfolders (`Core/`, `State/`, `UI/`) inside the synchronized `HelloNotes/` group so Xcode picks them up automatically.
- Each task is small enough to build-verify independently; never batch two risky changes without a build in between.

## Definition of done (every milestone)
1. `xcodebuild -scheme HelloNotes -destination 'platform=macOS' build` → **BUILD SUCCEEDED**, 0 warnings in app sources.
2. New logic has at least a smoke test where it's testable off-UI.
3. Docs updated if the design changed.
