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

## Pictures

**Insert Image** puts a picture in the note where the caret is, as a paragraph
of its own — at the end of the note when no caret is in it, and never inside
its properties. In a callout, a quote or a list item it stays inside it. On iPhone and iPad it is on the bar above the keyboard — on iPhone
in the bar's **⋯** menu when the row is full — and on the Mac it is
**Format ▸ Insert Image**. It is there in Edit; in Markdown and Split, type the
link.

- **Choose from Collection…** lists the pictures already in this collection,
  with a field to find one by its name or folder, and links the one you choose
  where it is. Nothing is copied.
- **Choose from Photos…** saves the photo into the collection and links it. On
  iPhone and iPad it keeps where it was taken unless you turn that off in the
  picker: **⋯ ▸ Options ▸ Location** (the picker says "Location Included" or
  "Location Not Included").
- **Take Photo…**, on an iPhone or iPad, does the same with a new photo, which
  carries no location. On a Mac, choose **File ▸ Import From Device**, or
  right-click in the note and choose **Import from iPhone or iPad**.

A new picture goes where a pasted one does: an `assets` folder beside the note,
unless **Settings ▸ General ▸ Attachments** says otherwise. A photo that other
apps cannot show, such as an iPhone's HEIC, is saved as JPEG. A moment later
its description appears in the brackets, worked out on the device: the words in
the picture, or what it shows.

A picture written the Obsidian way, `![[photo.png]]`, is shown as well, in Edit
and in Preview. Obsidian usually writes only the picture's name, so it is
found by name anywhere in the collection — while the collection lists its
other files (**Show Non-Note Files**, on unless you turn it off). With that
off, it is found only beside the note, in the collection's top folder or in
the pictures folder. `![[photo.png|300]]` shows it 300 points wide, never wider
than the text, and `|300x200` sets both sides — and the same goes at the end of
an ordinary picture's description, as Obsidian writes it there:
`![A cat|300](cat.png)`.

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
