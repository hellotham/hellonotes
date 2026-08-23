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
swift test --package-path Packages/NotesEditor                 # 400 tests, 31 suites
cd Packages/NotesEditor && xcodebuild test -scheme NotesEditor-Package \
  -destination 'platform=iOS Simulator,name=HN-iPad'           # 380 tests — run these too
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
