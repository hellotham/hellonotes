# Unimplemented, Deferred & Production Readiness

> As of **v1.0**, wrapping up for release. A single register of everything **not** shipped
> or **not** production-hardened: gaps, deferrals, bugs, tech debt, usability, accessibility,
> security, performance, and App-Store packaging. Compiled from a five-lane code audit
> (correctness · release/packaging · data-safety/concurrency/AI · usability/a11y · perf/scale).
> Everything that *was* deferred and later shipped lives in [implemented.md](implemented.md).

**Severity:** 🔴 blocker (fix before App-Store submit) · 🟠 should-fix (before ship, or a fast follow) · 🟡 backlog / nice-to-have.
**Blocking-cause tags:** 🍎 iOS parity · ⬆️ upstream-dependency · 🔒 by-policy.

> **What's already solid (do not re-litigate):** the editor is O(damage) TextKit 2 (no
> O(document) traps); scan/search/graph run off-main; the index cache re-parses only changed
> notes; the link graph patches incrementally; there is no in-RAM full-text corpus; the graph
> is node-capped; FSEvents is coalesced with self-write filtering; autosave/search/git are
> debounced; the editor's own image caches are bounded; git ops are FIFO-serialized; every
> **mutating** AI tool routes through an approval broker with a diff preview and `delete_note`
> is a Trash move; API keys/tokens are Keychain-only (WhenUnlocked, non-syncable) and never
> logged; entitlements/sandbox/hardened-runtime/signing/versioning are correctly configured.
> The code is clean — zero TODO/FIXME/HACK markers, no `fatalError`/`as!`, no debug prints, no
> committed secrets, no dead fork code.

---

## 0 · Release blockers & App-Store packaging

