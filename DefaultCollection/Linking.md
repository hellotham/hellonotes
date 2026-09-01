---
title: Linking
tags: [tour]
aliases: [Links, Wiki Links]
---

# Linking

Type `[[` and HelloNotes offers every note in the collection. Links are by
**name**, not by path, so moving a note between folders never breaks one.

## Try it

- A link to [[Organising]]
- A link with different display text: [[Rich Content|callouts and maths]]
- A link to a heading: [[Manual/Index#Keyboard shortcuts]]

## Backlinks

Open the **Links** inspector on any note and you will see what points *at* it —
including **unlinked mentions**, places where a note's title appears as plain
text and could become a link. This note is linked from [[Start Here]], which is
why that inspector is not empty.

## The graph

**⇧⌘G** opens the graph: notes as nodes, links as arrows. It is most useful for
noticing what *isn't* connected — an orphan usually means a note you forgot to
file rather than one nobody needs.

## Aliases

This note's front matter includes `aliases: [Links, Wiki Links]`. So `[[Links]]`
finds it too. Aliases are how a note can be called what people actually call it
without renaming the file.
