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

## 6b · Layout architecture — the parts not yet built *(design: [layout-architecture.md](layout-architecture.md); shipped parts: implemented.md §17)*

The sizing contract, the adaptive shell, both rails (the 64pt library switcher
with its Library place, and the inspector) and the width model are in. These
decisions are not:

- 🟡 **Manual pane splitting** (decision 2) — `ShellMetrics.maxPanes` computes
  the ceiling (`min(4, pane/320)`) and the contract test asserts it, but there is
  no split command and no second pane. Today: one pane, plus tabs.
- 🟡 **The persistent format bar** (decision 3) — `ShellContext.showsFormatBar`
  resolves the rule (pointer, pane ≥560, editing) and is tested; the bar itself
  isn't built. Formatting is still menu- and shortcut-driven.
- 🟡 **Column widths remembered per window** (decision 4) — dragging and
  collapsing work and are clamped to the contract's floors and caps, but only
  via the system's own state restoration; nothing is stored deliberately.
- 🟡 **Scroll-linked chrome retraction on compact** (decision 11) — chrome
  retracts when the note is expanded, not in response to scroll direction.
- 🟡 **A keyboard accessory bar** for touch editing (Part 3) — not built.

---

## 7 · iOS / iPadOS parity

- ✅ **Live editor** — shipped (`editor-M5`, see §6) with full block chrome; the remaining iOS-editor item is wiring the app-side services (code colours, embeds) — see §6.
- ✅ **Adaptive shell** — iOS resolves its layout by the same rule as macOS, with a compact tab-bar model of its own (implemented.md §17). The inspector rail, outline, tags, references, properties and history are now cross-platform.
- 🍎 **macOS-only surfaces** — Open Quickly, the Git UI, image paste, Mermaid preview, HTML/PDF export, multi-tab, wiki-link autocomplete, open-in-new-window, Graph/Mind Map/Slides, file viewer, and the whole AI stack. The shared `Core`/`State` layers can back iOS UIs later.
- 🟠 **AI as a compact place** (decision 7) — the bottom tab bar has no AI tab because `AssistantView` and Ask Library are still macOS-only. Decision 7 also wants Graph and Mind Map as full-screen sheets on iPad. **Unblock:** port those four views.
- 🟠 **Heading navigation from the iOS outline** — the inspector posts `.hnEditorFindQuery`, but `MarkdownEditorView` exposes no `EditorProxy` on iOS, so nothing consumes it. The outline reads; it doesn't scroll. **Unblock:** an iOS proxy seam in `MarkdownEditor`.
- 🟠 **Unlinked mentions in the iOS inspector** — needs the Spotlight query the macOS shell runs; the other two reference sections come straight from the index.
- 🟡 **iPad multitasking / Stage Manager** for the split layout is unverified on a device. The contract test covers a 320pt slice and a 250pt tile headlessly.

---

## 8 · Git / sync

- ⬆️ **Pull / merge** — SwiftGitX exposes `fetch` and `push` but no merge; there is no true "pull." **Unblock:** a merge API in SwiftGitX (or a libgit2 merge of our own).
- 🟠 **Merge-conflict resolution UI** — depends on merge existing first.
- 🟠 **Push smoke test** — HTTPS-token push against a real remote deserves one manual smoke test on a fresh machine before it's advertised; SSH remotes still rely on libgit2's ambient credentials.

---

## 8b · Cloud storage *(shipped 2026-07-21 — see [cloud-native-roadmap.md](cloud-native-roadmap.md); these are the known limits)*

**File Provider path (Box/Dropbox/OneDrive/Google Drive/iCloud) — production-ready.** Gaps:
- 🟡 **"Remove Download" is best-effort** — for a File Provider domain we don't own, eviction is the provider's call; we can trigger a download but can't force dehydration. Surfaced as a hint, not a guarantee.
- 🟡 **Content search skips online-only notes** by design (so a query never downloads the vault). There is no explicit *"search online files too (downloads N)"* escape hatch yet — title/tag/alias search does cover them.

