//
//  CLAUDE.md
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

# HelloNotes Architecture Rules
- Target Environment: macOS 27+ / iOS 27+ / Swift 5.10+ / Xcode 27 (from 1.3.3; 1.3.2 was 26.5).
  The floor is high on purpose: every AI feature runs on the 27 Foundation Models API (the
  `LanguageModel` protocol MLX plugs into, dynamic profiles, Private Cloud Compute), and an app
  cannot promise an OS its own embedded extensions refuse to run on.
- Multiplatform: One shell, `AdaptiveShell`, chosen by the *axis of abundance* (width/height), never by device — a Mac window and an iPad of the same size get the same layout. See `docs/layout-architecture.md`.
- The window has **exactly one collapsible column**: a sidebar holding a *single tree* — Recents and Bookmarks pinned at the top, then one root per open collection, expanding into that collection's folders. SwiftUI only gives a correctly-placed sidebar toggle to column one, which is why everything navigational lives there and **no command may live inside it** (a hidden command is an unreachable command). Commands go in the toolbar: search leading, New Note / Open Quickly centre, the five inspector toggles trailing. See `docs/shell-chrome.md`.
- Anything keyed on a collection (the outline cache key, drop targets, "New Note" at a root) reads the sidebar's selection. **A cache key must name everything the cached value depends on** — keying the outline on one collection made opening or closing another invisible.
- State: Use the `@Observable` macro exclusively. DO NOT use legacy `@ObservableObject` or `@StateObject`.
- Data Source: No CoreData. The local file system directory is the absolute source of truth.
- Git Operations: Use `SwiftGitX` (Import `SwiftGitX`) utilizing native Swift async/await concurrency.
- Build Verification: After writing code, use the Xcode MCP tool to run a compilation check to ensure 0 errors.

# Layout
- App: `HelloNotes/` — `Core/` (parsing, FileIO, indexes), `State/` (@Observable services), `UI/`, `Intelligence/` (Foundation Models: `Models/`, `Features/`, `Assistant/`, `Tools/`); `UI/Shell/` holds the layout contract; `ContentView` (one struct, both platforms — merged from the former `MacContentView`/`iOSContentView` split on 2026-08-22, because every cross-platform divergence traced back to two files a one-sided `#if` kept from seeing each other) supplies its slots.
- Editor: `Packages/NotesEditor` (MarkdownCore / MarkdownEditor / GFMRender) — the app's only editor; the old engine fork is gone.
- Website: `website/` (Astro 7 + Tailwind 4) — see `website/CLAUDE.md` and `docs/website.md`.
- Docs: shipped work → `docs/implemented.md`; backlog only → `docs/unimplemented.md`.

