# Fixtures — the images the GFM corpus points at

Every one of these is a 20×20 solid square. They exist because the corpus is
full of `![foo](train.jpg)` and `![foo](/url)`, and until they did, the sweep
loaded each page with no base URL at all: WebKit drew a broken-image box and
the editor, whose block renderer had nothing to open, left the source visible.
The harness then reported a 4pt disagreement on eighteen examples — it was
comparing two *fallbacks*, and neither side had rendered an image.

The names are the corpus's own targets, so nothing here is arbitrary. `url`,
`url2`, `uri1`–`uri3`, `foo` and `bar` have no extension because the corpus
writes none; both engines identify them by content. `/url` and
`/path/to/train.jpg` are root-absolute in the corpus, which is why the sweep
serves this folder as the root of its own `parity:` scheme rather than as a
`file:` base — a browser resolves `/url` to `file:///url`, and no harness can
put a file there.

Regenerate with the snippet in `Tools/RenderParity/Sources/RenderParity/main.swift`
(see `ParityScheme`) if a new target ever enters the corpus.
