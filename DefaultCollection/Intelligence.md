---
title: Intelligence
tags: [tour]
---

# Intelligence

Optional, and off until you ask for it.

## You choose where it runs

Every AI feature runs on Apple's **Foundation Models**, on one of two models:

| Model | Where your text goes |
|---|---|
| **On-Device** (the default) | nowhere — it stays on this Mac, iPhone or iPad |
| **MLX** | nowhere — an open model you download runs on this device |

Pick one for the **Assistant** and one for the **writing tools** in the AI
settings. The Assistant, Rewrite and the editor's AI menu name the model doing the work.
The Assistant can also look things up on the web — on its own, when a question
needs it — and so can Research in New Note from a Prompt. What they search for
goes to DuckDuckGo, and a page they read is fetched from its website.

## What it does

| Action | Result |
|---|---|
| Summarise Note | writes `summary:` into front matter |
| Suggest Tags | adds to `tags:` |
| Suggest Links | adds to `related:` |
| Rewrite or Expand Note… | proposes a change you accept or reject |
| New Note from a Prompt (**⌃⌘N**) | writes or researches a note you read before it is created |
| Ask Library (**⇧⌘J**) | answers from your notes, with citations |
| Assistant (**⇧⌘A**) | a conversation about your collection |

Summaries, tags and links go into **front matter**. Rewrites, new notes and the
Assistant's edits change your notes only when you accept them.

## Open models with MLX

HelloNotes suggests no models: choosing one is the advanced end of the app. In the AI
settings, give the name of an MLX language model on Hugging Face, or choose a folder that
holds one. If Hugging Face isn't reachable where you are, get a model another way and
choose its folder.

On a Mac, a model you already downloaded with other MLX tools is in your Hugging Face
cache, `~/.cache/huggingface/hub`. Choose the model's own folder there — the one named like
`models--mlx-community--…` — rather than a folder inside it.

Not every open model can use tools. With one that can't, the AI settings say so: the
Assistant chats without reading or changing your notes, and Research isn't available.

There are no API keys and no third-party AI services.
