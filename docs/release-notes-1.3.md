HelloNotes already had most of this. It was just filed under "AI" — in a panel and a window organised around the fact that a model was involved, which is the one thing you are least likely to be thinking about when you want a summary. So this release is mostly about putting each of these next to the thing it acts on, and then adding the two that were genuinely missing: finding the links you meant to make, and letting research arrive as a note instead of as a chat reply.

## Where the AI lives now

- **The Note menu.** Summarise Note, Suggest Tags, Suggest Links and Rewrite or Expand Note… sit beside Rename and Duplicate. Each answer lands in the inspector tab that already holds that kind of information — the summary at the top of **Outline**, tags in **Tags**, suggested links in **References**, beside the backlinks they are about to join.
- **A command palette**, ⇧⌘P. Type a command's name to run it, including the ones with no shortcut worth memorising. Built from the same set of actions the menu bar is, and a command that is unavailable right now is left out rather than shown greyed: everything you can find in it, you can run.
- **Select text and act on it.** The things the system's own Writing Tools cannot do, because they need your notes: link the phrase, find related notes, explain it using what you have written. A floating bar on the Mac; the standard selection menu on iPhone and iPad.
- **The AI features now work on iPhone and iPad**, where previously none of them did — note actions, rewriting, Ask Library, the Assistant, Review Links and New Note from a Prompt. The command palette remains Mac-only.

## Review Links

- **Review Links…** (⇧⌘L) walks a note phrase by phrase, the way a spell check does: **Link**, **Skip**, or **Never**. You see the phrase in its own sentence and the opening lines of the note it would point at, because the same phrase can deserve a link in one paragraph and not the next.
- **"Never" is remembered** for that collection, so a phrase you have rejected stops coming back. It is stored on your device, not in your notes — a decision you made is not something to commit to a shared repository.
- **Nothing is written until you finish**, and the whole set applies as one change you can undo in one step.
- Every phrase that **names** another note is a candidate; when a note turns up more than ten, you are shown the ten whose targets are most related to what you have written.
- Needs no AI provider at all — it is an exact scan of your own text.

## New Note from a Prompt

- ⌃⌘N, or **File ▸ New Note from a Prompt…**, in two modes.
- **Write** composes a note from a description. **Research** investigates a question on the web across several angles and lands the answer *as a note*, with its sources gathered at the end and a record of the question it came from.
- **Both connect to what you already have.** Notes you own on the topic are offered to the model as links, and every link that comes back is checked against your collection: anything naming a note that does not exist is turned back into ordinary text, and the draft tells you it happened. Research arrives joined up instead of as an island.
- **You read the whole draft before it exists.** Title and body are editable, and no file is created until you press **Create Note**.

## Suggest as I type *(Mac only, off by default)*

- Grey text appears after the cursor when you pause at the end of a line. ⌥⇥ or → accepts it; Esc dismisses it.
- **The suggestion is never part of your note until you accept it.** It is drawn on screen and nothing more — it cannot reach a save, a search result, your links, or a Git diff.
- Runs **on your device only**: a suggestion that has to cross the network arrives after you have already typed past it. Turn it on in **Assistant Settings ▸ Inline completion**.

## Smaller things

- **Related notes are found by the whole text, not just the title** — by the distinctive words two notes share, so an unusual name or term counts for far more than a common one. Built the first time something needs it rather than at launch, and kept current as you save.
- **Assistant Settings now says what your chosen model can and cannot do** — on-device or cloud, roughly how much of a note it reads, and which features would work better on a larger one.
- Deep research declines up front on a provider that cannot drive its tools, instead of failing part-way through.

---

Requires macOS 15 or later; the iOS/iPadOS build requires iOS 26.5. The on-device features additionally need macOS 26 and a Mac where Apple Intelligence is available and switched on — everything else in HelloNotes works without them. The widget and the Finder Quick Look preview are built for macOS 26.5, so on an earlier macOS the app runs normally but those two are absent.