**Direct-API providers (Dropbox, Box, Google Drive, OneDrive).** Gaps:
- 🟠 **Interactive sign-in needs a signed build** — `ASWebAuthenticationSession` won't reliably present from an unsigned CLI build. Only Dropbox has been proven through a *complete* real sign-in→token→API round-trip; Box/Drive/OneDrive are verified at the authorize endpoint + request shapes (clean auth-only 401s) but their final interactive sign-in is unexercised.
- 🟠 **`RemoteMirror.syncDown` is eager and whole-folder** — it downloads every `.md` on open (fine for note vaults, wrong for huge ones) and has no delta/cursor sync. On-demand hydration for *remote* collections is the natural next step.
- 🟠 **No conflict resolution on the remote path** — last-write-wins. `syncDown` won't clobber a newer local file and prunes remote deletions, but a genuine two-sided edit isn't detected (the local File-Provider path *does* have the conflict banner). `RemoteEntry.rev`/`modified` are already plumbed for this.
- 🟡 **Uploads are single-shot** — Box/Drive/OneDrive/Dropbox simple uploads cap out (e.g. Graph ~4 MB); no chunked/resumable session. Irrelevant for Markdown, wrong for large attachments.
- 🟡 **Sidebar promotion is macOS-only** — iOS presents the browser (edit-in-place); "Open as Collection" needs `Library` plumbed into the settings sheet.
- 🟡 **Remote collections aren't restored on launch** — deliberate (a stale cache shouldn't masquerade as a collection), but it means re-connecting each session.
- 🟡 **Box embeds a client secret** — Box has no PKCE public-client mode, so the secret ships in the app and is extractable. Fine for personal/dev use; a public release wants a backend proxy or Box JWT server-auth.
- 🟡 **Google "Testing" mode expires refresh tokens after 7 days** — an external, unverified consent screen means weekly re-sign-in. Publishing/verification (or Workspace-internal) removes it.

---

## 8c · Build & release hygiene

- ✅ ~~**Release build unverified**~~ — a Release-only Swift optimizer crash broke *every*
  archive (so no DMG, no App Store build) while Debug stayed green, and went unnoticed for
  ~6,400 lines because all verification was Debug. Fixed, and
  [production.md §1h](production.md) now requires the Release build with a debugging recipe
  ([implemented.md §13](implemented.md)).
- ✅ ~~**No CI**~~ — `.github/workflows/build-and-test.yml` now builds both platforms, runs
  `build-for-testing` (the step that actually compiles the test target), runs the suites, and
  builds Release on `main`. Added after one session produced both failures it exists to catch:
  a package API change left `HelloNotesTests` uncompilable while `xcodebuild build` kept
  reporting success — **`build` does not compile tests** — and two iOS breaks survived days of
  green macOS builds.
- 🟡 **The universal (arm64 + x86_64) slice is still verified by hand** — CI builds the native
  runner architecture only.
- 🔴 **The website screenshots predate the shell redesign** (2026-08-11). All five light/dark
  pairs in `website/src/lib/screens.ts` show the old wide left sidebar with its collection
  card, quick-action buttons and bookmarks — a UI that no longer exists. The manual text has
  been corrected; the images have not, because re-shooting them means driving the running app.
  Re-shoot all five at 1470×923, light and dark, then re-run
  [`scripts/make-screenshots.py`](../scripts/make-screenshots.py). **Blocks the next website
  deploy** — the download page and the feature tour both lead with them.
- 🟡 **Toolchain-sensitive code shapes** — two functions in `Core/VisionAlt.swift` are
  deliberately non-generic to dodge a SIL-inliner bug and carry comments saying so. If the
  Swift toolchain moves on, re-check before "simplifying" them back.

---

## 9 · HIG / platform polish

