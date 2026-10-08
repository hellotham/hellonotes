# Unimplemented, Deferred & Production Readiness

> As of **v1.3** (reconciled against the source 2026-08-16: §7's iOS entries revised
> where 1.3 closed them — the AI stack is no longer macOS-only — and inline completion
> added as the one 1.3 feature that did *not* reach iOS. The previous pass, 2026-08-15
> for v1.2, retired §8b's cloud entries and five earlier ones describing gaps that had
> already been closed; see [implemented.md §20](implemented.md).)
>
> **2026-08-25 doc-currency pass (spot-check, not a full reconciliation):** the project
> is at 1.3.2 (build 21, in App Review on both platforms as of 2026-09-04) and ships
> on macOS + iOS from one App Store Connect record —
> see `docs/production.md`. Three stale file references from the pre-2026-08-22
> `MacContentView`/`iOSContentView` split were corrected below (search this file for
> "2026-08-22 merge"), including one, the References-tab `unlinkedMentions: []` gap,
> that current source suggests is already closed. The "iOS parity audit (2026-08-21)"
> section further down was **not** re-verified in this pass — it sits in the same
> files as this session's separate, active bug investigation, so treat its "hard-coded
> `false`" and gating claims as unconfirmed rather than re-asserting them as still
> current.
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

*Resolved and moved to [implemented.md §50](implemented.md): the website's App
Store presence — links, both OS floors, iPhone and iPad screenshots — shipped
2026-09-15, once 1.3.2 went live on 7 September. The versioning rule that came
with it is worth keeping in view: a new DMG does **not** get 1.3.3 while the App
Store is on 1.3.2, because `check-download-page.sh` compares the two with `!=`
and they must match exactly once the app is public. Re-cut under the same
version instead — see implemented.md §49.*

- 🟡 **No macOS 26 layered app icon** — the classic 16→1024 PNG ladder is complete; there is no Icon Composer `.icon` layered asset for the 26 look (needs artwork). Legacy icon still ships fine.

---

## 1 · Data safety & correctness

