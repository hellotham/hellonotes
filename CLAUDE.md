//
//  CLAUDE.md
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

# HelloNotes Architecture Rules
- Target Environment: macOS 26.5+ / iOS 26.5+ / Swift 5.10+ / Xcode 26. The floor is high on
  purpose: the Intelligence features run on Foundation Models, and the Quick Look extensions
  already required 26.5 while the app claimed 15.0 — an app cannot promise an OS its own
  embedded extensions refuse to run on.
- Multiplatform: One shell, `AdaptiveShell`, chosen by the *axis of abundance* (width/height), never by device — a Mac window and an iPad of the same size get the same layout. See `docs/layout-architecture.md`.
- The window has **exactly one collapsible column**: a sidebar holding a *single tree* — Recents and Bookmarks pinned at the top, then one root per open collection, expanding into that collection's folders. SwiftUI only gives a correctly-placed sidebar toggle to column one, which is why everything navigational lives there and **no command may live inside it** (a hidden command is an unreachable command). Commands go in the toolbar: search leading, New Note / Open Quickly centre, the five inspector toggles trailing. See `docs/shell-chrome.md`.
- Anything keyed on a collection (the outline cache key, drop targets, "New Note" at a root) reads the sidebar's selection. **A cache key must name everything the cached value depends on** — keying the outline on one collection made opening or closing another invisible.
- State: Use the `@Observable` macro exclusively. DO NOT use legacy `@ObservableObject` or `@StateObject`.
- Data Source: No CoreData. The local file system directory is the absolute source of truth.
- Git Operations: Use `SwiftGitX` (Import `SwiftGitX`) utilizing native Swift async/await concurrency.
- Build Verification: After writing code, use the Xcode MCP tool to run a compilation check to ensure 0 errors.

# Layout
- App: `HelloNotes/` — `Core/` (parsing, FileIO, indexes), `State/` (@Observable services), `UI/`, `LLM/`; `UI/Shell/` holds the layout contract; `MacContentView` / `iOSContentView` supply its slots.
- Editor: `Packages/NotesEditor` (MarkdownCore / MarkdownEditor / GFMRender) — the app's only editor; the old engine fork is gone.
- Website: `website/` (Astro 7 + Tailwind 4) — see `website/CLAUDE.md` and `docs/website.md`.
- Docs: shipped work → `docs/implemented.md`; backlog only → `docs/unimplemented.md`.

