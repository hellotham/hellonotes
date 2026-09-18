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

Pick one in **Settings**, under **AI**. It is one choice for everything — the Assistant,
the writing tools and Research — because the app is either using Apple's model or using
yours. The Assistant, Rewrite and the editor's AI menu name the model doing the work.
The Assistant can also look things up on the web — on its own, when a question
needs it — and so can Research in New Note from a Prompt. What they search for
goes to DuckDuckGo, and a page they read is fetched from its website.

## The model's own settings

Under **Assistant** are the four settings the Foundation Models framework has, and no
invented ones:

| Setting | What it does |
|---|---|
| **Creativity** | how varied the answers are (0–2) |
| **Sampling** | Automatic, Greedy, Top-k or Top-p — how the next word is picked, with a seed for repeatable runs |
| **Maximum reply** | a shorter limit than the framework's own, if you want one |
| **Thinking** | how hard a reasoning model thinks, where the model reasons |

They apply to the **Assistant**. The writing tools ask for what each task needs —
rewriting wants determinism whatever you chose for conversation.

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

MLX models live in one place, the **models folder**. On a Mac that is your Hugging Face
cache, `~/.cache/huggingface/hub`, where `mlx_lm` and the other MLX tools keep theirs:
whatever is already there and HelloNotes can run is listed, ready to use, and a download
goes into the same place rather than a second copy. On iPhone and iPad the models folder
is HelloNotes' own storage. Either way, **Change…** points it somewhere else.

To add a model, give the name of an MLX language model on Hugging Face, like
`mlx-community/…`, and download it into the models folder. If Hugging Face isn't reachable
where you are, put a model into the folder another way.

**One MLX model runs at a time**, so MLX means that model everywhere: the Assistant and
the writing tools share it, and which one it is you choose in the models list — once, not
once per role.

Not every open model can use tools. With one that can't, the AI settings say so: the
Assistant chats without reading or changing your notes, and Research isn't available.

There are no API keys and no third-party AI services.
