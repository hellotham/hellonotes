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
> (`itunes.apple.com/lookup?id=6803259848`). The Mac description in App Store
> Connect opens "…for your Mac" and may differ elsewhere; **read the live Mac
> copy and carry its Mac-specific lines across before pasting**.

## Fields for both platforms

**Subtitle** (≤30 chars):
```
Local-first Markdown notes
```

**Promotional text** (≤170 chars, editable any time without review):
```
Plain Markdown files you own, with AI from Apple Foundation Models on your device — or an open model you download and run on your device with MLX.
```

**Keywords** (≤100 chars, comma-separated):
```
markdown,knowledge base,wiki,backlinks,zettelkasten,pkm,notes,notetaking,git,graph,local,privacy
```

**Version** — What's New in 1.3.3:
```
HelloNotes now runs its AI on Apple Foundation Models.

• Choose where AI runs: Apple Intelligence on your device, or an open model you download and run on your device with MLX. If Hugging Face isn't reachable where you are, you can choose a model folder instead.
• Summaries now cover the whole of a long note, not just its opening. Tag suggestions come back in the note's own language, and link suggestions only ever name notes you have.
• The Assistant looks through your notes before it answers, and changes nothing without your approval. Several changes proposed at once now wait their turn instead of failing.
• Third-party AI services and API keys are gone. Any keys you had stored for them are deleted from this device.

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
• #tags (nested) with autocomplete, searchable from the inspector
• Note transclusion — embed a whole note or a single section
• An interactive graph view of your whole vault

FIND ANYTHING
• Full-text search and "Open Quickly" across notes and headings
• Bookmarks, daily notes and templates

AI THAT STAYS ON YOUR DEVICE
• Summarise a note, suggest tags and links, and rewrite a passage — with Apple Foundation Models, powered by Apple Intelligence
• "Ask your library": answers grounded in your own notes, with citations
• An Assistant that can search and read your notes, look things up on the web, and edit notes only with your approval
• Or download an open model and run it on your device with MLX
The AI runs on your device. There are no third-party AI services and no API keys.

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
• #tags (nested) with autocomplete, searchable from the inspector
• Note transclusion — embed a whole note or a single section
• An interactive graph view of your whole vault

FIND ANYTHING
• Full-text search and "Open Quickly" across notes and headings
• Bookmarks, daily notes and templates

AI THAT STAYS ON YOUR MAC
• Summarise a note, suggest tags and links, and rewrite a passage — with Apple Foundation Models, powered by Apple Intelligence
• "Ask your library": answers grounded in your own notes, with citations
• An Assistant that can search and read your notes, look things up on the web, and edit notes only with your approval
• Or download an open model and run it on your Mac with MLX
The AI runs on your Mac. There are no third-party AI services and no API keys.

VERSION HISTORY WITH GIT
• Built-in Git: initialise a repo, browse a note's history and restore earlier versions

EXPORT & MORE
• Export to HTML or PDF
• Full light and dark support

Your files stay yours — readable in any editor, syncable with any tool. HelloNotes just makes them a joy to think in.

SUPPORTING HELLONOTES (OPTIONAL)
HelloNotes is free, and every feature is included for everyone. Two entirely optional purchases live in Settings > Support. Backing HelloNotes adds one thing — the ability to send a support request from inside the app — and nothing else:
• Champion — a one-off contribution of A$50. You can give more than once; the app remembers how many times.
• Commercial — an annual licence for using HelloNotes at work. A$50 per year, an auto-renewable subscription charged to your Apple Account on confirmation and renewing each year unless turned off at least 24 hours before the period ends. Manage or cancel it in the App Store: your name > Account Settings > Subscriptions > Manage.

Terms of Use (EULA): https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
Privacy Policy: https://hellotham.com/hellonotes/privacy
```

## Private Cloud Compute

**Not in this copy, deliberately.** Offering Private Cloud Compute needs Apple's
managed entitlement, which is not yet granted (the request form opens once the
App Store Small Business Program enrolment is approved). Without it the build
does not offer the model at all — see `LanguageModels.privateCloudComputeEnabled`
— so the listing must not mention it either. When the entitlement arrives, add it
to the promotional text and the AI section in the same change that adds the
entitlement and the `PRIVATE_CLOUD_COMPUTE` compilation condition, and adjust
"The AI runs on your device", which stops being true of that choice.

## Notes to reviewer (both platforms)

```
HelloNotes is a local-first Markdown editor. Nothing needs to be set up: a sample collection is bundled in the app and opens by itself on first launch, so the tour, the manual and every feature below are reachable immediately. To use your own notes instead, choose Open… and pick any folder of .md files.

All notes stay on the device in plain files; no account and no network are required for any core feature.

AI. The AI features run on Apple Foundation Models, on the device — with Apple Intelligence where it is available and turned on. Optionally, a person can download an open-source model from Hugging Face and run it on the device with MLX (Settings ▸ AI ▸ MLX Models); nothing is downloaded unless they ask. To answer a question, the Assistant — and Research, in New Note from a Prompt — can search the web through DuckDuckGo; the results are read by the model on the device. The app contains no third-party AI services, no ChatGPT or OpenAI integration, and no API keys or AI credentials of any kind.

IN-APP PURCHASES. Settings ▸ Support ▸ Support HelloNotes shows both products: Champion (a repeatable one-off contribution) and Commercial (an annual auto-renewable subscription). That screen carries the subscription's title, length, price per period, and working links to the Terms of Use (EULA) and the privacy policy. Every feature of the app is included for everyone; the only thing backing it adds is the ability to send a support request from inside the app, and that screen says so.
```
