# Unimplemented, Deferred & Production Readiness

> As of **v1.3** (reconciled against the source 2026-08-16: §7's iOS entries revised
> where 1.3 closed them — the AI stack is no longer macOS-only — and inline completion
> added as the one 1.3 feature that did *not* reach iOS. The previous pass, 2026-08-15
> for v1.2, retired §8b's cloud entries and five earlier ones describing gaps that had
> already been closed; see [implemented.md §20](implemented.md).)
>
> A single register of everything **not** shipped
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

- 🟡 **No macOS 26 layered app icon** — the classic 16→1024 PNG ladder is complete; there is no Icon Composer `.icon` layered asset for the 26 look (needs artwork). Legacy icon still ships fine.

---

## 1 · Data safety & correctness

*Resolved and moved to [implemented.md §6](implemented.md#6--production-release-hardening): flush-on-quit handshake; atomic assistant writes; surfaced file-operation failures (create/rename/duplicate/delete/folder/move) + partial-rename link-rewrite reporting; export-error alerts; off-main reconcile read; no-config-wipe persist; serialized git status/history/content reads.*
*Resolved and moved to [implemented.md §7](implemented.md#7--post-review-fix-pass-2026-07-19): `createRepository`/`cloneRepository` routed through the git FIFO queue; serialized `EditorModel` writes (no stale-on-quit race).*

- 🟡 **Assistant edit vs. open editor buffer** — the assistant's writes are now atomic, but if the same note is open in the editor with unsaved edits, the change still races the editor's autosave/reconcile (the write goes to disk, not through the open `EditorModel`). Reconciliation raises a conflict in the common case, but a narrow window remains. **Fix:** route assistant writes through the open buffer when the note is being edited.
- ✅ ~~**`ChatSessionStore` write is `try?`**~~ — resolved (§20): save/clear failures now report through the assistant's `errorText`, except `fileNoSuchFile` on clear (an empty conversation).

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
- 🟡 **External-change scan isn't fully coalesced** — *partly resolved (§20)*: `Task.detached` doesn't inherit cancellation, so a cancelled debounce task used to leave its walk running while the replacement started another. Cancellation is now forwarded, `enumerate` returns early, and partial results are discarded. **Still open:** there is no in-flight latch, so a change arriving mid-walk still starts a fresh walk once the current one is cancelled rather than queueing one re-run. Deliberately left — a latch adds re-entrancy to the core scan path.
- ✅ ~~**Collections open sequentially at launch**~~ — resolved (§20): `restore()` creates the collections up front and activates them in a task group, so launch costs the slowest scan rather than the sum.
- 🟡 **Main-actor single-file reads** in `linkMention`/`insertTemplate` (`MacContentView.swift`) — small user-initiated reads, low impact.
- 🟡 **`LibraryChatView.retrieve` reads every note per question** (off-main, user-initiated); fine now, revisit for very large vaults.

---

## 4 · Usability & error-surfacing

*Resolved and moved to [implemented.md §6](implemented.md#6--production-release-hardening): file-operation errors now surface (alert); folder-delete confirmation; ⌘P Print; "AI not configured" empty state; rename distinguishes name-taken from OS errors.*

- 🟡 **Push still has no Cancel** — clone has had a real Stop for some time, and **create** gained one in §20 (cancellable runner, cancellation forwarded into the detached libgit2 work, half-made repository removed). Push is the remaining op that spins on `git.isBusy` alone.
- ✅ ~~**References panel disappears when empty**~~ — resolved (§20): the button stays put and shows the same "No References" copy the inspector already used. (The inspector's own tab already had the empty state.)
- ✅ ~~**Duplicate has no keyboard shortcut**~~ — **entry was stale**: Duplicate is ⌘D (Finder convention) and Bookmark is ⇧⌘D (`AppCommands.swift`). Shipped before 1.1, never struck off.

---

## 5 · Accessibility

*Resolved and moved to [implemented.md §6](implemented.md#6--production-release-hardening): Graph is now VoiceOver-navigable (`accessibilityChildren`); git dirty-state dot is labelled (not colour-only). (Mind Map nodes were already real `Text`/`Button` views, so already navigable.)*

- ✅ ~~**No editor headings rotor**~~ — **entry was stale**: shipped on macOS (`accessibilityCustomRotors` + `NSAccessibilityCustomRotorItemSearchDelegate`) *and* iOS (`UIAccessibilityCustomRotor(systemType: .heading)`). The real gap underneath it — neither copy honoured the rotor's `filterString`, so typing to narrow the list did nothing — was fixed in §20, and the walk moved to `EditorDocument.rotorHeading(after:forward:matching:)` so it is testable.
- 🟠 **Custom TextKit-2 editor a11y needs an on-device VoiceOver audit** — concealed/replaced ranges (near-zero-size marker fonts, drawn block embeds) may misreport to VoiceOver. `NSTextView` is natively accessible, but the concealment layer needs verification on a real device with VoiceOver.
- ✅ ~~**Canvas labels scale by zoom, not Dynamic Type**~~ — resolved (§20): both canvases use `@ScaledMetric`, and the mind map feeds the same factor into `estimatedChipSize` so chips grow with their labels instead of clipping.
- ✅ ~~**Reduce Motion isn't queried**~~ — **entry was stale**: the only continuously animating surface (`SplashScreenView`) already pauses its `TimelineView` on `accessibilityReduceMotion`. Everything else is a precomputed layout or a single state transition.

---

## 6 · Editor gaps

- ✅ ~~**Concealed `$$` block leaves a coloured dot and a height gap**~~ — resolved (§20).
  Three separate defects, all from `collapse(range:to:)` treating a multi-line block as
  one line: the image band was reserved once per newline (~90pt of dead space), the block's
  trailing newline stayed at body size (a blank line under the formula), and the async code
  highlighter repainted a collapsed Mermaid fence's concealed source (the coloured specks).

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
- 🍎 **macOS-only surfaces** — Open Quickly, the Git UI, image paste, Mermaid preview, HTML/PDF export, multi-tab, wiki-link autocomplete, open-in-new-window, Graph/Mind Map/Slides, and the file viewer. *(The AI stack is no longer on this list: 1.3 brought Summarise / Suggest Tags / Suggest Links / Rewrite, the selection actions, Ask Library, the Assistant, Review Links and New Note from a Prompt to iOS — see implemented.md.)*
- 🟠 **AI as a compact place** (decision 7) — the Assistant and Ask Library now exist on iOS as sheets reached from the Library actions, but the bottom tab bar still has no AI tab. Decision 7 also wants Graph and Mind Map as full-screen sheets on iPad. **Unblock:** a compact AI place, and porting those two views.
- 🟠 **Inline completion (ghost text) is macOS-only** — the iOS editor is a different view (`MarkdownUITextView`, chrome via `ChromeOverlayView`) with no ghost-drawing path, and the whole interaction is Mac keys: ⌥⇥, →, Esc, none of which exist on a soft keyboard. This is not a `#if` to delete — it needs an acceptance gesture designed for touch (tap the ghost? a keyboard-accessory button?) and a drawing path in the UITextView chrome. A hardware-keyboard iPad would get the keys for free once the drawing exists.
- 🟠 **Heading navigation from the iOS outline** — the inspector posts `.hnEditorFindQuery`, but `MarkdownEditorView` exposes no `EditorProxy` on iOS, so nothing consumes it. The outline reads; it doesn't scroll. **Unblock:** an iOS proxy seam in `MarkdownEditor`.
- 🟠 **Unlinked mentions in the iOS inspector** — needs the Spotlight query the macOS shell runs; the other two reference sections come straight from the index.
- 🟡 **iPad multitasking / Stage Manager** for the split layout is unverified on a device. The contract test covers a 320pt slice and a 250pt tile headlessly.

---

## 8 · Git / sync

- ⬆️ **Pull / merge** — SwiftGitX exposes `fetch` and `push` but no merge; there is no true "pull." **Unblock:** a merge API in SwiftGitX (or a libgit2 merge of our own).
- 🟠 **Merge-conflict resolution UI** — depends on merge existing first.
- 🟠 **Push smoke test** — HTTPS-token push against a real remote deserves one manual smoke test on a fresh machine before it's advertised; SSH remotes still rely on libgit2's ambient credentials.

---

## 8b · Cloud storage *(reworked 2026-08-15 — see [cloud-native-roadmap.md](cloud-native-roadmap.md) Phase 5)*

**Mounted providers are the front door.** When a provider's desktop client is installed
its storage is already at `~/Library/CloudStorage/<Provider>` as ordinary dataless files,
so **File ▸ Open Cloud Folder…** needs no sign-in, no token, no cache and no sync engine.
The direct API sits under **Connect Over the Web** — the fallback for an account whose
client is absent. On iOS the Files picker covers the same ground.

Everything that was listed here as a gap has been implemented: metadata-first mirroring
with on-demand hydration, delta refresh on all four providers, revision-based conflict
detection with conflicted copies, restore-on-launch, a bounded cache with LRU eviction,
chunked upload past the 4 MB simple-upload cap, collection promotion on iOS, and an
explicit "download and search" escape hatch.

What remains are **constraints of the providers and the platform**, not deferred work:

- 🔒 **Box embeds a client secret.** Box has no PKCE public-client mode, so the secret ships
  in the app and is extractable. Removing it requires a backend proxy or Box JWT
  server-auth — i.e. a server to run, not code to write here. Moot when Box Drive is
  installed, which is now the default path.
- 🔒 **Google "Testing" mode expires refresh tokens after 7 days.** A property of an
  unverified consent screen in the *owner's* Google console; publishing/verification (or
  Workspace-internal distribution) removes it. Nothing in this codebase can.
- 🔒 **Interactive sign-in needs a signed build.** `ASWebAuthenticationSession` won't
  reliably present from an unsigned CLI build — a signing requirement, and irrelevant to a
  mounted provider. Only Dropbox has been proven through a *complete* real
  sign-in→token→API round-trip; the other three are verified at the authorize endpoint and
  at request/response shapes.
- 🔒 **"Remove Download" is best-effort.** For a File Provider domain we don't own,
  dehydration is the provider's decision; we can trigger a download but not force the
  reverse. Surfaced as a hint, not a guarantee. *(The direct-API mirror does evict its own
  cache, because there it is our decision to make.)*
- 🟡 **The three non-Dropbox delta feeds are fixture-tested, not live-tested.** Graph, Box
  and Drive delta parsing is pinned by response fixtures the way every other provider
  request in this codebase is, but none has been exercised against a live account. Box's
  feed is account-wide and filtered to the subtree; Drive's is id-keyed, so a change to a
  file in a folder never walked is left for the next full sync rather than guessed at.

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
- ✅ ~~**The website screenshots predate the shell redesign**~~ — reshot 2026-08-12,
  all ten plates from one binary, and the procedure (plus the Screen Recording
  requirement, the raw-filename convention, and the on-device model's
  non-determinism) is written up in [website.md](website.md) § Re-shooting them.

  The shoot found three more editor bugs, which is now its established value:
  the `$$` artifacts (§6, fixed), a red spell-check squiggle surviving
  concealment on every rendered formula, and — the serious one — `bind(to:)`
  flattening the *previous* document's fonts, so switching notes permanently
  corrupted the note you left. See [implemented.md §20](implemented.md).

- 🟡 **Toolchain-sensitive code shapes** — two functions in `Core/VisionAlt.swift` are
  deliberately non-generic to dodge a SIL-inliner bug and carry comments saying so. If the
  Swift toolchain moves on, re-check before "simplifying" them back.

---

## 9 · HIG / platform polish

- ✅ ~~**Main window has no `defaultSize`**~~ — added (1100×720) in the HIG pass, [implemented.md §10](implemented.md#10--human-interface-guidelines-usability-pass-2026-07-20).
- ✅ ~~**Minimal first-run onboarding**~~ — `WelcomeView` ships a one-time welcome sheet on both platforms (§10).
- 🟡 **Liquid Glass (macOS 26)** — custom sidebar chrome and `.background(.bar)` status bars may fight the new material; needs a visual pass on 26. *(Code audit found no custom fills or opt-outs; the remaining risk is visual-only.)*
- ✅ ~~**Dark Mode in the Canvas surfaces**~~ — **entry was stale**: `NodePalette` is built entirely from adaptive system hues (`.blue`, `.purple`, …), which resolve per appearance; nothing is a fixed RGB value.
- 🟡 **Editor Dynamic Type** — the note editor uses its own text-scale control rather than system Dynamic Type. Deliberate (§10 "Consciously not changed"), but revisit if accessibility review pushes back.

---

## 10 · Localization

- 🟠 *(international launch)* / 🟡 *(English-only launch)* — effectively **zero localization**: one `String(localized:)` in the whole codebase, every UI string an inline literal, no string catalog. Blocks non-English markets and adaptable system-integration strings. App-wide scope.

---

## 11 · Tech debt & cleanups

- 🟠 **Incremental parse doesn't converge for prose** (`Packages/NotesEditor/Sources/MarkdownCore/BlockParser.swift`) — convergence only fires at `open == .none` (`isAtBoundary`), which prose (paragraphs, blanks, lists, quotes, tables) never leaves standing between lines, so an edit near the top of a long non-heading note re-parses to EOF: O(document) per keystroke. Correctness holds (fuzz tests pass); only the "cost proportional to the edit" guarantee is defeated. **Fix** needs the convergence check to compare the full builder state (not just `.none`) with its own fuzz re-verification — deliberately still deferred: it is the parser every other feature sits on, and a release week is the wrong time. *(The two sibling defects noted here are resolved in §20: the dead `.blank` merge branch — the test sat after `closeOpen`, which had already reset `open` — and the CRLF classifiers, which made setext headings, thematic breaks and front matter parse as paragraphs in any Windows-saved file.)*

- ✅ ~~**Inconsistent regex construction**~~ — resolved (§20): `try!` is the convention for a literal pattern (a failure is a programming error, visible on the first run). `MindMapView`'s `try?` meant a broken pattern would have rendered every mind map with no links and never said why. The two patterns are *not* interchangeable — the mind map's handles `[[Target#heading]]` — so they stay separate.
- ✅ ~~**Fragile force-unwrap idioms on constants**~~ — resolved (§20) for both sites named. *(The `URL(string:)!` calls in `Core/Remote/*Store.swift` interpolate provider file IDs and are a separate, larger sweep.)*
- ✅ **Undocumented unsafe-concurrency conformances** — *resolved (§7):* `CollectionEmbedProvider`'s `@unchecked Sendable` now carries a lock-invariant justification, and the editor's `nonisolated(unsafe)` observer tokens (`busTokens`, `boundsObserver`) are documented; `MarkdownTextView`'s bounds observer is now removed in `deinit`.
- 🟡 **Heading jump is still timing-based** — the two copies of the 1.2 s highlight-clear are now one function (`hnJumpToHeadingInEditor`, §20), so they can no longer drift. The underlying want — an editor-ready signal instead of a fixed delay — is still open.
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
- ✅ ~~**The two `GitService` tests deadlock the app suite.**~~ The FIFO waited on
  itself. `run()` stored its task in `lastQueued` and then, inside that task,
  `execute()` called `refreshStatus()` — which took `previous = lastQueued`, *the
  very task it was running inside*, and awaited it while that task waited for the
  read to return. A cycle, which is why the main thread sat in `XCTWaiter` with
  the whole worker pool idle, and why a longer timeout would never have helped.
  `execute()` now uses `refreshStatusInQueue()`, which reads without taking a
  second slot. Full suite: **119 tests in 18 suites, 2.3s.**
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

**Credentials:** the *provider* credentials are handled correctly — they live in a
git-ignored `Config/Secrets.xcconfig` and were purged from git history before the
repo's first push, so nothing has ever leaked. Local developer key files are the
owner's own business and are not tracked here.

**Remaining, non-blocking:** the residual 🟡 items under each section above, and the
feature backlog — **§6/§7 the iOS live-editor milestone (`editor-M5`)**, §8 git pull/merge
(upstream), §9 HIG polish, §10 localization, §11 tech-debt tidy-ups, §12 test coverage.
None block the macOS 1.0 release.

A post-review fix pass (2026-07-19) resolved the blocker and most should-fix items from
a full-codebase review — see [implemented.md §7](implemented.md#7--post-review-fix-pass-2026-07-19).
The items it landed are struck from the sections above; what it left open is tracked below.

---

## 1.1 (2026-08-11)

The 1.1 batch closed the §6 concealment defects, the §11 CRLF and dead-branch
faults, the §1 silent transcript write, the §4 references empty state and
create-repository cancel, the §3 launch-scan serialization and superseded walks,
and the §5 rotor search field and canvas Dynamic Type — see
[implemented.md §20](implemented.md).

**Read this register against the source before working from it.** Reconciling it
for 1.1 found **five entries describing gaps that had already been closed** and
never struck off: the editor headings rotor (shipped on *both* platforms), the
Duplicate shortcut, the clone Cancel button, Reduce Motion, and the canvas colour
palette. Four were no-ops. The two that weren't hid the *real* defects underneath
them — the rotor ignoring its search field, and the canvases ignoring the system
text size — which only a code read surfaced.

**Deliberately not done in 1.1**, and why:

- **Incremental-parse convergence for prose** (§11) — the parser everything else
  sits on; the register itself flags it as too risky for a blind pass, and a
  release week is the wrong time.
- **Localization** (§10) — app-wide, not a point release.
- **SSRF IP-pinning** (§2) — needs a custom `URLProtocol`; a security change
  deserves its own scrutiny, not a release-day drive-by.
- **Git pull/merge** (§8) — blocked upstream in SwiftGitX.
- **The iOS AI ports** (§7) — four new views.
- **Column widths remembered per window** (§6b decision 4) — the *behaviour*
  already works via the system's own split-view state restoration (the autosaved
  frames are in `com.hellotham.HelloNotes`). Owning it deliberately is a
  code-ownership refactor with no user-visible change, and not worth
  destabilising the shell the release after its redesign.
- **An in-flight latch for external scans** (§3) — adds re-entrancy to the core
  scan path; the cancellation half shipped instead.

---

## iOS parity audit (2026-08-21)

36 files are wholly `#if os(macOS)`. Audited each for what it actually *uses*,
rather than what it is gated on. Three groups.

### Gated for no technical reason at all

These import no AppKit and use no Mac-only API. The gate is the only thing
stopping them compiling for iOS.

| File | Lines | Mac-only API used |
|---|---|---|
| `UI/GraphView.swift` | 457 | none |
| `UI/MindMapView.swift` | 527 | none (`NSRange`/`NSRegularExpression` are Foundation) |
| `UI/CommandPalette.swift` | 274 | none |
| `UI/GitSettingsView.swift` | 161 | none |

`AppActions.canGraph` is hard-coded `false` on iOS and `commandPalette` is `nil`,
so both commands appear greyed out in the iPad menu bar — accurately, but for a
reason that is circular.

### Cross-platform API, gated anyway

- **`State/SpotlightSearch.swift`** — `NSMetadataQuery` is Foundation and ships
  on iOS. Consequence: `iOSContentView` passes `unlinkedMentions: []` to the
  inspector with a comment admitting the References tab is short one of its
  three sections on iPad.

### Small, real dependency — and the replacement already exists in-tree

| File | Needs | Already available |
|---|---|---|
| `UI/SlidesView.swift` | `NSViewRepresentable` | the `UIViewRepresentable` pattern used by `iOSFileViewer` |
| `UI/MermaidPreviewView.swift` | `NSImage`, `NSRect` | `PlatformImage`, `PlatformDraw` |
| `UI/CloneRepositoryView.swift`, `UI/NewRepositoryView.swift` | `NSOpenPanel` | `FolderPicker` in `iOSContentView` |
| `Core/SmartPaste.swift`, `Core/ImagePaste.swift` | `NSPasteboard` | `UIPasteboard` |
| `Core/VisionAlt.swift` | Vision + `NSImage` | Vision ships on iOS |

`GitService` itself is **not** gated — iPad already reads history in the
inspector. It cannot clone, create or configure a repository, which is a UI gap,
not an engine one.

### The one that is not a UI gate

**iPad never notices a change made anywhere else.** `Core/FileWatcher.swift` is
built on **FSEvents**, which genuinely is macOS-only, and `Collection`'s
`startWatching` is gated with it. On a vault synced from a Mac, the iPad shows
stale content until a manual **Rescan Collection**. This is the largest
functional gap in the audit and the only one whose fix is not "delete the gate":
iOS wants `NSMetadataQuery` for ubiquitous items, or
`DispatchSource.makeFileSystemObjectSource` per directory.

### Genuinely Mac-only, correctly gated

`GlobalHotKey` (no system-wide hotkey on iOS), `ServicesProvider` (NSServices),
`QuickCaptureView` (depends on the hotkey), `ChromeProbe` (window chrome
measurement), `TerminationGuard` (`NSApplication` quit handshake — iOS covers
the same ground through `scenePhase`), and the multi-window surfaces
(`AuxiliaryWindows`, `NoteWindowView`, `LauncherView`). `MLXProvider` is
arguable: MLX runs on iOS, but the memory ceiling on an iPad makes it a
different feature rather than the same one.

### Already at parity by another route

`EditorExport` → `iOSEditorExport`; `FileViewerView` → `iOSFileViewer`;
`FindReplaceBar` → `UIFindInteraction`; `OpenQuicklyView` → `OpenQuicklyList`;
`EditorTabBar` → the iPad tab strip; the settings panes → `iOSSettingsView`.

