HelloNotes runs on iPad now — properly, not nominally. The iOS app has shipped for a while, but almost nothing in it could be reached: the editor crashed on the first tap, and when it didn't, there was no cursor to type with.

**This release raises the minimum to macOS 26.5 and iPadOS/iOS 26.5.** The Intelligence features are built on Foundation Models, which is 26-only.

## The iPad editor works

Four defects sat on top of each other, each hidden behind the one in front. Tapping a note crashed the app — a `UITextView` holds two references to its document and the editor replaced only one, so the view reported "0 characters" for a 19,000-character note. There was no cursor: a wiki-link tap recogniser had no delegate and beat the text view to it. The format bar never appeared. And switching notes kept the previous note's text — worse than it looked, since typing would have saved it over the new file.

Tables, diagrams and maths render there now too.

## Suggestions stop editing your writing

Accepting a suggested tag used to append `#tag` after your last paragraph. Accepting a link added a `## Related` heading the app invented. A summary was pushed in above your first line. All three now go to the note's properties — `tags:`, `related:` and `summary:` — where you can remove them again in the Properties pane, and where every other Markdown tool reads them. Your prose comes back untouched.

**And front-matter tags are finally read.** If a note declared `tags:` the way Obsidian does, HelloNotes could not see them at all: not in the tag list, not filterable. Three notes in the sample vault we ship were affected.

## Preview matches the editor, on both platforms

HelloNotes renders Markdown through GitHub's own engine, verified against the full GFM specification. Preview was not using it — it called a small hand-written stylesheet, and Export and Print were on the same wrong path. All three go through one engine now. It also fixes a serif bug present since the code was written: one malformed CSS property sent every preview, export and printed page back to Times.

## Your model's real limits, not a guess

Each AI provider now has a **Refresh** that asks which models your key can reach, so the list is current rather than whatever was true when the app was built. Eight providers also report how much each model holds, and HelloNotes uses that number — which fixes something quietly expensive: **Ask Library sent 12,000 characters to every provider** — about 0.3% of a million-token model's window — whatever model you chose. Summarising a long note summarised its first 4,000 characters.

Temperature, context budget and reply length are now yours to set per provider, over the range that provider actually accepts.

## Collections, and the cloud

The app manages **collections**, and the menus finally say so: New Collection, and Open Collection from a folder, iCloud Drive, an Obsidian vault, the cloud or a repository. **Manage Cloud Collections** replaces a scatter of per-provider windows. Several accounts on one service now work — a personal and a work OneDrive were one entry with one set of credentials, so signing in to the second silently overwrote the first. Adding a large cloud folder is much faster: folders are listed several at a time.

## Things you can actually read

The Mac's tag list only appeared once you started typing, so there was no way to discover a collection even had tags. It is always shown now. Ten fields in iOS Settings had no visible label at all. AI errors are selectable and have a copy button. Git and AI credentials are in Settings on both platforms — Git's only macOS route needed a repository already open, so the credentials to clone one were behind having cloned one.

## For the record

The editor package declares support for iOS and its tests had only ever run on macOS. They run on both now, which is how four simultaneous defects in the UIKit half went unnoticed for so long.