# Commands
- Build (macOS, full CLI build): `xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes build` — the Xcode MCP check above is the quick per-change gate; use this for full/Release verification.
- Editor tests (macOS): `swift test --package-path Packages/NotesEditor`
- Editor tests (**iOS — run these too**): `cd Packages/NotesEditor && xcodebuild test -scheme NotesEditor-Package -destination 'platform=iOS Simulator,name=HN-iPad'` (~35s, headless, no app launch — 379 tests in 29 suites). `swift test` only ever builds the package for macOS, so the UIKit half went untested for its whole life — that is how a `UITextView` showing a document it believed was empty, a zero-width keyboard bar and a link tap that ate the caret tap all shipped at once. Create the device once with `xcrun simctl create HN-iPad com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4-8GB com.apple.CoreSimulator.SimRuntime.iOS-26-5`.
- **Look at the iOS app without the user's device**: `xcodebuild build -destination 'platform=iOS Simulator,name=HN-iPad'`, then `xcrun simctl install HN-iPad <app>`, `xcrun simctl launch HN-iPad com.hellotham.HelloNotes`, and `xcrun simctl io HN-iPad screenshot out.png` — which is readable. A whole iPad session was shipped blind (a keyboard bar that never rendered, a zero-width one, five inspector toggles that could not work at that width) because nobody looked. `simctl` has no tap injection, so driving the UI still needs the live panel — which needs `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` from the user.
- Is it running on the device? `xcrun devicectl device info processes --device <id> | grep "HelloNotes.app/HelloNotes"` — **capital H**. A lower-cased pattern matches nothing and reads exactly like a crash-on-launch; an hour went into diagnosing a crash that never happened. Cross-check against `--domain-type systemCrashLogs`: no new `.ips` means no crash, whatever the process list appears to say.
- **The tests assert 648 of the corpus's 672 examples; the sweep asserts all 672.**
  `GFMSpecTests` and `LiveEditorConformanceTests` match an opening fence of
  `` ``` example `` only, so the 24 **extension**-tagged blocks are silently
  skipped — 8 `table`, 11 `autolink`, 2 `strikethrough`, 1 `tagfilter`, 2
  `disabled`. Tables and strikethrough have therefore never been checked for
  HTML byte-parity at all, only for geometry (`RenderParity` reads all 672).
  `spec.txt` holds 672 blocks; `grep -cE '^`+ example'` counts them. Widening
  those two parsers is the fix, and it may well surface real failures — the
  geometry sweep found six the day it started reading them.
- Layout contract: `xcodebuild test -project HelloNotes.xcodeproj -scheme HelloNotes -destination 'platform=macOS' -only-testing:HelloNotesTests/ShellContractTests` (~2s, headless — run it after any shell or representable change).
- **Edit ≡ Preview**: `./scripts/render-parity.sh` — lays the same note out in TextKit and in WebKit, offscreen, and fails if any block drifts more than a point. Three gates in one: a hand-written sample at 5 text sizes × 3 widths, **58 whole documents at 1200 / 800 / 560pt** (plus 420 measured and reported without failing — see the bullet below), and a chrome check that measures the marks themselves. Run it after touching `GFMBoxMetrics`, `StyleApplier`, `BlockBoxes`, `GFMLiveStyle` or `GFMPage`. It is a script, not a test, because a `WKWebView` never finishes loading under `swift test` *or* under XCTest in the app host — both were tried. See implemented.md §23.
- **The real-document gate**: `swift run --package-path Tools/RenderParity RenderParity --docs --width <w>` over `Tools/RenderParity/Documents` — READMEs, meeting notes, kitchen sinks, one document ending in each awkward thing and one starting with it. It found nineteen defects on its first outing with all 672 spec examples already agreeing, and it is the gate to run when a change is about *documents* rather than constructs. Bisect one with `--locate <file>`, which lays out every prefix a top-level block at a time and marks the row where the delta moves. **Width is a dimension of coverage, not a configuration**: six of the nineteen were horizontal errors that only become heights when something wraps, and two more (a heading's opening margin paid per wrapped line, a 900pt cap on every rendered embed) were exact at 800 and wrong at 420 and 1200. 420 is measured and **reported without failing**, because it is the only width where a four-column table stops fitting (so the only place the overflow layout is exercised) and also the only width where an open divergence fires — TextKit takes a line-break opportunity after `/` and WebKit does not, which is 20pt on any wrapped code line holding a URL. Both failing documents print with their deltas on every run, so a new shortfall there is a new line; if that listing ever names more than the two, something regressed.
- Live verification: run `scripts/relaunch-debug.sh` first — plain `open` reuses a stale instance and you test the wrong binary.
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
- Secrets: `Config/Secrets.xcconfig` (git-ignored) holds provider keys; the DMG bakes in whatever it held at build time. Never touch the repo-root `.env`.
- A UIKit control added onto a `UITextView` arbitrates against the view's own recognisers. `cancelsTouchesInView = false` governs touch *delivery*, not gesture *arbitration* — a bare `UITapGestureRecognizer` wins and silently eats the caret tap. Give it its own delegate object returning `shouldRecognizeSimultaneouslyWith: true`; never make the text view that delegate, it is already UIKit's for six recognisers of its own.
- Never swap `NSTextContentStorage.textStorage` under a live `UITextView`. AppKit tolerates it; UIKit keeps a second reference and the two disagree about the document's length, which throws `NSRangeException` from inside UIKit with no app frames on the stack. Build the content storage / layout manager / container first and pass the container to `UITextView(frame:textContainer:)`.
- A layout fragment's **rendering surface stops at its line boxes**. Chrome drawn
  *below* the text — an h1/h2 rule sits in the heading's bottom margin — is
  clipped away silently: the attribute is there, the metrics are right, the
  space is reserved, and no pixels appear. Grow `renderingSurfaceBounds` to
  reach whatever you draw. (A thematic break, drawn *inside* its line box, is
  never affected, which is what makes the two look inconsistent in one list.)
- **One box model, two renderers.** Edit lays a note out in TextKit and Preview lays it out in WebKit; they agree only because both measure from `MarkdownCore/GFMBoxMetrics.swift`. Never write a spacing, indent or line-height number into either side — add it there, where the editor reads it as points and `GFMRenderer.page` emits it as CSS. Two rules TextKit does not have: **CSS margins collapse** (the gap is `max`, not the sum — ask `GFMBoxMetrics.gap(after:before:)`), and `paragraphSpacing` ends every *paragraph*, so a block's gap goes on its **last line** only. Line heights are whole points because WebKit does not use a fractional one as given.
  A third: **CSS centres the glyphs in the line box and TextKit does not** — a pinned
  `min`/`maximumLineHeight` puts *all* the spare height above the text, so every line in
  Edit sat a half-leading (3pt at 16pt) below its Preview twin while the boxes agreed to a
  hundredth of a point. `BlockBoxes` corrects it with a **negative** `.baselineOffset`, and
  what that corrects is the *reported* baseline, not the ink — under a pinned line height
  no `.baselineOffset` of either sign moves a glyph (see the `.baselineOffset` bullet
  below). That is enough here, because every box measurement and every piece of chrome is
  derived from the reported number. The content height in that calculation is
  `round(ascender) + round(-descender)`, which is what *both* engines measured — the exact
  sum is 0.4pt out. Never "fix" this with `lineSpacing`: it shortens the line box, and
  chrome drawn from `typographicBounds` then stripes.
- **TextKit drops the trailing `paragraphSpacing` of the document's *last* paragraph; space
  that must survive that goes in `NSTextLayoutFragment.bottomMargin`.** The drop is right
  for a margin — GitHub zeroes `.markdown-body > *:last-child`'s margin-bottom too — and
  wrong for anything else parked there, and three things were parked there.
  **(1) An h1/h2's rule** is `padding-bottom: .3em` plus a border. Padding is *inside* the
  box and the fragment *is* the box, so `bottomMargin` is padding-bottom and
  `paragraphSpacing` is margin-bottom — which is precisely why one must survive at EOF and
  the other must not. `RenderedBlockFragment.bottomMargin` reserves it off
  `headingRuleAttribute`; `StyleApplier` only marks the line. A note ending in an h1 used to
  stand ~11pt short and clip its own rule off the bottom.
  **(2) An `<hr>`'s bottom margin** really is a margin, but `hr::before`/`hr::after` are
  `display: table` — a clearfix — so it never collapses out to the `:last-child` that gets
  zeroed. A rule ending a *list item* keeps its 24pt, a top-level one does not:
  `StyleApplier.keepARulesBottomMargin`.
  **(3) A note ending in a table/diagram/formula/HTML block** reserved no band for its
  image — fixed earlier by making the band the line box at EOF.
  `bottomMargin` is counted once per **fragment**, i.e. per paragraph, however many visual
  lines it wraps to. That is the whole reason it works where the tempting repairs do not:
  `minimumLineHeight` is only safe over *concealed* text, because a line height applies to
  every **wrapped** line and `StyleApplier` styles without knowing the pane width (an h1
  wrapping to three lines gained the inset three times); and `lineSpacing` shortens the line
  box, so chrome drawn from `typographicBounds` stripes. Both were tried, measured, reverted.
- **672 of 672 is necessary and not sufficient — lay out a real page and look at
  it.** The corpus tests constructs one at a time; every document is a
  combination. With every example agreeing, one README-shaped note still measured
  +7.06pt, and all of it was a ```bash fence written under a numbered step: an
  over-broad `li code` CSS rule that only shows when no list marker shares the
  code's first line box, and fence delimiters that were never concealed inside a
  list item, so the info string was drawn *inside* the code box. Both were
  invisible to 672 examples and to every height measurement. That shape is in the
  sample `render-parity.sh` gates, and the general answer is the **document
  gate** above: 58 real notes at three widths, which found nineteen more the
  first time it was run and two more the first time it was run *wider*.
