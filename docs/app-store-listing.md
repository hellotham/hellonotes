# App Store listing — 1.3.3

> **The copy for the version being prepared — not a record of what is live.**
> App Store Connect is the source of truth for the live listing
> (`docs/production.md` §4 explains why the runbook stopped carrying it). Before
> editing this file for a new version, refresh it from App Store Connect, per
> platform. It exists as a file so `StoreListingTests` can check every field
> against App Store Connect's limits and the listing rules *before* anything is
> pasted — the two defects those tests were written for (a 173-character
> promotional text, and a Description with no EULA link that got build 14
> rejected) were both invisible prose.
>
> Started from the live iOS description on 15 September 2026
> (`itunes.apple.com/lookup?id=6803259848`). The live **Mac** copy was read from
> App Store Connect on 16 September and its Mac-only lines carried across: it
> opens "…for your Mac", keeps *Multi-tab editing and open-in-new-window* and
> *keyboard-first* under EXPORT & MORE, and manages the subscription "in your
> Apple Account settings" rather than by the Settings path iOS uses — which is
> the phrasing that passed review, and replaces a guess made here.

## Note for App Review (macOS) — settled, 2026-09-19

The Mac app carries **no temporary-exception entitlement**. It asked for one,
`com.apple.security.temporary-exception.files.home-relative-path.read-write`
for `/.cache/huggingface/`, so it could list the MLX models a Mac already has
without making the person find the folder. App Review refused it on builds 23
and 24 under **guideline 2.4.5(i)**: *"not appropriate and will not be
granted … we encourage you to investigate other ways of implementing the
desired functionality."*

The other way is the sandbox's own: **Access MLX Models…** in Settings ▸ AI
opens a folder panel already pointed at `~/.cache/huggingface/hub`, one click
on Open grants it, and a security-scoped bookmark keeps it. Until then models
live in the app's own container. Nothing outside the container is reached
except through user-selected folders and their bookmarks — the same way the
app reaches notes.

**Do not re-add the entitlement.** It is refused in writing, on two builds.

## Fields for both platforms

**Subtitle** (≤30 chars):
```
Local-first Markdown notes
```

**Promotional text** (≤170 chars, editable any time without review):
```
Plain Markdown files you own, with AI from Apple Foundation Models on your device or on Private Cloud Compute — or an open model you run on your device with MLX.
```

**Keywords** (≤100 chars, comma-separated):
```
markdown,knowledge base,wiki,backlinks,zettelkasten,pkm,notes,notetaking,git,graph,local,privacy
```

**Version** — What's New in 1.3.3:
```
HelloNotes now runs its AI on Apple Foundation Models.

• Choose where AI runs: Apple Intelligence on your device, Apple's server model on Private Cloud Compute, or an open model you download and run on your device with MLX. If Hugging Face isn't reachable where you are, you can choose a model folder instead.
• Summaries now cover the whole of a long note, not just its opening. Tag suggestions come back in the note's own language, and link suggestions only ever name notes you have.
• The Assistant looks through your notes before it answers, and changes nothing without your approval. Several changes proposed at once now wait their turn instead of failing.
• Third-party AI services and API keys are gone. Any keys you had stored for them are deleted from this device.

Also in this version:
• A simpler window. Your collection is on the left, the note is in the middle, and what the note is — its outline, tags, links, properties, history and graph — is in one panel on the right. The Mind Map, the Assistant and Ask Your Library open as tabs beside your notes.
• The Mind Map draws the links across a whole collection; the Graph shows one note's links in and out.
• Find and Replace understands regular expressions.
• Return continues a list, a note scrolls past its last line, and the blank lines you type are shown.
• On an iPad held upright, the on-screen keyboard no longer rearranges the window.
• Report… beside the AI's answers and suggestions opens an email to us, and Settings > Support > Contact has our address.

HelloNotes 1.3.3 requires iOS 27 or macOS 27.
```

## Description