*Resolved and moved to [implemented.md §6](implemented.md#6--production-release-hardening): flush-on-quit handshake; atomic assistant writes; surfaced file-operation failures (create/rename/duplicate/delete/folder/move) + partial-rename link-rewrite reporting; export-error alerts; off-main reconcile read; no-config-wipe persist; serialized git status/history/content reads.*
*Resolved and moved to [implemented.md §7](implemented.md#7--post-review-fix-pass-2026-07-19): `createRepository`/`cloneRepository` routed through the git FIFO queue; serialized `EditorModel` writes (no stale-on-quit race).*
*Resolved and moved to implemented.md §51.13 (2026-09-24): typing while a note loaded — the blank, or the note shown before — could be saved over the note arriving; the buffer is write-locked for the whole load now.*
*Resolved and moved to implemented.md §51.14 (2026-09-25): opening a note in a full cloud cache evicted the notes open in other tabs to placeholders under them; every note an editor holds, in any window, is pinned now, and a placeholder is never taken as a note's text.*
*Resolved and moved to implemented.md §51.15 (2026-09-25): a write the app made into an open note never reached the editor in Edit, and the next typing carried the document back over it; typing in Edit was lost to a tab switch and return, to the document store letting its document go, to a prune, or to a change elsewhere loaded over it; and the host could pair one tab's document with the next tab's model. The two settle by which of them moved since they last matched now, and switching away saves. A note open in two windows no longer shares one document between them, and a property written back no longer cuts a letter off the body for each CRLF line in the front matter.*
*Resolved and moved to implemented.md §51.16 (2026-09-25): a save while the conflict banner was up wrote mine over theirs, and a Reload after it left mine in the file for the next check to load back; now only Keep Mine writes the note while a conflict is open, both resolutions wait for a write in flight, and a buffer let go with a conflict open — quit, a tab or window closed, iOS leaving the foreground — keeps mine beside the note as a conflicted copy.*
*Resolved and moved to implemented.md §51.19 (2026-09-26): a note window's editor was wired to nothing — a cloud note still a placeholder opened empty there, its saves were never uploaded, indexed or registered as the app's own, and a save into a folder that had gone was not refused. Tabs and note windows are wired by the same code now (`EditorWiring`); and a cloud note whose download fails opens unloaded, in either, where it opened as an empty note that took typing.*
*Resolved and moved to implemented.md §51.22 (2026-09-28): a rebuild of the indexes from the cache put a saved note's pre-save links, tags and aliases back, and a save's patch cancelled the rebuild in flight — a delete's, a walk's, a changed alias's — with nothing to run it again. What a save or a new note patches is kept until a rebuild has read the note from disk since, and applied over whatever a rebuild begun before it read; nothing cancels a rebuild but a newer one. A save made while the relatedness index was being built reaches it now, and a cancelled rebuild no longer loads search after the one that replaced it.*
*Resolved and moved to implemented.md §51.24 (2026-09-28): only the main window opened last had its tabs reconciled when a note changed on disk, and a note window's editor never was. Every open window is told now — each main window's tabs and each note window's editor — from when it appears to when it goes.*
*Resolved and moved to implemented.md §51.25 (2026-09-28): what was typed in the Markdown pane — Markdown and Split mode — was written only at the next flush, so leaving it for the sidebar or another pane wrote nothing and a crash before a flush lost it. It is written when editing stops, as Edit mode's is, on both platforms.*
*Resolved and moved to implemented.md §51.30 (2026-09-29): a property changed in the Properties panel — the inspector's or the note's popover — was written only at the next flush; the panel's commit ends with the editor's own save now, and a commit that changes nothing still writes nothing.*
*Resolved and moved to implemented.md §51.35 (2026-10-08): following an aliased wiki link from Edit — `[[Roadmap|the plan]]` — looked for a note named after the whole link, found none, and in the main window made one (`Roadmap|the plan.md`), the tour's own link to the manual among them; the alias comes off first now, with a table's escaping backslash, and a missing note is made under the name the link gives it.*
*Resolved and moved to implemented.md §51.36 (2026-10-09): a refresh with no delta cursor walks; a note made here and still empty is never taken for the provider's placeholder; a download is recorded only at the revision it read; token refreshes are single-flighted per account, read again after a refused exchange and never written back after a sign-out; Box, Drive and OneDrive list the content's revision; the self-test removes its leftovers through the mirror; a second large-folder prompt answers the first; a symlinked subfolder is walked, guarded against loops; the Assistant edits an open note in its editor; closing a window waits for its save; a reconcile clears a failed load; every app write into an open note is saved when made; a walk's late verdict cannot overwrite a recheck's success; and every reader of a wiki link takes a table's escaped alias pipe as the escape it is (`WikiLinkSyntax`).*

- ✅ ~~**`ChatSessionStore` write is `try?`**~~ — resolved (§20): save/clear failures now report through the assistant's `errorText`, except `fileNoSuchFile` on clear (an empty conversation).

---

## 2 · Security & privacy *(AI / networking)*

*Resolved and moved to [implemented.md §6](implemented.md#6--production-release-hardening): `web_fetch`/`web_search` SSRF protection + redirect re-validation; scoped "Allow all" (resets per conversation); bounded `web_search` + SSE error buffers.*
*Resolved and moved to [implemented.md §7](implemented.md#7--post-review-fix-pass-2026-07-19): `create_note` path-traversal containment; "Allow all" never auto-approves deletions; write-tool symlink containment; NAT64 in the SSRF classifier; Keychain secrets → `…ThisDeviceOnly`; credential-scrubbed git error strings.*
*Resolved and moved to implemented.md §51.36 (2026-10-09): the web tools' address check holds against DNS rebinding — each body is read whole and the address of every connection that served it checked (`URLSessionTaskMetrics`) before any of it reaches the model.*

- ⬆️ **Git PATs are written in plaintext to `.git/config`** — `GitRemoteURL.authenticated` embeds `user:token@host` into the remote URL (`GitCredentials.swift`), which libgit2 persists on disk; if the collection lives in Dropbox/iCloud the token leaves the Keychain. **Root cause:** SwiftGitX exposes no credential callback, so the token can't be supplied per-operation. **Unblock:** a SwiftGitX credential-callback API (then stop embedding the token in the URL). *(Error strings that would echo the URL are now credential-scrubbed — §7 — but the persisted config value remains.)*
- 🟡 **Structural prompt-injection exposure remains** — tool outputs and note content still re-enter the model context with no provenance separation. It's now materially reduced (SSRF guard blocks internal exfiltration; mutating tools are broker-gated, "Allow all" no longer persists across conversations and never auto-approves deletions), but a fully robust design would tag untrusted content and constrain what it can trigger.

---

## 3 · Performance & memory *(2,000-note scale)*

*Resolved and moved to [implemented.md §6](implemented.md#6--production-release-hardening): debounced search-aggregate rebuild; bounded `CollectionEmbedProvider`/`BlockRenderAdapter` image caches; bounded + off-main chat-transcript persistence.*
*Resolved and moved to implemented.md §51.11–§51.12 (2026-09-24): Mermaid diagrams rendered off the main actor, in the editor and in Preview; no whole-note comparison on the main actor when a note is saved, checked against the file (`reconcileWithDisk`), published to other scenes or typed into in Markdown mode (`adopt`'s bridged comparison among them).*
*Resolved and moved to implemented.md §51.15 (2026-09-25): the last two whole-note comparisons in `EditorHost` — a reload landing in an open Edit tab, and a cached tab shown again — are settled from counts. Typing in a Properties field no longer rewrites the note per character (the rows are a draft, committed on Return or on leaving the field); the inspector and the outline take the note compared by its version, not as a `String`; Review Links compares versions; reading a note's properties reads its front matter only; and `reconcileWithDisk` asks the file provider off the main actor.*
*Resolved and moved to implemented.md §51.17 (2026-09-26): every save patched the collection's link graph, search index and relatedness index on the main actor, a pass over the whole note each — 158 ms for a 2 MB note in a 200-note collection. The note is parsed once in `offMain` and the result applied on the main actor (under 5 ms), newest save only, never to a note that has left.*
*Resolved and moved to implemented.md §51.18 (2026-09-26): typing in Split mode rendered the page twice, walked the note for maths and diagrams, drew every diagram again and analysed it for the inspector — at least 700 ms of main-thread CPU a keystroke in a 694 KB note, the shell and the note column redrawing with it. What follows the note without editing it now follows the text as of the last pause in typing (`EditorModel.settledText`), and Preview, the Outline and the Tags tab are built off the main actor: 1.6 ms a keystroke.*
*Resolved and moved to implemented.md §51.22 (2026-09-28): a save's index patch cancelled a full rebuild in flight and nothing restarted it; no save cancels a rebuild now.*
*Resolved and moved to implemented.md §51.32 (2026-09-29): a vault's availability was checked by listing its root on the main actor, from a recheck (Retry, Relocate) and from the watcher's root change; both look off it now, taking turns with the watcher's events whole and in order, as they did when the look was synchronous.*
*Resolved and moved to implemented.md §51.34 (2026-10-08): a cloud collection's walk ran on the main thread, listing through main-actor stores that read their token from the Keychain and parsed every page there; it runs away from the main actor now, asking a lock where it asked the main actor, the stores are `nonisolated` with their pages parsed in `offMain`, Drive's change feed is placed from one map built off it, and each token is read from the Keychain once.*
*Resolved and moved to implemented.md §51.36 (2026-10-09): Open Quickly scores off the main actor; the Tags view's counts are folded with the index; the mind map's layout, Properties' front-matter read (no further than the editor folds), the transclusion card's read and section, a pasted picture's write, a new folder, the Trash move, launch's bookmark resolution and Try Again's and Relocate's, each account's first Keychain read, opening a note's file-provider question and `EditorDocument.make`'s parse are off it; a change seen during a walk asks for one more pass instead of cancelling it; and a cloud collection stages its downloads, reads its eviction stats, decodes its manifest, folds its placeholders and compares its unsent records off the main actor, and a cancelled walk no longer waits for its prefetch.*

- 🟡 **A transclusion card is drawn on the main actor.** Its read and its section (`NoteTranscluder.section`) are off it, the provider is `nonisolated` so its lock guards something, and its cache keeps the 64 cards used last rather than emptying past them (implemented.md §51.36). The drawing — `lockFocus`, which is main-thread-only on the Mac — still runs there per uncached `![[Note]]`. **Fix:** draw through a `CGContext`, as diagrams are (§51.11).
- ✅ ~~**Collections open sequentially at launch**~~ — resolved (§20): `restore()` creates the collections up front and activates them in a task group, so launch costs the slowest scan rather than the sum.
- 🟡 **`LibraryChatView.retrieve` reads every note per question** (off-main, user-initiated); fine now, revisit for very large vaults.
- 🟡 **Formulas, tables and HTML blocks in the editor are rendered on the main actor.** `EditorHost`'s `renderMath`, `renderTable` and `renderInlineMath` run inside `MainActor.run`: a formula because `MTMathUILabel` is a view; a table because on the Mac it is drawn through `PlatformImageKit.image(size:)`, whose `lockFocusFlipped` is main-thread-only — the limit the diagram flip had, and the `CGContext` route that freed diagrams (§51.11) would likely free tables too (`PlatformImageKit` is declared `nonisolated` and its header says off-main renderers call it, which `image(size:)` cannot serve on the Mac). HTML blocks render through a `WKWebView` (`HTMLBlockImageRenderer`). Not measured.
- ✅ ~~**A cloud collection writes its whole manifest on the main actor, at every change.**~~ — fixed 2026-09-27 (implemented.md §51.21): `ManifestWriter` writes the newest record away from the main actor, one write per burst; a save sends the bytes it wrote, and any other upload reads in `offMain`.
- 🟡 **A save lists its note's folder on the provider, before and after.** `upload` asks `providerEntry` — a listing of the note's folder — before writing a note made here and after every write, for the revision, and so do a move and a new folder; the listing's page is parsed off the main actor since implemented.md §51.34, but it is a round trip each time, and a page of the whole folder. **Fix:** have `write`, `move` and `createFolder` return the resulting entry (Dropbox's API already answers with it), and add a one-item metadata call, so a save lists nothing — each provider's response shape checked against a live account. (Rename's, duplicate's and move's `fileExists` checks are off the main actor since §51.36.)
- 🟡 **A refresh with a cursor applies the delta's entries on the main actor** (`applyChanges`: paths, a `holdsContent` stat and a placeholder per entry — 40 ms per 2,000 entries with nothing to write, 147 ms with placeholders; the concurrency review of implemented.md §51.34). The rest that review found — a download's write, eviction's stats, the scan's placeholders and sizes, `sendUnsent`'s comparison, the manifest's first decode, and a Cancel waiting for a whole account's prefetch — is off it (§51.36). **Fix:** the delta's loop the way the walk is: an `@concurrent` helper over a snapshot and `waitingToGo`, its records applied on the main actor.
- 🟡 **Preview's page carries every diagram, formula and card as base64 in its HTML**, so each load hands the web view all of it again. What was found beside it — the Tags view's counts, the mind map's layout, Properties' front-matter read and the embed provider's reads — is off the main actor (implemented.md §51.36). **Fix:** serve the images through a `WKURLSchemeHandler` from `PreviewSuperset.rendered`, so the page is its text.
- 🟡 **`EditorDocument.replaceText` parses the whole note on the main actor** — an app write into an open note, or a reload. `make` parses off it since implemented.md §51.36; `replaceText` settles a live document — its selection and its undo stack — in one synchronous step (`DocumentLoad.settle`), so taking its parse off the actor means making that settle asynchronous. **Fix:** parse off the main actor and apply the result in the turn that settles, re-checking the document's version.

---

## 4 · Usability & error-surfacing

*Resolved and moved to [implemented.md §6](implemented.md#6--production-release-hardening): file-operation errors now surface (alert); folder-delete confirmation; ⌘P Print; "AI not configured" empty state; rename distinguishes name-taken from OS errors.*
*Resolved and moved to implemented.md §51.23 (2026-09-28): Preview went back to the top of the note each time it was handed a new page — once per pause in typing in Split mode, and at every change made under it in Preview. The page says where it has been scrolled to, and the next page of the same note opens there; a note the preview has not shown opens at the top, and one switched back to where it was left.*
*Resolved and moved to implemented.md §51.36 (2026-10-09): Push has a Stop — a push written against libgit2 with callbacks that stop it once cancelled (SwiftGitX's push gave libgit2 none), which Create's push uses too. A connect that never completes is the one thing a callback cannot interrupt.*

- ✅ ~~**References panel disappears when empty**~~ — resolved (§20): the button stays put and shows the same "No References" copy the inspector already used. (The inspector's own tab already had the empty state.)
- ✅ ~~**Duplicate has no keyboard shortcut**~~ — **entry was stale**: Duplicate is ⌘D (Finder convention) and Bookmark is ⇧⌘D (`AppCommands.swift`). Shipped before 1.1, never struck off.
- ✅ ~~**Clearing a number property turns it into text.**~~ — resolved (implemented.md §51.15): the panel's rows are a draft, so the empty value in between is never written, and the number typed next is written as a number.

---

## 5 · Accessibility

*Resolved and moved to [implemented.md §6](implemented.md#6--production-release-hardening): Graph is now VoiceOver-navigable (`accessibilityChildren`); git dirty-state dot is labelled (not colour-only). (Mind Map nodes were already real `Text`/`Button` views, so already navigable.)*

- ✅ ~~**No editor headings rotor**~~ — **entry was stale**: shipped on macOS (`accessibilityCustomRotors` + `NSAccessibilityCustomRotorItemSearchDelegate`) *and* iOS (`UIAccessibilityCustomRotor(systemType: .heading)`). The real gap underneath it — neither copy honoured the rotor's `filterString`, so typing to narrow the list did nothing — was fixed in §20, and the walk moved to `EditorDocument.rotorHeading(after:forward:matching:)` so it is testable.
- 🟠 **Custom TextKit-2 editor a11y needs an on-device VoiceOver audit** — concealed/replaced ranges (near-zero-size marker fonts, drawn block embeds) may misreport to VoiceOver. `NSTextView` is natively accessible, but the concealment layer needs verification on a real device with VoiceOver.
- ✅ ~~**Canvas labels scale by zoom, not Dynamic Type**~~ — resolved (§20): both canvases use `@ScaledMetric`, and the mind map feeds the same factor into `estimatedChipSize` so chips grow with their labels instead of clipping.
- ✅ ~~**Reduce Motion isn't queried**~~ — **entry was stale**: the only continuously animating surface (`SplashScreenView`) already pauses its `TimelineView` on `accessibilityReduceMotion`. Everything else is a precomputed layout or a single state transition.

---

## 6 · Editor gaps

*Resolved and moved to implemented.md §51.33 (2026-10-08): Preview's aliased wiki link inside a table pointed at a note whose name ends in a backslash, because the rewrite to GFM kept the table's escape in the target; on the lines `BlockParser` calls a table it drops it now, as the editor's table reads the row.*
*Resolved and moved to implemented.md §51.36 (2026-10-09): Preview redraws when a note it transcludes changes; a link clicked in Preview is followed as one in Edit is; Edit's table splits a row at `\\|` as cmark-gfm does; a table's picture breaks a cell's line at `<br>`, draws no other tag, sets tabular figures and puts a cell's baseline where the page does; and incremental parsing converges in prose.*

- ✅ ~~**Concealed `$$` block leaves a coloured dot and a height gap**~~ — resolved (§20).
  Three separate defects, all from `collapse(range:to:)` treating a multi-line block as
  one line: the image band was reserved once per newline (~90pt of dead space), the block's
  trailing newline stayed at body size (a blank line under the formula), and the async code
  highlighter repainted a collapsed Mermaid fence's concealed source (the coloured specks).

*The **iOS live editor** (`editor-M5`) is now **shipped**, including the fragment chrome — see [implemented.md §6](implemented.md#6--production-release-hardening). iOS has a live TextKit 2 editor with inline styling, caret-driven concealment, and the full block chrome (bullets, checkboxes, callouts, gutter bars, heading rules) via an overlay renderer; the `BlockRendering` chrome was ported to cross-platform CoreGraphics with no macOS regression.*

- ✅ ~~**iOS block embeds / inline math aren't consumed**~~ — the collapse path reached iOS some time ago (the `#if canImport(AppKit)` is gone from `EditorDocument`), and `ChromeOverlayView` draws block pictures. A note the document store handed back still showed none of it until 2026-09-24: its paragraphs were laid out inside `UITextView`'s initialiser, before the fragment delegate was installed, in plain fragments the overlay does not draw (implemented.md §51.8). Tables, formulas and diagrams were seen drawn on the iPad simulator after the fix; transclusion cards were not checked there.
- ✅ ~~**A second identical fenced code block, or the same `$…$` formula or inline picture in a second block, is left undrawn.**~~ — fixed 2026-09-24. `EditorDocument` kept four render caches keyed by content, each turning a second request for a key already in flight away and refreshing only the block that started it; all four now map a key to every block waiting on it (implemented.md §51.8, `IdenticalRendersTests`, `TableEmbedTests.identicalTablesAreBothDrawn`).
- 🟡 **Maths and pictures inside a table cell are drawn as their source in Edit's picture of the table.** Preview draws a cell's `$…$` (the app's formula image, `PreviewSuperset`) and its `![alt](path)`; the picture draws the formula's source and the image's alt text. Drawing them needs the picture to take rendered pieces from the app — the table is drawn asynchronously already — and to lay replaced elements out in its lines, growing a line box as CSS does: new rendering, not a fix to what the picture draws, which matches the page since implemented.md §51.36 (`<br>`, other tags, tabular figures, the cell's baseline).
- 🟡 **Live transclusion** — `![[Note]]` embeds render as a static image card (macOS); nested callouts and live selection inside a transclusion aren't supported (needs nested live-layout embeds).
- 🟡 **Emoji shortcodes** — `:smile:` renders as literal text (matches raw GitHub *source*; github.com substitutes the glyph only at display time, which cmark-gfm/the Preview doesn't). Low value.
- ✅ ~~**A note opened straight into Edit shows its front matter unfolded.**~~ — fixed 2026-09-26. The host put back a caret nobody had placed (`selectedRange` reads `{0, 0}` before anything puts one in a document): on a note's first load it opened the blank line under the front matter, and on an app write or a reload of a note nobody had clicked into it unfolded the front matter itself. A document has no caret until one is placed now (`EditorDocument.caret`), and the settle puts back only one it had (implemented.md §51.20, `FrontMatterStaysFoldedTests`, `UnplacedCaretTests`).

---

## 6b · Layout architecture — the parts not yet built *(design: [ui.md](ui.md) §11; shipped parts: implemented.md §17)*

The sizing contract, the adaptive shell, both rails (the 64pt library switcher
with its Library place, and the inspector) and the width model are in. These
decisions are not:

- 🟡 **Manual pane splitting** (decision 2) — `ShellMetrics.maxPanes` computes
  the ceiling (`min(4, pane/320)`) and the contract test asserts it, but there is
  no split command and no second pane. Today: one pane, plus tabs.
- ✅ ~~**The persistent format bar** (decision 3)~~ — **superseded, not built.**
  `ShellContext.showsFormatBar` resolved the rule and was tested while no view
  ever read it, which reads as coverage and is worse than neither; the predicate
  and its constants are gone (§41). Formatting is the **Format** menu with a
  pointer and **the system's own bar above the keyboard** with a finger — the
  floating shortcuts row on iPad, an `inputAccessoryView` on iPhone. That costs
  the app no row at all, which `shell-chrome.md` D1 ("one row of chrome, ever")
  wanted, and it appears with a hardware keyboard too.
- 🟡 **Column widths remembered per window** (decision 4) — dragging and
  collapsing work and are clamped to the contract's floors and caps, but only
  via the system's own state restoration; nothing is stored deliberately.
- 🟡 **Scroll-linked chrome retraction on compact** (decision 11) — chrome
  retracts when the note is expanded, not in response to scroll direction.
- 🟡 **A keyboard accessory bar** for touch editing (Part 3) — not built.
- 🟡 **What the UI registers still hold is design** — each UI design document ends with the defects and gaps its fact-checks found ([ui.md](ui.md) §12, [primary.md](primary.md) §12, [secondary.md](secondary.md) §9, [toolbars.md](toolbars.md) §14, [menu.md](menu.md) §8, [tabs.md](tabs.md) §2.5), and those lists stay the register. Their defects are fixed and marked there (implemented.md §51.36); what is left is design and new work — the tabs redesign proposed in [tabs.md](tabs.md) §3–§9 above all.

---

## 7 · iOS / iPadOS parity

*Resolved and moved to implemented.md §51.9–§51.10 (2026-09-24): the tapped line scrolled above the top of the editor when the keyboard came up (scroll-past-end was a covered inset; the Mac had the same shape); the diagram zoom opening on the first diagram in Markdown and Split (a View diagram button on every diagram's fence now).*
*Resolved and moved to implemented.md §51.29 (2026-09-29): Split mode lost the keyboard when it changed from stacked to side by side — on an iPad in portrait the keyboard itself made that change — because its two arrangements were two branches of an `if`; one `AnyLayout` keeps the panes now, with a rule of the app's own that drags on both platforms. Every rule that drags, `ResizableDivider` included, followed the pointer at half speed; each drag is measured in a space that does not move.*

- ✅ **Live editor** — shipped (`editor-M5`, see §6) with full block chrome; the remaining iOS-editor item is wiring the app-side services (code colours, embeds) — see §6.
- ✅ **Adaptive shell** — iOS resolves its layout by the same rule as macOS, with a compact tab-bar model of its own (implemented.md §17). The inspector rail, outline, tags, references, properties and history are now cross-platform.
- 🍎 **macOS-only surfaces** — two, and each is a Mac *shell* concept rather than a gated feature: **menu-bar quick capture** (a `MenuBarExtra`; the iOS equivalent would be a share extension or a Control Center control, i.e. a different feature — the capture *sheet* itself is on iPad, in the shell command menu and the Library actions), and the **Services menu / global hotkey**, which have no iOS counterpart at all: both are system-wide entry points into a *frontmost other app*, which iOS does not offer to third parties. **Open a note in a new window** and the **launcher window** are no longer on this list — both shipped on iPad in the second parity pass (implemented.md §25). Every other entry that used to sit here was stale: Graph, Mind Map, the command palette, Open Quickly, HTML/PDF export, print, the file viewer, unlinked mentions and the Git settings UI were all already on iOS when the audit checked, and image paste, multi-tab, Marp slides, Find & Replace, `[[wiki-link]]` / `#tag` autocomplete, inline completion, heading navigation, folds, inline maths, Mermaid preview and clone/new-repository landed in 1.3.2. See implemented.md §24–25. *(A list of what a platform lacks decays faster than the code does; this one was re-derived feature by feature, because a grep for `#if os(macOS)` reports that a file contains a gate, not what the gate covers.)* *(The AI stack is no longer on this list: 1.3 brought Summarise / Suggest Tags / Suggest Links / Rewrite, the selection actions, Ask Library, the Assistant, Review Links and New Note from a Prompt to iOS — see implemented.md.)*
- ✅ ~~**Open Quickly used to be weaker on iOS**~~ — fixed: iPad had a list of its own filtering titles by substring, so ⌘O found a different set of things on each platform. Both now run `quickOpenResults` (fuzzy, headings included, debounced) through one view.
- ✅ **AI as a compact place** (decision 7) — built. `CompactPlace` grew its fourth tab, and the reason recorded for its absence ("the Assistant and Ask Library views are still macOS-only") had expired when 1.3 brought both to iOS — the comment outlived the constraint it described. The place puts Ask Your Library and New Note from a Prompt up front, the four note-scoped actions under them (disabled together, with a footer saying which of "no note" or "no provider" is the reason), and the Assistant and AI Settings last. *(Still open from decision 7: Graph and Mind Map as full-screen sheets on iPad — both views are already cross-platform, so this is a presentation to add, not a port.)*
- ✅ **Inline completion (ghost text)** — shipped on iOS. The ghost is painted by `ChromeOverlayView` (a `UITextView` doesn't invoke a subclass's `draw` over its own text), and the acceptance gesture that had to be designed rather than ported is **a tap on the ghost itself** — the one region on screen where a tap otherwise means nothing, since the caret is already at the end of that line. ⌥⇥ / Esc are offered while a suggestion shows, so a Magic Keyboard iPad behaves like the Mac. Still not on: `→` to accept (the soft keyboard has no arrow) and the Mac's `complete:` on-demand ⌥Esc.
- ✅ **Folds, inline maths and tappable chrome on iOS** — front-matter folds, callout folds and inline `$…$` maths were the last `#if canImport(AppKit)` in `EditorDocument`. The *drawing* half had been cross-platform since the chrome overlay landed (`PlatformDraw`, `drawChromeOnly` already painted the chevron and the baseline images) — only the document half was gated, and the taps that drive it were unwritten. Tapping a task checkbox toggles it; tapping a callout's chevron folds it. One difference from the Mac, deliberate: the caret is not restored afterwards, because AppKit lets a click be intercepted *before* it moves the caret and UIKit's own recogniser runs alongside ours, so there is no "before" to restore to. The tapped line reveals its source — which is what tapping any line in this editor does.
- ✅ **Heading navigation from the iOS outline** — shipped: `MarkdownEditor` now vends an `EditorProxy` on iOS, and `iOSLiveEditor` listens on the same `.hnEditorFindQuery` bus the Mac's editor does.
- ✅ **Unlinked mentions in the iOS inspector** — shipped; `computeUnlinkedMentions` runs on iPad and the References tab has all three of its sections.
- ✅ **Settings that had no reader on iOS** — "Increase contrast", Reading width, Editor width, Wrap guide and Sort order all had a control, a `UserDefaults` key and a `CloudPrefs` entry, and nothing on iPad read any of them. Fixed in the second parity pass (implemented.md §25): the WCAG colour maths is now framework-free and shared, the measure is a `MeasuredText` modifier both shells apply, the wrap guide is painted by `ChromeOverlayView`, and sort order moved to `AppearanceSettings` with both trees reading it. *(This is the shape to watch for: not a missing feature, a setting with no reader — which looks identical to a working one until you change it.)*
- ✅ **Open a note in a new window** — shipped on iPad. `AppActions.note.openInNewWindow` was an optional closure left nil on iOS, so the menu item and the palette row both drew, enabled, and did nothing. `iOSNoteWindowView` fills the second scene; the pane it hosts is shared with the main window so the two cannot drift.
- ✅ **The launcher** — `LauncherView` is cross-platform. Recents, Obsidian vaults and saved libraries are reachable on iPad; `library.onOpened` records opens there now, which it never did.
- 🟡 **iPad multitasking / Stage Manager** for the split layout is unverified on a device. The contract test covers a 320pt slice and a 250pt tile headlessly.
- ✅ **Done in an auxiliary window left the app** — fixed by the app opening no windows of its own, on either platform, and by making these surfaces **panes** rather than modals (implemented.md §51.4). The Assistant, Graph, Ask Library and Mind Map are content of the trailing panel beside the editor, which is now a column wherever one fits; New Window and Open in New Window remain on both platforms, because a window someone asks for by name is the only kind the app opens.

---

## 8 · Git / sync

- ⬆️ **Pull / merge** — SwiftGitX exposes `fetch` and `push` but no merge; there is no true "pull." **Unblock:** a merge API in SwiftGitX (or a libgit2 merge of our own).
- 🟠 **Merge-conflict resolution UI** — depends on merge existing first.
- 🟠 **Push smoke test** — HTTPS-token push against a real remote deserves one manual smoke test on a fresh machine before it's advertised; SSH remotes still rely on libgit2's ambient credentials.

---

## 8b · Cloud storage *(reworked 2026-08-15 — see [cloud-native-roadmap.md](cloud-native-roadmap.md) Phase 5)*

**Mounted providers are the front door.** When a provider's desktop client is installed
its storage is already at `~/Library/CloudStorage/<Provider>` as ordinary dataless files,
so that path needs no sign-in, no token, no cache and no sync engine. The direct API is
the fallback for an account whose client is absent. On iOS the Files picker covers the
same ground.

Both live behind one command — **File ▸ Open Collection ▸ from Cloud…**, which opens
**Manage Cloud Collections** (implemented.md §28). The fork is *answered* there rather
than asked in a menu, because which route applies is a fact about the device that
`CloudProvider.installedClients()` can state. Several accounts per provider are
supported; the Keychain is keyed by account id, not provider name.

Everything that was listed here as a gap has been implemented: metadata-first mirroring
with on-demand hydration, delta refresh on all four providers, revision-based conflict
detection with conflicted copies, restore-on-launch, a bounded cache with LRU eviction,
chunked upload past the 4 MB simple-upload cap, collection promotion on iOS, and an
explicit "download and search" escape hatch.

What remains are **constraints of the providers and the platform**, not deferred work:

- 🔒 **iOS cannot open a *synced* cloud folder** — confirmed on a real iPad,
  2026-08-27. The Files picker lists a provider's File Provider location, but
  its folders are not selectable, so "Open Cloud Folder" cannot return one. A
  provider vends either `.folder` or `.directory` and some vend neither in a
  form the picker will hand back (`FolderPicker` already asks for both). The
  **online** path is unaffected and was verified working on the same device
  across all four providers — Dropbox, Box, Google Drive and OneDrive — so an
  iPad reaches any cloud folder by signing in rather than through the synced
  copy. Local folders open normally.
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
- ✅ ~~**A note created locally in a cloud collection is never uploaded.**~~ — fixed 2026-09-27 (implemented.md §51.21), with the rest of its kind: a rename, a move, a copy, a new folder, a delete, a link rewrite, a pasted picture and quick capture into a note not yet downloaded now reach the provider, in the order they were made; the providers gained `move` and `createFolder`.
- 🟡 **Every provider's listing names the content's revision, and only Dropbox's has been seen live.** Box's `etag`, Drive's `headRevisionId` and OneDrive's `eTag` are asked for and parsed since implemented.md §51.36, pinned by fixtures, so a save's conflict check has a revision on every provider; none of the three has been run against a live account.
- 🟡 **Moving and making folders are request-tested, not live-tested.** The four providers' `move` and `createFolder` (§51.21) are pinned by `ProviderMoveAndFolderTests` the way the delta feeds are, and run against a fake as strict as Box and Drive — not against a live account.
- 🟡 **A rename does not rewrite links in a cloud note not yet downloaded.** The rewrite reads the notes the index says link to the renamed one, and a placeholder's links are unknown until it is opened, so its copy on the provider keeps the old name. Downloading every note to rename one is the cost that rules out the obvious fix; a provider-side search for `[[Old name` would find them.

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
- ✅ ~~**The universal (arm64 + x86_64) slice is still verified by hand**~~ — **stale** from 1.3.3: at a macOS 27 deployment target Xcode 27 builds `arm64` alone (`ARCHS_STANDARD`), and macOS 27 runs only on Apple silicon, so there is no x86_64 slice to verify; the release runbook says so ([production.md](production.md)). The website's "Apple silicon & Intel" is 1.3.2's, and changes with 1.3.3's site.
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

*Resolved and moved to implemented.md §51.36 (2026-10-09): incremental parsing converges in prose (3–7 lines a keystroke, not the rest of the note); a heading jump waits for its editor rather than a fixed delay, and clears nothing afterwards; the tag tree nothing showed is gone; `ResumableTreeWalk.run` is `@concurrent`; the app type-checks as Swift 6 with no errors; and `syncDown` and `pruneLocalItems` are gone, their tests' rules held to `syncMetadata`.*

- ✅ ~~**Inconsistent regex construction**~~ — resolved (§20): `try!` is the convention for a literal pattern (a failure is a programming error, visible on the first run). `MindMapView`'s `try?` meant a broken pattern would have rendered every mind map with no links and never said why. The two patterns are *not* interchangeable — the mind map's handles `[[Target#heading]]` — so they stay separate.
- ✅ ~~**Fragile force-unwrap idioms on constants**~~ — resolved (§20) for both sites named. *(The `URL(string:)!` calls in `Core/Remote/*Store.swift` interpolate provider file IDs and are a separate, larger sweep.)*
- ✅ **Undocumented unsafe-concurrency conformances** — *resolved (§7):* `CollectionEmbedProvider`'s `@unchecked Sendable` now carries a lock-invariant justification, and the editor's `nonisolated(unsafe)` observer tokens (`busTokens`, `boundsObserver`) are documented; `MarkdownTextView`'s bounds observer is now removed in `deinit`.
- 🟡 **English-only inline copy** — see §10 (also a maintainability cost).
- 🟡 **Dictation's tap uses the API macOS/iOS 27 deprecated** (`VoiceCapture.swift`,
  `installTap(onBus:bufferSize:format:block:)` — now the only warning in the app's own
  code in a Release build). The replacement, `installTapOnBus:bufferSize:format:error:block:`, reports
  a failure as an error where the old call raises an Objective-C exception the app
  cannot catch (a format the hardware refuses). It is not a drop-in swap: its
  documentation gives a supported buffer of **100–400 ms**, and the app asks for
  4,096 frames — about 85 ms at 48 kHz. It is also `NS_REFINED_FOR_SWIFT`, so the
  Swift spelling has to be read from a build. Change it with a microphone to hand,
  on both platforms, and test that dictation still starts; the old call still works
  on 27.

---

## 12 · Testing gaps

- ✅ ~~**No end-to-end / UI tests**~~ — the four flows named are tested end to end through the real services: an external change against an open note (`ExternalChangeTests`, `ConflictSaveTests`, `WhoseTextWinsTests`), a rename with its links (`EscapedAliasLinkTests`, `CollectionFileOperationTests`, `TabsFollowMovesTests`), Git commit and push to a real bare repository (`GitServiceTests`, `GitPushTests`), and an approved Assistant edit (`AgentToolTests`); `HelloNotesUITests` launches and drives the app on iOS (implemented.md §51.36).
- ✅ ~~**Data-safety paths lack tests**~~ — atomic assistant writes (`AgentToolTests`, `FileIO.replace` in `RoadmapTests`), flush-on-quit and a closing window's save (`FlushRegistryTests`), and rename (`CollectionFileOperationTests`, `EscapedAliasLinkTests`, `CloudCollectionChangesTests`) each have theirs (implemented.md §51.36).

- ✅ **The app suite is hosted by the app, so it is slow and it launches a window.** A macOS
  unit-test bundle needs a test *host*, and there is no flag that stops it. Both consequences
  worth fixing are fixed:
  - ✅ The host used to restore the **user's real library** on launch — 2,000 notes of
    coordinated cloud I/O on the same main actor the `@MainActor` tests run on. The suite sat
    for 20+ minutes looking hung. `TestEnvironment.isRunningTests` now skips the app's launch
    work under a test host; 117 tests complete in seconds.
  - ✅ It opened the app's main window on the person's screen, every run, and took focus.
    `Scene.suppressedUnderTests` keeps a test host's window from opening (`TestHostTests`,
    implemented.md §51.36). A hosted bundle is still slower than a plain one; that is the host.
- ✅ ~~**The two `GitService` tests deadlock the app suite.**~~ The FIFO waited on
  itself. `run()` stored its task in `lastQueued` and then, inside that task,
  `execute()` called `refreshStatus()` — which took `previous = lastQueued`, *the
  very task it was running inside*, and awaited it while that task waited for the
  read to return. A cycle, which is why the main thread sat in `XCTWaiter` with
  the whole worker pool idle, and why a longer timeout would never have helped.
  `execute()` now uses `refreshStatusInQueue()`, which reads without taking a
  second slot. Full suite: **119 tests in 18 suites, 2.3s.**
- ✅ ~~The git tests would also be faster and more hermetic if they did not copy the whole
  `SampleVault` per test~~ — they run on a two-note vault (implemented.md §51.36).

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
  on iOS. ~~Consequence: `iOSContentView` passes `unlinkedMentions: []` to the
  inspector, so the References tab is short one of its three sections on
  iPad.~~ **No longer current**: now that the shell is one `ContentView` for
  both platforms (2026-08-22 merge), the call sites pass
  `unlinkedMentions: references.unlinkedMentions` — the real value, not an
  empty array — so this specific gap reads as closed. Re-verify in the app
  rather than trusting this correction alone; it's a source read, not a
  render check, and this section overlaps work that may still be in flight.

### Small, real dependency — and the replacement already exists in-tree

| File | Needs | Already available |
|---|---|---|
| `UI/SlidesView.swift` | `NSViewRepresentable` | the `UIViewRepresentable` pattern used by `iOSFileViewer` |
| `UI/CloneRepositoryView.swift`, `UI/NewRepositoryView.swift` | `NSOpenPanel` | `FolderPicker`, now in the shared `ContentView` (was `iOSContentView` before the 2026-08-22 merge) |
| `Core/SmartPaste.swift`, `Core/ImagePaste.swift` | `NSPasteboard` | `UIPasteboard` |
| `Core/VisionAlt.swift` | Vision + `NSImage` | Vision ships on iOS |

`GitService` itself is **not** gated — iPad already reads history in the
inspector. It cannot clone, create or configure a repository, which is a UI gap,
not an engine one.

### Corrected: iPad *does* notice external changes

An earlier draft of this audit claimed the iPad never sees a change made
elsewhere, on the evidence that `Core/FileWatcher.swift` is FSEvents and
macOS-only. That was wrong, and wrong in the way audits usually are — it read
the gate and stopped.

iOS has `Core/DirectoryPresenter.swift`: a real `NSFilePresenter` registered on
a private queue, with `presentedSubitemDidChange` and `presentedItemDidChange`
wired into the iOS `Collection.activate` / `deactivate`. FSEvents is macOS-only;
*change detection* is not, and the portable substitute was already there.

What is genuinely coarser: a presenter reports "something under here changed"
rather than FSEvents' path list, so iOS coalesces a burst into one rescan
instead of reconciling named paths. That is a difference in precision, not a
missing feature.

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


## GFM geometric conformance — closed in the corpus, open beyond it

Preview is byte-exact GFM (648/648, plus GitHub-API parity). The *editor* is
measured against it by `Tools/RenderParity --spec`, which lays every spec
example out in both engines and compares the height of what each one paints.

| | agree | named | differ ≥1pt |
|---|---|---|---|
| examples as written (one construct, alone) | **672 / 672** | 0 | **0** |
| the same examples with a paragraph above and below (`PARITY_CONTEXT=1`) | **672 / 672** | 0 | **0** |

`agree` is `compared − failures − named`: a named divergence is never counted as
an agreement, and there are none left to count — `NamedDivergence.reason()`
returns `nil` unconditionally, so the sweep has no way to excuse an example any
more. The rate is printed against the corpus, never against what survived it —
an example that leaves the denominator makes the agreement rate go up for the
wrong reason, and this file's numbers were wrong in exactly that way for most of
their life.

**The denominator is 672, and nothing is excluded from it.** It used to read 645
and 633, and every one of the missing examples turned out to be the instrument
rather than the corpus. Three findings, written up in full in implemented.md
§23:

- The sweep matched an opening fence of ` ```… example ` and had therefore
  never read the twenty-four GFM **extension** examples — the whole Tables
  section included, which is the construct with the most geometry in it. It
  printed "648 examples", and 648 is what `spec.txt` appears to hold if you only
  count what you already match.
- The page's height was `scrollHeight - paddingTop - paddingBottom`, a scroll
  extent, where the editor answers with `usageBoundsForTextContainer.height`, a
  *painted* bottom. On a well-formed page the two agree, which is why the wrong
  one looked right; on an example that leaves a tag open, the re-parented
  trailing `<p>` keeps a 16pt bottom margin that nothing paints in, and the
  editor was charged for it. Measuring the painted bottom instead brought the
  fifteen context exclusions and the three named `#126`–`#128` ones back with
  real numbers.
- The corpus's image targets resolved nowhere **on either side**, so the
  eighteen −4.00pt "broken-image placeholder" failures below were two fallbacks
  being compared to each other. See *Disproved* below.

**Every example number recorded in this file before that change is stale by up
to twelve.** Reading the extensions renumbered everything after the first table
example: the old #568 is #580.

**Every section is now exact end to end in both sweeps**, extensions included,
with nothing named and nothing excused. The three examples that used to carry a
name are written up in implemented.md §23; the short version is that all three
reasons were true statements about one engine and false statements about the
comparison, and closing them changed what the *harness* rendered twice and what
the editor rendered once.

**672 of 672 is necessary and it is not sufficient**, which is why the numbers
above are no longer the last word. `RenderParity --docs` lays out 58 whole
documents — `Tools/RenderParity/Documents` — at 800, 560 and 1200pt, and
`scripts/render-parity.sh` gates on it. It failed 9 of its first 35 documents
with every spec example already agreeing, and nineteen distinct causes came out
of that; six of them were horizontal errors that only become heights when
something wraps, and two were +0.00pt at every width and visible only in a
picture. Anything listed as open below is open *there*, not in the corpus.

### Disproved — three things this file recorded as impossible

Each was a claim about the platform, and none of them had been put to the
platform. They are kept here rather than deleted because the shape of the
mistake repeats: a limit was inferred from one failed attempt and then written
down as a property of TextKit, of WebKit, or of the corpus.

**"The Images section is one cause, eighteen times — WebKit's broken-image
placeholder, and matching it would fit the editor to one browser's fallback."**
Wrong about which cause. The sweep loaded every page with `baseURL: nil` and
gave the editor no image base either, so neither side drew an image: WebKit drew
its placeholder, the editor left the `![foo](/url)` source on screen, and the
harness compared the two fallbacks. It was never a question about placeholders.
`Tools/RenderParity/Fixtures` holds the twenty-by-twenty squares the corpus
points at, served through a `parity:` scheme whose root *is* that folder —
because half the targets are root-absolute (`/url`), and a browser resolves those
to `file:///url`, which no harness can create. The section went from 18 failures
to 3, and the three that are left are a different thing entirely (an inline
replaced element inside a text line, below).

**"An h1/h2 ending a note loses its rule inset, and it cannot move into the line
height."** True about the line height, and it was never the only place to put it.
`paragraphSpacing` is dropped on the document's last paragraph — correctly, since
GitHub zeroes `:last-child`'s margin-bottom — but a rule's inset is
`padding-bottom`, which is *inside* the box, and the fragment **is** the box.
`NSTextLayoutFragment.bottomMargin` reserves it there: once per fragment however
many visual lines it wraps to, which is exactly the property `minimumLineHeight`
lacks. Eight examples, and the user-visible half was a note ending in an h1
drawing its rule below `usageBounds` — off the end of the note.

**"A line break inside an inline construct costs Edit a line and Preview none,
and TextKit cannot close that gap."** The paragraph went on: "concealing it is
not possible either — concealment sets width, not line-breaking behaviour", and
"the only route is rewriting the user's text". Both halves are false in this
codebase's own source. Concealment here sets a **line height**
(`BlockBoxes.collapsedLine`), not a width, and the editor already stands a
multi-line construct in a single visual box that way — every table, every
`$$…$$`, every raw HTML block, via `EditorDocument.collapse`. The third route is
the one the editor takes a dozen times a note: leave the source in the storage,
conceal it, and draw the rendered fragment. So the eleven remaining joins are
*not attempted*, which is a different sentence from *impossible*; what they need
is a rendered fragment for a joined inline run, i.e. a feature. They are listed
under **What is left** with their measurements.



**`li code { line-height: 1 }` reaches a `pre > code`, and nothing shows it.**
The rule exists so an inline `` `code` `` span cannot inflate the line it sits
on. It has the same specificity as `pre code { line-height: inherit }` and is
written after it, so inside a list item it also wins for the `<code>` of a
fenced block: measured with `PARITY_CSS=line-height`, 13.6px where the same
fence at the top level resolves 20px. Moving the `pre code` rule below it fixes
the computed value and moves **no box at all** — across the whole corpus, not
one example changed — because the item's own marker sits in that line box and
is taller than either. So the fix was reverted rather than shipped with a story
attached to it. It is recorded here because the overlap is real and the day
something else changes that line box it will stop being invisible.

**The parser cannot reopen a container, and the geometry no longer needs it
to.** `* foo` / `  * bar` / blank / `  baz` is one item holding a paragraph, a
nested list and a second paragraph, which also makes the outer list *loose*.
Teaching the blank-line rule to look for an *enclosing* item was tried and
reverted, and that half stands: blocks are a flat, non-overlapping tiling, so
re-opening `foo` emits a second `foo` block spanning the nested one and drops
the open `bar` block on the floor — a probe showed exactly that, two `listItem`
blocks both starting at line 0 and `bar` gone.

What was wrong was the conclusion that the 16pt therefore could not be
recovered. It was recovered at the *box* layer, where the question is not "which
block is open" but "which list does this block belong to":
`BlockBoxes.membership(of:in:)` answers `sibling` / `interior` / `outside` from
content columns, and `  baz` is `interior` to `foo` whatever the parser did with
it. The same predicate fixed a disagreement nobody had noticed — `box(at:)`
compared content columns while `listIsLoose` compared `indent / 2`, so `1. a` /
blank / `  2. b` was one list to one of them and two lists to the other, and a
genuinely loose list was scored tight. Lists and List items are both at zero
failures now. The parser's model limit is real and is recorded here; it is not
what that measurement was.

**The `<script>` / `<style>` collapse is done for closed blocks, and
deliberately not for unclosed ones.** A closed one is self-contained, renders as
an embed of nothing, and folds away: measured in context at base 16 / width 800,
`<style>`, `<script>` and `<script type=…>` all sit within 0.6pt of the page.
(A `KNOWN GAP` comment claiming this had been backed out over margins 10–23pt
short survived in the source long after it stopped being true; it has been
corrected.)

An **unclosed** one was recorded here as "the remaining +136pt, spec #142", on
the reasoning that CommonMark runs the block to the end of the document, so the
browser puts everything below `<style` inside the element and the page goes
blank from there down. It does not, and that was the whole of the difference:
GitHub's tagfilter escapes the leading `<`, so the browser is handed
`&lt;style …` and makes **text** of it — one whitespace-collapsed run, with no
element anywhere. Which is why `.markdown-body > *:last-child` then lands on the
*paragraph above*, and why the editor was 16pt long there rather than 136 short.
`BlockBoxes.producesElement` models it now: #142 measures +0.05pt in context and
+0.03 bare. See implemented.md §23.

The result is not fitted to one size or one column width: the sweep is reported
at base 16 / width 800, and `scripts/render-parity.sh` re-runs the hand-written
sample across five bases and three widths on every change — worst per-block
drift 0.03pt — and then the 58 real documents at three widths of their own.

The second row is the one worth acting on. A spec example is a one-construct
document, so it is measured at the document's edges — and the two engines define
those differently (below). Wrapping asks the question a note actually poses.
`--measure "<markdown>"` answers it for a single snippet, which is how each of
the fixes below was pinned down.

### Closed in the container-interior pass

Container blocks got their interiors, one construct at a time, without giving up
the flat block list. (What the two waves after it closed — the harness findings,
list membership and looseness, reference links, tables and
`NSTextLayoutFragment.bottomMargin` — is written up in implemented.md §23.)

- a blank line no longer ends a list item when what follows is indented to the
  item's content column (CommonMark's rule) — and the blank is styled as the
  paragraph margin it stands for
- indented code *inside* a list item gets the `pre` box, padding and band
- an ATX heading inside a blockquote gets its own line height, font and rule
  inset (`> # Foo` was a quoted line of body text: 43pt short)
- lazy continuation — `> bar` / `baz` is one quoted paragraph
- a lone `-` with no paragraph above it is an empty list item, not text
- looseness is a property of the whole list again (the parser change had hidden
  it: with the blank *inside* an item, no blank block separated the items)
- raw HTML: no margin of its own, the fragment's own margins measured with
  sentinels (the stylesheet zeroes `:last-child`'s, and a one-element fragment
  *is* the last child), and a wrapper made only of tags collapses like a
  reference definition instead of showing markup the reader never sees
- an empty blockquote is a box of no height and no margin
- a reference definition collapses on its own even when it shares a block with
  a paragraph, or sits inside a list item. The cmark inversion cannot see those
  — a container node covers the definitions consumed between its children, and
  cmark-gfm has no node for a definition to ask about — so `ReferenceDefinition`
  recognises the one construct outright, and only where a definition may legally
  start: a block's first line, after a blank line, or after another definition.
  `foo` then `[bar]: /url` stays text, because a definition cannot interrupt a
  paragraph and hiding that line would delete something the reader sees
- an angle-bracketed destination ends at its `>`, and a title must be separated
  from it by whitespace — `[foo]: <bar>(baz)` is a paragraph, and treating it as
  a definition *hid a line of text*
- an empty ATX heading has no line box at all (`<h2></h2>` keeps only its
  margins and, for h1/h2, its rule)
- tabs: expanded to the next multiple of four, with index and column counted
  separately — conflating them read `\t\tbar` from the middle of the word — and
  a tab may separate a list marker from its content
- CommonMark's content column is the marker plus **one to four** spaces, not
  the marker plus one
- an empty list item cannot interrupt a paragraph; a setext underline does not
  apply over reference definitions
- indented code inside a blockquote gets the `pre` box
- a `>` line opening or closing a quote separates nothing and collapses
- an empty h3–h6 has self-collapsing margins (no height, padding or border, so
  its own top and bottom margins merge); h1/h2 keep both, a border stops the
  collapse. `gapBetween` is now the single place that answers "what separates
  these two blocks", because `gapAfter` and `gapShares` used to compute it
  separately and a rule added to one was silently missing from the other —
  which of them applied depended on whether the writer left a blank line
- a nested list inside a continued item is its own block again, so the depth
  machinery spaces it (swallowing it into the parent hid that structure)
- a setext underline may carry trailing whitespace — `Foo` over `   ----   ` is
  an h2, not a paragraph and a rule
- a backtick fence's info string may not contain a backtick, so ``` ``` ``` on
  one line is a paragraph holding a code span, not a fence that swallows the
  rest of the note
- an **unclosed** fence has no closing line: its last line is code, not a
  padding band, and the box's bottom padding comes from that line's own height
- a thematic break needs three *dashes*, not three characters — `-   ` is one
  dash and three spaces, which is an empty list item
- a bare wrapper tag inside a list item or a quote (`- <div>`) collapses, while
  a line carrying anything that draws (`<img>`, `<br>`) or any text does not
- a reference definition may run over several lines (`[` / `foo` / `]: /url`),
  so the longest span that parses as one wins
- inside a quote, a box opens only where a line goes *deeper* than the paragraph
  has already been. Fewer markers than the line above is lazy continuation — a
  continuation line may carry no `>` at all — so `>>> foo` / `> bar` / `>>baz`
  is one paragraph, not three boxes with margins between them
- lazy continuation is a *paragraph* rule: `>     foo` holds a code block, so
  the unprefixed line under it starts something of its own — and an indented
  line under an open quote paragraph is continuation text even when it looks
  like a list marker
- `applyQuoteBars` is given the unrendered ranges, so a reference definition
  inside a quote stays collapsed instead of being written back at full height by
  the pass that draws the bars
- an ATX heading, a **setext** heading and a thematic break inside a *list item*
  get their own boxes, as they already did inside a quote. A line of dashes
  indented to the item's content column with text above it underlines that text
  rather than ruling off the list — the spec gives setext precedence when a line
  could be read either way
- a setext heading's paragraph may open with reference definitions, so the
  heading covers only the text below them
- a code run inside a list item extends over blank runs of *any* length; looking
  one line ahead split one code block into two, each paying for its own padding
- indented code may begin on the item's *marker* line (`1.     code`), measured
  past the marker so the `1.` stays a marker and not part of the code box
- a quote holding nothing but a reference definition is as much "not a box" as
  an empty one, so `box(at:)` takes the unrendered ranges
- **list bullets** were centred on the *line box* and drawn from the concealed
  marker's character position: a half-leading too high and 6pt too far right.
  They belong at the x-height centre, half the list indent left of the text.
  Found by dumping both sides with `--png` and counting pixels — every height
  measurement was green throughout
- **quote bars** were drawn per line at fractional y, leaving a hairline seam at
  every line break where the rendered page draws one unbroken border. Snapped to
  whole points so consecutive segments meet. Measured: a 1px break at row 2073
  of a 2× dump, gone afterwards
- **a rendered image reserves the baseline below it.** An `<img>` is inline: it
  sits on the text baseline, so the line box is the image plus what the strut
  hangs beneath — a half-leading and a descender, 6pt at 16pt body. Tables,
  diagrams and formulae are block-level and get none. Only visible with an image
  that *resolves*, which no spec example did until the fixture folder existed; a
  standalone image now lays out at 146.01 against Preview's 146.00

### Found by looking, not by measuring

Five defects were fixed this pass that every height measurement called fine —
which is the argument for the gate below existing at all:

- list bullets 6pt too far right and a half-leading too high
- quote gutters seamed at every line break
- `> - item` not rendered as a list at all: raw dash, no bullet, no indent
- the `>` visible *inside* a quoted code block, set in the code font
- the code band painted through the quote bar instead of starting after it

**Headings inside a list item** are done — see implemented.md, including the
one limit this section used to list. When the *document's first block* was a
list item opening with a heading, that heading's top margin went into the line
box, and a line height applies to every **wrapped** visual line: the margin was
paid once per line, +24.01pt at an 800pt pane, +48.01 at 560, +72.01 at 420.
The repair recorded here — "the fragment carrying its own top inset" — is
exactly what closed it, and by then the mechanism already existed for the loose
item beside it (`openingMarginAttribute` / `RenderedBlockFragment.topMargin`)
and had simply not been carried across. The lesson is the narrow one: a
`KNOWN LIMIT` comment with a working mechanism next to it is a to-do, and the
gate that caught it was the document sweep run at a width nobody had gated on.

### The appearance gate

`render-parity.sh` used to compare *heights* only, and stayed green through
three defects you could see at a glance. It now ends with
`RenderParity --chrome`, which renders both sides and measures the marks
themselves: the first list bullet's height above its own baseline and its
distance left of its own text, and the number of breaks in the first quote's
gutter. Everything is relative to something in the same image, because the two
dumps sit at different absolute offsets.

Two things that took a second attempt, so they are not repeated:

- **Anchor on structure, not on row numbers.** The first version looked in fixed
  row bands and reported failures on chrome that was already correct. A gate
  that cries wolf is worse than no gate. It now finds the bullet by grouping
  rows into bands and taking the first whose leftmost mark is indented past the
  paragraph margin but short of the list's text column.
- **Count the breaks in a bar; do not measure the longest.** A quote's gutter
  has one legitimate 20px gap — the margin between its own paragraphs — so a
  one-pixel seam at every line break hides completely behind it. Measuring the
  longest gap passed a bar that was visibly striped; counting catches it.

Both were validated by reintroducing each defect and confirming the gate fails
(bullet Δ+4.0pt; quote bar 1 break against Preview's 0), then restoring.

### What is left

Nothing, in the corpus — 672 of 672 in both sweeps, with nothing named. The five
groups this section used to list are all closed; they are kept here in one line
each so the shape of each fix stays findable, and written up in full in
implemented.md §23.

| was | examples | how it closed |
|---|---|---|
| the element-layer join | 11 | a content element spanning both source lines, with the newline folded to a space in the element and left alone in the storage (`JoinedLines.swift`) |
| an inline replaced element inside a text line | 3 | an attachment on the image's first character, and dropping the `maximumLineHeight` clamp on a paragraph that holds one |
| raw HTML blocks that do not stand alone | 8 ctx / 12 bare | rendering the whole balanced span rather than the block, refusing table-internal fragments WebKit discards, and a third answer in `isTagsOnly` for a tag run that reaches the end of the input |
| edge-of-document cases | 8 bare | a box that paints nothing is a box of no height *and* no margin — one rule, not eight special cases |
| the h1/h2 rule at EOF | 7 bare | `NSTextLayoutFragment.bottomMargin`, which is per fragment however many lines it wraps to |

The two that used to remain were *named* rather than fixed — an Obsidian embed,
and a page whose last element is not the one `:last-child` selects — and both
turned out to be reasons about one engine rather than about the comparison. They
are closed and written up in implemented.md §23, and the sweep can no longer
name anything: `NamedDivergence.reason()` returns `nil`, and the two JavaScript
shape flags that fed it were deleted with it, so a regression on exactly those
shapes comes back as a failure rather than as an excuse.

### Still open — each with the command that reproduces it

None of these is visible to the spec corpus; two of them are visible to the
document gate at 420pt, which is why that width is measured and printed on every
run of `scripts/render-parity.sh` even though it does not fail the suite. Every
entry is measured rather than asserted, because the three divergences this file
used to *name* were all excuses that nobody could check.

- **Display maths.** `$$ … $$` measures **edit 132.00 / preview 152.00,
  −20.00pt**. It is not a box-model difference at all: the editor draws the
  formula with SwiftMath and `GFMRenderer` attaches no maths extension, so
  Preview prints the literal `$$`. Two *contents*, not two measurements. What
  closes it is one maths engine for both surfaces — the move
  `HTMLBlockImageRenderer` already makes for raw HTML — which needs a LaTeX
  renderer inside the page and is a dependency decision. Deliberately **not**
  closed by making the editor's fallback match the page: that would turn the
  gate green over an app that still diverges.
- **A table wider than its pane — mostly closed, and not entirely.** Edit
  scaled the whole bitmap down where Preview wraps the cell text, and the
  shortfall was edit-shorter-than-preview every time. `GFMTableGeometry.fitted`
  replaced the proportional bitmap scale with column shrinking and wrapped row
  heights — CSS's rule reduced to its two bounds, the width a column *wants*
  against the width it *needs*, with the deficit shared out in proportion to
  how much each has to give, and overflow rather than clipping past the
  minimums. That took the 420pt document run from 5 of 58 short to 2.
  **One table shortfall is left**, and it is worth stating precisely because
  the run's headline no longer separates the two causes:

      swift run --package-path Tools/RenderParity RenderParity \
        --locate Tools/RenderParity/Documents/01-readme.md --width 420

  bisects `01-readme.md` (−43.89 in total) into **two** blocks, not one: the
  ```swift line at −20.00, which is the solidus case below, and a three-column
  `| Flag | Default | What it does |` table at **−23.96**, which is this one.
  `README.md`'s −19.91 is solidus only. So the table work closed three of the
  four documents it was aimed at and left one grid measuring short at 420;
  this entry closes when that block does.
- **TextKit breaks a line after `/` and WebKit does not.** The cheapest real
  case is one line of Swift at a 420pt pane:

      ```swift
      .package(url: "https://example.com/widget-kit", from: "1.0.0")
      ```

  **edit 72.00 / preview 92.00, −20.00pt** — two lines against three, +0.00 from
  460pt up. At roughly 43 columns WebKit breaks at the spaces only
  (`.package(url:` / `"https://example.com/widget-kit", from:` / `"1.0.0")`)
  while TextKit breaks inside the URL after a solidus and fits it into two. The
  discriminator: the same line with `-` in place of the `/` is +0.00 at every
  width, because both engines break after a hyphen, and with no separator at all
  it is +0.00 too. So it is **one break opportunity**, not a wrapping model.
  Neither side can be told to match the other by a declaration:
  `overflow-wrap: anywhere` is already on `pre` and `pre > code` and does not
  help — the URL token *fits* on a line of its own, so the browser never breaks
  inside it — while `word-break: break-all` and `line-break: anywhere` would
  break far more than TextKit does rather than less, and `lineBreakStrategy = []`
  on the editor side removes nothing. Giving the page the opportunity means
  emitting `<wbr>` into cmark's output, which is the byte parity
  `GFMRenderTests` holds, so there is no repair today. It is why the document
  gate **reports** 420 rather than failing on it: the run prints
  `note  documents width 420 … 56 agree, 2 differ` with both document names and
  both deltas on every run, so a new shortfall there is a new line and not a
  silence. A gate that fails every run for a reason nobody can act on is one
  people learn to ignore — this repository has been round that loop once already
  with the chrome check.
- **A wikilink is underlined in Edit and not in Preview.** `[[wiki]]` measures
  +0.00pt against the page and is not the same picture: `StyleApplier` gives a
  non-embed wikilink a live `.link` (`hellonotes-wiki://…`, for hover and click)
  and nothing sets `linkTextAttributes`, so AppKit underlines it for free, while
  `github-markdown-css` underlines `a` on hover only. An ordinary
  `[text](url)` escapes it because the `.link` goes on the concealed `(url)`
  run, not on the visible text. The repair is one `linkTextAttributes`
  assignment, and it changes every link in the editor — a decision about
  affordance rather than about parity.
- **Note transclusion diverges in a real vault, and only there.**
  `![[Some Note]]` resolves in Edit through `BlockRenderAdapter` →
  `CollectionEmbedProvider` → a `NoteTranscluder` card; in Preview
  `NoteMarkdown.prepare` turns it into `![](Some%20Note)` and WebKit draws a
  broken-image box. `BlockRenderAdapter` decides note-vs-image by file
  extension, which `NoteMarkdown` cannot do — it has no vault. Closing it means
  giving `prepare` a resolver and inlining the target's Markdown, which is a
  feature. Invisible to both gates: neither has a vault.
- **Export and print still render the raw note.** `HelloNotes/UI/EditorExport.swift`
  calls `GFMRenderer.page` on the note's own text at six call sites, so an
  exported or printed note keeps its literal `![[…]]` and its raw YAML front
  matter. Same class as the `![[foo]]` divergence — a surface that renders a
  note without taking the step that turns a note into GFM — but export is
  neither Edit nor Preview, and whether front matter belongs in an export is a
  product decision.
- **`StyleSpec.appendInlineRuns` still parses inlines with an empty reference
  map,** so the hand-written styler — the path used above
  `StyleApplier.gfmOverlayMaxLength` — does not colour or conceal reference
  links. The cmark overlay does for every document under that gate. Threading
  the map through would start concealing `][ref]` tails, a wrap-width change in
  the large-document path that no gate here measures.
- **One edge case introduced knowingly.** Concealing a list item's own indent
  inside a nested code box leaves near-zero-width characters at the head of the
  line, and TextKit treats them as a first token: where a *single* token is
  longer than the whole column, the line is moved down before being broken and
  the editor makes one more line than the page (+20pt at exactly-overflowing
  tokens). Real code lines have spaces early on and are unaffected; it replaced
  a defect that fired on the common case (a 61-column line was two lines in Edit
  and one in Preview at 640pt).

Two things seen in the PNG dumps that are **not** defects, recorded so they are
not re-investigated: the harness's editor has no code highlighter attached, so
its listings are monochrome where Preview's are coloured (the app supplies
`CodeHighlighterAdapter`); and Preview squeezes CJK punctuation where Edit sets
it full-width, which no height can see and which is a font-feature difference
rather than a box one.
