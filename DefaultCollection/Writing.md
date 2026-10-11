---
title: Writing
tags: [tour]
---

# Writing

The editor styles Markdown **as you type**. There is no preview to switch to and
no round trip: a heading looks like a heading the moment you type `#`, and the
`#` is still there in the file.

## Try it

Put the caret on the next line and type `## A heading`, then a blank line, then
some text with `**bold**` and `*italic*` in it.

Formatting has shortcuts where you would expect: **⌘B** for bold, **⌘I** for
italic, **⇧⌘7** for a bulleted list, **⇧⌘9** for a numbered one.

Without a keyboard, the same commands are on the bar above it. On iPad that is
the row iPadOS floats over the keyboard — bold, italic and the rest sit beside
the language selector and the dictation button, and they stay there when a
hardware keyboard is attached. On iPhone they are on a bar of their own directly
above the keys. On the Mac they are in the **Format** menu.

## The four views

| View | What it is for |
|---|---|
| **Edit** | Live styling. Where you write. |
| **Preview** | Rendered exactly as GitHub renders it. |
| **Markdown** | The raw source, unstyled. |
| **Split** | Source and rendered side by side. |

Preview is not an approximation — it is checked against the CommonMark and GFM
specification, all 672 examples, so what you see is what GitHub would show.

## Lists that behave

- Press Return in a list and the next bullet appears — the next number in a
  numbered list, and an empty box after a task
- Press Return on an empty bullet to end the list: a nested one moves out a
  level, and one at the list's own level leaves a blank line with the caret
  below it
- [ ] Task lists work too
- [x] And can be ticked in Edit

This works in Edit and Markdown alike, inside a quote too, and never in code.

## Space

Every blank line you type shows in Edit: one between two paragraphs is the
usual gap, and each one after it is an empty line. Preview closes a run of them
up to that one gap, as GitHub does.

A note longer than the window scrolls on past its end, in every view, until
its last line is about halfway up — so the line you are writing need not sit at
the bottom edge.