- ✅ ~~**Main window has no `defaultSize`**~~ — added (1100×720) in the HIG pass, [implemented.md §10](implemented.md#10--human-interface-guidelines-usability-pass-2026-07-20).
- ✅ ~~**Minimal first-run onboarding**~~ — `WelcomeView` ships a one-time welcome sheet on both platforms (§10).
- 🟡 **Liquid Glass (macOS 26)** — custom sidebar chrome and `.background(.bar)` status bars may fight the new material; needs a visual pass on 26. *(Code audit found no custom fills or opt-outs; the remaining risk is visual-only.)*
- 🟡 **Dark Mode in the Canvas surfaces** — graph/mind-map folder colours are drawn directly and may not adapt or meet contrast in dark mode.
- 🟡 **Editor Dynamic Type** — the note editor uses its own text-scale control rather than system Dynamic Type. Deliberate (§10 "Consciously not changed"), but revisit if accessibility review pushes back.

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

- 🟡 **The app suite is hosted by the app, so it is slow and it launches a window.** A macOS
  unit-test bundle needs a test *host*, and there is no flag that stops it. Two consequences
  were worth fixing and one is left:
  - ✅ The host used to restore the **user's real library** on launch — 2,000 notes of
    coordinated cloud I/O on the same main actor the `@MainActor` tests run on. The suite sat
    for 20+ minutes looking hung. `TestEnvironment.isRunningTests` now skips the app's launch
    work under a test host; 117 tests complete in seconds.
- 🔴 **The two `GitService` tests deadlock the app suite.** `gitInitStatusAndCommit` and
  `gitNoteHistoryTracksFileRevisions` pass **alone** and pass **as a pair**, but in a full run
  of `HelloNotesTests` they never report and `xcodebuild test` never returns. Everything else
  passes first: `Suite HelloNotesTests passed after 2.0s`, 117 tests green, then nothing.

  Measured, not guessed — sampling the live test host shows the main thread parked in
  `-[XCTWaiter _performWait:]` with the entire libdispatch worker pool idle in
  `start_wqthread`. Nothing is running: an async continuation never resumes. That is a
  deadlock, not slowness, so a longer timeout will not help.

  Moving them to their own `@Suite(.serialized) GitServiceTests` was not enough (it did fix
  `HelloNotesTests` itself, which now completes in ~2s). Next step is the `GitService` FIFO:
  `run` and `serializedRead` both chain onto `lastQueued` from a `@MainActor` context and then
  `await task.value` — worth checking whether one path can await a task that is itself waiting
  on the main actor. Reproduce with:
  `xcodebuild test -project HelloNotes.xcodeproj -scheme HelloNotes -destination 'platform=macOS' -only-testing:HelloNotesTests`

  **Blocks CI's Test step** — the workflow is otherwise ready, and its `build`,
  `build-for-testing` and Release jobs are all useful today.
- 🟡 The git tests would also be faster and more hermetic if they did not copy the whole
  `SampleVault` per test — a two-note fixture would prove the same thing.

---

## Status

**§0–§5 are substantially resolved** in the production-hardening pass — see
[implemented.md §6](implemented.md#6--production-release-hardening) for the full list
(privacy manifest, UTI import, Release `-O`, acknowledgements; flush-on-quit, atomic
assistant writes, surfaced file/export errors, serialized git reads; web SSRF guard,
scoped "Allow all", bounded buffers; debounced aggregate rebuild, bounded caches,
bounded transcript; ⌘P Print, folder-delete confirm, AI-not-configured state; Graph
VoiceOver, labelled git state).

**§9 HIG / usability** was worked through in the HIG pass —
[implemented.md §10](implemented.md#10--human-interface-guidelines-usability-pass-2026-07-20)
(shortcut conflicts, save/git error surfacing, empty states, first-run onboarding, native
sidebars, VoiceOver rotor + labels, Reduce Motion, terminology, cancelable clone).

**Cloud storage** shipped in full (§8b lists the residual limits) —
[implemented.md §11](implemented.md#11--cloud-native-storage-2026-072021).

**Remaining before submission:** the one item only the owner can do — **rotate + remove
the working-tree `.env`** (§0). Note the *provider* credentials are already handled
correctly: they live in a git-ignored `Config/Secrets.xcconfig` and were purged from git
history before the repo's first push, so nothing leaked. `.env` is git-ignored and untracked
too, but it still sits in the working tree with live keys in plaintext.

**Remaining, non-blocking:** the residual 🟡 items under each section above, and the
feature backlog — **§6/§7 the iOS live-editor milestone (`editor-M5`)**, §8 git pull/merge
(upstream), §9 HIG polish, §10 localization, §11 tech-debt tidy-ups, §12 test coverage.
None block the macOS 1.0 release.

A post-review fix pass (2026-07-19) resolved the blocker and most should-fix items from
a full-codebase review — see [implemented.md §7](implemented.md#7--post-review-fix-pass-2026-07-19).
The items it landed are struck from the sections above; what it left open is tracked below.