- **A reason beside a divergence must name something about the *comparison*.**
  The sweep can excuse an example by naming it (`NamedDivergence`), and three
  examples were excused for years by reasons that were true about one engine and
  silent about what the two engines were each asked to render: "cmark has no
  `![[…]]`" — which never asked what Preview hands cmark (the app rewrites it
  first, so the two surfaces had always agreed and only the harness had not);
  "the editor would have to know whether the next block produces an element" —
  which it already did, one file over; and two measurements stated as a matter of
  taste when the question had an answer. A reason with nothing in it to check is
  unfalsifiable by construction. `NamedDivergence.reason()` now returns `nil`
  unconditionally and the shape flags that fed it are deleted; if something needs
  excusing again, write the excuse about the comparison or it is not one.
- **A gate that keeps its own copy of what it is grading measures the copy.**
  Three separate defects were this: the harness built its preview page without
  the note→GFM step the app takes (`NoteMarkdown.prepare`), it carried its own
  `paintedContentBottom` beside the package's, and it mirrored the editor's
  `min(width, 900)` embed cap — so both sides shrank a wide picture and agreed
  with each other about a page that does no such thing. Each rule now lives once,
  in the package, and the harness calls it.
- **Height parity is not appearance parity.** `--spec` compares *heights*, so it
  cannot see a glyph drawn in the wrong place. `RenderParity --png <dir>` dumps
  both sides as images; `/tmp/crop` + a bright-row scan turns "looks off" into a
  pixel count. That is how the list bullets were found sitting a half-leading
  high and 6pt too far right, and the quote bars seamed at every line break,
  with every height measurement green. **Check the polarity of any dump before
  you read it**: the editor side once painted a dark canvas under light-theme
  (near-black) glyphs — 54 of a possible 765 of contrast — and the chrome gate
  reported "no list bullet found" against chrome that was drawn correctly.