# Commands
- Build (macOS, full CLI build): `xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes -skipPackagePluginValidation build` — the Xcode MCP check above is the quick per-change gate; use this for full/Release verification. **Every app `xcodebuild` needs `-skipPackagePluginValidation`**: mlx-swift's `Cmlx` target carries a `CudaBuild` build-tool plugin (inert on Apple platforms), and without the flag the build fails at "Validate plug-in" before compiling a file. Xcode's GUI asks once to Trust & Enable instead. The Hugging Face bridges in `Intelligence/Models/MLXBridge.swift` are hand-written rather than mlx-swift-lm's macros for the same reason — a macro plugin would need `-skipMacroValidation` everywhere too.
- Editor tests (macOS): `swift test --package-path Packages/NotesEditor`
- Editor tests (**iOS — run these too**): `cd Packages/NotesEditor && xcodebuild test -scheme NotesEditor-Package -destination 'platform=iOS Simulator,name=HN-iPad'` (~35s, headless, no app launch — 387 tests in 30 suites, verified 2026-09-04). It runs **three bundles** and prints a summary line for each — 18/4, 173/13, 196/13 — so the total is their *sum*; reading only the last one says "196 in 13" and looks like two thirds of the suite silently stopped running. `swift test` only ever builds the package for macOS, so the UIKit half went untested for its whole life — that is how a `UITextView` showing a document it believed was empty, a zero-width keyboard bar and a link tap that ate the caret tap all shipped at once. Create the device once with `xcrun simctl create HN-iPad com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4-8GB com.apple.CoreSimulator.SimRuntime.iOS-27-0` (1.3.3's floor; the iOS 26.5 devices were kept, renamed `HN-iPad-26.5` etc., so `name=HN-iPad` resolves to one device). MLX cannot run in the simulator, and the app says so there.
- **Look at the iOS app without the user's device**: `xcodebuild build -destination 'platform=iOS Simulator,name=HN-iPad'`, then `xcrun simctl install HN-iPad <app>`, `xcrun simctl launch HN-iPad com.hellotham.HelloNotes`, and `xcrun simctl io HN-iPad screenshot out.png` — which is readable. A whole iPad session was shipped blind (a keyboard bar that never rendered, a zero-width one, five inspector toggles that could not work at that width) because nobody looked. `simctl` has no tap injection, so driving the UI still needs the live panel — which needs `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` from the user.
- Is it running on the device? `xcrun devicectl device info processes --device <id> | grep "HelloNotes.app/HelloNotes"` — **capital H**. A lower-cased pattern matches nothing and reads exactly like a crash-on-launch; an hour went into diagnosing a crash that never happened. Cross-check against `--domain-type systemCrashLogs`: no new `.ips` means no crash, whatever the process list appears to say.
- Layout contract: `./scripts/run-tests.sh -only-testing:HelloNotesTests/ShellContractTests` (~2s — run it after any shell or representable change).
- **Model evaluations** (Apple's Evaluations framework, real on-device model, ~30s, opt-in — needs Apple Intelligence, so never CI): `TEST_RUNNER_HN_EVALUATIONS=1 ./scripts/run-tests.sh -only-testing:HelloNotesTests/IntelligenceEvaluationTests`. Tags, links, rewrites, long-note summaries and Assistant tool trajectories. Add `TEST_RUNNER_HN_EVAL_MLX_FOLDER=<absolute path>` to run the same suite on an MLX model — a model folder, or a model's `models--org--name` folder in `~/.cache/huggingface/hub` (list what is there with `mlx_lm.manage --scan`; never download one without asking), loaded through the app's own folder path; a `~` would expand inside the test host's container. Two more suites run under the same flags and pick themselves by the model: `AssistantEditEvaluation` (a tool call, an approval, and the note on disk changes — the trajectory suite denies every approval, so nothing else ever writes) and `AssistantWithoutToolsEvaluation` (a model whose template has no tools must answer in words, not imitation calls). Add them with their own `-only-testing:` flags. Run after touching any prompt, schema, tool, `HistoryWindow` or `TokenBudget` — the unit tests prove plumbing and could not see the two defects this suite found in its first hour (below). Read per-sample results with `xcrun xcresulttool export attachments --path <xcresult> --output-path <dir>` (`.xcevalresult` JSON). Two more opt-in probes run inside the signed app: `TEST_RUNNER_HN_RESEARCH_PROBE=1 … -only-testing:HelloNotesTests/ResearchProbe` (a real deep-research run, ~30s, searches the web) and `TEST_RUNNER_HN_PCC_PROBE=1 … -only-testing:HelloNotesTests/PrivateCloudComputeProbe` (one PCC request; does nothing unless the build is entitled).
- **iOS interface tests** — the only check that a screen actually *draws*:
  `xcodebuild test -project HelloNotes.xcodeproj -scheme HelloNotes -destination 'platform=iOS Simulator,name=HN-iPhone' -skipPackagePluginValidation -only-testing:HelloNotesUITests`
  (~4 min, 12 cases, headless). Run it after any change to a settings screen, the
  shell, or the editor's chrome — **and actually run it**:
  `testTheOpenNoteIsNotClippedOffTheScreen` waited for a word count that was
  removed from the status bar on 2 September and failed every run from that day
  to 16 September, because nothing ran this suite in between. A test naming a
  thing the app no longer has fails for a reason that has nothing to do with what
  it tests, and a suite nobody runs says nothing at all.
- App tests (macOS): `./scripts/run-tests.sh` — **never a bare `xcodebuild test`**.
  The bundle is *hosted by the app*, so a raw run opens HelloNotes on the user's
  screen and leaves test hosts behind; the script quits their app first
  (gracefully — it may hold unsaved edits), runs the suite, and kills any host
  afterwards whatever the result. 507 tests in 79 suites, ~9s (1.3.3).
- **Edit ≡ Preview**: `./scripts/render-parity.sh` — lays the same note out in TextKit and in WebKit, offscreen, and fails if any block drifts more than a point. Three gates in one: a hand-written sample at 5 text sizes × 3 widths, **58 whole documents at 1200 / 800 / 560pt** (plus 420 measured and reported without failing — see the bullet below), and a chrome check that measures the marks themselves. Run it after touching `GFMBoxMetrics`, `StyleApplier`, `BlockBoxes`, `GFMLiveStyle` or `GFMPage`. It is a script, not a test, because a `WKWebView` never finishes loading under `swift test` *or* under XCTest in the app host — both were tried. See implemented.md §23.
- **The real-document gate**: `swift run --package-path Tools/RenderParity RenderParity --docs --width <w>` over `Tools/RenderParity/Documents` — READMEs, meeting notes, kitchen sinks, one document ending in each awkward thing and one starting with it. It found nineteen defects on its first outing with all 672 spec examples already agreeing, and it is the gate to run when a change is about *documents* rather than constructs. Bisect one with `--locate <file>`, which lays out every prefix a top-level block at a time and marks the row where the delta moves. **Width is a dimension of coverage, not a configuration**: six of the nineteen were horizontal errors that only become heights when something wraps, and two more (a heading's opening margin paid per wrapped line, a 900pt cap on every rendered embed) were exact at 800 and wrong at 420 and 1200. 420 is measured and **reported without failing**, because it is the only width where a four-column table stops fitting (so the only place the overflow layout is exercised) and also the only width where an open divergence fires — TextKit takes a line-break opportunity after `/` and WebKit does not, which is 20pt on any wrapped code line holding a URL. Both failing documents print with their deltas on every run, so a new shortfall there is a new line; if that listing ever names more than the two, something regressed.
- Live verification: run `scripts/relaunch-debug.sh` first — plain `open` reuses a stale instance and you test the wrong binary.
  `HN_CONFIG=Release ./scripts/relaunch-debug.sh` launches the **Release** build, which is the only one that proves anything
  about the sandbox: Xcode injects `temporary-exception.files.absolute-path.read-only = /` into Debug builds, so a Debug run
  cannot reproduce an entitlement bug and cannot fail to.
- Release/DMG: use the `/release` skill (`docs/production.md` Appendix A2 is authoritative).

# Hard-won rules
- Cold builds take 30–47 min (74 targets). A long `xcodebuild` is a cold build, not a hang.
- Debug proves nothing about Release: check `-configuration Release` before archiving (a Release-only optimizer crash once broke every archive — implemented.md §13).
- A viewport must report the size it is **offered**, never the size it **contains**. Every representable wrapping a scrolling/content-sized view implements `sizeThatFits` via `viewportSizeThatFits` and never returns `nil` — `nil` means "ask the platform view", whose `fittingSize` is the whole document (3433pt for a 76-line note), which inflates every ancestor until the top of the content sits above the window, unreachable. Pair every `minWidth/minHeight` with a maximum. Details: implemented.md §17.
- Vault content I/O goes through `Core/FileIO` (coordinated), never `String(contentsOf:)`/`.write(to:)` — raw reads of dataless cloud files fail with EDEADLK. The `vault-io-reviewer` agent checks this.
- **`git checkout -- <file>` is a destructive command in this tree.** Thousands
  of lines sit uncommitted for a whole session, so it does not "undo my last
  edit" — it discards every uncommitted change to that file. Revert an
  experiment the way you made it: a `python3` replace of the exact text you
  added. If it does happen, the session transcript is a real backup:
  `~/.claude/projects/-Volumes-Photos-Apps-hellonotes/<id>.jsonl` holds every
  `tool_use` input, so the edit commands can be extracted and re-applied — and
  a `grep`/`sed` output captured before the loss verifies the reconstruction
  line-for-line.
- `project.pbxproj`: git is the source of truth. Never accept an Xcode regenerate/modernize prompt; recover with `git checkout HEAD -- HelloNotes.xcodeproj/project.pbxproj`.
- Secrets: `Config/Secrets.xcconfig` (git-ignored) holds the cloud-storage provider keys (Dropbox, Box, Google Drive, OneDrive — there are no AI keys from 1.3.3); the DMG bakes in whatever it held at build time. Never touch the repo-root `.env`.
- **Editor rendering, the box model and the parity harness have their own rules,
  and they live in `Packages/NotesEditor/CLAUDE.md`.** Read that file before
  touching `GFMBoxMetrics`, `StyleApplier`, `BlockBoxes`, `GFMLiveStyle`,
  `GFMPage`, the TextKit fragment drawing, or `Tools/RenderParity`. They were
  moved out of here because they are unreadable noise for website, LLM, shell
  and State work — which is most work — and are auto-loaded the moment you edit
  anything under `Packages/NotesEditor/`.
- **A context window is a thing you *ask* the model for, never a thing you
  remember.** The provider layer kept per-provider tables that were wrong the week
  after they were written; it is gone (1.3.3). `LanguageModels.contextSize(of:)`
  reads `SystemLanguageModel.contextSize` (8,192 for AFM 3 Core Advanced on this
  generation, not the 4,096 the docs quote for Core) and Private Cloud Compute's
  `contextSize` (32,768). Budgets are **tokens, estimated script-aware**
  (`TokenBudget`): the on-device model counts 44 English characters as 11 tokens
  and 24 Chinese characters as 19, so an English character ratio sends a Chinese
  note five times over the window.
- **Never truncate text you are about to replace.** The old rewrite trimmed the
  selection to the budget, then replaced the *whole* selection with a rewrite of
  its beginning — deleting the rest. A feature whose output replaces its input
  refuses over-length input (`IntelligenceService.rewrite`); one that describes
  its input processes all of it (`summarize` goes through parts, then the parts);
  only a *suggestion* may read an opening (tags, links).
- **Adding a non-optional stored property to a persisted `Codable` type silently
  resets the user's configuration.** Synthesised decoding *throws* on a missing
  key, and a settings object that decodes with `try?` and falls back to defaults
  turns that into a silent wipe (1.3.2's `LLMSettings` had exactly that shape).
  Anything stored in `UserDefaults` decodes field by field or reads plain keys
  leniently — `ModelChoice(stored:fallback:)`, and `IntelligenceMigration` reads
  only `kind` and `model` from the old provider blob.
- **Concurrency in `ResumableTreeWalk` buys back *latency*, nothing else — and
  the serial path must not pay for it.** A provider listing is a network round
  trip spent idle, so `TreeSource.listingConcurrency` (6 for `RemoteTreeSource`)
  overlaps them; a local listing is a syscall over a warm cache, so the default
  is **1** and width-1 awaits directly. Routing width-1 through the window put an
  unstructured `Task` around every local directory and made the local walk ~4×
  slower — caught by `theWalkIsCompetitiveWithTheEnumeratorOnARealisticVault`,
  which is why that benchmark exists. The safety invariant is that **`head` means
  *next to apply*, not *next to fetch***: an in-flight listing is still inside
  `frontier[head...]`, so a checkpoint taken mid-window loses nothing. Only
  fetching overlaps — `onBatch` is not `@Sendable`.
- **`Form { IntelligenceSettingsForm(…) }` collapses — the shared AI settings form is
  already a `Form`.** Nesting one Form in another renders a clipped stub: a
  half-drawn section header in an empty box and nothing else. That is how the
  iOS AI settings screen shipped in build 11 having never once drawn. Related
  and equally invisible from the Mac: **`TextField(title:text:prompt:)` shows its
  title only as the placeholder on iOS**, so supplying `prompt:` leaves the field
  unlabelled there while macOS shows the label to its left — use
  `LabeledContent`. A shared view guarantees both platforms are built from the
  same code and guarantees nothing about whether either draws.
- **Look at iOS on the simulator; it costs nothing and does not touch the user's
  screen.** `xcrun simctl install/launch` plus the iOS Simulator MCP
  (`screenshot`, `tap`, `swipe`) drives the real UI headlessly. Two traps: derive
  tap coordinates from the *device's* point size (`pixelWidth`/2 or /3 — the
  iPhone 13 Pro Max is 1284×2778 px at 3× = **428×926 pt**), never from the
  screenshot's displayed pixels; and a plain `tap` **does not drive a `UISwitch`**
  — use `touch_path` with a ~120ms dwell, or you will diagnose a working toggle
  as broken. To reach a settings state, seed it:
  `xcrun simctl spawn <dev> defaults write com.hellotham.HelloNotes aiAssistantModel -string mlx`.
- **Suggestions write front matter, never the body.** Tags → `tags:`, links →
  `related:`, summaries → `summary:`, via `NoteEdits.appending(_:toListProperty:of:)`
  and `setting(_:property:of:)`. Three YAML rules travel with that: a value
  starting with `[` **must** be quoted (`- [[Note]]` unquoted is a nested
  sequence, not a string, so it does not survive its own round trip); a scalar is
  one line, so a summary is folded; and `MarkdownParsing.tags` reads the `tags:`
  key plus inline tags **in the body only** — scanning front matter for `#` turns
  a summary quoting a hashtag into a tag nobody wrote.
- **A source-symmetry check cannot see whether a screen renders.**
  `PlatformParityTests` asks whether every `AppActions` field is wired on both
  shells; that is the *command* axis and it is blind to rendering, labelling and
  reachability — which is where every parity bug actually found has been.
  `sizeThatFits` answers **0** for a healthy `Form` (a viewport reports the size
  it is offered), and `ImageRenderer` draws a nested `Form` **identically** to a
  plain one, so neither can catch a collapsed screen. The check that works is
  `HelloNotesUITests`, which launches and navigates the real app — and it was
  proved by reintroducing the bug and watching it fail. **Any check of this kind
  needs a negative control**, or it quietly starts passing for everything.
- **Three traps when writing those UI tests.** Orientation decides which shell
  you get: an iPhone 13 Pro Max in landscape is 926pt — regular width — so the
  compact tab bar does not exist and every test skips with a message that reads
  like a broken test (`XCUIDevice.shared.orientation = .portrait`). The compact
  shell remembers its last place and the overflow button lives on Notes, so
  select it first. And the splash is deliberately `.isModal`, which XCUITest
  treats as an interrupting alert it cannot dismiss — wait it out.
- **`TextField(title:text:prompt:)` is unlabelled on iOS.** The title is drawn
  only as the placeholder there, and a `prompt:` replaces it — so the field has
  no name at all, while macOS shows the label to its left and looks perfect. Use
  `LabeledField`; `PlatformParityTests` guards it. The rule: a field must be
  identifiable without typing in it, so a prompt that *names* the field is a
  label and a prompt that shows an *example* is not.
- **An asset you cannot regenerate lives in the repo, not in a scratchpad.** The
  raw App Store window captures were shot into a session scratchpad, composited
  into the branded website frames, and never committed — `make-screenshots.py`
  called capturing them "a manual step" and stopped there. When the store needed
  *undecorated* Mac screenshots they were unrecoverable: compositing is one-way
  (gradient, caption, rounded corners, shadow), the scratchpad was gone, git had
  only the decorated versions, ASC's Media Manager had only the decorated
  versions, and the sole surviving copies were **1999px previews inside session
  transcripts** — the transcript downscales, so it is a record, not a backup.
  The script now copies its inputs to `assets/screenshots-raw/`. The rule
  generalises: if remaking it needs someone's machine, their vault, or their
  time, commit it the first time.
- **"Screenshotting to check" *is* capturing.** Verify the Mac app's loaded
  collection by reading it, never by looking:
  `/usr/libexec/PlistBuddy -c "Print :collectionPaths"
  ~/Library/Containers/com.hellotham.HelloNotes/Data/Library/Preferences/com.hellotham.HelloNotes.plist`.
  Capture only once that names SampleVault alone. Saying "I won't ship this one"
  is not the same promise as "I won't take it": three captures of a private
  2,019-note vault were taken *while checking whether the vault had switched*.
  Back the plist up first and restore it after — opening or closing a collection
  changes the user's state.
- **Read every summary a command prints.** The iOS editor suite emits **three**
  bundle lines (18/4, 173/13, 196/13); `tail -3` shows the last one, and
  reporting "196 of 383 tests ran" from it invented a coverage hole that did not
  exist. Same failure shape as the `> 600` spec guard: a number that is true of
  a fragment reads exactly like a number that is true of the whole.
- **Look at the artefact before describing it.** Four claims in one session came
  from inference where one command would have settled it: an "unlabelled button"
  that a frame dump showed was SwiftUI's inert `Menu` twin; a "missing" test
  target; a screenshot set called complete without opening the iPad tab; and a
  file search that excluded `2560x1600` *because* the wanted files were assumed
  to be that size. Inference about a file is not evidence about a file.
- **"Is anything else needed?" is a request to re-inventory every surface**, not
  to re-check the one just touched. Answering it from the DMG alone left iPad
  sitting on a single stale screenshot through two submissions.
- **`click at` coordinates do not register in this SwiftUI app; `click <element>`
  does.** implemented.md §15's blanket "synthetic clicks do not register" is true
  only of *coordinate* clicks. AXPress on a **named element** works —
  `click (first button of toolbar 1 of window 1 whose description is "Outline")`
  reaches every inspector toggle, and `click menu item "…" of menu 1 of menu bar
  item "View"` reaches every command. Reading the §15 note as absolute is what
  made re-shooting the screenshots look impossible when it was not. Opening a
  collection is the one step genuinely unscriptable: the picker is a separate
  XPC process (`com.apple.appkit.xpc.openAndSavePanelService`), and keystrokes
  aimed at it land on the app instead — where `⌘⇧G` is **Graph View**, so a
  mistimed "go to folder" silently opens a graph window over the user's vault.
- **One directory, two names — and Foundation only ever offers you one.**
  `/var/x` and `/private/var/x` are the same folder; `standardizedFileURL` does
  **not** unify them (it resolves `.` and `..` and stops), and
  `resolvingSymlinksInPath` normalises *towards the short form* — given
  `/private/var/x` it returns `/var/x`, never the reverse. So "ask for the other
  spelling" silently returns the same string. Compare paths through
  `CollectionIndexCache.rootPrefixes(root)`, which carries both by hand, and
  never per file: resolving symlinks per note is the syscall-per-file trap
  `ResumableTreeWalk` already warns about. When no prefix matches,
  `relativePath` returns an **absolute** path, and the cache will happily store
  it — that is how a collection came to disagree with itself about the names of
  its own notes.
- **`contentsOfDirectory(at:)` refuses a symlink at the end of a path** with
  ENOTDIR; `contentsOfDirectory(atPath:)` follows it. `Collection.unavailability`
  uses the second, so a vault reached through a symlink passed every health check
  and then failed its first listing — healthy, and empty. Resolve for the
  *enumeration* only and keep the collection's own spelling on the URLs you
  store, or you trade one mismatch for another.
- **"The same notes" is a set, not an array.** `CollectionIndexCache.notes(for:)`
  sorts a **Dictionary's** values, and dictionary order depends on the process's
  hash seed — so two notes sharing a modification date come out in a different
  order on a different run. Comparing pictures as `[Note]` called that a change
  and rebuilt the sidebar on every launch. Ties are ordinary: anything written,
  copied or checked out in one batch shares a date.
- **A green test can be resting on the defect you are about to remove.** With
  absolute paths in the cache, `notes(for:)` discarded every record and
  `activate` fell through to a synchronous scan — so the test for the
  *asynchronous* verification never had to wait for it, and passed. Fixing the
  cache made it fail. When a fix breaks an unrelated-looking test, suspect the
  test was passing for the wrong reason.
- **Exactly one thing consults a purchase, and it is not a feature.** Backing the
  app buys an in-app **support request** — a channel, never a queue, and never
  "priority" (the listing promised that and no queue existed).
  `SupportContractTests.onlyTheSupportRequestConsultsAPurchase` allows three
  files and is meant to stay three; a second test asserts the gate is actually
  present, because an allow-list proves nothing about whether the file uses what
  it permits. The purchase screen must not claim nothing is gated.
- **`DefaultCollection/` ships inside the binary.** It is the tour and the user
  manual, and a reviewer reads it. When behaviour changes, its notes are part of
  the change — `Manual/Supporting HelloNotes.md` said "nothing is locked" for a
  while after something was.
- **Private Cloud Compute without its entitlement is a crash, not an error.**
  `PrivateCloudComputeLanguageModel.availability` reports `.available` in a signed
  app that lacks `com.apple.developer.private-cloud-compute`, and the first request
  ends the process with a `fatalError` inside Foundation Models — it killed the test
  host, and a concurrent evaluation with it. An unsandboxed `swiftc` probe reports
  the same availability and does *not* crash, so probing outside the app proved
  nothing. The model is only created and offered under the `PRIVATE_CLOUD_COMPUTE`
  compilation condition (`LanguageModels.privateCloudComputeEnabled`), added in the
  same change as the entitlement; `PrivateCloudComputeEntitlementTests` fails if
  they disagree. Never add the entitlement before Apple assigns it (signing breaks).
  Steps: `docs/production.md` §1b-PCC.
- **A profile's `historyTransform` is handed the instructions entry too** —
  `["instructions", "prompt"]` on the first request — and that entry carries the
  tool definitions. `HistoryWindow.fit` first trimmed from the latest prompt and
  dropped it: the on-device Assistant had no tools and no instructions, and
  answered questions about the vault by inventing notes. Unit tests passed; only
  the evaluation's tool-call score (0) showed it. Keep instructions, trim turns.
- **The model issues parallel tool calls** (four lookups in one step, run
  concurrently), so two edits can ask for approval at once. `PermissionBroker`
  queues; it used to deny a prompt raised while another showed, which fails the
  second edit for nothing. And a tool that *throws* aborts the whole response
  (`ToolCallError`, transcript rolled back) — recoverable failures are returned
  as text (`ToolOutcome`), only cancellation propagates.
- **Don't use `SystemLanguageModel(useCase: .contentTagging)` for tags.** Measured:
  it extracts key *phrases* ("bikes along the Kamo river") whatever the schema's
  `@Guide` says, and its guardrail refused a sourdough-baking note. The general
  model asked for *topics* works; name the note's language in the instructions
  (`NLLanguageRecognizer`) — a guide saying "in the note's language" is ignored.
- **Every tool, profile and `@Generable` type the framework calls is
  `nonisolated`.** This target defaults to `MainActor` and is Swift 5 mode, so an
  isolation mistake is a *warning*, not an error. Tools hop to the main-actor
  `ToolContext` for work; `WebGuard` is `nonisolated` because its synchronous DNS
  lookup was running on the main thread.
- **What ships is what is in the bundle, not what runs.** The repo `README.md` sat
  in the app target's Resources phase from the first commit, so every App Store
  build carried a list of fourteen AI services; and a type name or string literal
  is compiled into the binary (`OpenAISettingsButton`, a table of provider names
  for an upgrade notice). `ShippedContentTests` fails if Resources copies anything
  but `DefaultCollection` or if app code or bundled notes name an AI service.
  A clean `strings` scan of the binary is not proof a name is gone: an optimised
  build folds some short literals into the machine code, where no scan sees them
  (checked with `swiftc -O`: `"Groqish"` vanished, `"OpenAI"` did not). Check the
  source, which is what the test does.
- **A write the app makes outside the editor must tell the open editors, and an
  approved write must replace only what was approved.** `noteDidSave` registers a
  write as the app's own, so the watcher ignores it — and a tab showing that note
  then saves its stale text over the change. Call
  `Collection.noteChangedOutsideEditor()`. A write computed from an earlier read
  that someone approved goes through `FileIO.replace(_:at:ifContentsEqual:)`:
  clicking Approve in the Assistant's window ends editing in the note's window,
  which saves typing the diff never showed. And never read a note as `?? ""` on
  a path that shows or replaces it — an unreadable note is not an empty one.
- **A `nonisolated async` helper that waits or polls must be `@concurrent`.**
  Under approachable concurrency it inherits the caller's actor, so
  `FileIO.materialise` polled the file provider on the main thread every 200 ms
  for up to a minute, from both the editor and the Assistant. `offMain` catches
  main-actor state in its closure only as a *warning* in this target — and the
  call still hops at runtime.
- **A streaming reply must not redraw the conversation per snapshot.** The
  on-device model yields ~40 snapshots a second; redrawing each re-parsed the
  reply's Markdown from line one (15 ms at 30 KB). `AssistantModel` follows at
  most ten times a second with a trailing catch-up (a tool call followed by a
  pause must still appear), and `AnswerMarkdown.Streaming` parses only new lines.
  Anything shown per line of a note — the approval diff — is computed once off
  the main actor and laid out in a `LazyVStack` (a plain `VStack` of 10,000 lines
  took 898 ms).
- **The models folder is the Hugging Face cache, and the app asks for it by
  name.** A sandboxed Mac app cannot read `~/.cache/huggingface` — where
  `mlx_lm` and every other MLX tool keeps its models — and making someone point
  a file panel at it before the app can see models the machine already has is a
  chore, not a design.
  `com.apple.security.temporary-exception.files.home-relative-path.read-write`
  with `/.cache/huggingface/` is honoured by macOS 27's sandbox profile
  (`/System/Library/Sandbox/Profiles/application.sb` still handles
  `temporary-exception.files.home-relative-path.*`), so the folder is simply the
  default and downloads land where the other tools look. It is a *temporary
  exception*: App Review may ask, and `docs/app-store-listing.md` carries the
  justification. Verify it in **Release** (`HN_CONFIG=Release
  ./scripts/relaunch-debug.sh`): Xcode gives Debug builds the whole disk, so a
  Debug run cannot tell you whether the entitlement works.
  Inside the sandbox `NSHomeDirectory()` is the container, so the path comes
  from `getpwuid(getuid())`.
- **A Hugging Face cache snapshot cannot be opened from the sandbox.** Every file
  in `models--org--name/snapshots/<rev>/` is a symlink into `../../blobs/`, and a
  folder grant covers the folder, not what its links point to — measured with
  `sandbox-exec`: "Operation not permitted" on the snapshot, readable from the
  model's folder. Debug builds read the whole disk, so neither the test host nor
  a Debug run can show it. So the grant is on the **models folder** — the cache
  itself, `~/.cache/huggingface/hub` — and `MLXModelFolder` lists its
  `models--*` entries and resolves each `refs/main`. Read sizes *through* the
  links: a link's own size listed a 17 GB model at 81 bytes.
- **No command lives only behind a gesture.** A long-press, right-click or swipe
  is a shortcut; everything in one needs a visible route too (HIG, Context
  menus: always make their items available in the main interface). A row with
  commands of its own shows them behind `RowActionsMenu` (`…`); a note's are in
  the open note's menu, from the same `SidebarMenu` list. `Menu(primaryAction:)`
  *looks* like a plain button and is a hidden menu: tap was New Note, hold was
  everything else, and on every iPad that hid Settings.
- **Every panel drags to resize, and the width is the person's.**
  `shell-chrome.md` D7 promised a draggable splitter from the day the inspector
  was designed and the code never had one, so every panel was whatever number
  the shell had written down — 280pt of inspector beside a graph that wanted
  760. `ResizableDivider` stores the width and **clamps it at use**: drag it
  wide, narrow the window, and the width is borrowed back rather than
  forgotten. A 1pt line is not a target; the grab area is 10pt and the pointer
  changes over it.
- **Collections on the left, the editor in the middle, anything else on the
  right — one panel, one state, one width.** Outline, Tags, References,
  Properties, History, Mind Map, Graph, Ask Library and the Assistant are not
  two kinds of thing; they are nine views of the right panel (`SidePanel`), and
  treating them as two cost two enums, two chromes and two widths. The band has
  one toggle; the panel's own header picks what it shows, the same way on both
  platforms. The panel is a **column** wherever the editor keeps its floor
  beside it (`ShellMetrics.hasPanelColumn`) — *an editor never blocks editing*,
  so it is never a modal over the note — and only a phone, with no room for a
  column, carries it over the note.
- **The app opens no window of its own, on either platform.** `openWindow` on
  iPadOS makes a scene that *replaces* the notes in full-screen apps and in
  Split View, and closing it left the app — Done in the Assistant showed the
  Home Screen. Nothing tells full-screen from windowed
  (`UIWindowScene.isFullScreen` is Mac Catalyst only; `sizeRestrictions` is
  non-nil in both, probed on iPadOS 27), and the answer was not to give the Mac
  something the iPad cannot have: **parity is one rule and one shape, not a
  platform's worth of exceptions.** A window happens when someone asks for one
  by name — New Window, Open in New Window — and those two are on both
  platforms like every other command.
- **Accent on accent draws nothing.** On iPad a selected row, and `.selection`,
  *are* the tint — so a tinted glyph inside one vanishes. The inspector's chosen
  tab was a blank pill and a row's `…` disappeared into its own highlight. Use
  `.secondary`, or the tint at low opacity behind it.
- **One Settings, opened at a page.** AI settings are `SettingsPage.ai`, never a
  second screen: a standalone "AI Settings" sheet beside "Settings…" read as two
  places. The Mac's page is stored, because `openSettings` takes no argument;
  iOS pushes it. The Assistant presents Settings itself — on iOS it is already
  presented, and the shell cannot present over it, which is why its old
  "Open AI Settings…" did nothing on iPad. ⌘, opens Settings on iPad too.
- **The on-device model is "System"** — Apple's name for it (`fm --help`:
  `system`, "System model available"). Its variant, AFM 3 Core or Core
  Advanced, is the hardware's decision; naming it made people ask for the other.
- **A platform gate inside a modifier chain goes in a helper.**
  `ShellComplianceTests` requires every `#if os(…)` to have an `#else`, and a
  postfix `#if` with an empty branch does not compile ("reference to member
  cannot be resolved without a contextual type"). Write a function with both
  branches (`presentingSettings`, `startingInHuggingFaceCache`).
- **An unused value is how you find out an API moved under you.**
  `@_disfavoredOverload` does not remove the old function, it demotes it, so a
  call that still type-checks binds to the *new* one: `dropDestination(for:)`
  took `(items, location) -> Bool` and now takes `(items, session) -> Void`, same
  arity. Both sidebars kept compiling and the `false` that refused a drop onto
  Recents was discarded — the whole signal was one `expression of type 'Bool' is
  unused`. Read the warnings an OS bump adds, and read the `.swiftinterface`
  (`xcrun --sdk macosx --show-sdk-path`) rather than guessing which overload won.
  Refuse a drop with `isEnabled:`, which declines before the row lights up.
- **A menu from a toolbar mid-screen is capped — about 520pt on a portrait
  iPad — and scrolls.** Settings came last in the iPad's `…` menu and fell below
  the fold of the menu added to make it findable. Order for the fold.
- **The simulator tool's taps arrive as a mouse.** After the first one
  `PointerPresence` reports a pointer, the band switches to 24pt rows and stays
  there across relaunches — so a touch-sized layout can only be looked at
  before the first tap.
- **One model, and the framework's knobs — no roles, no inventions.** There was
  a model for the Assistant and another for the writing tools; with MLX they
  could not even differ, since one MLX model is loaded at a time, so picking one
  silently moved the other. `IntelligenceSettings.model` is the single choice:
  the app is either on Apple's model or on yours. What is tunable is exactly
  what `GenerationOptions` and `ContextOptions` expose — temperature (0–2),
  `samplingMode` (greedy, top-k, top-p, each with a seed), `maximumResponseTokens`
  and `reasoningLevel` — applied to the Assistant's profile. A control the model
  never sees is worse than no control, and a knob the framework has and the app
  hides is a question someone has to ask.
- **The app suggests no models, and remembers no fact about one.** Four
  suggestions with sizes and a sentence each lasted a day: checked against the
  Hub they were last updated in 2025, while the models on the machine were 2026
  ones, and not one of the four had ever been run. A live Hub list was rejected
  too — a network call in a settings screen, ranked by popularity, which is not
  advice. What a model can do is read from the model (tools from its chat
  template, weight size from its files); the context window is the device's
  (`MLXModelStore.contextTokens`); reasoning is never declared, because it must
  be declared before loading and declaring it wrongly fails every request.
  `ShippedContentTests.noModelIsSuggested` fails if an id reappears.
- **An MLX model can only call tools its chat template shows it.** The adapter
  passes tool definitions to the template; Gemma 3's never mentions `tools`, so
  they vanish. Given the Assistant's tools, Gemma 3 27B wrote
  `read_note("Welcome")` in a code block as its *answer* and nothing ran — the
  right tool, in a syntax nothing parses, and its template rejects tool turns
  anyway. `MLXChatTemplate.rendersTools` reads the template; without tools the
  model gets no `.toolCalling` capability, the Assistant runs chat-only and says
  so, and Research is unavailable. The writing tools don't need tools and passed
  every evaluation on the same model.
- **A test that reads a document fails silently when the document is
  restructured.** `StoreListingTests` read the listing fields out of
  `production.md`; rewriting that file to stop duplicating live metadata removed
  them, and the 3.1.2(c) guard failed on every run for a week, unread. The copy for
  the version in preparation now lives in `docs/app-store-listing.md`. When you
  restructure a file, grep the tests for its name first.
- Docs describe the UI from source, not memory — verify shortcuts/menus with the `docs-fact-checker` agent (a draft once shipped two invented shortcuts).
- Commit trailer: `Co-Authored-By: Claude <model> <noreply@anthropic.com>` per repo convention.