**Description** — iPhone and iPad (≤4000 chars):
```
HelloNotes is a fast, private, local-first Markdown knowledge base for iPhone and iPad. Your notes are plain .md files in a folder you choose — no account, no lock-in, no cloud required.

WRITE IN LIVE MARKDOWN
• A native editor with live styling — headings, bold, lists, tables and syntax-highlighted code
• LaTeX math ($…$ and $$…$$) and Mermaid diagrams rendered inline
• Obsidian-style callouts, hidden comments, and a clean editor that tucks YAML front matter into an editable Properties panel

CONNECT YOUR IDEAS
• [[Wiki-links]] with autocomplete, including links straight to a heading
• Backlinks and unlinked mentions, with one-click linking
• #tags (nested) with autocomplete, and a Tags view of every tag in the collection
• Note transclusion — embed a whole note or a single section
• A mind map of the links across your whole vault, and a graph of each note's links in and out

FIND ANYTHING
• Full-text search and "Open Quickly" across notes and headings
• Bookmarks, daily notes and templates

AI ON YOUR DEVICE, OR ON PRIVATE CLOUD COMPUTE
• Summarise a note, suggest tags and links, and rewrite a passage — with Apple Foundation Models, powered by Apple Intelligence
• "Ask your library": answers grounded in your own notes, with citations
• An Assistant that can search and read your notes, look things up on the web, and edit notes only with your approval
• Run Apple's model on your device, or choose Private Cloud Compute for Apple's server model: what it is sent isn't stored, and isn't accessible to Apple
• Or download an open model and run it on your device with MLX
There are no third-party AI services and no API keys.

VERSION HISTORY WITH GIT
• Built-in Git: initialise a repo, browse a note's history and restore earlier versions

EXPORT & MORE
• Export to HTML or PDF
• Full light and dark support

Your files stay yours — readable in any editor, syncable with any tool. HelloNotes just makes them a joy to think in.

SUPPORTING HELLONOTES (OPTIONAL)
HelloNotes is free, and every feature is included for everyone. Two entirely optional purchases live in Settings > Support. Backing HelloNotes adds one thing — the ability to send a support request from inside the app — and nothing else:
• Champion — a one-off contribution of A$50. You can give more than once; the app remembers how many times.
• Commercial — an annual licence for using HelloNotes at work. A$50 per year, an auto-renewable subscription charged to your Apple Account on confirmation and renewing each year unless turned off at least 24 hours before the period ends. Manage or cancel it in Settings > your name > Subscriptions.

Terms of Use (EULA): https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
Privacy Policy: https://hellotham.com/hellonotes/privacy
```

**Description** — Mac (≤4000 chars):
```
HelloNotes is a fast, private, local-first Markdown knowledge base for your Mac. Your notes are plain .md files in a folder you choose — no account, no lock-in, no cloud required.

WRITE IN LIVE MARKDOWN
• A native editor with live styling — headings, bold, lists, tables and syntax-highlighted code
• LaTeX math ($…$ and $$…$$) and Mermaid diagrams rendered inline
• Obsidian-style callouts, hidden comments, and a clean editor that tucks YAML front matter into an editable Properties panel

CONNECT YOUR IDEAS
• [[Wiki-links]] with autocomplete, including links straight to a heading
• Backlinks and unlinked mentions, with one-click linking
• #tags (nested) with autocomplete, and a Tags view of every tag in the collection
• Note transclusion — embed a whole note or a single section
• A mind map of the links across your whole vault, and a graph of each note's links in and out

FIND ANYTHING
• Full-text search and "Open Quickly" across notes and headings
• Bookmarks, daily notes and templates

AI ON YOUR MAC, OR ON PRIVATE CLOUD COMPUTE
• Summarise a note, suggest tags and links, and rewrite a passage — with Apple Foundation Models, powered by Apple Intelligence
• "Ask your library": answers grounded in your own notes, with citations
• An Assistant that can search and read your notes, look things up on the web, and edit notes only with your approval
• Run Apple's model on your Mac, or choose Private Cloud Compute for Apple's server model: what it is sent isn't stored, and isn't accessible to Apple
• Or download an open model and run it on your Mac with MLX
There are no third-party AI services and no API keys.

VERSION HISTORY WITH GIT
• Built-in Git: initialise a repo, browse a note's history and restore earlier versions

EXPORT & MORE
• Export to HTML or PDF
• Multi-tab editing and open-in-new-window
• Full light and dark support, keyboard-first

Your files stay yours — readable in any editor, syncable with any tool. HelloNotes just makes them a joy to think in.

SUPPORTING HELLONOTES (OPTIONAL)
HelloNotes is free, and every feature is included for everyone. Two entirely optional purchases live in Settings > Support. Backing HelloNotes adds one thing — the ability to send a support request from inside the app — and nothing else:
• Champion — a one-off contribution of A$50. You can give more than once; the app remembers how many times.
• Commercial — an annual licence for using HelloNotes at work. A$50 per year, an auto-renewable subscription charged to your Apple Account on confirmation and renewing each year unless turned off at least 24 hours before the period ends. Manage or cancel it in your Apple Account settings.

Terms of Use (EULA): https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
Privacy Policy: https://hellotham.com/hellonotes/privacy
```

