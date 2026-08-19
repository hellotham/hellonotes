HelloNotes runs on iPad now — properly, not nominally. The iOS app has shipped for a while, but almost nothing in it could be reached: the editor crashed on the first tap, and when it didn't, there was no cursor to type with. This release is mostly that, plus a rendering fix that turns out to have affected the Mac just as much.

**This release raises the minimum to macOS 26.5 and iPadOS/iOS 26.5.** The Intelligence features are built on Foundation Models, which is 26-only, and the Quick Look extensions already required 26.5 while the app claimed 15.0 — an app cannot promise an OS its own embedded extensions refuse to run on.

## The iPad editor works

Four defects sat on top of each other, each hidden behind the one in front.

- **Opening a note and tapping crashed the app.** A `UITextView` holds two references to the document it shows, and the editor was replacing only one of them. The view answered "0 characters" for a 19,000-character note while its layout engine laid out all 19,000; the first tap past the beginning read a range that did not exist. AppKit tolerates that swap and UIKit does not.
- **There was no cursor.** A tap recogniser for wiki links had no delegate, so it competed with the text view's own caret tap and won — then did nothing, because most taps are not on a link. Scrolling worked throughout, which is what made it look like the keyboard was broken rather than the tap.
- **The format bar never appeared.** It was built as a SwiftUI keyboard toolbar, which attaches only to views SwiftUI manages. It is now a real keyboard accessory: a scrolling row of fourteen commands with undo, redo and dismiss pinned where they cannot move.
- **Switching notes kept the previous note's text.** Worse than it looked: the stale document was still wired to the model, so typing into what appeared to be the old note would have saved its contents over the new file.

## Tables, diagrams and maths render on iPad

They were parsed, styled, and given a reserved band to sit in — and then nothing was drawn into it. The renderers and the layout fragment were already cross-platform; one step between them was not, so the iPad wired up a renderer it never called. Mermaid diagrams, display maths and `![[Note]]` transclusions arrive with the same fix.

## Markdown mode stopped rewriting your Markdown

Typing `---` under a table header produced an em dash, and the table quietly stopped being a table. Markdown mode used a control that offers no way to switch typographic substitution off, on the one screen in the app that shows nothing but source. Quotes and `--` went the same way.

## Preview matches the editor, on both platforms

HelloNotes renders Markdown through GitHub's own engine, verified against the GitHub API and the full GFM specification. The Preview was not using it — it called a small hand-written stylesheet instead, so the editor styled text from GitHub's parse tree while the Preview beside it did not. Export and Print were on the same wrong path.

They all render through the same engine now, and there is only one renderer left in the app, so this cannot drift apart again. It also fixes a serif bug that had been there since the code was written: a single malformed CSS property meant every preview, every exported HTML file and every printed page fell back to Times.

## Everything the Mac can do, the iPad can reach

- **A menu bar**, with the keyboard shortcuts that come with it — ⌘B, ⌘F, Find, and the View menu. iPadOS builds its menu bar the same way macOS does; the app simply never offered it one.
- **File tabs** across the top, with everything else behind a single control, sharing the Mac's tab model rather than a second implementation of it.
- **The inspector** — Outline, Tags, References, Properties, History — over the note, with a button to show it. It was unreachable before: the control that would have opened it needed a screen wider than an iPad.
- **Notes can be renamed, duplicated, bookmarked, exported and deleted**, and the sidebar shows folders as a tree that remembers which ones you left open.

## For the record

The editor package declares support for iOS and its tests had only ever run on macOS. They run on both now, which is how four simultaneous defects in the UIKit half went unnoticed for so long.