*Resolved and moved to [implemented.md §6](implemented.md#6--production-release-hardening): privacy manifest, `.md` UTI import, optimized Release build, and the in-app acknowledgements screen.*

- 🟠 **Rotate & remove the working-tree `.env`** *(user action — cannot be automated)* — `/.env` holds 6 live keys (Gemini, Mistral, OpenAI, OpenRouter, Ollama, Groq). It is **gitignored and was never committed** (verified across all history), so it is not a repo leak, but the keys are live. **Rotate all six and delete the file** before any CI/distribution. Left here because only the account owner can rotate them.
- 🟡 **No macOS 26 layered app icon** — the classic 16→1024 PNG ladder is complete; there is no Icon Composer `.icon` layered asset for the 26 look (needs artwork). Legacy icon still ships fine.

---

## 1 · Data safety & correctness *(highest non-release risk)*

- 🟠 **Assistant note writes are non-atomic and bypass the open editor buffer** — `EditNoteTool`/`WriteNoteTool` write with a plain (non-`.atomic`) `Data.write` (`CollectionTools.swift:206,242`) straight to disk, not registered as a self-write, and not reconciled with an `EditorModel` that may hold newer unsaved edits for the same note. Outcome is timing-dependent: a conflict, or the editor's next autosave silently overwrites the assistant's change (or vice-versa). **Fix:** atomic writes + route through the same save/self-write path as the editor.
- 🟠 **No synchronous flush on quit** — flush is a fire-and-forget `Task { await tabs.flushAll() }` on `scenePhase` change (`MacContentView.swift:351`, `iOSContentView.swift:114`); there is no `applicationWillTerminate` synchronous drain, so up to one debounce interval (~600 ms) of edits can be lost on a fast ⌘Q.
- 🟠 **`rewriteWikiLinks` (rename) is not transactional** — `renameNote` moves the file, then rewrites links across every other note in a loop where each write is `try?`-swallowed (`Collection.swift:412-434`, `:431`); a mid-batch failure (or a regex-compile early-return after the file already moved) leaves some notes rewritten and others with dangling `[[oldTitle]]` links, with no error and no recovery pass.
- 🟠 **All local file operations fail silently** — `createNote`/`renameNote`/`duplicateNote`/`deleteNote`/`createFolder`/`moveItem` return `nil` or swallow via `try?` (`Collection.swift:348–510`) and their UI callers do nothing on failure. Rename-to-existing-name, a permissions error, or a name-collision race just no-ops with no message. `EditorModel.swift:166` (`saveError = …`) is the correct pattern to copy. Also `MacContentView.linkMention` (`:1063`) and the front-matter/property writes swallow errors.
- 🟠 **Export fails invisibly** — `EditorExport.save()` writes with `try?` and `pdfData` returns `nil` on a render failure (`EditorExport.swift:35,40`); a failed HTML/PDF export dismisses the panel identically to success.
- 🟠 **GitService status/history reads aren't serialized against writes** — the FIFO `run()` queue covers init/commit/push/fetch, but `refreshStatus()`/`history()`/`content()` each open their own `Repository` handle outside the queue (`GitService.swift:51,113,153`), and `refreshStatus` is called on a debounce from the UI *and* after every queued op — so a status walk can run concurrently with a queued index write (inconsistent reads / index-lock contention). `createRepository`/`cloneRepository` also bypass the queue (`:333,395`).
- 🟡 **`reconcileWithDisk` reads on the main actor** — synchronous `String(contentsOf:)` (`EditorModel.swift:110`), unlike `open` which reads off-main; a large externally-changed note briefly stalls the UI.
- 🟡 **`set(try? encode(...))` can wipe config** — `LLMSettings.swift:113` (provider configs), `GitCredentials.swift:169` (git accounts), `ChatSessionStore.swift:46,50` (chat log): if the encode throws, `nil`/nothing is written, silently clearing stored state.

---

## 2 · Security & privacy *(AI / networking)*

- 🟠 **`web_fetch` has no SSRF protection and is ungated** — it accepts any `http(s)` URL with no block on loopback/private/link-local ranges (`WebTools.swift:104`), follows redirects with no delegate, and is *not* permission-gated (read-only). Because fetched pages and note bodies flow back into the model, injected content can point `web_fetch` at an internal endpoint (`127.0.0.1`, `169.254.169.254`, `10./192.168.`) and exfiltrate via a later fetch/search. **Fix:** block private/loopback/link-local, cap redirects and re-validate each hop.
- 🟠 **"Allow all this session" is a blanket, never-reset grant** — `PermissionBroker.allowAllThisSession` auto-approves *all* future mutating tool calls with no per-tool/per-note scope, and `reset()` has no caller in app code (`PermissionBroker.swift:41,58`). Combined with the injection surface above, one "Allow all" click lets injected instructions drive `write_note`/`delete_note` for the rest of the app's lifetime. **Fix:** scope/expire the grant; add a reset (per-conversation, per-tool, or a timeout).
- 🟠 **Git PATs are written in plaintext to `.git/config`** — `GitRemoteURL.authenticated` embeds `user:token@host` into the remote URL (`GitCredentials.swift:188`), which libgit2 persists on disk; if the collection lives in Dropbox/iCloud the token leaves the Keychain. (Root cause: SwiftGitX has no credential callback — ⬆️ upstream.)
- 🟡 **Unbounded response buffers** — `web_search` buffers the whole body via `URLSession.shared.data` (`WebTools.swift:37`; `web_fetch` is already capped at 4 MB — mirror it); the SSE providers accumulate an unbounded error body on non-2xx (`AnthropicProvider.swift:31`, `GeminiProvider.swift:29`).
- 🟡 **Structural prompt-injection exposure** — tool outputs and note content re-enter the model context with no provenance separation/sanitization. Mitigated for *mutating* actions by the broker (unless "Allow all" is armed); read/exfiltration tools stay ungated.
- 🟡 **Keychain items aren't `ThisDeviceOnly`** — so they're included in encrypted device backups. Acceptable for BYO keys/PATs, but make it a conscious decision.

---

## 3 · Performance & memory *(2,000-note scale)*

- 🟠 **Every autosave rebuilds all search aggregates O(collection) on the main actor** — the "incremental" save path patches the link graph O(1 note) but then calls `rebuildAggregates()` which recomputes `entryByURL`, tags, the recursive tag tree, link targets, and a `QuickOpenItem` per note + alias + heading across the whole collection (`CollectionSearchModel.swift:136-147,91-101,244-273`) — ~10k+ allocations per save on the UI thread for a 2,000-note vault. `CollectionEmbedProvider.update` also rebuilds `notesByName` O(N) each save. **Fix:** patch aggregates incrementally and/or move the rebuild off-main.
- 🟠 **Two embed caches are unbounded** — `CollectionEmbedProvider.cache` is never evicted (its `update` bumps a `revision` that's never read but does *not* clear the cache, contradicting its own comment — `CollectionEmbedProvider.swift:21,25`) and `BlockRenderAdapter.cache` has no cap (`BlockRenderAdapter.swift:33,78`). Both hold rendered `NSImage`s keyed by mtime, so every edit to a transcluded/embedded note adds an image that never frees. **Fix:** LRU/count cap like the editor's own caches.
- 🟠 **Transclusion card render runs on the main actor** — a file read + `lockFocus` per uncached embed (`CollectionEmbedProvider.swift:37-62`, via `BlockRenderAdapter.swift:63`) blocks the UI while rendering.
- 🟠 **Chat transcript grows unbounded and re-serializes on the main actor each turn** — `save` rewrites the entire `messages` array (with verbatim tool outputs / full note bodies) on every turn (`AssistantModel.swift:106`, `ChatSessionStore.swift:46`); nothing caps or truncates it. **Fix:** true append, or cap/rotate.
- 🟡 **External-change scan isn't coalesced** — each watcher batch that passes the change filter runs a fresh full directory walk with no in-flight cancellation (`Collection.swift:248`); a bulk `git checkout`/`pull` can trigger several back-to-back walks (the expensive *derive* is coalesced, so impact is bounded).
- 🟡 **Collections open sequentially at launch** — `Library.restore()` awaits each collection's off-main scan before the next (`Library.swift:134,192`); a saved library of many collections serializes cold-scan latency (single-collection launch is unaffected).
- 🟡 **Main-actor single-file reads** in `linkMention`/`insertTemplate` (`MacContentView.swift:1061,1102`).
- 🟡 **`LibraryChatView.retrieve` reads every note per question** (off-main, user-initiated — `LibraryChatView.swift:147`); fine now, revisit for very large vaults.

---

## 4 · Usability & error-surfacing

- 🟠 **Local file operations show the user nothing on failure** — the §1 silent-failure cluster surfaces here as UX: rename/duplicate/delete/new-folder/move that fail just close the dialog with no message. Needs one consistent error-surfacing pass (alert/toast).
- 🟠 **Folder delete has no confirmation** — "Move to Trash" on a folder instantly trashes all its contents (`NoteOutlineList.swift:505` → `MacContentView.swift:1107`); add a confirm for folders (single notes are recoverable, lower stakes).
- 🟠 **No Print support (⌘P)** — there is no `NSPrintOperation`/print path anywhere; a standard menu item for a notes app is absent. (PDF export exists but is not the same as ⌘P.)
- 🟠 **No "AI not configured" guidance** — with zero providers/keys set, the Assistant still invites "Ask anything…" (`AssistantView.swift:122`); there's no config gating and no link to Settings — the user only finds out via an error after sending.
- 🟡 **Indeterminate spinners with no timeout/cancel** — git clone/create/push spin on `git.isBusy` alone (`CloneRepositoryView.swift:139`, `NewRepositoryView.swift:81`, `MacContentView.swift:693`); a hung network op spins forever with no cancel.
- 🟡 **References panel disappears when empty** instead of a "No backlinks yet" state (`NoteEditorView.swift:622`).
- 🟡 **`renameNote` conflates "invalid" and "name taken"** (both return `nil`, `Collection.swift:369`), so even a fixed error path can't tell the user which.
- 🟡 **Duplicate has no keyboard shortcut** (⌘D is Bookmark, Finder-style).

---

## 5 · Accessibility

- 🟠 **No editor headings rotor** — zero `accessibilityRotor` in the codebase; long notes have no VoiceOver heading navigation (headings are already extracted, so this is cheap).
- 🟠 **Graph & Mind Map are opaque to VoiceOver** — nodes/edges are drawn into a `Canvas` and aren't accessibility elements (`GraphView.swift:234`, `MindMapView`); only the chrome buttons are labelled. A blind user gets an empty rectangle.
- 🟠 **Custom TextKit-2 editor a11y is unverified** — concealed/replaced ranges may misreport to VoiceOver; needs an on-device VoiceOver audit of the editor.
- 🟡 **Colour-only signalling** — the git dirty-state dot in the outline is orange-vs-grey with no label/shape (`NoteOutlineList.swift:377`).
- 🟡 **Canvas labels scale by zoom, not Dynamic Type** (`GraphView.swift:331`, `MindMapView.swift:158`); the rest of the UI respects Dynamic Type.
- 🟡 **Reduce Motion isn't queried** — low exposure (graph/mind-map are precomputed, not live-simulated).

---

## 6 · Editor gaps

- 🍎 **Rich iOS editor** — the live TextKit 2 editor is wired **macOS-only** (`NewEditorHost`); iOS uses a plain-text `TextEditor`. This is no longer an engine wall — the `MarkdownEditor` target already has a `UITextView(usingTextLayoutManager:)` path — so it's shell-wiring (tracked as editor-M5).
- 🟡 **Live transclusion** — `![[Note]]` embeds render as a static image card; nested callouts and live selection inside a transclusion aren't supported.
- 🟡 **Emoji shortcodes & raw HTML entities** — `:smile:` / `&amp;copy;` render as literal text (as in raw GitHub *source*), not the display-time glyphs; a small table-driven pass would cover the common cases.

---

## 7 · iOS / iPadOS parity

- 🍎 **Live editor** (see §6) and the **macOS-only surfaces** — FSEvents watching, Open Quickly, tags tree, the Git UI, image paste, Mermaid preview, document statistics, outline, HTML/PDF export, multi-tab, version history, wiki-link autocomplete, open-in-new-window, Graph/Mind Map/Slides, file viewer, and the whole AI stack. The shared `Core`/`State` layers can back iOS UIs later.
- 🟡 **iPad multitasking / Stage Manager** for the split layout is unverified.

---

## 8 · Git / sync

- ⬆️ **Pull / merge** — SwiftGitX exposes `fetch` and `push` but no merge; there is no true "pull." **Unblock:** a merge API in SwiftGitX (or a libgit2 merge of our own).
- 🟠 **Merge-conflict resolution UI** — depends on merge existing first.
- 🟠 **Push smoke test** — HTTPS-token push against a real remote deserves one manual smoke test on a fresh machine before it's advertised; SSH remotes still rely on libgit2's ambient credentials.

---

## 9 · HIG / platform polish

- 🟡 **Main window has no `defaultSize`/explicit restoration** (`HelloNotesApp.swift:20`) — relies on system frame autosave; verify first-launch isn't undersized.
- 🟡 **Liquid Glass (macOS 26)** — custom sidebar chrome and `.background(.bar)` status bars may fight the new material; needs a visual pass on 26.
- 🟡 **Dark Mode in the Canvas surfaces** — graph/mind-map folder colours are drawn directly and may not adapt or meet contrast in dark mode.
- 🟡 **Minimal first-run onboarding** — a clean launch shows the Launcher/file-picker with no welcome explaining the file-system model or pointing at AI/git setup.

---

## 10 · Localization

- 🟠 *(international launch)* / 🟡 *(English-only launch)* — effectively **zero localization**: one `String(localized:)` in the whole codebase, every UI string an inline literal, no string catalog. Blocks non-English markets and adaptable system-integration strings. App-wide scope.

---

## 11 · Tech debt & cleanups

- 🟡 **Inconsistent regex construction** — `try! NSRegularExpression` on constant patterns in `MarkdownParsing.swift:38,44,123` vs `try?` for the same pattern class in `MindMapView.swift:429`; pick one (a shared precompiled-regex helper).
- 🟡 **Fragile force-unwrap idioms on constants** — `URL(string:)!` (`AppCommands.swift:236`), `stack.last!` on an unenforced invariant (`MindMapView.swift:319`); safe today, brittle.
- 🟡 **Undocumented unsafe-concurrency conformances** — `nonisolated(unsafe) var busTokens` (`MarkdownTextView.swift:450`) and `@unchecked Sendable` on `CollectionEmbedProvider` (`:17`) rely on invariants with no justification comment (unlike `FileWatcher`/`SpotlightSearch`, which document theirs).
- 🟡 **Duplicated magic-timing** — the 1.2 s highlight-clear `asyncAfter` is copy-pasted in two paths (`MacContentView.swift:1164`, `NoteEditorView.swift:598`); if they drift, toolbar vs outline "clear highlight" diverges. (Same root as the §1 timing-based scroll-to-heading hand-off — replace both with an editor-ready signal.)
- 🟡 **English-only inline copy** — see §10 (also a maintainability cost).

---

## 12 · Testing gaps

- 🟡 **No end-to-end / UI tests** beyond the app unit tests and the editor package's conformance/perf suites. Consider smoke tests for the highest-risk flows: save→external-change reconciliation, rename-with-link-rewrite, git commit/push, and assistant tool approval.
- 🟡 **Data-safety paths lack tests** — the §1 items (atomic assistant writes, flush-on-quit, transactional rename) would each benefit from a regression test once fixed.

---

## Suggested go/no-go order

1. **Must fix before submission (§0):** privacy manifest; rotate + remove `.env`; UTI import; Release `-O`; acknowledgements screen.
2. **Fix before ship or as an immediate patch:** the §1 data-safety cluster (atomic assistant writes + editor-buffer reconciliation, flush-on-quit, transactional rename, surface file-op/export errors, serialize git reads) and the §2 security cluster (web_fetch SSRF, scoped "Allow all", PAT-in-config); the §3 perf hotspots A/B/C (off-main aggregate rebuild, bound the two embed caches).
3. **Fast-follow:** §4 usability (folder-delete confirm, ⌘P, AI-not-configured), §5 accessibility (rotor, Canvas VoiceOver, editor audit), then the §6–§12 backlog by appetite.
