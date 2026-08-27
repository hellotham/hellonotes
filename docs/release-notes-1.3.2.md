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

## Adding a collection says what it does

The ways into a library had accumulated one at a time and stopped describing
anything. The app manages **collections**, so the menu now says so: **New
Collection** (an empty folder, or a Git repository) and **Open Collection**
(from a folder, iCloud Drive, an Obsidian vault, the cloud, or a repository).
"New Repository" is no longer a peer of collections — it is one way of making
one, which is all it ever was.

Two of those entries used to be the *same command listed twice*: "Open
Collection" and "Open Obsidian Vault" both opened the same picker in the same
place. They are genuinely different now — one starts in Documents, the other
where Obsidian keeps its vaults — and **iCloud Drive** has its own entry,
because it lives somewhere neither of the others can reach and was the hardest
cloud folder on the machine to open.

The first-run screen and the launcher now offer this same set, generated from
one list rather than described separately. They had drifted to offering two
ways in while the toolbar offered eight.

## Cloud storage is one screen

**Manage Cloud Collections** replaces a scatter of per-provider windows and two
differently-named commands for one intent. It lists the cloud collections you
already have, the ways to add another, and your accounts.

- **Several accounts on one service** now work. A personal and a work OneDrive
  were previously *one* entry with *one* set of credentials, so signing in to
  the second silently overwrote the first. Each is now its own account, keeps
  its own credentials, and can be renamed to something you recognise.
- **One account can supply several collections**, without signing in again.
- **Removing a cloud collection** says plainly that your files are not deleted.
- Which route applies — a folder your provider already syncs here, or one that
  needs signing in — is now *answered* rather than asked: on macOS the app reads
  which provider apps are installed and names them.

Two fixes behind that. **A cloud collection added over a provider's API stopped
syncing after one relaunch**, silently becoming a stale local copy: it was
saved both as a plain folder and as a cloud collection, and the plain one won on
restore. And **OneDrive was never detected as installed**, because it ships
under a bundle identifier the app did not check.

## Credentials live in Settings, on both platforms

Git accounts had no route on macOS except the inspector's Git pane — which
needs a repository already open, so the credentials you need to *clone* a
repository were behind having cloned one. AI provider keys had the mirror-image
gap: a Settings tab on macOS, nothing in iOS Settings at all. Both are now in
Settings on both platforms, entered and removed in the same place.

**Acknowledgements** moved out of Settings to sit beside About, where it
belongs — nothing in it is a preference.

## The app asks your AI provider what it can do

The model list was hand-written, and a hand-written list of model IDs is stale
the week after it is written — this one still offered `gemini-2.0-flash` and
`gpt-4o`. Each provider now has a **Refresh** button that asks which models your
key can actually reach.

Eight of them — Gemini, Anthropic, OpenRouter, Mistral, Groq, Together AI, Ollama
and LM Studio — also report how much each model can hold, and HelloNotes uses
that number. Which fixes something that was quietly costing you most of what you
were paying for: **Ask Library sent 12,000 characters to every provider**, about
0.3% of a million-token model's window, and it would have gone on sending 12,000
whatever the model behind it. Summarising a long note summarised its first 4,000
characters and said nothing about the rest.

That was one number doing two jobs — the least a provider needs for a feature to
be worth offering, and the most that feature would ever send. They are separate
now, and only the first is a limit. What your model can hold is the other.

You can still type any model ID; refreshing never overwrites one you chose, so a
fine-tune or a deployment alias keeps working.

## Temperature, context and reply length are yours to set

Per provider, beneath the model:

- **Temperature**, over the range that provider genuinely accepts. The single
  slider was pinned to 0–1 — the wrong range for Anthropic, which rejects
  anything higher, and half the available range for everyone else.
- **Context budget**, in characters, if you would rather send less than your
  model can hold.
- **Max reply length**, which the app had never once set.

Where each number came from is stated rather than implied: a limit your model
reported reads differently from a cautious default, and they look identical
written down. OpenAI, xAI, DeepSeek, Cerebras and Perplexity publish model names
but not limits, and the app says so instead of guessing.

All of it is in one place on both platforms — **Settings ▸ AI** on the Mac,
**Settings ▸ AI ▸ Providers & API Keys** on iPad. Sixteen providers is a lot of
rows, so each one is a single line — off, needs a key, or the model it is using —
that opens to the model and the key, with the rarely-touched limits behind
**Advanced**.

On iPhone and iPad that screen previously did not draw at all: it opened to a
clipped header and an empty box. It works now.

## Adding a large cloud folder is much faster

The app listed one folder at a time and waited for each before asking for the
next. On a local disk that is the right thing to do. On a cloud provider every
listing is a network round trip spent waiting, so a thousand folders meant a
thousand waits, one after another. It now asks for several at once — six, kept
deliberately inside what providers allow — while still applying the results in
order, so nothing about resuming an interrupted sync changes.

Two smaller costs went with it: the file count shown in the progress line was
recalculated from the whole folder on every step rather than counted as it went,
and every file cost three questions to the file system where one would do.

## Suggestions stop editing your writing

Accepting a suggested tag used to append `#tag` after your last paragraph.
Accepting a link added a `## Related` heading the app invented. A summary was
pushed in above your first line. All three now go into the note's properties —
`tags:`, `related:` and `summary:` — where metadata belongs, where you can remove
them again in the Properties pane, and where every other Markdown tool reads
them. Your prose comes back untouched, byte for byte.

**And front-matter tags are finally read.** If a note declared `tags:` the way
Obsidian does, HelloNotes could not see them at all — not in the tag list, not
filterable, not searchable. Three notes in the sample vault we ship were affected.

## Tags you can actually find, and fields you can actually read

The Mac's tag list only appeared once you started typing, so there was no way to
discover a collection even *had* tags. It is always shown now, ordered by how
many notes carry each. iPad had listed them all along.

Ten fields in iOS Settings had no visible label — "Daily notes" was two unnamed
boxes reading "Collection root" and "yyyy-MM-dd", and the Git fields could be
told apart only by guessing which example belonged to which. They are labelled.

Error messages are now selectable and have a copy button, everywhere the AI
features report a problem — previously they were cut to three lines, and the rest
was reachable only by hovering, which iPhone and iPad cannot do.

## For the record

The editor package declares support for iOS and its tests had only ever run on macOS. They run on both now, which is how four simultaneous defects in the UIKit half went unnoticed for so long.
