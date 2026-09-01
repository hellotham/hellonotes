---
title: Intelligence
tags: [tour]
---

# Intelligence

Optional, and off until you ask for it.

## On device, by default

On Apple Intelligence hardware, HelloNotes uses Apple's **on-device Foundation
Models**. Your notes are not sent anywhere.

## What it does

| Action | Result |
|---|---|
| Summarise Note | writes `summary:` into front matter |
| Suggest Tags | adds to `tags:` |
| Suggest Links | adds to `related:` |
| Rewrite or Expand | proposes a change you accept or reject |
| Ask Library (**⇧⌘J**) | answers from your notes, with citations |
| Assistant (**⇧⌘A**) | a conversation about your collection |

Everything it writes goes into **front matter**. It never rewrites your prose
without asking.

## Your own key

You can point it at another provider instead — sixteen are supported — by adding
your own API key in Settings. In that case the text goes to that provider under
your own account, and the app says so before it does.
