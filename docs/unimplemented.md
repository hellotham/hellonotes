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
> is a Trash move; API keys/tokens are Keychain-only (`WhenUnlockedThisDeviceOnly`, non-syncable,
> excluded from backups) and never logged; entitlements/sandbox/hardened-runtime/signing/versioning
> are correctly configured.
> The code is clean — zero TODO/FIXME/HACK markers, no `fatalError`/`as!`, no debug prints, no
> committed secrets, no dead fork code.

---

## 0 · Release blockers & App-Store packaging

*Resolved and moved to [implemented.md §6](implemented.md#6--production-release-hardening): privacy manifest, `.md` UTI import, optimized Release build, and the in-app acknowledgements screen.*

- 🟠 **Rotate & remove the working-tree `.env`** *(user action — cannot be automated)* — `/.env` holds 6 live keys (Gemini, Mistral, OpenAI, OpenRouter, Ollama, Groq). It is **gitignored and was never committed** (verified across all history), so it is not a repo leak, but the keys are live. **Rotate all six and delete the file** before any CI/distribution. Left here because only the account owner can rotate them.
- 🟡 **No macOS 26 layered app icon** — the classic 16→1024 PNG ladder is complete; there is no Icon Composer `.icon` layered asset for the 26 look (needs artwork). Legacy icon still ships fine.

---

## 1 · Data safety & correctness

*Resolved and moved to [implemented.md §6](implemented.md#6--production-release-hardening): flush-on-quit handshake; atomic assistant writes; surfaced file-operation failures (create/rename/duplicate/delete/folder/move) + partial-rename link-rewrite reporting; export-error alerts; off-main reconcile read; no-config-wipe persist; serialized git status/history/content reads.*
*Resolved and moved to [implemented.md §7](implemented.md#7--post-review-fix-pass-2026-07-19): `createRepository`/`cloneRepository` routed through the git FIFO queue; serialized `EditorModel` writes (no stale-on-quit race).*

- 🟡 **Assistant edit vs. open editor buffer** — the assistant's writes are now atomic, but if the same note is open in the editor with unsaved edits, the change still races the editor's autosave/reconcile (the write goes to disk, not through the open `EditorModel`). Reconciliation raises a conflict in the common case, but a narrow window remains. **Fix:** route assistant writes through the open buffer when the note is being edited.
- 🟡 **`ChatSessionStore` write is `try?`** (`ChatSessionStore.swift:46,50`) — a failed transcript write/removeItem is silent; low stakes (chat history, load is resilient) but worth surfacing.

---

## 2 · Security & privacy *(AI / networking)*

*Resolved and moved to [implemented.md §6](implemented.md#6--production-release-hardening): `web_fetch`/`web_search` SSRF protection + redirect re-validation; scoped "Allow all" (resets per conversation); bounded `web_search` + SSE error buffers.*
*Resolved and moved to [implemented.md §7](implemented.md#7--post-review-fix-pass-2026-07-19): `create_note` path-traversal containment; "Allow all" never auto-approves deletions; write-tool symlink containment; NAT64 in the SSRF classifier; Keychain secrets → `…ThisDeviceOnly`; credential-scrubbed git error strings.*

- ⬆️ **Git PATs are written in plaintext to `.git/config`** — `GitRemoteURL.authenticated` embeds `user:token@host` into the remote URL (`GitCredentials.swift`), which libgit2 persists on disk; if the collection lives in Dropbox/iCloud the token leaves the Keychain. **Root cause:** SwiftGitX exposes no credential callback, so the token can't be supplied per-operation. **Unblock:** a SwiftGitX credential-callback API (then stop embedding the token in the URL). *(Error strings that would echo the URL are now credential-scrubbed — §7 — but the persisted config value remains.)*
- 🟠 **SSRF guard isn't pinned to the fetched IP (DNS rebinding / TOCTOU)** — `WebGuard.validate` resolves the host with `getaddrinfo` and classifies the addresses, but `URLSession.bytes(for:)` performs a **second, independent** resolution for the connection. An attacker-controlled short-TTL domain can return a public A record during `validate()` and `169.254.169.254`/`127.0.0.1` during the fetch. Redirects are re-validated but share the gap. **Root cause:** URLSession offers no per-request IP pinning. **Unblock:** resolve once and connect to the pinned IP via a custom `URLProtocol`/Network.framework (a `URLSessionTaskMetrics.remoteAddress` check fires too late for a streamed body). Static private hosts and encoded-IP forms are already blocked.
- 🟡 **Structural prompt-injection exposure remains** — tool outputs and note content still re-enter the model context with no provenance separation. It's now materially reduced (SSRF guard blocks internal exfiltration; mutating tools are broker-gated, "Allow all" no longer persists across conversations and never auto-approves deletions), but a fully robust design would tag untrusted content and constrain what it can trigger.

---

## 3 · Performance & memory *(2,000-note scale)*

*Resolved and moved to [implemented.md §6](implemented.md#6--production-release-hardening): debounced search-aggregate rebuild; bounded `CollectionEmbedProvider`/`BlockRenderAdapter` image caches; bounded + off-main chat-transcript persistence.*

- 🟡 **Transclusion card render runs on the main actor** — a file read + `NoteTranscluder` `lockFocus` per *uncached* `![[Note]]` embed (`CollectionEmbedProvider.swift`) blocks the UI while rendering. Now bounded/cached (so it's rare), but the first render of each card is still main-actor. **Fix:** render to a bitmap off-main (lockFocus is main-only, so this needs a `CGContext`/`NSBitmapImageRep` path).
- 🟡 **External-change scan isn't coalesced** — each watcher batch that passes the change filter runs a fresh full directory walk with no in-flight cancellation (`Collection.swift`); a bulk `git checkout`/`pull` can trigger several back-to-back walks (the expensive *derive* is already coalesced, so impact is bounded).
- 🟡 **Collections open sequentially at launch** — `Library.restore()` awaits each collection's off-main scan before the next (`Library.swift`); a saved library of many collections serializes cold-scan latency (single-collection launch is unaffected).
- 🟡 **Main-actor single-file reads** in `linkMention`/`insertTemplate` (`MacContentView.swift`) — small user-initiated reads, low impact.
- 🟡 **`LibraryChatView.retrieve` reads every note per question** (off-main, user-initiated); fine now, revisit for very large vaults.

---

## 4 · Usability & error-surfacing

*Resolved and moved to [implemented.md §6](implemented.md#6--production-release-hardening): file-operation errors now surface (alert); folder-delete confirmation; ⌘P Print; "AI not configured" empty state; rename distinguishes name-taken from OS errors.*

- 🟡 **Indeterminate spinners with no timeout/cancel** — git clone/create/push spin on `git.isBusy` alone (`CloneRepositoryView.swift`, `NewRepositoryView.swift`); a hung network op spins with no cancel. The op has a libgit2 timeout, but the UI offers no Cancel button.
- 🟡 **References panel disappears when empty** instead of a "No backlinks yet" state (`NoteEditorView.swift`).
- 🟡 **Duplicate has no keyboard shortcut** (⌘D is Bookmark, Finder-style).

---

## 5 · Accessibility

*Resolved and moved to [implemented.md §6](implemented.md#6--production-release-hardening): Graph is now VoiceOver-navigable (`accessibilityChildren`); git dirty-state dot is labelled (not colour-only). (Mind Map nodes were already real `Text`/`Button` views, so already navigable.)*

- 🟠 **No editor headings rotor** — zero `accessibilityRotor`; long notes have no VoiceOver heading navigation. The editor is an `NSTextView` (`NSViewRepresentable`), so this needs AppKit-level accessibility (custom `accessibilityCustomRotors` on the text view exposing heading ranges), not a SwiftUI rotor. Headings are already extracted, so the data is there.
- 🟠 **Custom TextKit-2 editor a11y needs an on-device VoiceOver audit** — concealed/replaced ranges (near-zero-size marker fonts, drawn block embeds) may misreport to VoiceOver. `NSTextView` is natively accessible, but the concealment layer needs verification on a real device with VoiceOver.
- 🟡 **Canvas labels scale by zoom, not Dynamic Type** (`GraphView`, `MindMapView`); the rest of the UI respects Dynamic Type.
- 🟡 **Reduce Motion isn't queried** — low exposure (graph/mind-map layouts are precomputed, not live-simulated).

---

## 6 · Editor gaps

*The **iOS live editor** (`editor-M5`) is now **shipped**, including the fragment chrome — see [implemented.md §6](implemented.md#6--production-release-hardening). iOS has a live TextKit 2 editor with inline styling, caret-driven concealment, and the full block chrome (bullets, checkboxes, callouts, gutter bars, heading rules) via an overlay renderer; the `BlockRendering` chrome was ported to cross-platform CoreGraphics with no macOS regression.*

- 🟡 **iOS block embeds / inline math aren't consumed** — the renderers (`PlatformImageKit`/`MathImageRenderer`/`TableImageRenderer`/Mermaid/transclusion) are now cross-platform and `iOSLiveEditor` wires a `BlockRenderAdapter` (§7), and code-syntax colours **do** render on iOS — but `EditorDocument`'s collapse + `RenderedBlockFragment` image path is still `#if canImport(AppKit)`, so the adapter is never invoked on iOS and embeds/`$…$` math show their Markdown source. **Fix:** port the block-image collapse to the iOS `ChromeOverlayView` (which today draws only fragment chrome, not block images).
- 🟡 **Live transclusion** — `![[Note]]` embeds render as a static image card (macOS); nested callouts and live selection inside a transclusion aren't supported (needs nested live-layout embeds).
- 🟡 **Emoji shortcodes** — `:smile:` renders as literal text (matches raw GitHub *source*; github.com substitutes the glyph only at display time, which cmark-gfm/the Preview doesn't). Low value.

---

## 7 · iOS / iPadOS parity

- ✅ **Live editor** — shipped (`editor-M5`, see §6) with full block chrome; the remaining iOS-editor item is wiring the app-side services (code colours, embeds) — see §6.
- 🍎 **macOS-only surfaces** — Open Quickly, tags tree, the Git UI, image paste, Mermaid preview, document statistics, outline, HTML/PDF export, multi-tab, version history, wiki-link autocomplete, open-in-new-window, Graph/Mind Map/Slides, file viewer, and the whole AI stack. The shared `Core`/`State` layers can back iOS UIs later.
- 🟡 **iPad multitasking / Stage Manager** for the split layout is unverified (needs a device).

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

- 🟠 **Incremental parse doesn't converge for prose** (`Packages/NotesEditor/Sources/MarkdownCore/BlockParser.swift`) — convergence only fires at `open == .none` (`isAtBoundary`), which prose (paragraphs, blanks, lists, quotes, tables) never leaves standing between lines, so an edit near the top of a long non-heading note re-parses to EOF: O(document) per keystroke. Correctness holds (fuzz tests pass); only the "cost proportional to the edit" guarantee is defeated. **Fix** needs the convergence check to compare the full builder state (not just `.none`) with its own fuzz re-verification — deferred from the review-fix passes as too risky for a blind `--fix`. (Related, same file: the `.blank` merge branch is dead — `closeOpen` nulls `open` before the `if case .blank` test — and the thematic-break / setext / front-matter-fence classifiers don't tolerate a trailing `\r`, so CRLF files mis-parse those constructs.)
- 🟡 **Inconsistent regex construction** — `try! NSRegularExpression` on constant patterns in `MarkdownParsing.swift:38,44,123` vs `try?` for the same pattern class in `MindMapView.swift:429`; pick one (a shared precompiled-regex helper).
- 🟡 **Fragile force-unwrap idioms on constants** — `URL(string:)!` (`AppCommands.swift:236`), `stack.last!` on an unenforced invariant (`MindMapView.swift:319`); safe today, brittle.
- ✅ **Undocumented unsafe-concurrency conformances** — *resolved (§7):* `CollectionEmbedProvider`'s `@unchecked Sendable` now carries a lock-invariant justification, and the editor's `nonisolated(unsafe)` observer tokens (`busTokens`, `boundsObserver`) are documented; `MarkdownTextView`'s bounds observer is now removed in `deinit`.
- 🟡 **Duplicated magic-timing** — the 1.2 s highlight-clear `asyncAfter` is copy-pasted in two paths (`MacContentView.swift:1164`, `NoteEditorView.swift:598`); if they drift, toolbar vs outline "clear highlight" diverges. (Same root as the §1 timing-based scroll-to-heading hand-off — replace both with an editor-ready signal.)
- 🟡 **English-only inline copy** — see §10 (also a maintainability cost).

---

## 12 · Testing gaps

- 🟡 **No end-to-end / UI tests** beyond the app unit tests and the editor package's conformance/perf suites. Consider smoke tests for the highest-risk flows: save→external-change reconciliation, rename-with-link-rewrite, git commit/push, and assistant tool approval.
- 🟡 **Data-safety paths lack tests** — the §1 items (atomic assistant writes, flush-on-quit, transactional rename) would each benefit from a regression test once fixed.

---

## Status

**§0–§5 are substantially resolved** in the production-hardening pass — see
[implemented.md §6](implemented.md#6--production-release-hardening) for the full list
(privacy manifest, UTI import, Release `-O`, acknowledgements; flush-on-quit, atomic
assistant writes, surfaced file/export errors, serialized git reads; web SSRF guard,
scoped "Allow all", bounded buffers; debounced aggregate rebuild, bounded caches,
bounded transcript; ⌘P Print, folder-delete confirm, AI-not-configured state; Graph
VoiceOver, labelled git state).

**Remaining before submission:** the one item only the owner can do — **rotate + remove
the working-tree `.env`** (§0).

**Remaining, non-blocking:** the residual 🟡 items under each section above, and the
feature backlog — **§6/§7 the iOS live-editor milestone (`editor-M5`)**, §8 git pull/merge
(upstream), §9 HIG polish, §10 localization, §11 tech-debt tidy-ups, §12 test coverage.
None block the macOS 1.0 release.

A post-review fix pass (2026-07-19) resolved the blocker and most should-fix items from
a full-codebase review — see [implemented.md §7](implemented.md#7--post-review-fix-pass-2026-07-19).
The items it landed are struck from the sections above; what it left open is tracked below.
