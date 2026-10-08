# What the assistant writes

Every cell below carries inline Markdown, the way a note's tables do: keys in
bold, properties in code, links to other notes, a correction struck through.
The editor draws a table as a picture, and the picture has to show what the
page shows.

| Action | Result | Notes |
| --- | --- | --- |
| Summarise Note | writes `summary:` into front matter | **never** the body |
| Suggest Tags | adds to `tags:` | see [[Organising]] |
| Suggest Links | adds to `related:` | as [[Examples/Nested Note\|an alias]] |
| Rewrite or Expand | proposes a change you *accept* or *reject* | ~~overwrites~~ never overwrites |
| Ask Library (**⇧⌘J**) | answers from your notes, with citations | [how it works](https://example.com/docs/intelligence/ask-library) |
| Assistant (**⇧⌘A**) | a conversation about your collection | pipes: `a \| b` and a \| c |

A narrower one, with markup in the header row and every alignment:

| **Key** | *Meaning* | `Default` |
| :-- | :-: | --: |
| `verbose` | print **every** step | `false` |
| `retries` | how many times to ~~give up~~ try again | `3` |

The prose after the tables is ordinary, so the blocks below them are measured
too.
