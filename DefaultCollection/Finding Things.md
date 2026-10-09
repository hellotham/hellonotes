---
title: Finding Things
tags: [tour]
---

# Finding Things

| Want | Press |
|---|---|
| Jump to a note by name | **⇧⌘O** Open Quickly |
| Find in this note | **⌘F** |
| Search every collection | **⌥⌘F** |
| Any command, by name | **⇧⌘P** Command Palette |
| Today's daily note | **⇧⌘T** |
| Capture a thought without leaving | **⌃⌘K** Quick Capture |

On iPad without a keyboard, the **search** button in the bar over the note holds
Search Notes, Open Quickly and Find & Replace, and the bar's **+** holds today's
note and Quick Capture. On iPhone, the **Search** tab searches.

## Patterns

In the find bar, **`.*`** makes the search a regular expression: `\d+` finds
numbers, `^` the start of every line. In the replacement, `$1` is the first group
in brackets and `\n` a new line — so finding `(\w+)@(\w+)` and replacing with
`$2 for $1` turns *me@home* into *home for me*. A pattern ignores case unless it
starts with `(?-i)`.

## The outline

**Summary & Outline**, in the panel, lists a note's headings and jumps to them,
with word count and reading time. On a long note it is faster than scrolling.

## Recents and bookmarks

Both live at the top of the sidebar. Bookmark a note to pin it there.
