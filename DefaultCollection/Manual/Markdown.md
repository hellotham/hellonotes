---
title: Markdown Reference
tags: [manual]
---

# Markdown Reference

CommonMark plus GitHub Flavored Markdown, checked against all 672 specification
examples, plus the extensions below.

## Standard

`# Heading` · `**bold**` · `*italic*` · `` `code` `` · `> quote` · `- list` ·
`1. list` · `- [ ] task` · `[text](url)` · `![alt](image)` · `---` rule ·
tables · fenced code with syntax highlighting · footnotes · strikethrough.

## Extensions

| Syntax | Does |
|---|---|
| `[[Note]]` | link by name |
| `[[Note\|text]]` | link with display text |
| `[[Note#Heading]]` | link to a section |
| `![[Note]]` | embed a note |
| `![[Note#Heading]]` | embed a section |
| `#tag` | tag, in the body |
| `> [!note]` | callout |
| `> [!tip]-` | callout, collapsed |
| `$x$` / `$$x$$` | LaTeX maths |
| ` ```mermaid ` | diagram |
| `%%` | comment, hidden when rendered |

## Front matter

A YAML block at the very top, between `---` lines. `title`, `tags`, `aliases`,
`summary` and `related` have meaning to HelloNotes; anything else is yours and is
preserved untouched.