- **Ask the engine, don't reason about specificity.** `--measure --dump` with
  `PARITY_CSS=line-height,font-size` appends those *computed* values to every
  row of the box dump. A box of the wrong height is a declaration that did not
  apply or one that applied where it should not have; two rounds of plausible
  reasoning about which named the wrong rule twice, and one run of this settled
  it. `PARITY_SECTION=""` lists every failing example, and set-diffing those
  numbers between runs (`comm`) is the only honest way to tell a fix from a
  trade — the aggregate hides a regression behind a win. `comm` needs
  **lexically** sorted input, so `sort` and never `sort -n`: given numeric order
  it produces nonsense silently rather than erroring, which reads exactly like a
  clean set-diff. The sweep is
  `swift run --package-path Tools/RenderParity RenderParity --spec`, once bare
  and once under `PARITY_CONTEXT=1`; it covers **672 examples with nothing
  excluded**, and because the twenty-four GFM extension examples were invisible
  to it for its whole life, **any example number written down before that is
  stale by up to twelve** (the old #568 is #580).
- **`.baselineOffset` under a pinned line height moves the *reported* baseline
  and not the ink.** `NSTextLineFragment.glyphOrigin.y` comes back with the
  offset already taken off and AppKit draws from the unlifted one, so the two
  cancel: chrome positioned from `glyphOrigin` has to add the lift back (see
  `drawListBullets`) or it lands where the text is not. Measured on a 2× dump:
  changing the value by 20pt moves the glyph **zero pixels**, for the
  half-leading correction and the code box's padding alike. Two consequences to
  keep straight. The half-leading is a *metrics* correction and that is enough —
  it is what every box measurement and every piece of chrome is derived from.
  The code box's bottom padding was not, and for the editor's whole life it went
  undrawn: `padCodeLine`, `applyNestedCode` and the quote's own listing lines each
  reserved 16pt below the last line and then "lifted the glyphs off it", so the
  reservation and the lift cancelled exactly and a one-line indented code block
  sat hard against the floor of its box. It is now reserved *outside* the line box
  (`NSTextLayoutFragment.bottomMargin`, with `drawCodeBand` painting over it) —
  one change covering all of them. Do not "verify" any of this from `glyphOrigin`:
  `render-parity.sh`'s baseline column reads `glyphOrigin` too, which is why the
  gate confirmed its own input for years. The chrome check now measures the ink's
  distance from the panel's top and bottom edges instead, so it cannot go undrawn
  again silently.
- **A blockquote holds *blocks*, and `StyleApplier.applyQuoteBars` is where that
  is worked out.** `BlockParser` emits one flat block per quote, and the flat,
  non-overlapping block tiling cannot express a reopened container at all (the
  probe that tried came back with two `listItem` blocks both starting at line 0
  and the inner content dropped). So the quote's interior carries its own
  container stack — one open fence plus the content columns of the list items
  open inside it — built in a single pass over the quote's lines and dead when
  the function returns. Anything that reads a quote line *on its own* is a bug
  waiting: `> aaa` is prose or a line of a listing depending on what came before
  it, and `>>     two` is an indented code block or a list item's own paragraph
  depending on what column the item opened at. Four columns is only the right
  ruler when nothing is open.
- **Adding a stored property to a type shared across modules needs a clean
  package build.** SwiftPM's incremental build left the test bundle holding the
  old layout of `Block` after `ListInfo` gained a field, and the result was a
  SIGSEGV in `objc_release` on a corrupt pointer — which reads exactly like a
  logic bug and is not one. `rm -rf Packages/NotesEditor/.build/arm64-apple-macosx`
  and re-run before believing a crash of that shape.
- Never put a spacing number in a renderer — `RenderedBlockFragment.imageGap` was 6pt of
  padding around every rendered embed that `GFMBoxMetrics` knew nothing about, i.e. 12pt on
  every table, diagram, formula and HTML block. It is 0.
- Docs describe the UI from source, not memory — verify shortcuts/menus with the `docs-fact-checker` agent (a draft once shipped two invented shortcuts).
- Commit trailer: `Co-Authored-By: Claude <model> <noreply@anthropic.com>` per repo convention.
