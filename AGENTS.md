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
- Multiplatform: One shell, `AdaptiveShell`, chosen by the *axis of abundance* (width/height), never by device — a Mac window and an iPad of the same size get the same layout. See `docs/ui.md`, and for each part of the window `docs/primary.md`, `docs/secondary.md`, `docs/toolbars.md`, `docs/tabs.md` and `docs/menu.md`.
- The window is three regions, each about one thing: **the collection on the left, the note in the middle, what the note is on the right** — and each command is in one place (after 1.3.3 builds 27 and 28, at the person's direction; `docs/shell-chrome.md` D12, D13 and D14).
  - **The sidebar** — the one collapsible column — is the collection: a *single tree* (Recents and Bookmarks pinned at the top, then one root per open collection, expanding into its folders), with its tools as named rows above the tree (`SidebarCommands.swift`) — **Mind Map**, **Assistant**, **Git** (Ask Your Library was folded into the Assistant in 1.3.5) — and, in its header, its own **toggle** and a **`+`** for New Folder, New Collection, Open Collection (with Open Recent) and Open Default Collection (`collectionAddItems`). One definition: rows in the column and in the phone's Notes place (the phone's sidebar — the panel was its only route to the collection's map, so moving the Mind Map out left it none until the rows came — whose bar has the same `+`), a strip in the tall shell's band. While the sidebar is hidden its toggle is the bar's first button, so a hidden sidebar can always come back ("a hidden command is an unreachable command"). All of these but New Folder and Git are in the menu bar too (`docs/menu.md` §8).
  - **The bar over the editor** is three buttons: **`+`** (New Note, Today's Note, New Note from a Prompt, Quick Capture, Dictate to Daily Note) · **🔍** (Search Notes — which opens the search field in its place while a search lasts — Open Quickly, Find & Replace in Note) · **⚙** Settings | tabs | Note Actions ⌄ (the note's own commands, Open in New Window among them) · Panel. There is no More menu.
  - **The right panel** is the open note's views (`SidePanel`): Summary & Outline, Tags, Links, Properties, History, Graph.
  - **The bottom bar** is how the note is shown — save status and the four view modes — in the main window. A note window, which has no panel and no command bar, keeps the note's commands there too (`NoteEditorView.commandsInBottomBar`).
  - The collection's tools open in the middle as **tabs** beside the notes (`CollectionTool`, `ToolTabs`); choosing a note puts them behind it. `ShellComplianceTests.eachCommandIsInOnePlace` holds the arrangement.
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
- Editor tests (macOS): `swift test --package-path Packages/NotesEditor` — **three bundles here too**: 318/39, 215/18, 26/4 — 559 tests in 61 suites, 2026-10-12 — and `tail` shows the smallest. A toolchain bump can stop this target *compiling*, which both editor suites share, so both die at once and silently: Xcode 27 made `TableEmbedTests.blankImage` unreachable from the `nonisolated` `BlockRenderer` witness beside it, and 408 + 387 tests had been building nothing for weeks. `error: Build failed` is a failing suite, not a missing one.
- Editor tests (**iOS — run these too**): `cd Packages/NotesEditor && xcodebuild test -scheme NotesEditor-Package -destination 'platform=iOS Simulator,name=HN-iPad'` (~35s, headless, no app launch — 533 tests in 57 suites, verified 2026-10-12). It runs **three bundles** and prints a summary line for each — 292/35, 215/18, 26/4 — so the total is their *sum*; reading only the last one says "26 in 4" and looks like nearly all of the suite silently stopped running. `swift test` only ever builds the package for macOS, so the UIKit half went untested for its whole life — that is how a `UITextView` showing a document it believed was empty, a zero-width keyboard bar and a link tap that ate the caret tap all shipped at once. Create the device once with `xcrun simctl create HN-iPad com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4-8GB com.apple.CoreSimulator.SimRuntime.iOS-27-0` (1.3.3's floor; the iOS 26.5 devices were kept, renamed `HN-iPad-26.5` etc., so `name=HN-iPad` resolves to one device). MLX cannot run in the simulator, and the app says so there.
- **Look at the iOS app without the user's device**: `xcodebuild build -destination 'platform=iOS Simulator,name=HN-iPad'`, then `xcrun simctl install HN-iPad <app>`, `xcrun simctl launch HN-iPad com.hellotham.HelloNotes`, and `xcrun simctl io HN-iPad screenshot out.png` — which is readable. A whole iPad session was shipped blind (a keyboard bar that never rendered, a zero-width one, five inspector toggles that could not work at that width) because nobody looked. `simctl` has no tap injection, so driving the UI still needs the live panel — which needs `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` from the user.
- Is it running on the device? `xcrun devicectl device info processes --device <id> | grep "HelloNotes.app/HelloNotes"` — **capital H**. A lower-cased pattern matches nothing and reads exactly like a crash-on-launch; an hour went into diagnosing a crash that never happened. Cross-check against `--domain-type systemCrashLogs`: no new `.ips` means no crash, whatever the process list appears to say.
- Layout contract: `./scripts/run-tests.sh -only-testing:HelloNotesTests/ShellContractTests` (~2s — run it after any shell or representable change).
- **Window parity**: `./scripts/window-parity.sh` — the whole window: the iPad app in the `HN-iPad` simulator in landscape against the Mac app at exactly its safe area, same settings, same sample collection, captured empty and with a note open, compared pixel by pixel with only the OS's own masked — the traffic lights and the sidebar toggle they displace, the window's corners, iPadOS's resize grabber. It is what found the 28pt strip a hidden Mac title bar still reserves (`contentUnderTitleBar`) and the notes saved in the same second listed in a different order on each (`Note.newestFirst`) — neither visible to the scene renders. **The safe area is measured**: the capture test asks SpringBoard for the status bar's height and the script sizes the Mac's window and cuts the iPad's picture from that. It was 24pt, written down, and the simulator's is 32 now — the gate failed on 3.5% of an empty window that matched until it was (implemented.md §51.43); SpringBoard's number, because one taken from where the app drew would pass an app that began 8pt low. **With a note open the note is reported, not judged**: its text is 17pt on iOS and 16pt on the Mac on purpose (`baseEditorFontSize`), so the verdict there is the chrome's. It quits your running HelloNotes gracefully, launches the Debug build as a capture session with only `DefaultCollection` open (all three lists in the argument domain), reads the window through Accessibility for any other collection's name before each picture (`window-names.swift` — a count, never a name), and afterwards only *reads* your preferences back to check them: an earlier version imported a backup and lost the race with `cfprefsd`, leaving the sample as the only open collection. `PARITY_REUSE_IPAD=1` keeps the last iPad half. Its negative control is in the script's header: one point of padding above the shell on the Mac alone fails both states (1.3% and 4.0% on 2026-10-12). The Mac half needs the screen unlocked: with `loginwindow` in front, a new window stays at 90% of its size and cannot be captured, which reads exactly like a window-sizing bug.
- **Chrome parity**: `./scripts/chrome-parity.sh` — renders the chrome (bar, rows, status bar, panel header, a settings form, a sheet bar, an empty state) on macOS *and* in the `HN-iPad` simulator and compares the two pictures pixel by pixel; anything past antialiasing (Δ>12, or >0.1% of a scene) fails, and a one-pixel shift fails it by 4–7%. Run it after touching `Chrome*.swift` or any shared control. The macOS half is app-hosted, so it goes through `run-tests.sh`.
- **Model evaluations** (Apple's Evaluations framework, real on-device model, ~30s, opt-in — needs Apple Intelligence, so never CI): `TEST_RUNNER_HN_EVALUATIONS=1 ./scripts/run-tests.sh -only-testing:HelloNotesTests/IntelligenceEvaluationTests`. Tags, links, rewrites, long-note summaries and Assistant tool trajectories. Add `TEST_RUNNER_HN_EVAL_MLX_FOLDER=<absolute path>` to run the same suite on an MLX model — a model folder, or a model's `models--org--name` folder in `~/.cache/huggingface/hub` (list what is there with `mlx_lm.manage --scan`; never download one without asking), loaded through the app's own folder path; a `~` would expand inside the test host's container. Two more suites run under the same flags and pick themselves by the model: `AssistantEditEvaluation` (a tool call, an approval, and the note on disk changes — the trajectory suite denies every approval, so nothing else ever writes) and `AssistantWithoutToolsEvaluation` (a model whose template has no tools must answer in words, not imitation calls). Add them with their own `-only-testing:` flags. Run after touching any prompt, schema, tool, `HistoryWindow` or `TokenBudget` — the unit tests prove plumbing and could not see the two defects this suite found in its first hour (below). Read per-sample results with `xcrun xcresulttool export attachments --path <xcresult> --output-path <dir>` (`.xcevalresult` JSON). Two more opt-in probes run inside the signed app: `TEST_RUNNER_HN_RESEARCH_PROBE=1 … -only-testing:HelloNotesTests/ResearchProbe` (a real deep-research run, ~30s, searches the web) and `TEST_RUNNER_HN_PCC_PROBE=1 … -only-testing:HelloNotesTests/PrivateCloudComputeProbe` (one PCC request; does nothing unless the build is entitled).
- **iOS interface tests** — the only check that a screen actually *draws*:
  `xcodebuild test -project HelloNotes.xcodeproj -scheme HelloNotes -destination 'platform=iOS Simulator,name=HN-iPhone' -skipPackagePluginValidation -only-testing:HelloNotesUITests`
  (~4.5 min, 15 cases and the launch test, 2026-10-12 — the run prints
  "Executed 15 tests, with 3 tests skipped"; three skip there: the window-parity capture
  and the store's screenshots unless their own runs ask for them, and the
  iPad's test — headless). **Then the iPad's, which a phone cannot run**:
  the same command with `name=HN-iPad13` and
  `-only-testing:HelloNotesUITests/HelloNotesUITests/testTypingOnAnIPadHeldUpright`
  (~25s). Every other case is the phone's, whose shell is chosen by width
  alone, so nothing here had ever brought a keyboard up on an iPad: a note
  could not be typed in on one held upright, and no test, parity run or
  review said so (implemented.md §51.41). Run both after any change to a
  settings screen, the shell, or the editor's chrome — **and actually run them**:
  `testTheOpenNoteIsNotClippedOffTheScreen` waited for a word count that was
  removed from the status bar on 2 September and failed every run from that day
  to 16 September, because nothing ran this suite in between. A test naming a
  thing the app no longer has fails for a reason that has nothing to do with what
  it tests, and a suite nobody runs says nothing at all.
- App tests (macOS): `./scripts/run-tests.sh` — **never a bare `xcodebuild test`**.
  The bundle is *hosted by the app*, so a raw run opens HelloNotes on the user's
  screen and leaves test hosts behind; the script quits their app first
  (gracefully — it may hold unsaved edits), runs the suite, and kills any host
  afterwards whatever the result. 902 tests in 138 suites, ~35s (2026-10-12).
  **As CI runs it** — unsigned, so unsandboxed, so with a temporary folder that
  has two names: `./scripts/run-tests.sh -only-testing:HelloNotesTests
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=`. Three
  things about that, each learnt the hard way (implemented.md §51.48): **name
  `-only-testing:HelloNotesTests` yourself**, because any extra argument
  replaces the script's own, and without it the interface tests' runner is
  built and launched unsigned and macOS tells the person it "is damaged";
  **run the plain script afterwards**, which signs everything again (that run
  is slow, once); and **an unsandboxed host writes in the real `~/Library`** —
  list `Preferences`, `Application Support`, `Caches` and `WebKit` for
  `com.hellotham.HelloNotes` and `HelloNotes` before and after, and move out
  what appeared. Never `defaults delete com.hellotham.HelloNotes`: from a
  shell that can name the app's *container*.
  Its tests of collection walks keep time, and fail one at a time on a busy
  machine (three runs in four at a load average over 12); run it again before
  believing a failure there, and read *which* test it was.
- **Edit ≡ Preview**: `./scripts/render-parity.sh` — lays the same note out in TextKit and in WebKit, offscreen, and fails if any block drifts more than a point. Three gates in one: a hand-written sample at 5 text sizes × 3 widths, **60 whole documents at 1200 / 800 / 560pt** (plus 420 measured and reported without failing — see the bullet below), and a chrome check that measures the marks themselves. Run it after touching `GFMBoxMetrics`, `StyleApplier`, `BlockBoxes`, `GFMLiveStyle` or `GFMPage`. It is a script, not a test, because a `WKWebView` never finishes loading under `swift test` *or* under XCTest in the app host — both were tried. See implemented.md §23.
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
- **Only a newer rebuild cancels a rebuild — a save never does, and a rebuild
  never undoes a save.** A save patches the link graph and search in place and
  leaves the note's size and date in `notes` alone (restating would re-sort the
  list on every save), so the index cache, keyed on those, still vouches for
  the pre-save record. `Collection.KeptSave` holds what each save and each new
  note patched until a rebuild has read that note from disk since: a rebuild
  reads those notes past the cache and applies the rest over what it read when
  it lands. The guard it replaced cancelled the rebuild in flight — and with it
  whatever that rebuild was for, a delete, a walk's findings, an alias's
  backlinks — with nothing to run it again. A cancel is a promise that
  something newer does the work. And a cancelled rebuild still finishes
  reading, so it must not write the index cache after a newer one has: each
  rebuild is numbered, and `CollectionIndexCache.save(_:for:rebuild:)` refuses
  an older number (implemented.md §51.22).
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
- **The iPhone Duo is two displays and four poses, and the app's chrome fills
  the side its status column takes.** Xcode 27.1's `HN-iPhoneDuo` (iOS 27.1)
  has an outer display of 466×678pt — compact width, so the phone's shell —
  and an inner one of 951×669pt, landscape-native and regular both ways, so
  the columns shell, and the band when turned; the idiom is **phone** on both.
  Built against the 27.1 SDK the app runs edge to edge there with the status
  bar as a *column* down one side — a horizontal safe-area inset, which every
  bar's background stopped at: a white strip under the column on every
  screen, on both displays — and under the bottom bar the home indicator's
  34pt inset was a white band the same way (20pt on an iPad, where the
  parity gate cuts it off and so never saw it). A bar's background fills the
  safe area at the sides and the bottom (`chromeBackground()`, one fill), and
  nothing reads the idiom from `UIDevice` or a scale from `UIScreen.main` —
  the trait collection answers for the view on whichever display it is on.
  **The iOS 27.1 runtime is the Duo's alone**: `simctl create` refuses every
  other phone on it ("Incompatible device"), so a 27.1 defect cannot be told
  from a Duo defect by running another phone on 27.1 — there is none. And
  two `-only-testing:` flags kept in one zsh variable are **one argument**
  (zsh does not split words): xcodebuild selects nothing, prints "Executed 0
  tests" and exits 0, on two phones in a row here; split with `${=T}`, or
  pass them literally. Pose it with `scripts/duo-pose.sh <Closed|
  "Partially Open"|Open|"Rotate Right"|list>`: Device Hub draws its controls
  in SwiftUI, which System Events cannot see, so the script goes through the
  AX API (select the device's row, **Start**, then the pose). A pose change
  backgrounds the app — relaunch it before shooting; a test run on the Duo
  closes Device Hub's window (the app keeps running — `open -a` it with the
  device booted and the window is back), and **quitting Device Hub shuts
  every booted simulator down**, as Simulator.app did. Hardware keys
  (`typeKey`) do not reach the app on the Duo simulator, while typed text
  does: the two arrow-key interface tests skip there on their control
  (`keysArrive`) and pass on `HN-iPhone`. `xcrun simctl io
  HN-iPhoneDuo screenshot --display=primary` is the outer display and
  `--display=primary-1` the inner, which is black while closed (a black
  picture is the pose, not the app). In the book pose (Partially Open) the
  hinge is a 40pt **division** reserved region down the middle of the inner
  display (`UIView.reservedRegions(kind: .division)`, UIKit only in 27.1):
  the editor column straddles it today. The store takes Duo screenshots at
  1398×2034 and 2007×2853 from April 2027 for apps built with the 27.1 SDK.
- **Suggestions write front matter, never the body.** Tags → `tags:`, links →
  `related:`, summaries → `summary:`, via `NoteEdits.appending(_:toListProperty:of:)`
  and `setting(_:property:of:)`. Three YAML rules travel with that: a value
  starting with `[` **must** be quoted (`- [[Note]]` unquoted is a nested
  sequence, not a string, so it does not survive its own round trip); a scalar is
  one line, so a summary is folded; and `MarkdownParsing.tags` reads the `tags:`
  key plus inline tags **in the body only** — scanning front matter for `#` turns
  a summary quoting a hashtag into a tag nobody wrote. And a write rewrites only
  the lines of the keys it changes (`FrontMatter.splicing`, implemented.md
  §51.26): rendering the whole block again turned every flow list into a block
  list and dropped comments whenever any key changed.
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
  changes the user's state. **`collectionPaths` lists local collections only.**
  A cloud collection comes back on launch from `remoteCollectionCaches`
  (`Library.restore()`), so read that key too and capture only if it is empty:
  on 24 September `collectionPaths` said DefaultCollection alone and the
  sidebar in the capture showed a OneDrive collection's folders. The capture
  was deleted; the check is both keys now.
  **A capture session is the other way to take one, and it names all three
  lists** — `collectionBookmarks`, `collectionPaths` and
  `-remoteCollectionCaches "()"` in the argument domain, with
  `-HNCaptureSession YES`: the app then opens the sample alone whatever the
  person has open, and `window-parity.sh` left the third out until 12 October.
  Three more things a launch with the sample replaced, each found by comparing
  preference *key names* before and after, or by looking at what came out:
  the notes donated to Spotlight were retracted and the widget's recent notes
  republished from the sample (both hold back under `CaptureSession` now); the
  window's saved frame became the capture's (the script writes that one key
  back); and **the Assistant opens on the last conversation, which is the
  person's** — one capture held it and was deleted, and the chats folder is
  moved aside for a run now. Before each picture, read the window through
  Accessibility for the names of the person's other collections and their
  folders, printing a count and nothing else; a match takes no picture
  (`assets/screenshots-raw/README.md`).
- **A hosted test's defaults are `ScratchDefaults`, never
  `UserDefaults(suiteName:)`.** The tests run inside the app's sandbox, so a
  named suite is a plist in the person's own `Library/Preferences`, and
  clearing its domain empties the file and keeps it: five kinds of test left
  741 there, one per run. Nor can one be deleted for good — cfprefsd writes
  a domain when it chooses, seconds or minutes later, and a file deleted before
  that write is written again. `@Test(.scratchDefaults)` and
  `ScratchDefaults.suite(label)` name the suite by a path in a folder of the
  test's own in the temporary directory, and delete the folder when the test
  ends; `ScratchDefaultsTests` guards it (implemented.md §51.31).
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
  aimed at it land on the app instead — where `⌘⇧G` is **Graph**, so a
  mistimed "go to folder" silently opens the panel over the user's vault.
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
  its own notes. **And the collection's own `id` is the other name**: canonical,
  so `/var/…` where an iPhone's root is `/private/var/…`, and where a link
  points for a root reached through one. The sidebar names folders by that
  id, and a URL built from it (`URL(fileURLWithPath: folderID)`) is spelled
  the way no walked note is — a note made there had two identities, and its
  rename left the walked one listed (implemented.md §51.56). Anything a
  collection is handed goes through `Collection.ownSpelling(of:)`, and
  "the same file" is `sameFile`, by relative path — never
  `standardizedFileURL`, which answers for a file that has just gone the
  other way round. The Mac and the simulator cannot show any of this; a root
  reached through a symlink can (`SymlinkedRootTests`).
- **`contentsOfDirectory(at:)` refuses a symlink at the end of a path** with
  ENOTDIR; `contentsOfDirectory(atPath:)` follows it. `Collection.unavailability`
  uses the second, so a vault reached through a symlink passed every health check
  and then failed its first listing — healthy, and empty. Resolve for the
  *enumeration* only and keep the collection's own spelling on the URLs you
  store, or you trade one mismatch for another.
- **Order notes with `Note.newestFirst`, never by date alone.** Notes saved
  in the same second (a batch write, a copy, a checkout — the whole sample
  collection) tie, and a date-only sort leaves them in whatever order it was
  handed: a dictionary's, which changes with the hash seed. The Mac and the
  iPad listed the same folder in two orders, and one Mac could on two launches.
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
  they disagree. Apple granted it on 17 October 2026, and both are in the app
  target from build 33. **Apple provisions it for Development, Ad hoc and App
  Store Connect, never Developer ID** — an export of an archive that carries it
  fails ("not available for Developer ID provisioning profiles"), so the DMG is
  archived from the entitlements without it, and on the Mac the flag also reads
  the *signed* entitlement, so that build does not offer the model.
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
- **A note tool's result takes the room the turn has left — querying notes is
  what the Assistant is for** (the person, 2026-10-18: "querying notes in the
  assistant is the only useful functionality at present, so we have to
  optimise for this"). Search, read, exact-text search and the note list
  shaped their results by fixed counts — six results, or ten, whatever the
  window — and said nothing about what they left out. Now each takes its part
  of `TurnRoom`: the history's share of the window less what the turn already
  holds, older turns making way (`HistoryWindow.fit`), the reply's reserve
  kept. **Results asked for in one step share it** — the model may call
  several tools at once, and their results reach the transcript together —
  so each is measured and taken on the main actor with nothing in between, a
  call alone getting all that is left; and a room lives as long as its
  session, so turns are told apart by where they begin (`Held.turnStart`) —
  told apart by size, the next question the shape of the last inherited its
  spent room. A result that cannot fit is said in
  words (`ToolContext.noRoom`), never sent past the window, where the whole
  request fails; what didn't fit is counted ("… and 37 more notes matched").
  **Each of Research's questions has a room of its own**, measured the same
  way (`TurnRoom.held(in:)`, `DeepResearch.researcherTools`): it gave each
  result a fixed share whatever its question had read already, and on the
  on-device model's 8,192 tokens a third page ran the session past its
  window. A web page and a search's results take their own cap and no more
  than is left, reserved before the network is asked (`TurnRoom.reserve`) and
  cut by tokens, never characters; only a tool on its own, in no session's
  room, takes a quarter of the window (`ToolLimits.resultTokens`). **And `TokenBudget.prefix` is the
  longest prefix that fits, cut inside a paragraph if it must** — it was the
  first of `chunks`, which stops before a paragraph too big for one, so a note
  with a long opening paragraph was read as its title and tagged from nothing.
- **The Assistant reads; it changes nothing, in 1.3.5 — the person's
  decision, 2026-10-18, with editing for a later release.** The tools that
  create, edit, write and delete notes are kept and not offered
  (`NoteTools.tools(for:contextTokens:)`), the instructions tell the model to
  give the person text to paste instead, `AssistantEditEvaluation` is
  disabled, and `AssistantReadOnlyTests` fails if a mutating tool comes back.
  It is labelled **experimental** where it opens: a model with an 8K window
  reads a few notes at a time, and is not a full chat assistant — say so
  rather than promise one. The two rules after the next are about those
  tools, for when they return.
- **A conversation is the library's, never a view's — and what it is, it
  keeps.** One `AssistantModel` per collection (`Library.assistant(for:settings:)`),
  shown by any window whose sidebar has that collection. It was its tab's
  `@State`, so a note shown in the tab's place took it down: a turn still
  streaming saved over the transcript of the model made when the tab came
  back, **Use my notes** came back on beside a Cloud (Apple) choice restored
  from disk, and a question from Ask the Assistant was taken by whichever
  window's tab heard it first. A view drawn from the list must observe it:
  read through `@ObservationIgnored`, the tab drew its spinner before its
  task had made the model, and never drew again. Its model, Use my notes and its summary are
  kept beside the transcript (`ChatSessionStore.Conversation`); a model the
  folder no longer lists stays the conversation's and says so — swapped for
  the default, it could be off the device. **The summary of what no longer
  fits is a turn, never instructions**: the model's account of text that
  quotes notes and pages (`HistoryWindow.fit`, read before each request
  through `EarlierSummary`), and only what a summary has read counts as
  covered (`AssistantModel.summaryParts`).
- **Calling the tool is the request for approval — say so, or the on-device
  model asks in words.** Told only that "the person approves every change", it
  replied "Please confirm this is correct" and never called `edit_note` (four of
  four). Once calling, it sends the changed line as `oldText` and that line *with
  its neighbours restated* as `newText`, so `EditReplacement` reads whole lines
  restated on both sides as context (one side is how an insertion looks — left
  as written); rewording the arguments' `@Guide`s did not move it (four in five
  before and after). An evaluation's setup must be
  the app's: `collection.scan()` fills no search index, and the edit evaluation,
  never before run on the on-device model, failed there first because
  `search_notes` truthfully found nothing. Check results whole —
  `contains("apples")` passed a note with a second "- apples" (implemented.md
  §51.36).
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
- **An editor's copy of a note goes back into the model only through
  `EditorModel.adopt(_:fromLoad:)`.** The host builds its document from the
  model's text and pushes it back when editing settles (end of editing, a
  flush, the host going away) on the rule "if they differ, the editor's is
  newer" — wrong for a document built while the note was still loading, which
  holds nothing: if the load lands without it being refreshed, pushing it back
  saves an empty note over a full one. That wiped `Start Here` on 19 September
  (a new 0-byte file, quarantined by HelloNotes, seven seconds after build 22
  launched). `adopt` refuses a copy made from an earlier load;
  `UnloadedNoteTests` holds it, with a negative control.
- **A write the app makes into an open note goes through
  `EditorModel.applyEdit`, never `editor.text = …`.** It carries what is on
  screen first, so the change is made to what the person sees; the host
  follows `textVersion` and, the buffer alone having moved, replaces the
  document — undo reset, and a caret in the body moved *with* the body
  (`DocumentLoad.caret`), because an app write lands in the front matter,
  above it: kept at its offset, the next keystrokes went into the middle of a
  word. Written straight into the buffer, the change never reached the
  document in Edit and the next carry took it away again. Which side wins is
  `DocumentLoad.settle`'s rule — whichever moved since they last matched —
  asked of counts, never of the texts. And bind rows a focused field can
  outlive by identity, never by index: a field hands its text back as it ends
  editing, after its rows may have changed, and `ForEach($properties)` trapped
  on a note switch (implemented.md §51.15).
- **Nothing is written unless something writes it.** A text change schedules
  no save (`EditorModel.scheduleSave` is empty on purpose), so a commit — the
  end of editing in either pane, a property committed in the panel — ends with
  the model's own `save()` (§51.25, §51.30), never a second way to write, and a
  commit that changed nothing writes nothing (`applyEdit` says whether it
  changed the note). Without it the change reached the file at the next flush,
  and a crash before one lost it. Every app write is a commit: `applyEdit` ends
  with the same save (§51.36), so a tag, link or summary accepted, the link
  review, a rewrite, a restored version and a template are written when made.
- **A write the app makes outside the editor must tell the open editors, and an
  approved write must replace only what was approved.** `noteDidSave` registers a
  write as the app's own, so the watcher ignores it — and a tab showing that note
  then saves its stale text over the change. Call
  `Collection.noteChangedOutsideEditor()`. A write computed from an earlier read
  that someone approved goes through `FileIO.replace(_:at:ifContentsEqual:)`:
  clicking Approve in the Assistant's window ends editing in the note's window,
  which saves typing the diff never showed. And never read a note as `?? ""` on
  a path that shows or replaces it — an unreadable note is not an empty one.
- **Anything the app makes, moves or deletes in a cloud collection's cache is
  reported to the mirror, which takes it to the provider in turn.** A cloud
  collection is a cache of a provider's folder, and `RemoteMirror`'s manifest is
  the provider's record, so a file changed in the cache and not reported lives
  on one device: new notes, renames, copies and new folders did, and a rename's
  old name came back at the next sync (implemented.md §51.21). Go through
  `Collection` (`madeHere`, `noteDidSave`, `renameNote`, …), which calls
  `sendSave`/`sendMove`/`sendDelete`/`sendFolder` — and a move or a delete is
  reported *before* the file goes (`willMove`; `sendDelete(of:removing:)`
  removes the file itself), or a walk in the gap puts the old name back: the
  walk runs off the main actor and asks about each file, and writes its
  placeholder, under the lock a change is reported under (`WaitingToGo`),
  so a file gone and not yet reported is one it repairs (implemented.md
  §51.34). The upload gate is `isPlaceholder` — never "the manifest does not say
  it was downloaded", which is every note made here. A record marked `unsent`
  holds something the provider never received: nothing may replace its file —
  not eviction, not a walk, not a download. Changes and walks take turns, in
  order; a walk applies what it found to the record as it stands when it ends,
  and leaves alone what a waiting change will take away.
- **A Swift 6 typecheck is how an isolation mistake shows when Swift 5 mode
  says nothing — and it needs `-continue-building-after-errors`.** Take the
  `builtin-SwiftDriver … swiftc -module-name HelloNotes …` line from a build
  log, drop the output, index and incremental flags, set `-swift-version 6`
  and add `-typecheck`. Without the flag the driver schedules no job after the
  first that fails, and the module has Swift 6 errors of its own (16, in seven
  files, on 2026-10-08), so most files are never checked and the run reads
  clean: a deliberate type error put in RemoteMirror.swift went unreported.
  Before believing a clean result, put a deliberate error in the file under
  review and see it reported (implemented.md §51.34).
- **A `nonisolated async` helper that waits or polls must be `@concurrent`.**
  Under approachable concurrency it inherits the caller's actor, so
  `FileIO.materialise` polled the file provider on the main thread every 200 ms
  for up to a minute, from both the editor and the Assistant. `offMain` catches
  main-actor state in its closure only as a *warning* in this target — and at
  runtime nothing hops: the body is synchronous, so main-actor code it reaches
  runs on the pool thread, unchecked (probed 2026-09-29, implemented.md
  §51.28). A warning there is a data race in waiting, not a stall.
- **Moving work off the main actor adds an `await`, and an `await` lets the
  next event in first.** `Collection.handle` ran each watcher event whole; once
  `.rootChanged` awaited its look at the folder off the main actor, an
  `.unmounted` reported after it was handled during the await and then
  overwritten with the look's `.missing`, and a recheck's `.ready` overwrote an
  unmount the same way (implemented.md §51.32). Events and rechecks now take
  turns (`Collection.inTurn`) — whole, in the order they came — and a turn must
  never await a turn, or it waits for itself. Where no timing can see a quick
  call, a probe of the thread it ran on can (`Collection.availabilityProbes`,
  keyed by path so parallel tests hear only their own).
- **`@Observable` compares on every set, so a note-sized `Equatable` property
  compares the whole note.** The macro's setter asks
  `shouldNotifyObservers(old, new)`, which is `lhs != rhs` for an `Equatable`
  member (see it: `swiftc -typecheck -Xfrontend -dump-macro-expansions`), so
  `editor.text = …` compared the note with itself on the main actor on every
  set — per keystroke in Markdown mode, 41 ms a MB when the new text is an
  editor's bridged `NSString`. A note's text is observed by hand (`access` /
  `withMutation` around an `@ObservationIgnored` store: `EditorModel.text`,
  `LiveBuffer.text`); what nothing watches is `@ObservationIgnored`; and a view
  follows the text by `EditorModel.textVersion`, never `onChange(of:
  editor.text)`, which is one more comparison. Whether a save has anything to
  write is a byte comparison off the main actor (`EditorModel.sameBytes`) —
  `==` is canonical equivalence, and a change of normalisation is a change to
  the file. implemented.md §51.12.
- **A streaming reply must not redraw the conversation per snapshot.** The
  on-device model yields ~40 snapshots a second; redrawing each re-parsed the
  reply's Markdown from line one (15 ms at 30 KB). `AssistantModel` follows at
  most ten times a second with a trailing catch-up (a tool call followed by a
  pause must still appear), and `AnswerMarkdown.Streaming` parses only new lines.
  Anything shown per line of a note — the approval diff — is computed once off
  the main actor and laid out in a `LazyVStack` (a plain `VStack` of 10,000 lines
  took 898 ms).
- **A regular expression on the main actor needs a time limit, and only
  `.reportProgress` can impose one.** The find bar searches on every keystroke,
  on the main actor, and `(a*)*b` over 28 `a`s ran past five seconds with
  nothing able to stop it — `NSRegularExpression` has no timeout. Enumerating
  with `.reportProgress` calls the block *during* the backtracking (1,511 times
  in 0.2 s, probed), so a deadline can set `stop`: `FindPattern` gives a search
  half a second, and the bar says **Too slow** (implemented.md §51.39). Anything
  else that runs a pattern someone typed needs the same.
- **The Hugging Face cache is reached by *asking the person*, never by
  entitlement — App Review refused that in writing.** A sandboxed Mac app
  cannot read `~/.cache/huggingface`, where `mlx_lm` and every other MLX tool
  keeps its models, so 1.3.3 shipped
  `com.apple.security.temporary-exception.files.home-relative-path.read-write`
  for `/.cache/huggingface/` to make the models on the machine simply appear.
  **TestFlight rejected builds 23 and 24 for it** — guideline 2.4.5(i), *"not
  appropriate and will not be granted"* — which is a refusal, not a request for
  justification, so reviewer notes cannot rescue it and a read-only variant is
  the same kind of request. Do not re-add it in any form. What replaces it is
  the sandbox's own route, made short: **Access MLX Models…** opens a folder
  panel already pointed at `~/.cache/huggingface/hub`
  (`fileDialogDefaultDirectory`, which runs outside the sandbox and so can show
  a folder the app cannot yet read), one click on **Allow** grants it (the
  panel's button reads Allow and its message says not to pick a model — it
  read Open, and looked like a request to open one), and the
  security-scoped bookmark keeps it. Until then `MLXModelStore.ownStorage` is
  `HubCache.default.cacheDirectory`, which is already container-aware, and
  `usesOwnStorage` is what the button reads.
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
- **The Mac and the iPad are the same pixels, so the app draws its own
  chrome — never the platform's.** A system control, container, text style or
  colour is each OS's drawing at each OS's numbers: `.font(.body)` is 13pt on
  the Mac and 17pt on iOS, a `Toggle` 36×16 and 51×31, a `Form` row 36pt and
  44pt, `.secondary` and `Color.orange` different values, `.borderless` grey
  and accent-tinted, and a `List`, `NavigationStack` bar, `.toolbar`,
  `TabView` or material different pictures outright. Use the tokens in
  `UI/Shell/Chrome.swift` (`Chrome.Typeface`/`Chrome.Style` — the Mac's sizes;
  `Chrome.Colour` — AppKit's values, both appearances) and the controls in
  `ChromeControls.swift`/`ChromeRows.swift`: `ChromePushStyle`/
  `ChromeBorderlessStyle`/`ChromeLinkStyle`, the switch and checkbox styles,
  `ChromePopUp`, `ChromeSegmented`, `ChromeSlider`, `ChromeStepper`,
  `ChromeTextField` (placeholders are drawn by the app), `ChromeForm` +
  `ChromeSection`, `ChromeSheetBar` + `chromeSheetFrame`, `ChromeEmptyState`,
  `ChromeDivider`, `ChromeRowFrame`. `chromeDefaults()` in `ThemedRoot` makes
  them the defaults at every window root — so **an unstyled `Button` is a push
  button**, and a row, card or glyph needs `ChromePlainStyle`. What stays the
  OS's: its window controls (`WindowControls.leadingInset`), and a menu,
  popover or alert once *open*; the button that opens one is ours. Inside menu
  content `Divider()` is the menu's separator — never `ChromeDivider`.
- **Fixed numbers were not enough; three platform differences survive them,
  each measured by `scripts/chrome-parity.sh`.** macOS font smoothing puts
  12–19% more ink on every glyph (`Chrome.matchTextRendering()` registers
  `AppleFontSmoothing = 0` for the app only). A line box is rounded per
  platform — 11pt is 14.0 on the Mac and 13.5 on iOS, 17pt 20.0 and 20.5 — so
  paragraphs drift half a point a line; `.lineHeight(.leading(increase: 3))`
  at the root makes every line its size + 3 — whole points, so there is
  nothing to round (`ChromeParityTests.everyLineIsItsSizePlusThree`; a
  `.multiple(factor: 16/13)` rule agreed only where 16/13 happened to land on
  a whole point). Stack spacing is the same trap: a stack that names none gets
  a gap each platform computes from its own rounding of the font — 9pt against
  8.5 for 13pt text over a button — so every vertical stack names its spacing
  (`everyVerticalStackNamesItsSpacing`), including the implicit one a
  `ScrollView` with several children makes.
  And even at 13pt, where the totals agree, macOS puts the baseline half a
  point lower, so a single line centred in a control sat a pixel low:
  `ChromeLine` centres on the capitals and fixes its own box. Chrome text is
  not scaled through text styles any more: `ChromeTextScale` applies one
  factor from one table, driven by the app's Text Size on **both** platforms
  (it syncs between devices, and the iPad used to ignore it) with iOS's own
  Larger Text on top — exactly 1.0 at the defaults.
- **A view nothing shows is deleted in the change that stops showing it.**
  `TagTreeRow` lost its last caller when the tag tree was replaced (11 Aug),
  `RemoteBrowserView` when browsing became the folder picker (late Aug), and a
  `ChromeBackButton` was written for sheets that turned out not to need one —
  all three kept compiling with no caller, and the chrome sweep converted one
  of them line by line without being able to tell it was invisible. Before
  converting or fixing a view, grep for its callers; after replacing one,
  delete the old one. A file with no route to the screen is not a feature
  kept in reserve, it is a question someone has to ask.
- **Every panel drags to resize, and the width is the person's.**
  `shell-chrome.md` D7 promised a draggable splitter from the day the inspector
  was designed and the code never had one, so every panel was whatever number
  the shell had written down — 280pt of inspector beside a graph that wanted
  760. `ResizableDivider` stores the width and **clamps it at use**: drag it
  wide, narrow the window, and the width is borrowed back rather than
  forgotten. A 1pt line is not a target; the grab area is 10pt and the pointer
  changes over it. **Measure a drag where nothing moves** — `.global`, or the
  container's named coordinate space — never in a `DragGesture`'s default
  `.local`, which is the rule's own and moves with the drag: every rule in the
  app followed the pointer at half speed until §51.29. A test of one must turn
  the run loop between its mouse events (`MouseDrag`, RuleDragTests.swift);
  sent back to back, nothing is laid out until the button is up, and the
  half-speed rule passes.
- **A view whose arrangement follows its size changes its *layout*, never its
  branch.** Two branches of an `if` are two sets of views, so crossing between
  them makes every child again — a text view with the keyboard and the caret
  among them. And the keyboard is a size change: Split on an iPad in portrait
  flipped to side by side when it came up, made the source's text view again
  without it, and so sent it away (§51.29). `AnyLayout` changes the layout and
  keeps the children (`AdaptiveSplit`).
- **The right panel is the open note's; the collection's tools are tabs.**
  Summary & Outline, Tags, Links, Properties, History and Graph are views of the
  one panel (`SidePanel`), with one state, one width and one header that picks
  what it shows, the same way on both platforms. The Mind Map, the Assistant and
  Ask Your Library were views of it too — nine, "not two kinds of thing" — and
  that is how a map of one note's ideas came to be called the Mind Map while the
  collection's links were the Graph: the panel did not say what it was about,
  so neither did its views. **The Graph is one note's links in and out; the
  Mind Map is the links across the collection, drawn as a mind map**
  (`CollectionMindMap`), and it and the Assistant open from the sidebar as
  tabs (Ask Your Library, the third, became part of the Assistant in 1.3.5). The panel is a **column** wherever the editor keeps its
  floor beside it (`ShellMetrics.hasPanelColumn`) — *an editor never blocks
  editing*, so it is never a modal over the note — and only a phone, with no
  room for a column, carries it over the note.
- **The window root's line height reaches text drawn into a `Canvas`, and there
  `draw(_:at:)` ignores the point.** `chromeDefaults()` makes every line its
  size plus three (`.lineHeight(Chrome.lineHeight)`); a `GraphicsContext` text
  draw under it lands at the canvas's origin, so every Graph label was drawn in
  one pile in the corner on both platforms, and no orb had a name. A canvas
  that draws text takes the default back with `.lineHeight(nil)`. A render
  without the root's defaults draws correctly, so a check of it must apply
  `chromeDefaults()` — the first probe left them out and saw nothing wrong
  (`GraphLabelTests`, with a negative control).
- **A threshold on a pixel is a fact about the display, and CI's draws at
  one pixel a point.** `GraphLabelTests` found the labels as near-black pixels.
  At two pixels a point a label's strokes fill pixels; at one they fill none,
  so the runner drew the graph and failed "no labels at all" — put down to a
  slow layout, then to a window never shown, with a change made for each.
  Read ink against the picture (grey, and about as dark as its darkest
  grey), read the picture at half size here as well as at full, and **make a
  picture test that fails count what it did see**: "2,621 pixels of anything"
  was the whole diagnosis, against 2,735 in this Mac's picture halved
  (implemented.md §51.49).
- **A keyboard covers part of a scene; it does not make the scene shorter.**
  The shell is the band when the scene is taller than wide and the columns
  when it is not, and it went by the height the scene was *offered* — which a
  keyboard takes from: 1032×1324 became 1032×941 on the 13-inch iPad in
  portrait. So the keyboard coming up changed the shell; those are two
  branches, every view was made again, the text view that asked for the
  keyboard was gone, the keyboard with it, and the scene was tall again. A note
  could not be typed in, and the Assistant, which takes the keyboard as it
  appears, went round for good: the whole main thread, 1.8 GB in two minutes.
  The shell goes by the scene's height to its bottom edge now
  (`shellKind(width:offeredHeight:bottomInset:)`): what the keyboard takes from
  the one it gives to the other. `ShellKeyboardTests` holds it on the Mac — a
  keyboard is a bottom safe-area inset, and `safeAreaPadding` is one — and
  `testTypingOnAnIPadHeldUpright` on the device. The same rule as the one about
  a view whose arrangement follows its size, one level up: the shell itself was
  the largest view that did.
- **A launch argument with no value goes last, or is given one.** Every `-key`
  is paired with the token after it, whatever that is. `-HNHideTips` ahead of
  `-editorViewMode edit` took `-editorViewMode` as its value and pinned
  nothing, on either platform, silently. On the Mac the word left over
  (`edit`, `YES`) is a file to open, and an app launched to open a file shows
  **no window of its own** — which read, for an hour, as the app launching
  without one. `-HNHideTips YES` was as good — the app only asked whether the
  argument was there — and the flag went with the tips in 1.3.5.
- **A script that presses a button fails when the button is not there, and a
  test does not skip on the symptom of what it is for.** The store-screenshot
  test's `tap` returned quietly when it found nothing, and the run passed with
  seven pictures of one screen. The iPad typing test skipped when no keyboard
  was showing, to allow for a simulator with a hardware keyboard connected —
  and a keyboard that has come up and gone away again is not showing either,
  so on the defect itself it skipped, and `xcodebuild` printed `TEST
  SUCCEEDED`. Both were found by the negative control and not before it. A
  skip is neither a pass nor a failure; read the count of them.
- **A name given to a row that is not a group is given to everything in it.**
  `ChromeSegmented` names each segment, and the editor then named the *control*
  "View mode" — which SwiftUI hands to every element of a container that is
  not an accessibility element itself, over the element's own. VoiceOver read
  "View mode" four times, and nothing could ask for Preview by name. The
  control is a group of its own now (`.accessibilityElement(children:
  .contain)`), so a name given to it names the group;
  `testEachViewModeSaysWhichItIs`.
- **A link opens in the window that is open.** On the Mac a `WindowGroup`
  answers an external event — a `hellonotes://` link, so every tap on the
  widget — by making a new window unless an open one says it would rather
  take it. None did: three links, four main windows, the note opened in all
  of them (counted through Accessibility). `takingLinksWhereOpen()` says so
  for the main window; with none open one is still made.
- **A link that launches the app arrives before the library does.** It is
  handed to the router as soon as there is a window, and the window's first
  work is bringing back what was open — so resolved at once it named nothing
  and was dropped: the app came up and the note did not, and a tap on the
  widget with the app closed did what a tap on the icon does. The router
  *holds* what it cannot resolve until `Library.launchDidSettle()`, then tries
  it once (`NavigationRouter.hold`). Held, never awaited: `route` still
  answers for now, or an intent with no window would wait on a launch that
  never comes. Anything else that acts on the library from outside the window
  at launch meets the same empty library. `LinkAtLaunchTests` stage the launch
  in a `Library(defaults:)` of their own — a hosted test's plain `Library()`
  that opens a folder writes it into the person's list of open collections.
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
  places. Settings is one container on both (`AppSettingsView`: a strip of five
  tabs over the page, 560×640) — the Mac's `Settings` window and the iPad's
  sheet show the same view — and the page is stored (`SettingsPage.storageKey`),
  because the Mac's `openSettings` takes no argument; a sheet route may also pass
  it. The Assistant presents Settings itself — on iOS it is already presented,
  and the shell cannot present over it, which is why its old "Open AI
  Settings…" did nothing on iPad. ⌘, opens Settings on iPad too.
- **A model is named by where it runs, then whose it is: Local (Apple), Cloud
  (Apple), Local (*an MLX model's name*)** (`LanguageModels.name(of:)`, the
  person's decision, 2026-10-18). "System" and "Private Cloud Compute" side by
  side read as two system models, which both are — the difference a person
  needs is where the text goes. Never the variant, AFM 3 Core or Core
  Advanced: that is the hardware's decision, and naming it made people ask for
  the other. Each answer and suggestion carries the name of the model that
  made it (`ModelStamp`), recorded by the work itself
  (`IntelligenceService.stamped`, `DeepResearch.onModel`, the Assistant's
  turn) — a stamp taken before the work named Cloud (Apple) for a request
  Local (Apple) answered after a refusal.
- **The one fallback goes towards the device.** Cloud (Apple) has a daily
  allowance; once it is spent a request runs on Local (Apple) instead
  (`LanguageModels.serving`, asked of `quotaUsage` each time, never
  remembered), and the request that finds it spent before the framework says
  so is asked again there, once (`fallback(after:on:)`). Nothing ever falls
  back *to* the cloud, no other failure is retried on another model, and the
  person is told in a line, with nothing to press — a **Request More** button
  was added for the framework's limit-increase sheet without being asked for,
  and taken out (2026-10-18). `quotaUsage` is a cached local value — 1,000
  reads in 47 µs, probed — and a process without the entitlement reads it
  without harm ("not reached", no reset date), so a view may ask it on every
  redraw; it is only a *request* without the entitlement that crashes.
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
- **New Note goes where you are looking, and every vault mutation is
  coordinated.** Two defects from one iPad report. `newNote()` called
  `createNote()` with no folder, so on the tall shell — whose left pane *is* a
  folder picker and whose right pane lists that folder — a note made with a
  folder selected landed at the collection root, outside the only list on
  screen; it reads as "nothing happened", and the name you then type is a
  rename of a file you cannot see. It passes `bandContainerID` now, the same
  identifier the folder row's own **New Note Here** uses, expanding the folder
  first (`ShellActions.expand`) so the note is not created into a closed one
  — and that identifier is the collection's canonical `id`, which on an iPhone
  is the folder's *other* name, so the collection respells it
  (`ownSpelling`; the rule above, and §51.56).
  Separately, **rename, duplicate and move called `FileManager` directly** —
  the one place vault I/O escaped `FileIO`. In the app's container that works,
  which is why the simulator could not reproduce a failing rename; on a File
  Provider folder an uncoordinated move races the provider, which can put the
  old name back. `FileIO.move`/`FileIO.copy` coordinate and announce the move
  (`item(at:willMoveTo:)`), and all three run through `offMain`.
- **A modifier that configures a presenter wraps it — it never sits inside.**
  `fileDialogDefaultDirectory`, `fileDialogMessage` and their siblings set
  values the `fileImporter` reads from *its own* environment, and an
  environment flows inward. Build 25 put the directory on the `Form` and
  attached the importer outside it, so **Access MLX Models…** opened wherever
  the app's last panel had been — an Obsidian vault — and the build passed
  review, every test, and a read of the code. Apple's docs say the modifier
  "configures the fileImporter" and nothing about which side. Settled by a
  probe (`NSOpenPanel.directoryURL`, read in-process, both orderings,
  off-screen): inside → `~/Documents`, outside → `~/.cache/huggingface/hub`.
  `ShellComplianceTests.folderPanelConfigurationWrapsTheImporter` guards it.
- **A control in a bar carries a title, not just a picture.** When the bar runs
  out of room the system folds its items into an overflow menu and titles each
  row from the item's **label**, so `Image(systemName:)` as a label leaves a bare
  glyph with a disclosure arrow and no name. On an iPad mini in portrait with the
  band and the right panel both open — the worst case the shell has — the note
  menu drew exactly that, next to a row that read "Panel" because it uses a
  `Label`. `.accessibilityLabel` does not rescue it: VoiceOver reads it and
  nobody sees it. `ShellComplianceTests.barControlsAreLabelledNotJustDrawn`
  allows one image-only label, the search field's clear button, and is meant to
  stay one.
- **A menu from a toolbar mid-screen is capped — about 520pt on a portrait
  iPad — and scrolls.** Settings came last in the iPad's `…` menu and fell below
  the fold of the menu added to make it findable. Order for the fold.
- **The simulator tool's taps arrive as a mouse.** After the first one
  `PointerPresence` reports a pointer, and what reads it — the graph's "Tap" or
  "Click" — says the pointer's word until the next launch. Row heights are
  fixed and do not follow it (implemented.md §51.36).
- **One model, and the framework's knobs — no roles, no inventions.** There was
  a model for the Assistant and another for the writing tools; with MLX they
  could not even differ, since the store ran one MLX model, so picking one
  silently moved the other. `IntelligenceSettings.model` is the single choice
  — the **default**, since 2026-10-18: the Assistant's menu can choose another
  for one conversation (`AssistantModel.conversationChoice`; New conversation
  goes back to the default), and the writing tools use the default. What is tunable is exactly
  what `GenerationOptions` and `ContextOptions` expose — temperature (0–2),
  `samplingMode` (greedy, top-k, top-p, each with a seed), `maximumResponseTokens`
  and `reasoningLevel` — applied to the Assistant's profile. A control the model
  never sees is worse than no control, and a knob the framework has and the app
  hides is a question someone has to ask.
- **The control named *Default model* lists every model you could be running.** The
  picker offered Apple's model and one entry for MLX, because only one MLX model
  loads at a time — a fact about *loading* used to justify a fact about
  *choosing*. So "which of my models" became a second decision, in another
  section, behind a **Use** button; with the remembered model no longer in the
  cache the entry even read "MLX · MLX", and a folder of four ran none of them.
  `ModelOption.mlx(id)` is one entry per model in the folder, and `choose` sets
  the model *and* the switch to it. Two traps this opens, both hit on the way:
  `isAvailable` must ask about **that** model, or the store's "no model chosen"
  disables every entry and nothing can ever be picked; and a tick meaning "in
  use" must read `model == .mlx && chosenID == id`, or it claims a model is in
  use while the app answers on Local (Apple). **And the Assistant's menu
  repeated the mistake** — one MLX entry, because one model "loads at a time"
  — until the person found one model where they had several, and said the
  rest: "You are assuming the user does not have space to load multiple
  models simultaneously. This is incorrect" (2026-10-18). It lists
  `LanguageModels.options`, and a conversation runs the entry it chose
  (`ModelOption`, `languageModel(for:)`) beside the default's, untouched.
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
- **Room to scroll past the end of a note is part of the document — never a
  limit some way of scrolling has to ask about.** Build 28 moved it into the Mac
  clip view's `constrainBoundsRect`. A wheel honours that, so every test passed;
  a trackpad stopped at the last line, and that line, at the bottom edge, was
  drawn cut through its middle where the text view's frame ended under it. Before
  that it was a scroll-view content inset, which every scroll-to-visible counts
  as *covered*. It is now the bottom of the text container's inset, the origin
  pinned at the top (`TextPlacement`), on both platforms and in Markdown mode
  too. A trackpad gesture cannot be driven from a test — synthesised phased
  events scroll nothing, even sent through an ordered-in window — so the tests
  assert the room where every scroll finds it: the text view's own frame,
  half a viewport below the last line (`ScrollPastEndTests`,
  `EditorScrollingTests`, implemented.md §51.40).
- **The text column is a rule each scrolling view applies at its own width,
  never a frame around the view.** `MeasuredText` framed the editor to the
  column — so its scroller sat at the column's edge, and with the defaults 32pt
  short of the pane, because the shell took 16pt off each side that the text
  views inset by themselves. It publishes `TextColumn` now; the editors put it
  in their container inset (`TextPlacement`), Preview in its page's margins,
  the inline title through `TextColumnLayout`. On the Mac that means an
  overridden `textContainerOrigin` — probed under TextKit 2 before relying on
  it: ink and hit-testing both move with it. Anything that offsets by
  `textContainerInset` as if it were the origin is now wrong; use
  `textContainerOrigin`.
- **A synchronous test that pumps the run loop never runs a main-actor task.**
  `RunLoop.run(until:)` inside a test that is itself a main-actor job cannot
  drain the main queue, so `Task { @MainActor in … }` work — the overlay
  refresh, the background styling pass — simply never happens, and the test
  measures an editor nobody uses. The first probe of the heading flicker saw
  nothing wrong for exactly that reason. Make the test `async` and alternate a
  short run-loop turn with `await Task.sleep` (`HeadingTypingTests.pump`).
- **And a test that awaits gives the run loop the last turn.** A main-actor
  task runs in the await, and what it changed is laid out by the run loop,
  before anything is drawn. Restyle a paragraph break and TextKit makes the
  paragraph after it a new fragment — frame zero, state `.none` — until the
  view's layout pass; `HeadingTypingTests` read between the two on CI's
  runner, and reported a paragraph "moved" by exactly the scroll offset. Its
  wait ended on a sleep, by a deadline. End a pump on a turn of the run loop,
  count its looks (`Waits.Pump` in the app's tests: its seconds, and no
  fewer than twenty looks), and take a fragment's place only when its `state` is
  `.layoutAvailable` — no place, with the run loop turned, is a failure of its
  own: the blank frames of build 28 (implemented.md §51.49).
- **A hosted test's `AppearanceSettings()` is the person's own.** It reads
  their preferences and *writes them on every set*, so a test may read a width
  or a size to work out what to expect and must never assign one. Test the
  rule below the settings instead (`TextColumnTests` sets the column on the
  view).
- **A key command in an iOS text view asks for priority, or it is listed and
  never called.** Since iOS 15 a text view's own handling of its keys — the
  arrows, Return — comes before a `UIKeyCommand` that does not set
  `wantsPriorityOverSystemBehavior`. ↑ off the first line of a note never
  reached its title on iPhone or iPad, from the day the inline title shipped,
  with a unit test that read `keyCommands` and found the command there. Offer
  a command only while it applies and it is safe to ask for priority; and
  **Return and Tab reach the text view as typed text**, through
  `shouldChangeTextIn`, past a key command offering to take them. Only a
  pressed key shows any of this: `XCUIElement.typeKey` for the arrows,
  `typeText("\n")` for Return (`typeKey` with Return types nothing into a text
  view). Reading `keyCommands` is the source-symmetry check again
  (implemented.md §51.44).
- **A key the editor gives away, it asks about first.** The list of
  suggestions by the caret is the host's and the keys are the text view's,
  which stays first responder. `CompletionKeyHandler.wants` must cost nothing
  and change nothing — UIKit asks it for every command it considers, and the
  host ranked every title in the collection to answer "how many rows"
  (`CompletionMemo`). Nothing is chosen until an arrow chooses it, so Return
  with the list open is still Return; and the arrows are the list's only while
  the construct is being typed, because the list also shows for a caret
  passing through a link that is already there (`CompletionChoice`).
- **`repo.add(path:)` cannot stage a deletion; `repo.add(paths:)` can.** The
  first is libgit2's `add_bypath`, which fails on a file that is gone, and
  `commitAll` called it behind a `try?`: a deleted note was never committed,
  by Commit or by Auto-commit, and with nothing else pending Commit failed
  with an empty error. The second is `add_all`. A commit also writes the whole
  index, so one that names its files (`GitService.commit(_:message:)`) refuses
  when another tool has something staged.
- **`standardizedFileURL` drops `/private` only from a path that exists.** A
  folder that is there and a file just deleted from it come out spelled two
  ways (`/var/folders/…` and `/private/var/folders/…`, probed), so "is this
  file inside that root" answers no — and the commit of a deletion would have
  been skipped without a word on an iPhone, whose containers are
  `/private/var/…`. This sharpens the "one directory, two names" rule above:
  the two spellings can come from *one* call. Ask through
  `CollectionIndexCache.rootPrefixes`. The test host's own folders have no
  `/private` twin, so a test there cannot see it; spell the paths by hand.
- **A commit nobody pressed Commit for obeys one rule**
  (`GitService.allowsUnattendedCommits`): never in a cloud-backed collection,
  never in a collection that is one folder of a larger repository. Auto-commit
  had both guards and the Assistant's commit had neither, and took every
  pending change in the collection with it. It commits its own note now,
  whatever Auto-commit's switch says — the person approved that change, and a
  commit of its own is how it is taken back.
- **What a line says about privacy is true of the feature it is printed on,
  not of a part of it.** "Runs on this device. Your notes never leave it." was
  true of the model and printed on an Assistant that searches the web with
  terms the model writes after reading notes. The model's line is about the
  model; what a search sends is `LanguageModels.webSummary`, shown wherever the
  web tools are; `PrivacyLineTests` fails the day a tool set gains or loses the
  web without the sentence changing.
- **An append is a write into a note, and today's note is the one that is
  open.** `Collection.append` — Quick Capture, dictation, the daily-note
  intent — wrote the file and called `noteDidSave`, which marks the write as
  the app's own so the watcher tells nobody: the tab kept its text, and with
  typing not yet saved the person was asked to choose between what they had
  typed and what they had captured. It is made in the editor that holds the
  note (`applyEdit`), and otherwise over the text it read and no other
  (`FileIO.replace(_:at:ifContentsEqual:)`) with the editors told — the rule
  above about writes outside the editor, which this path was older than. And
  **a thing that clears what was typed as it sends must be able to give it
  back**: Quick Capture answered "Added to today's note." for any failure but
  a missing collection (`NavigationRouter.dailyNote`, implemented.md §51.45).
  Two traps on the way: **an editor can be loaded over a placeholder** (a
  refresh that finds the provider's copy changed marks the note not
  downloaded and leaves the bytes), so the editor is asked only when the file
  is not one; and `applyEdit`'s save is one nobody waits for, so anything that
  answers "done" awaits `editor.save()` first.
- **A cleanup removes what was made, not what has the name.** A failed New
  Collection ▸ Git Repository… removed the folder it was making — and so a
  *file* of that name, which is why making it had failed, and an empty folder
  the person had made. Record what was there before, and take away only the
  rest (`GitService.createRepository`, `NewRepositoryTests`).
- **A deadline is kept by a clock that nothing it waits for can hold up.**
  `FileIO.materialise` gave a download a minute and checked the minute
  between synchronous calls to the file provider: one that never returned
  held the "Downloading … from the cloud" banner up for good on an iPad. Its
  first fix was measured wrong in review: the timer sat on GCD's shared,
  capped pool with the calls it was outlasting. So — ask a file provider on
  **lanes** (a file always on one of sixteen serial queues: a silent provider
  holds a lane a file, never the pool), schedule the next question rather
  than sleep for it, keep the deadline on a **serial queue of its own**, read
  one monotonic deadline, and say which way it ended (`FileIO.waitForDownload`,
  `finishes(within:)`). A test's stand-in provider brings lanes of its own —
  held silent on the app's, it held up whichever test's note hashed to the
  same lane (implemented.md §51.51, §51.52). **And a question about *now* is
  asked of a URL with no memory**: `URL.resourceValues` answers from a cache
  on the URL that only the main run loop clears, and a lane has none, so the
  wait read its first "not downloaded" back for the whole minute, and the
  walk's answer rode the note's URL into the editor and Try Again — "takes
  forever" on the iPad through two "fixes" (§51.56). Read through
  `FileIO.currentResourceValues(at:keys:)`.
- **A process is what it executes, not what its command line mentions.**
  `pgrep -f` on the bundle path matches every process whose command line
  *names* it — a shell running a command that mentions the app, an editor,
  `sample` — and six places found the app that way, three of them choosing
  what to `kill -9` or `pkill`: `run-tests.sh` took the shell that had started
  it for the running app and refused, twice. Ask
  `scripts/hellonotes-processes.sh` (`app`, `hosts`, `all`, `at <path>`): the
  executed file's name *and* the started path's bundle layout, and a host by
  its own arguments. Two more traps it met: `pgrep -f -NSTreat…` reads the
  pattern as options and prints nothing, so a check built on it can never
  fail (the preflight's never did); and in zsh a variable named `path` is
  `$PATH` (implemented.md §51.50).
- **A CI step that can wait for ever is bounded, and looked at before it is
  stopped.** The macOS test job on `main` started 775 tests, finished none and
  ran into its ninety minutes; GitHub called it *cancelled*, which read as
  someone having stopped it, and nothing was kept. `scripts/ci-bounded.sh`
  follows the output and, after five silent minutes, samples the test host,
  pictures the runner's screen, counts what started and finished, keeps it all
  as an artifact and fails. A job's status is not its cause: read which step,
  and how long it ran. The runner tests an **unsigned, unsandboxed** build —
  not what `run-tests.sh` runs here — so a failure there may be one this Mac
  cannot have (implemented.md §51.46).
- **Every lister respells to the collection's own name for its folder —
  and `resolvingSymlinksInPath` will not tell you when it must.** `/var` is
  `/private/var`, Foundation answers `/var/…` for either, and a listing of
  `/var/…` comes back as `/private/var/…`: so "rewrite only if the path went
  through a link" never fired, and a collection rooted there held scanned
  notes under one name and made, moved and renamed ones under the other. A
  note's identity is its URL — a tab on a note that had not moved closed when
  another did. Decide from the **listing**: does the first entry's folder
  spell as the folder that was asked for (`LocalTreeSource.cameBackUnderAnotherName`,
  `Collection.listedRootLength`)? An iPhone's containers have both names and
  the simulator's do not; **only CI's unsandboxed test host showed this**, in
  failures first read as slowness. Read a failing test's own message before
  naming its cause: five of eight said `/var` and `/private/var` in so many
  words (implemented.md §51.48).
- **A wait counts looks, not seconds.** `let deadline = ContinuousClock.now +
  .seconds(5)` runs out while *another test* has the main actor, and the wait
  comes back from its first sleep already spent, with the work it waited for
  queued behind it. `Waits.Patience` and the `eventually` helpers give a wait
  as many looks as its seconds hold sleeps (`HelloNotesTests/Waits.swift`).
  And a thing held open for a test is held until the test lets it go — never
  for a time the test hopes to fit inside.
- **A test never blocks a thread of the concurrency pool waiting for other
  work.** A Swift Testing test runs on the pool, which has one thread a core.
  Three `TokenCacheTests` each sat in `DispatchSemaphore.wait()` for a block
  handed to a global queue: three of sixteen threads here, and **all three** on
  CI's runner, where 824 tests then never began and the job ran into its
  limit twice. Run the held work on a thread of its own
  (`Thread.detachNewThread`) and *await* the wait (`TokenCacheTests.wait(for:)`).
  The nearest thing here to the runner is
  `TEST_RUNNER_LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 ./scripts/run-tests.sh` —
  a one-thread pool; it does not reproduce that stall, and it does fail the
  tests that assume a roomy machine. And the lesson of how it was found: two
  plausible causes had been written down (a locked screen, an unsigned build)
  and one five-second `sample` of the stalled process made both unnecessary
  (implemented.md §51.47).
- **A locked screen takes the keychain with it.** With the Mac locked,
  `notarytool` says "No Keychain password item found for profile" and
  `xcodebuild -exportArchive` says "Failed to Use Accounts" — the same words
  as a profile that was never stored and a sign-in that has lapsed. Check
  `ioreg -n Root -d1 -a | grep -A1 IOConsoleLocked` before believing either.
  (The upload with the team's API key, and the hosted test suite, are
  unaffected.) A sign-in that *has* lapsed says the same thing unlocked, and
  only the person can renew it: Xcode ▸ Settings ▸ Accounts. **And an
  `xcodebuild` that wants the account while the screen is locked can lose it
  for good** — seen on 2026-10-17: profiles made at 15:13–15:30, the screen
  locked, a build at 15:35 said "Invalid credentials in keychain …, missing
  Xcode-Username", and from then on, unlocked, "No Accounts": Xcode's stored
  list held none (`DVTDeveloperAccountManagerAppleIDLists`, counted, never
  printed) and its keychain items were gone, while the running Xcode could
  still look signed in. Check the lock *before* an `-allowProvisioningUpdates`
  run, not after.
- **A test that sleeps "past" a timer is racing it.** The walk test slept
  900 ms to get past a 750 ms reveal — but the reveal's clock starts when its
  task first has the main actor, and with the whole suite's work queued there
  it started late in 2 runs of 40. Wait for the condition. And a test double
  that counts is shared state: `listCalls += 1` under six listings at once
  lost a count in 12 walks of 2,000, and the test it served failed one run in
  three. When a test fails once in a while, **count what failed**: this one
  recorded one issue where a real cancellation records three, which said the
  walk had not been cancelled before any code was read.
- **A test asks what happened — never how long it took, and never whether
  it is over by now.** `#expect(elapsed < .seconds(5))` after a cancel failed
  on CI's runner with the cancel honoured at once: the five seconds were the
  rest of the suite's. And "its catch-up done", as a sleep of 100ms, was a
  read still on its way that then landed after the test had moved on. Have
  the double say what was done to it (`SlowRoot.finished`), and have the app
  say what is under way (`EditorModel.reconcilesInFlight`,
  `Collection.savesBeingIndexed`) — then wait for *that*, after one sleep so
  a task made a moment ago has started. Run `-only-testing:` on a **suite**:
  named down to a function, xcodebuild "Executed 0 tests" and exits 0, and a
  control that ran nothing reads as a control that passed (implemented.md
  §51.49).
- **A test of a tool that deletes must answer the question.** A deletion is
  asked about every time, whatever "Allow all" was given, so a test that calls
  `deleteNote` with an approving broker waits for ever — and a hosted run that
  waits for ever looks like a hang in the app.
- Docs describe the UI from source, not memory — verify shortcuts/menus with the `docs-fact-checker` agent (a draft once shipped two invented shortcuts). **Read its reverse column too: a doc fact-check is also a source check.** Checking the AI page after the two model roles collapsed found three *strings in the app* still telling people to choose a model "for writing tools" and "for the Assistant" — a picker that no longer existed — and two file headers describing the design the file below them had replaced.
  **Turning on something that sat behind a flag needs the same check**: the day
  Private Cloud Compute became choosable, four strings and one screen written
  while it could not be were wrong — the "too long" errors told it to choose
  itself, and a conversation switched to it partway said nothing about sending
  what came before (implemented.md §51.54).
- Commit trailer: `Co-Authored-By: Claude <model> <noreply@anthropic.com>` per repo convention.
