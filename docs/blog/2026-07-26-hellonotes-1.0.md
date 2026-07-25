# HelloNotes 1.0 — a Markdown knowledge base that's actually a Mac app

*Fifteen days. 220 commits. 32,000 lines of Swift. One compiler bug that quietly broke every Release build.*

<p align="center">
  <img src="https://raw.githubusercontent.com/hellotham/hellonotes/main/website/public/assets/icon.png" width="128" alt="HelloNotes app icon">
</p>

**HelloNotes 1.0 is out today.** It's free, signed and notarised by Apple, universal for Apple silicon and Intel, and it needs macOS 15 or later.

👉 **[Download it](https://github.com/hellotham/hellonotes/releases/latest/download/HelloNotes.dmg)** · **[hellotham.com/hellonotes](https://hellotham.com/hellonotes/)** · **[Source](https://github.com/hellotham/hellonotes)**

---

## What it is

A knowledge base whose database is a folder.

Your notes are ordinary `.md` files somewhere you chose. There is no import step, no library format, no account, and no sync service of ours. If HelloNotes vanished tomorrow, every note would still open in any text editor on any platform — because they were never anything else.

![Your notes. Your files. Local and private.](https://raw.githubusercontent.com/hellotham/hellonotes/main/website/src/assets/screens/dark_01.png)

On top of that folder you get the things that make a pile of files into a knowledge base: `[[wiki-links]]` with autocomplete and aliases, backlinks, unlinked mentions, transclusion, nested tags, full-text search, daily notes, templates, and a graph view. Plus Git version history, cloud-folder support, and on-device AI.

An existing **Obsidian vault opens as-is** — wiki-links, tags, aliases and front matter intact. There's nothing to convert, because there's nothing to convert *to*.

---

## The bet

Every Markdown tool asks you to give something up. Obsidian is powerful and local-first, but
Electron — heavy, and never quite native in the way text handling on a Mac can be. Bear and
Apple Notes are fast and beautifully native, but your notes live in an opaque database you
can't `grep` or version. Typora is a lovely focused writing surface but is document-centric
rather than a linked knowledge base. VS Code will happily edit Markdown, but it's a code
editor wearing a writing hat.

Four things, and nothing had all of them:

1. Genuinely native performance and feel
2. Plain files on disk that you own
3. First-class Git sync
4. A linked knowledge graph — `[[wiki-links]]` and backlinks

The bet behind HelloNotes was that a knowledge tool built on **AppKit + TextKit 2 + SwiftUI** could deliver editing latency, scroll performance and OS integration that web-tech competitors structurally cannot — while keeping your data in an open, greppable format you fully own.

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

### We forked a Markdown engine, wrote eight patches, upstreamed five — then deleted all of it

The first editor was built on a fork of an open-source TextKit 2 Markdown engine. Eight features were blocked on missing engine hooks, so each one became a patch on the fork and a focused upstream PR: scroll-to-location, inline Mermaid, find & replace, tag autocomplete, callouts, `%%comments%%`, front-matter hiding, transclusion.

It worked. It also *failed the product's own performance targets* on large notes — scroll jank, freezes, caret lag. And when we finally sat down and enumerated why, every cause turned out to be **structural rather than a bug**:

- Full-document AST re-tokenise on every edit, with a parse cache keyed by string equality — O(document) per keystroke *and* per caret move.
- `ensureLayout(for: documentRange)` to position code-block overlays — O(document) layout. That was the freeze.
- Chrome implemented as overlay subviews, reconciled per scroll through `DispatchQueue.main.async`.
- Text passed as `Binding<String>` through SwiftUI — a whole-string copy and O(n) compare per keystroke.

You cannot patch your way out of an architecture. So the fork was deleted and the editor rewritten from scratch as a greenfield package, in five milestones, ending with the fork removed from the dependency graph entirely. The patches are still published upstream; they were good patches. They were just holding up the wrong building.

---

## Proving it renders like GitHub (not "looks about right")

"GitHub-compatible Markdown" is the kind of claim everyone makes and nobody tests. So we tested it.

The Preview renders through **cmark-gfm** — the same engine GitHub uses — into HTML, shown in a
WKWebView styled with github-markdown-css. (That's the one place a web view earns its keep: the
whole point is to be byte-identical to GitHub, and GitHub renders HTML.) The test suite makes two
assertions:

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

The fix was a coordinated-I/O layer and migrating every single vault read and write onto it — editor open and save, collection indexing, rename-with-link-rewrite, daily notes, search and link-graph indexing, image paste, export, agent tools. Coordinated reads materialise on demand and are a no-op for local files.

A second pass made indexing *dataless-aware*, so opening a cloud vault doesn't download all of it — the exact opposite of what you want. Verified live against a real 2,019-note iCloud vault: no hangs, no `EDEADLK`.

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

## Three bugs that nearly shipped

The interesting part of building anything is the part that goes wrong.

### 1. Every Release build was broken, and nothing caught it

Packaging the DMG failed at the archive step. `swift-frontend` **segfaulted** — no `error:` line, no archive, therefore no DMG and no App Store build. Debug built perfectly, which is exactly why the bug survived roughly 6,400 lines of work: every verification build for days had been Debug.

The useful line was buried in the full build log:

```
While running pass "EarlyPerfInliner" on SILFunction "$s10HelloNotes11OnceResumer…CfD"
```

The SIL performance inliner was walking a **null generic signature** while inlining the compiler-generated `deinit` of a *generic* class. A toolchain bug — but one our own code triggered, since the compiler hadn't changed since the last good build.

What didn't fix it, recorded so nobody retries it: `-Osize`, single-file compilation mode, dropping an `AnyObject` constraint. What did: deleting the generic parameter, which turned out to buy nothing. Both functions now carry comments explaining why they must stay non-generic.

**The lesson went straight into the docs: Debug proves nothing about Release.**

### 2. Commits with no author

Git commits were failing silently, unsigned. Cause: **a sandboxed GUI app cannot read `~/.gitconfig`.** The fix writes a commit identity into the repository's *local* config, falling back to the macOS account name.

### 3. The launch site shipped a redirect loop

The old site used `privacy.html` and `support.html`, and those URLs are registered with **App Store Connect**. Preserving them looked trivial. It wasn't:

- Astro's `redirects` config honours the build format, so a key of `/privacy.html` emitted a `privacy.html/` *directory* — `/privacy.html` still 404'd.
- Hand-written redirect files in `public/` were worse. GitHub Pages resolves `<path>.html` **before** `<path>/index.html`, so `public/privacy.html` shadowed the real `/privacy` route and redirected to itself. **This shipped, live, and broke both legal pages.**

The actual answer is one line of build config — `build: { format: 'file' }` — so a single artefact answers both URL forms with no redirects at all.

---

## Shipping it

The [product site](https://hellotham.com/hellonotes/) is sixteen pages of Astro and Tailwind — landing page, feature tour, screenshot gallery, download page with checksum and Gatekeeper verification, an eight-section user manual, and the about/privacy/support pages App Review expects. It deploys from source on every push.

The disk image deliberately isn't in the repository; at 35 MB it would sit in git history forever. Shipping a build is a GitHub Release, and the download button points at `releases/latest`.

Some numbers from the fifteen days:

| | |
|---|---|
| Commits | 220 |
| Swift | ~32,000 lines across 167 files |
| Tests | 83 editor-package tests (9 suites) + 63 app unit tests |
| GFM spec conformance | 648/648 |
| Verified against | a real 2,019-note vault |
| Ships as | signed, notarised, universal DMG |

---

## A note on how it was built

This was written with **[Claude Code](https://claude.com/claude-code)** as a pair — the git history is co-authored throughout, and the [implementation history](https://github.com/hellotham/hellonotes/blob/main/docs/implemented.md) is a genuine engineering log rather than a changelog.

The honest summary of that experience: it is dramatically faster at *writing* code than at *knowing when the code is wrong*. Every one of the three bugs above was caught by a human insisting on verification — building Release, opening the live URL, reading the actual bytes. The docs in this repo carry a lot of "what did **not** work" for exactly that reason.

One example that stuck: a first draft of the manual's keyboard-shortcut page confidently documented two shortcuts that **do not exist**. Grepping the actual `.keyboardShortcut()` modifiers found them. Documenting a UI from memory produces output that is fluent, plausible and wrong.

---

## Get it

**[Download HelloNotes 1.0](https://github.com/hellotham/hellonotes/releases/latest/download/HelloNotes.dmg)** — free, macOS 15+, Apple silicon & Intel.

Drag it to Applications and point it at any folder of Markdown files. Or an empty folder, and start.

- 🌐 [hellotham.com/hellonotes](https://hellotham.com/hellonotes/)
- 📖 [User manual](https://hellotham.com/hellonotes/manual)
- 💻 [Source on GitHub](https://github.com/hellotham/hellonotes)
- 🐛 [Issues & feature requests](https://github.com/hellotham/hellonotes/issues)

Published by [Hello Tham](https://hellotham.com).
