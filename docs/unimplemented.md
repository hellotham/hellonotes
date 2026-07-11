# Unimplemented & Deferred

> As of **v0.1**.

A running register of everything scoped, approved, or attempted but **not** shipped,
with the reason and what would unblock it. Revisit periodically.

Each item is tagged by what's blocking it:

- 🧱 **Engine wall** — blocked by a missing hook in a dependency (mostly
  `swift-markdown-engine`, some `SwiftGitX`). Needs an upstream feature or a fork.
- 🛠️ **Backlog** — buildable with what we have; just not done yet.
- 🍎 **iOS parity** — exists on macOS, not yet on iOS/iPadOS.
- 🔒 **By policy** — intentionally not done for safety/architecture reasons.

---

## Editor (MarkdownEngine) limitations

These share a root cause: MarkdownEngine's public surface doesn't expose the hook
we'd need. Several features have been shaped around these walls.

- ✅ **Scroll-to-section / outline jump** *(Milestones 3, 7 & 9)* — **RESOLVED via the fork.**
  Fixed in [`ChristineTham/swift-markdown-engine@hellonotes-patches`](https://github.com/ChristineTham/swift-markdown-engine)
  (see [markdown-engine-strategy.md](markdown-engine-strategy.md)): the engine's default
  scroll path now uses the TextKit 2 fragment layout universally, so find/jump reaches
  off-screen matches. The outline **jumps to a heading and scrolls** to it (restored and
  verified live). `[[Note#heading]]` **link clicks** now navigate *and* scroll too: the
  wiki-link resolver strips the `#heading` fragment before the existence check (so the link
  renders resolved/clickable), and the host parses the fragment on click to post the same
  `.hnEditorFindQuery`. Verified live.

- ✅ **Note transclusion / embeds `![[Note]]` / `![[Note#heading]]`** *(Obsidian review)* —
  **RESOLVED (host-side).** A `VaultEmbedProvider` set as the engine's image provider renders a
  referenced note (or one `#heading` section) to an inline card image via `NoteTranscluder`,
  reusing the existing image-embed block path — no engine change needed. The card renders
  headings, lists, emphasis, code, **inline/block LaTeX** (SwiftMath) and **Mermaid diagrams**
  (front matter stripped), refreshing on the source note's change via a vault-revision
  fingerprint. Verified live. *(Limitation: still a static image render — nested callouts and
  live selection inside a transclusion aren't supported.)*

- ✅ **Callouts `> [!note]` and comments `%%…%%`** *(Obsidian review)* — **RESOLVED via the
  fork.** `> [!type]` callouts render as tinted boxes (colored band + accent bar + bold title,
  `[!` `]` hidden) via a new `.calloutTint` fragment attribute; `%%…%%` comments (inline and
  multi-line) are dimmed. Callout headers now show **type SF Symbols**, and `[!type]-`/`[!type]+`
  callouts are **collapsible** with a clickable chevron. Verified live.

- ✅ **Tag autocomplete** *(Milestone 8 — the `#` half of "wiki-link & tag autocomplete")* —
  **RESOLVED via the fork.** The fork adds a `.tag` inline-selection kind: when the caret is
  in a `#tag` (≥1 body char, `#` at a whitespace/line boundary so headings don't match) the
  engine fires `onInlineSelectionChange(.tag)` with the tag text + caret rect, plus an
  `isLiteralMode` replacement so the host can commit a plain `#tag ` verbatim. HelloNotes reuses
  its wiki-link completion popup to offer existing vault tags. Verified live (fork @ `41f4304`).

- 🧱 **Create-on-miss by clicking a muted `[[link]]`** *(Milestone 3)*
  Clicking a wiki-link to a non-existent note should offer to create it. The engine
  doesn't fire the link callback for non-existent targets. (Create-on-miss *does* work
  when navigating via the link resolver elsewhere; this is specifically the in-editor
  click path.) **Unblock:** a link-click callback that also fires for unresolved links.

- ✅ **Inline Mermaid rendering in the editor** *(Milestone 5)* — **RESOLVED via the fork.**
  The fork adds a `DiagramRenderer` service (mirroring `LatexRenderer`); HelloNotes supplies
  a `MermaidDiagramRenderer` (BeautifulMermaid) so standalone ` ```mermaid ` blocks now render
  as native images **inline in the editor**, collapsing the fence like block LaTeX. The caret
  reveals the source for editing and re-renders on blur. Verified live. The Diagrams sheet
  remains as a full-size gallery. Diagrams now **theme-match** the editor (transparent
  background + zinc light/dark) and **wide diagrams clamp to the reading column** with a
  horizontal scroller (the engine's scrollable-block overlay). Both verified live.

- ✅ **Hiding raw front matter in the editor** *(Milestone 5)* — **RESOLVED via the fork.**
  The leading `---` YAML block now collapses to nothing in the editor (its fence
  thematic-break rules suppressed), pairing with the editable Properties panel; the raw YAML
  reveals only when the caret is inside it. Verified live (fork @ `51e64e2`).

---

## Git / sync (SwiftGitX)

- 🧱 **Pull / merge** *(Milestone 4)*
  SwiftGitX exposes `fetch` and `push` but no merge, so there's no true "pull." Fetch
  updates refs and the user merges externally. **Unblock:** a merge API in SwiftGitX
  (or a libgit2 merge implemented ourselves).

- 🛠️ **Merge-conflict resolution UI** *(Milestone 4, P2)*
  Depends on merge existing first. No UI to resolve conflicting hunks.

- 🔒 / 🛠️ **Remote auth & real-remote push** *(Milestone 4)*
  Push/fetch rely on libgit2's configured credentials (SSH agent / stored tokens);
  the app deliberately doesn't manage credentials (safety rule). Push is implemented
  but **has not been exercised against a real remote**. **Unblock:** test against a
  real remote; decide how far credential handling can go within policy.

- 🛠️ **In-app Git identity** *(Milestone 4)*
  Commits fall back to the OS account identity when global git config is unreadable
  (`ensureCommitIdentity`). There's no settings UI to set a proper name/email.

---

## iOS / iPadOS parity

The iOS/iPadOS build is a browse / read / plain-text-edit companion. The following
exist on macOS but not on iOS yet.

- 🍎🧱 **Rich iOS editor** *(Milestone 6)*
  iOS uses a plain `TextEditor` (same `EditorModel`, autosave, conflict logic). Live
  Markdown styling / syntax-highlighted code / LaTeX math via MarkdownEngine are
  AppKit-only, so they're absent on iOS. **Unblock:** a UIKit/TextKit 2 iOS editor
  (either an iOS-capable MarkdownEngine or a new editor).

- 🍎 **macOS-only features not yet on iOS** *(Milestone 6)*
  FSEvents external-change watching, "Open Quickly" (⌘O), the folder tree, the tags
  sidebar, the Git UI, image paste → assets, and Mermaid preview.

- 🍎 **Bear/Lettera companions are macOS-only** *(Milestones 7 & 8)*
  Document statistics, the outline, HTML/PDF export, multi-tab editing, the nested-tag
  **tree UI**, Git version history, wiki-link autocomplete, and open-in-new-window are
  all macOS-only. (Note: the shared `Core`/`State` pieces — `TagTree`, nested-tag
  matching in `VaultSearchModel`, `DocumentStatistics`, `GitService.history` — are
  cross-platform and could back iOS UIs later.)

---

## Performance / architecture

- 🛠️ **Incremental index / graph updates** *(Milestone 3)*
  The wiki-link graph and search index do a full rebuild on any change. Correct and
  fast for target vault sizes; revisit with per-note incremental updates when
  large-vault profiling warrants it.

---

## Notes for revisiting

- The 🧱 editor items cluster around one theme: **MarkdownEngine gives us text +
  a few inline-token/link hooks, but no general "act on a source range / caret
  offset / custom render" surface.** If we ever adopt a fork or a different editor,
  scroll-to-section, tag autocomplete, inline Mermaid, front-matter hiding, and
  create-on-miss could likely all be revisited together.
- 🛠️ **Backlog** items are the cheapest wins — they need no upstream changes.
