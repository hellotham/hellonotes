# HelloNotes 1.0 — a Markdown knowledge base that's actually a Mac app

*Fifteen days. 220 commits. 32,000 lines of Swift. Built by prompting — which turned out to be a much stranger job than I expected.*

<p align="center">
  <img src="https://raw.githubusercontent.com/hellotham/hellonotes/main/website/public/assets/icon.png" width="128" alt="HelloNotes app icon">
</p>

**HelloNotes 1.0 is out today.** It's free, signed and notarised by Apple, universal for Apple silicon and Intel, and it needs macOS 15 or later.

👉 **[Download it](https://github.com/hellotham/hellonotes/releases/latest/download/HelloNotes.dmg)** · **[hellotham.com/hellonotes](https://hellotham.com/hellonotes/)** · **[Source](https://github.com/hellotham/hellonotes)**

---

## What it is

A knowledge base whose database is a folder.

Your notes are ordinary `.md` files somewhere you chose. There is no import step, no library format, no account, and no sync service of mine. If HelloNotes vanished tomorrow, every note would still open in any text editor on any platform — because they were never anything else.

![Your notes. Your files. Local and private.](https://raw.githubusercontent.com/hellotham/hellonotes/main/website/src/assets/screens/dark_01.png)

On top of that folder you get the things that make a pile of files into a knowledge base: `[[wiki-links]]` with autocomplete and aliases, backlinks, unlinked mentions, transclusion, nested tags, full-text search, daily notes, templates, and a graph view. Plus Git version history, cloud-folder support, and on-device AI.

An existing **Obsidian vault opens as-is** — wiki-links, tags, aliases and front matter intact. There's nothing to convert, because there's nothing to convert *to*.

---

## The bet

Every Markdown tool asks you to give something up. Obsidian is powerful and local-first, but Electron — heavy, and never quite native in the way text handling on a Mac can be. Bear and Apple Notes are fast and beautifully native, but your notes live in an opaque database you can't `grep` or version. Typora is a lovely focused writing surface but is document-centric rather than a linked knowledge base. VS Code will happily edit Markdown, but it's a code editor wearing a writing hat.

Four things, and nothing had all of them:

1. Genuinely native performance and feel
2. Plain files on disk that you own
3. First-class Git sync
4. A linked knowledge graph — `[[wiki-links]]` and backlinks

My bet was that a knowledge tool built on **AppKit + TextKit 2 + SwiftUI** could deliver editing latency, scroll performance and OS integration that web-tech competitors structurally cannot — while keeping your data in an open, greppable format you fully own.

That bet is only interesting if the editor is genuinely good. Which is where most of the fifteen days went.

---

## The editor is the whole product

HelloNotes styles Markdown *as you type*. Headings grow, emphasis takes effect, tables align, callouts get their coloured band — while the file on disk stays exactly the Markdown you typed. Move the caret into a construct and its raw syntax appears so you can edit it; move away and it tidies itself again.

![LaTeX maths & Mermaid diagrams, inline](https://raw.githubusercontent.com/hellotham/hellonotes/main/website/src/assets/screens/dark_02.png)

Maths and Mermaid diagrams render **natively** — no browser engine anywhere in the editor. Code blocks are syntax-highlighted across ~190 languages using GitHub's own theme. Callouts collapse. YAML front matter is hidden from the prose and shown as a typed, editable Properties panel instead of raw YAML.

![Callouts, properties & rich Markdown](https://raw.githubusercontent.com/hellotham/hellonotes/main/website/src/assets/screens/dark_03.png)

Two design rules got it there, and they're the intellectual core of the whole project:

> **1. Raw Markdown *is* the text storage.** One text, one coordinate system. Byte fidelity holds by construction, because presentation is only attributes and drawing — never text substitution.
>
> **2. Every editing-path operation is O(damage), never O(document).** Full-document passes happen exactly once, at open, off the main thread.

Concretely, on a 3.8 MB stress note: the initial parse is ~12 ms, the first screens style in ~48 ms, and a full keystroke cycle measures ~6 ms. Perf tests fail the build if a 1 MB parse exceeds 50 ms or a keystroke cycle exceeds 5 ms.

### I forked a Markdown engine, shipped eight patches, upstreamed five — then deleted all of it

The first editor was built on a fork of an open-source TextKit 2 Markdown engine. Eight features were blocked on missing engine hooks, so each became a patch on the fork and a focused upstream PR: scroll-to-location, inline Mermaid, find & replace, tag autocomplete, callouts, `%%comments%%`, front-matter hiding, transclusion.

It worked. It also *failed my own performance targets* on large notes — scroll jank, freezes, caret lag. When I finally sat down and enumerated why, every cause turned out to be **structural rather than a bug**:

- Full-document AST re-tokenise on every edit, with a parse cache keyed by string equality — O(document) per keystroke *and* per caret move.
- `ensureLayout(for: documentRange)` to position code-block overlays — O(document) layout. That was the freeze.
- Chrome implemented as overlay subviews, reconciled per scroll through `DispatchQueue.main.async`.
- Text passed as `Binding<String>` through SwiftUI — a whole-string copy and O(n) compare per keystroke.

You cannot patch your way out of an architecture. So I deleted the fork and had the editor rewritten from scratch as a greenfield package, in five milestones, ending with the fork gone from the dependency graph entirely. The patches are still published upstream; they were good patches. They were just holding up the wrong building.

---

## Proving it renders like GitHub (not "looks about right")

"GitHub-compatible Markdown" is the kind of claim everyone makes and nobody tests. I didn't ask for GitHub-compatible. I asked for **identical to the GitHub REST `POST /markdown` API** — and that one word changed the architecture.

The Preview renders through **cmark-gfm**, the same engine GitHub uses, into HTML shown in a WKWebView styled with github-markdown-css. (That's the one place a web view earns its keep: the whole point is to be byte-identical to GitHub, and GitHub renders HTML.) Two assertions hold it in place:

- **648/648** on the GFM specification's own `spec.txt` corpus (638 exact, plus 10 documented tagfilter and extended-autolink overrides that GitHub applies too).
- **Byte-identity** against a captured response from `api.github.com/markdown`, normalising only GitHub's own display post-processing.

Then the *live editor* was moved onto that same cmark AST, so what you type looks like what you'd get: **340/340** inline constructs and **711/722** block classifications agree with cmark.

If a note looks right in HelloNotes, it looks right in a README.

---

## Your notes, connected

![See how your thinking connects](https://raw.githubusercontent.com/hellotham/hellonotes/main/website/src/assets/screens/dark_04.png)

The graph view is a native `Canvas` force-directed layout — no web view, no D3 — with directional arrows and focus tracing to follow one thread through a collection. There's a content-based mind map for a single note's structure, and every note shows what links to it, what it links out to, and which notes mention it *without* linking yet.

---

## Cloud storage, without a cloud

You can keep a collection in iCloud Drive, Dropbox, Box, OneDrive or Google Drive. Files stay online-only until you open them.

This one nearly didn't work at all, for a reason worth writing down: **the app used `NSFileCoordinator` nowhere.** Every read was `String(contentsOf:)`, every write `.write(to:.atomic)`. On a File Provider volume, reading an *online-only* file that way can fail outright with `EDEADLK` — which meant cloud folders, **including iCloud**, were quietly unusable.

The fix was a coordinated-I/O layer and migrating every single vault read and write onto it — editor open and save, collection indexing, rename-with-link-rewrite, daily notes, search and link-graph indexing, image paste, export, agent tools. A second pass made indexing *dataless-aware*, so opening a cloud vault doesn't download all of it — the exact opposite of what you want. Verified against my real 2,019-note iCloud vault: no hangs, no `EDEADLK`.

---

## Intelligence that stays on your Mac

![Ask your library — answers with citations](https://raw.githubusercontent.com/hellotham/hellonotes/main/website/src/assets/screens/dark_05.png)

Ask a question in plain language and get an answer grounded in your own notes, with citations back to the source files. It runs on-device through Apple Intelligence by default. If you'd rather use your own model, there are adapters for MLX, OpenAI-compatible endpoints, Anthropic and Gemini — your key, your endpoint.

There's also an agentic assistant with tools gated behind an explicit permission broker, and per-note intelligence: summarise, suggest tags, suggest links.

---

## Light and dark, everywhere

Both the app and its website follow your Mac, or pin to one appearance:

| Light | Dark |
|---|---|
| ![HelloNotes in light appearance](https://raw.githubusercontent.com/hellotham/hellonotes/main/website/src/assets/screens/light_03.png) | ![HelloNotes in dark appearance](https://raw.githubusercontent.com/hellotham/hellonotes/main/website/src/assets/screens/dark_03.png) |

---

# How this was actually built

I wrote very little of this code by hand. I built HelloNotes by prompting [Claude Code](https://claude.com/claude-code), and the git history is co-authored throughout.

That sentence makes it sound easy. It wasn't — it was just *differently* hard. Here's what the job actually turned out to be.

## The prompt was never "build me an app"

Before any code existed, I wrote three documents:

- **`PRD.md`** — who it's for, the four-way gap in the market, what v1.0 must do.
- **`architecture.md`** — the layer model, and the rules (`@Observable` only, no CoreData, the folder is the source of truth).
- **`implementation-plan.md`** — a milestone sequence, M0 through M13.

The plan is the part that made this work. Each milestone wasn't a wish, it was a table — task, target file, and an **acceptance criterion**:

| # | Task | File(s) | Acceptance |
|---|---|---|---|
| 1.2 | `EditorModel`: load text, dirty tracking, debounced autosave | `State/EditorModel.swift` | Edits hit disk ≤1s after typing stops; kill-mid-edit leaves file intact. |
| 1.7 | Persist vault via security-scoped bookmark | `WorkspaceIndexer.swift` | Relaunch reopens the last vault automatically. |

And each milestone closed with a *done-when* sentence in plain English — for M1: "open an existing folder of `.md` files, edit any note with live formatting and code highlighting, changes auto-persist, and new/deleted notes reflect on disk — all reopening cleanly on relaunch."

So my prompts were mostly **"do Milestone 3"**. The plan already said what done looked like, which file it lived in, and how I'd know. An LLM will happily produce something plausible for a vague request; it produces something *correct* far more often when the acceptance criterion is written down before it starts. Writing the spec was my highest-leverage work all fortnight.

(That plan has since been folded into [`implemented.md`](https://github.com/hellotham/hellonotes/blob/main/docs/implemented.md), which is the honest engineering log — milestones, fixes, and a lot of what *didn't* work. It's still in git history if you want the original.)

## The gate: every milestone ends on a green build

Zero errors, zero warnings in app sources, plus tests where the plan called for them. No milestone was "done" on a description of the work — only on a build.

This has an unglamorous consequence: a cold build of this project takes **30 to 47 minutes**. Seventy-four targets, including MLX, libgit2 and swift-transformers. More than once I nearly killed a build I assumed had hung. Learning to sit through it — and writing "a long `xcodebuild` is a cold rebuild, not a hang" into my own notes so I'd stop second-guessing — was a genuine part of the process.

## My actual job was refusing "deferred"

This is the thing I'd tell anyone building software this way.

The single most valuable thing I did was **say no to plausible-sounding excuses**. Twice, a hard TextKit 2 concealment bug came back to me as *"reverted — this is cosmetic."* It was not cosmetic. Concealing `> [!note]` syntax when the caret leaves the line **is the feature**; without it you're just looking at raw Markdown.

So it became a standing rule: never defer requested work as "too hard", "cosmetic", "non-core", "not a blocker" or "deferred polish". Root-cause it. And if genuinely stuck after real effort, say exactly what was tried and what the specific technical blocker is — and ask. Don't quietly downgrade my task.

An LLM is agreeable by disposition. It will accept a lowered bar the instant you offer one, and it will offer you one if you let it. Holding the bar is the human's job, and it's most of the job.

## Verifying is much harder than building

Generating a plausible fix takes seconds. Establishing whether it *actually works* took most of my attention, and four separate traps ate real hours:

**1. You will test the wrong build.** `osascript quit` followed by `open` frequently left a stale instance running — so the UI under test was the *old* binary, and a fix would "fail" verification when it had worked all along. This silently wasted debugging time more than once before I traced it. There's now a `scripts/relaunch-debug.sh` that force-kills everything, launches the newest build, and prints the PID and launch time so I can prove the instance is fresh.

**2. Screenshots came back black.** The controlling process didn't have macOS Screen Recording permission — a system security setting that can't be granted from inside a coding session. Rather than loop on it, the answer was to stop trying to photograph the screen: build the real editor **offscreen inside the app process**, force layout, and cache it to a PNG. Then assert against GitHub's exact hex values (`#d73a49` light, `#ff7b72` dark) instead of eyeballing it. That produced a stronger proof than a screenshot ever would have — an asserted, repeatable one.

**3. The Escape key never arrives.** Synthetic `Escape` from the automation tooling simply doesn't reach the app; every other key works fine. So any Escape-dependent behaviour looks broken, and you will confidently "verify dead" a fix that is perfectly alive. That one cost a whole verification round before I worked out the input, not the code, was the problem.

**4. Live rendering lies after a messy interaction.** A garbled sequence in the Open Quickly palette once left the editor in a *transient* bad render — setext headings at body size, checked tasks struck through — which survived mode toggles and scrolling. The storage-level unit tests had been right the entire time. The rule I wrote down: judge live rendering only on a clean relaunch and a clean open. If it looks wrong on screen but a package test says the storage is correct, reload before you believe it.

There's a pattern in all four. The AI was never the unreliable part — **the measurement was**. Most of my debugging was debugging my own instruments.

## Xcode tried to delete the app. Twice.

Unprompted, Xcode regenerated the project into its default *SwiftData* template. It came in two waves.

The first emptied the app target's package dependencies, so nothing could resolve — `Unable to resolve module dependency: 'Markdown' / 'SwiftGitX' / 'MarkdownEditor'`. The second was worse, because the build *succeeded*: it had replaced the app entry point with `@Query`/`Item` boilerplate, reset the Info.plist Markdown UTIs to `com.example.item-document`, deleted the app icons, and swapped 855 lines of real tests for a five-line stub. It also helpfully added a `ContentView.swift` and an `Item.swift` I never asked for.

Recovery is `git checkout HEAD -- <each clobbered file>`. The rule now: **git is the source of truth for `project.pbxproj`**, never accept an Xcode "modernize" or regenerate prompt, and `git diff --stat` after any Xcode session that touched project settings — looking specifically for template-shaped damage.

## Set the bar at provable, not plausible

The GFM fidelity work only exists because I refused "looks right".

The technique that worked is almost embarrassingly simple: `POST` the test Markdown to `api.github.com/markdown`, take GitHub's canonical HTML as ground truth, and diff it against the app's render section by section. That found real gaps — unordered `-` not becoming bullet glyphs, missing blockquote gutter bars, task-list dashes not concealed — that no amount of looking at the screen would have surfaced.

The same instinct is why `implemented.md` records what **didn't** work. When the Release build broke (below), three plausible fixes failed before the real one landed. Those three are written down. That's the highest-value paragraph in the whole document, because it's the one that stops a future session — mine or the AI's — from cheerfully retrying them.

---

## Three bugs that nearly shipped

### 1. Every Release build was broken, and nothing caught it

Packaging the DMG failed at the archive step. `swift-frontend` **segfaulted** — no `error:` line, no archive, therefore no DMG and no App Store build. Debug built perfectly, which is exactly why the bug survived roughly 6,400 lines of work: every verification build for days had been Debug.

The useful line was buried in the full build log:

```
While running pass "EarlyPerfInliner" on SILFunction "$s10HelloNotes11OnceResumer…CfD"
```

The SIL performance inliner was walking a **null generic signature** while inlining the compiler-generated `deinit` of a *generic* class. A toolchain bug — but one my own code triggered, since the compiler hadn't changed since the last good build.

What didn't fix it, recorded so nobody retries it: `-Osize`, single-file compilation mode, dropping an `AnyObject` constraint. What did: deleting the generic parameter, which turned out to buy nothing. Both functions now carry comments explaining why they must stay non-generic.

**Debug proves nothing about Release.** That went straight into the build docs.

### 2. Commits with no author

Git commits were failing silently, unsigned. Cause: **a sandboxed GUI app cannot read `~/.gitconfig`.** The fix writes a commit identity into the repository's *local* config, falling back to the macOS account name.

### 3. The launch site shipped a redirect loop

The old site used `privacy.html` and `support.html`, and those URLs are registered with **App Store Connect**. Preserving them looked trivial. It wasn't:

- Astro's `redirects` config honours the build format, so a key of `/privacy.html` emitted a `privacy.html/` *directory* — `/privacy.html` still 404'd.
- Hand-written redirect files in `public/` were worse. GitHub Pages resolves `<path>.html` **before** `<path>/index.html`, so `public/privacy.html` shadowed the real `/privacy` route and redirected to itself. **This shipped, live, and broke both legal pages.**

The actual answer is one line of build config — `build: { format: 'file' }` — so a single artefact answers both URL forms with no redirects at all.

---

## Two things I caught at the very last minute

Worth including because they're the exact failure mode of building this way — output that is fluent, confident and wrong.

**The manual documented two keyboard shortcuts that don't exist.** `⌃⌘S` for the sidebar, `⌘T` for a new tab. Both entirely reasonable. Both invented. Grepping the actual `.keyboardShortcut()` modifiers in the source found them before publication. Documenting a UI from memory rather than from the code produces plausible fiction.

**The first batch of marketing screenshots contained my real notes.** All 2,019 of them, personal folder names legible down the sidebar. They were caught, discarded, and re-shot against the demo vault with every other collection closed — and the app's preferences were backed up and restored so the session left no trace. But they'd have gone straight onto the front page.

Neither of these is a coding error. Both are judgement, and judgement is the part that stays yours.

---

## Shipping it

The [product site](https://hellotham.com/hellonotes/) is sixteen pages of Astro and Tailwind — landing page, feature tour, screenshot gallery, download page with checksum and Gatekeeper verification, an eight-section user manual, and the about/privacy/support pages App Review expects. It deploys from source on every push.

The disk image deliberately isn't in the repository; at 35 MB it would sit in git history forever. Shipping a build is a GitHub Release, and the download button points at `releases/latest`.

Fifteen days, in numbers:

| | |
|---|---|
| Commits | 220 |
| Swift | ~32,000 lines across 167 files |
| Tests | 83 editor-package tests (9 suites) + 63 app unit tests |
| GFM spec conformance | 648/648 |
| Cold build time | 30–47 minutes, 74 targets |
| Verified against | a real 2,019-note vault |
| Ships as | signed, notarised, universal DMG |

---

## Get it

**[Download HelloNotes 1.0](https://github.com/hellotham/hellonotes/releases/latest/download/HelloNotes.dmg)** — free, macOS 15+, Apple silicon & Intel.

Drag it to Applications and point it at any folder of Markdown files. Or an empty folder, and start.

- 🌐 [hellotham.com/hellonotes](https://hellotham.com/hellonotes/)
- 📖 [User manual](https://hellotham.com/hellonotes/manual)
- 💻 [Source on GitHub](https://github.com/hellotham/hellonotes)
- 📓 [The full build log](https://github.com/hellotham/hellonotes/blob/main/docs/implemented.md) — every milestone, fix and dead end
- 🐛 [Issues & feature requests](https://github.com/hellotham/hellonotes/issues)

Published by [Hello Tham](https://hellotham.com).
