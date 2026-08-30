# NotesEditor — the editor engine

Three targets: **MarkdownCore** (Foundation-only, Sendable parsing kernel),
**MarkdownEditor** (TextKit 2 UI, macOS + iOS), **GFMRender** (cmark-gfm
GitHub-identical Preview + parity tests).

## The two invariants (the reason this package exists)

1. **Raw Markdown IS the text storage.** One text, one coordinate system.
   Presentation is attributes and fragment drawing — never text substitution.
   Concealment is a same-length attribute transform.
2. **Every editing-path operation is O(damage), never O(document).** Whole-doc
   passes happen once, at open, off-main. Perf tests fail the build past
   budget (1 MB parse < 50 ms, keystroke cycle < 5 ms) — do not weaken them.

## Commands

All three are run **from the repository root**, not from this directory.

```bash
swift test --package-path Packages/NotesEditor                 # 401 tests, 31 suites
cd Packages/NotesEditor && xcodebuild test -scheme NotesEditor-Package \
  -destination 'platform=iOS Simulator,name=HN-iPad'           # 381 tests — run these too
# ^ prints THREE bundle summaries (169/12, 18/4, 194/13). The total is their sum;
#   reading only the last one says "194 in 13" and looks exactly like two thirds
#   of the suite having silently stopped running.
./scripts/render-parity.sh                                     # Edit ≡ Preview: the gate
                                                               # for anything visual
```

`swift test` only ever builds the package for macOS, so the UIKit half is
untested until the second command runs — that is how a `UITextView` showing a
document it believed was empty, a zero-width keyboard bar and a link tap that
ate the caret tap all shipped together.

The GFM spec corpus is 672 examples and `GFMSpecTests` asserts all of them:
660 exact, 10 GitHub-extension overrides, 2 that differ from the corpus in
serialisation only (task-list `<input>` attribute order — see
`GFMSpec.sameHTMLDocument`). Its parser reads the extension-tagged fences
(`example table`, `example autolink`, …) as well as the bare ones, and the
count is asserted `== 672` rather than as a floor, which is what let the 24
tagged blocks go unread for years.

## Traps (all previously hit; details in docs/implemented.md §2, §5)

- One-shot `setRenderingAttributes` vanishes on fragment re-layout — use
  `renderingAttributesValidator`.
- Set `NSTextView.font`/typingAttributes **before** attaching styled storage,
  or per-run concealed fonts get clobbered.
- Never `setAttributedString` a large pre-styled string (lazy conversion stalls
  ~100 ms on first edit) — style progressively in batches.
- `scrollRangeToVisible` is unreliable in TK2: `ensureLayout(for:)` the target
  range, then `enumerateTextSegments`.
- UITextView does not call custom fragment `draw` — iOS chrome goes through
  `ChromeOverlayView`. Subclasses built via `init(usingTextLayoutManager:)`
  skip stored-property init: make such properties `lazy`.
- GFM fidelity questions → extend the GFMRender spec/parity tests, not the
  hand-written StyleSpec.

## Rendering, the box model and parity — rules moved here from the root

These were in the repository-root `CLAUDE.md`, where they were loaded for every
session including website, LLM and shell work that cannot act on them. They are
unchanged, and they are the expensive ones: each traces to a defect that shipped.
They apply to this package's sources and to `Tools/RenderParity`, which grades it.

- **Both spec parsers read all 672 examples; assert the corpus's size, never a
  floor.** `GFMSpecTests` and `LiveEditorConformanceTests` used to match an
  opening fence of `` ``` example `` only, so the 24 **extension**-tagged blocks
  — 8 `table`, 11 `autolink`, 2 `strikethrough`, 1 `tagfilter`, 2 `disabled`
  (task lists) — were skipped without a word, and tables and strikethrough had
  never been checked for HTML byte-parity at all. What hid it for years was the
  guard: `#expect(examples.count > 600)` is true of 648, so the gate could not
  report the 24 it could not see. It is `== 672` now, which is the corpus's own
  size — `grep -cE '^`+ example' spec.txt` counts it.
  Widening cost exactly two divergences, both task lists, and neither a
  rendering fault: the linked cmark-gfm writes
  `<input type="checkbox" disabled="" />` where the corpus, cut from an older
  release, wrote `<input disabled="" type="checkbox">`. Same element, same
  attributes, same page — byte-parity was simply the wrong question, since
  Preview hands the HTML to WebKit, which parses it. `GFMSpec.sameHTMLDocument`
  forgives attribute order and a void element's slash and **nothing else**, and
  `sameHTMLDocumentIsStrict` holds it to that; the two examples are pinned in
  `serialisationOnly`, so a third has to be read rather than absorbed. Standing
  score: **660 exact + 10 GitHub-extension overrides + 2 serialisation-only =
  672/672**.

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
