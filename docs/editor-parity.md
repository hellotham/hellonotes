# New editor — feature coverage

*The in-repo engine (`Packages/NotesEditor`) is now the **only** editor; the
`swift-markdown-engine` fork is gone (M4 complete). This tracks GFM +
extension coverage and the remaining deferred polish.*

Updated 2026-07-17 (post-M4).

## GitHub Flavored Markdown

| GFM feature | Status | Notes |
|---|---|---|
| Headings (ATX + setext) | ✓ | |
| Bold, italic, bold+italic | ✓ | |
| Strikethrough `~~` | ✓ | GFM |
| Inline code, fenced code | ✓ | + ~190-language syntax highlighting |
| Blockquotes | ✓ | |
| Lists (ordered, unordered, nested) | ✓ | |
| Task lists `- [ ]`/`- [x]` | ✓ | GFM; rendered as clickable checkboxes |
| **Tables** `\| … \|` | ✓ | GFM; rendered as an aligned grid (per-column `:--`/`:-:`/`--:` alignment, header band, grid lines), caret-in reveals source |
| Links `[text](url)`, images `![alt](url)` | ✓ | |
| Autolinks `<url>`, bare `http(s)://`, bare `www.` | ✓ | GFM extended autolinks; `<>` brackets conceal |
| Thematic breaks `---` | ✓ | drawn as a full-width rule |
| Footnote refs `[^id]` | ✓ | styled; definitions shown inline (readable) |
| Hard line breaks (two trailing spaces) | ✓ | |
| Emoji shortcodes `:smile:` | — | GitHub.com feature, not core GFM; shown as text (Obsidian-style) |
| HTML entities `&amp;`, raw HTML | — | source editor shows as-is (a render-mode concern) |

## HelloNotes / Obsidian extensions

| Feature | Status |
|---|---|
| `[[wiki-links]]` (+ aliases, `#heading`, resolved/broken tint, click-nav, autocomplete) | ✓ |
| `![[embeds]]` — image files, `![[Note]]` transclusion cards | ✓ |
| `#tags` (+ nested, autocomplete) | ✓ |
| `==highlight==`, `%%comments%%` | ✓ |
| Callouts `> [!type]` (band + bar + icon + colored title) | ✓ |
| Block math `$$…$$` (SwiftMath), Mermaid diagrams | ✓ |
| Front matter (hidden/dimmed) | ✓ |

## AI-native + platform

| Area | Status | Notes |
|---|---|---|
| Large-note performance | ✓✓ | the rewrite's reason to exist; 3.8 MB note opens ~48 ms, keystroke ~6 ms (see editor-rewrite.md) |
| Syntax concealment + caret reveal | ✓ | block-granularity reveal |
| Autosave / conflicts / external reload | ✓ | via EditorModel bridge (`loadRevision`, `willFlush`) |
| Undo/redo per document; caret autoscroll | ✓ | stock NSUndoManager against raw storage; standard NSTextView autoscroll |
| Find & replace (⌘F) | ✓ | app FindReplaceBar over the `hn.editor.*` bus; native find bar also available |
| Format menu commands | ✓ | bold/italic/strike/highlight/code, headings, lists, quote — undoable via the typing path |
| Image paste → attachment, smart paste (HTML→md) | ✓ | host paste intents; non-intent pastes forced to plain text |
| Scroll-to-heading (outline, `[[Note#h]]`, search) | ✓ | TK2-safe ensureLayout + segment-frame scroll |
| Preview / Source / Split modes | ✓ | Preview = the same editor `editable(false)` (all syntax rendered, no caret) |
| **Writing Tools (Apple Intelligence)** | ✓ | `.complete` behavior, `.plainText` results so rewrites can't corrupt Markdown; styling pauses during sessions |
| **System inline predictions** | ✓ | honors the system keyboard setting (`.default`) |
| **AI rewrite selection** (canned tasks + custom prompt) | ✓ | context menu → sheet → Replace/Insert Below via EditorProxy; user's chosen provider |
| **AI edit seam** | ✓ | `EditorProxy.replace/performAITransform` — undoable programmatic edits |
| Code-block syntax highlighting | ✓ | HighlighterSwift (doc-cited survey: Apple ships no multi-language highlighter; see editor-rewrite.md) behind our `CodeHighlighting` protocol — colors-only overlay, per-hash cache, no flash |
| Rendered embeds: `![[image]]`, Mermaid, block LaTeX, transclusion, **tables** | ✓ | all through one fragment-drawn `BlockRenderer` path (source concealed + collapsed outside the caret, revealed inside, byte-pure storage, per-hash cache). LaTeX via in-app SwiftMath `MathImageRenderer`; tables via `TableImageRenderer` (aligned grid) |
| Task checkbox click-toggle | ✓ | real glyphs over the concealed `[ ]`/`[x]`; click toggles undoably, persists to disk |
| Callouts (`> [!type]`) rendered | ✓ | tinted band + gutter bar + icon + colored title |

## Deferred polish (not blockers)

| Item | Notes |
|---|---|
| Inline `$…$` LaTeX as image | genuinely hard (baseline-aligned inline image + width reservation); styled monospace source meanwhile |
| Callout collapse/fold, front-matter fold | cosmetic |
| Conceal `> [!type]` header syntax | attempted; hit a TextKit indent-collapse bug, reverted — needs revisit |
| Footnote definitions as a rendered list | refs styled + definitions readable inline today |
| iOS editor | M5 — `UITextView(usingTextLayoutManager:)` on the shared kernel |
