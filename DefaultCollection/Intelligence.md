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
| **System** (the default) | nowhere — Apple's model on this Mac, iPhone or iPad |
| **MLX** | nowhere — an open model you download runs on this device |

Pick one for the **Assistant** and one for the **writing tools** in **Settings**, under
**AI**. The Assistant, Rewrite and the editor's AI menu name the model doing the work.
The Assistant can also look things up on the web — on its own, when a question
needs it — and so can Research in New Note from a Prompt. What they search for
goes to DuckDuckGo, and a page they read is fetched from its website.

## What it does

| Action | Result |
|---|---|
| Summarise Note | a summary you can save to `summary:` in front matter |
| Suggest Tags | tags you tap to add to `tags:` |
| Suggest Links | links you tap to add to `related:` |
| Rewrite or Expand Note… | proposes a change you accept or reject |
| New Note from a Prompt (**⌃⌘N**) | writes or researches a note you read before it is created |
| Ask Library (**⇧⌘J**) | answers from your notes, with citations |
| Assistant (**⇧⌘A**) | a conversation about your collection |

Nothing is written until you say so: a summary when you choose **Save to Properties**,
a tag or link when you tap it, and rewrites, new notes and the Assistant's edits when
you accept them.

## Open models with MLX

HelloNotes suggests no models: choosing one is the advanced end of the app.

MLX models live in one place, the **models folder**. On a Mac, choose your Hugging Face
cache, `~/.cache/huggingface/hub` — where other MLX tools keep their models — and the MLX
language models there that HelloNotes can run are listed, ready to use. On iPhone and iPad the models folder is
HelloNotes' own storage unless you choose another.

To add a model, give the name of an MLX language model on Hugging Face, like
`mlx-community/…`, and download it into the models folder. If Hugging Face isn't reachable
where you are, put a model into the folder another way. One MLX model runs at a time.

Not every open model can use tools. With one that can't, the AI settings say so: the
Assistant chats without reading or changing your notes, and Research isn't available.

There are no API keys and no third-party AI services.
