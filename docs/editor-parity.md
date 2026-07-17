# New editor — parity tracker

*Old engine (`swift-markdown-engine` fork) vs the in-repo engine
(`Packages/NotesEditor`), toggled in Settings → General → Editor. The fork
is removed when every ⚠/✗ that matters is ✓ (M4 in docs/editor-rewrite.md).*

Updated 2026-07-17 (M1).

| Area | Status | Notes |
|---|---|---|
| Live block styling (headings, lists, tasks, quotes, callout tint, fences, tables-as-text, HR, front matter) | ✓ | via MarkdownCore StyleSpec |
| Inline styling (bold/italic/strike/highlight/code/math-source/comments/tags/footnotes) | ✓ | |
| Syntax concealment + caret reveal | ✓ | block-granularity reveal |
| Wiki links: resolved/broken tint, click-to-navigate, aliases, `#heading` targets | ✓ | existence via linkCandidates |
| URLs: live links, click to open | ✓ | |
| Autosave / conflicts / external reload | ✓ | via EditorModel bridge (`loadRevision`, `willFlush`) |
| Undo/redo per document | ✓ | stock NSUndoManager against raw storage |
| Caret autoscroll while typing | ✓ | standard NSTextView behavior, nothing fights it |
| Large-note performance | ✓✓ | the rewrite's reason to exist; see numbers in editor-rewrite.md |
| Find (⌘F) | ✓ | app FindReplaceBar bus wired (query/step/replace/replace-all/clear); native NSTextView find bar also available |
| `[[wiki]]` / `#tag` autocomplete popup | ✓ | live-verified: popup at caret, fuzzy ranking, acceptance replaces the open token |
| Format menu commands (bold/italic/…, headings, lists, quote) | ✓ | live-verified ⌘B; all commands undoable via the typing path |
| Image paste → attachment, smart paste (HTML→md) | ✓ | host paste intents; non-intent pastes forced to plain text |
| Scroll-to-heading (outline, `[[Note#h]]`, search hits) | ✓ | find-bus queries drive TK2-safe ensureLayout + segment-frame scroll |
| **Writing Tools (Apple Intelligence)** | ✓ | `.complete` behavior, results constrained to `.plainText` so rewrites can't corrupt Markdown; styling pauses during sessions, one catch-up restyle at end |
| **System inline predictions** | ✓ | `inlinePredictionType = .yes` |
| **AI edit seam** | ✓ | `EditorProxy.replace/performAITransform` — undoable programmatic edits through the typing path; ready for provider-driven rewrite UI |
| **Rewrite selection with AI** (canned tasks + free-form prompt) | ✓ | live-verified on-device: context-menu "Rewrite with AI…" → sheet with 6 canned tasks + custom instruction, preview, Replace/Insert Below through the undoable EditorProxy path; routed through the user's chosen provider (Apple on-device or cloud key) |
| Provider-driven ghost completion | ✗ | later — system inline predictions cover the basic case today |
| Code-block syntax highlighting | ✓ | live-verified. HighlighterSwift (kept after a doc-cited survey: Apple ships no multi-language highlighter through the 26 SDKs; hljs wrappers beat tree-sitter for cached one-shot snippets — see editor-rewrite.md). Behind our own `CodeHighlighting` protocol: engine-swappable, colors-only overlay (metrics stay ours), synchronous re-apply from a per-document cache so caret reveals never flash. Now a *direct* SPM dependency (survives fork removal at M4) |
| Rendered embeds: `![[image]]`, Mermaid | ✓ | live-verified. Fragment-drawn: source concealed + collapsed when caret is outside, revealed for editing when inside; image sized to the column, drawn in a paragraph-spacing band; storage stays byte-pure. Engine-swappable `BlockRenderer` protocol + per-content-hash cache (sync re-apply, no flash). Image files via disk resolution; Mermaid via the app's BeautifulMermaid renderer |
| Rendered embeds: block LaTeX (`$$…$$`), transclusion cards | ⚠ | infra done (same fragment path); LaTeX needs a math-render dependency (SwiftMath), transclusion needs the note→image renderer ported off the fork — M3b |
| Inline LaTeX rendered as image | ✗ | later; styled source meanwhile |
| Callout collapse, front-matter fold | ✗ | M3 |
| Task checkbox click-toggle | ✗ | M3 |
| Table grid chrome / wide-table scrolling | ✗ | M3; aligned text + dimmed pipes meanwhile |
| Writing Tools config, Continuity Camera routing | ✗ | arrives with native-roadmap Phase A, on the new engine |
| Preview mode on new engine | ✗ | M4 — same view, `editable(false)`; old engine renders Preview until then |
| iOS editor | ✗ | M5 — UITextView(usingTextLayoutManager:) on the same kernel |