## Private Cloud Compute

**In this copy from build 33 — and never pasted with an earlier build.** Apple
granted the managed entitlement on 17 October 2026, and build 33 is the first
to carry it with the `PRIVATE_CLOUD_COMPUTE` compilation condition
(`docs/production.md` §1b-PCC). Build 32 — in review on iOS when it was granted
— does not offer the model at all, so its listing must not name it: metadata
describing a choice the build under review lacks is Guideline 2.3's
inaccurate metadata. The promotional text is the exception that can be changed
without review, which makes it the easiest one to paste early by mistake.
"The AI runs on your device" went from both Descriptions, because it is untrue
of that choice; what is sent is described in Apple's words for it, the same
sentence the app prints under the picker
(`LanguageModels.privacySummary(of:)`). `StoreListingTests` still fails a
listing that names the model in a build that cannot offer it.

## Notes to reviewer (both platforms)

```
HelloNotes is a local-first Markdown editor. Nothing needs to be set up: a sample collection is bundled in the app and opens by itself on first launch, so the tour, the manual and every feature below are reachable immediately. To use your own notes instead, choose Open… and pick any folder of .md files.

All notes stay on the device in plain files; no account and no network are required for any core feature.

AI. The AI features run on Apple Foundation Models, on the device — with Apple Intelligence where it is available and turned on. In Settings ▸ AI ▸ Model a person can instead choose Private Cloud Compute, Apple's server model (the managed entitlement com.apple.developer.private-cloud-compute, granted to this app on 17 October 2026); the line under the picker then says the text is sent to Apple's Private Cloud Compute to process, isn't stored and isn't accessible to Apple; a line there says when the day's allowance is nearly or fully used; and in an Assistant conversation a line above the message field says the conversation so far is sent with each message. Optionally, a person can download an open-source model from Hugging Face and run it on the device with MLX (Settings ▸ AI ▸ MLX Models); nothing is downloaded unless they ask. To answer a question, the Assistant — and Research, in New Note from a Prompt — can search the web through DuckDuckGo; the results are read by the chosen model — on the device, or on Private Cloud Compute when that is chosen. The app contains no third-party AI services, no ChatGPT or OpenAI integration, and no API keys or AI credentials of any kind.

SAFEGUARDS (Guideline 1.2). What the AI writes goes only into the person's own notes — files on their device or in their own cloud storage — and the Assistant's conversations, kept in the app's own storage on the device. HelloNotes has no accounts, no other users and nowhere in the app to publish what it writes, so nothing it generates is shown to anyone else unless the person sends it somewhere themselves. The on-device System model applies Apple's guardrails, and Private Cloud Compute is Apple's own model on Apple's servers; an MLX model is one the person chooses and downloads themselves, and HelloNotes does not filter its output. The AI's answers and suggestions — Assistant replies, Ask Your Library answers, rewrites, New Note from a Prompt drafts, and the summary, tag and link suggestions in the right panel — have Report… beside them, which opens an email to info@hellotham.com carrying the response, the question, the model in use and the app version, for the person to read before sending. Settings ▸ Support ▸ Contact gives everyone the same address and the support website (hellotham.com/hellonotes/support), for anything else the AI wrote — the suggestions shown as grey text while typing, for one — and for anything at all.

IN-APP PURCHASES. Settings ▸ Support shows both products, under Champion and Commercial: Champion (a repeatable one-off contribution) and Commercial (an annual auto-renewable subscription). That screen carries the subscription's title, length, price per period, and working links to the Terms of Use (EULA) and the privacy policy. Every feature of the app is included for everyone; the only thing backing it adds is the ability to send a support request from inside the app, and that screen says so.
```
