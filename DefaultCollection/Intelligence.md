---
title: Intelligence
tags: [tour]
---

# Intelligence

Optional, and off until you ask for it.

## You choose where it runs

Every AI feature runs on Apple's **Foundation Models**, on one of these models:

| Model | Where your text goes to be processed |
|---|---|
| **Local (Apple)** (the default) | nowhere — Apple's model on this Mac, iPhone or iPad |
| **Cloud (Apple)** (the App Store version) | to Apple's Private Cloud Compute, for Apple's server model; it isn't stored, and it isn't accessible to Apple |
| **Local (*model name*)** | nowhere — an open model you download runs on this device, with MLX |

Pick the **Default model** in **Settings**, under **AI**. The writing tools and Research
use it, and so does the Assistant — whose menu can pick another for one conversation;
**New conversation** goes back to the default. Each Assistant reply, summary, suggested tag
or link, rewrite and new note's draft says which model made it, in small type beside it:
**Local (Apple)** with a lock, or **Cloud (Apple)** with a cloud.

Cloud (Apple) needs an internet connection, and not every device can use it. It reads far
more at once than Local (Apple), but it can't make suggestions as you type — a round trip
to Apple's servers can't keep up with typing, so those need a model on this device. Apple
sets a daily allowance. Settings and the Assistant say when you are close to it, and once
it is used up, Local (Apple) does the work instead until it resets — nothing to do, and
what it makes says Local (Apple).

Whichever model runs, a web search leaves the device. The Assistant
can look things up on the web — on its own, when a question needs it, while **Use my
notes** is on — and so can Research in New Note from a Prompt. What they search for goes to DuckDuckGo, and
can include words from your question or from notes they have read; a page they
read is fetched from its website. The Assistant and the AI settings say so too.

## The model's own settings

Under **Assistant** are the four settings the Foundation Models framework has, and no
invented ones:

| Setting | What it does |
|---|---|
| **Creativity** | how varied the answers are (0–2) |
| **Sampling** | Automatic, Greedy, Top-k or Top-p — how the next word is picked, with a seed for repeatable runs |
| **Maximum reply** | a shorter limit than the framework's own, if you want one |
| **Thinking** | how hard a reasoning model thinks, where the model reasons |

They apply to the **Assistant**. The writing tools use settings of their own for each
task, whatever you chose for conversation.

## What it does

| Action | Result |
|---|---|
| Summarise Note | a summary you can save to `summary:` in front matter |
| Suggest Tags | tags you tap to add to `tags:` |
| Suggest Links | links you tap to add to `related:` |
| Rewrite or Expand Note… | proposes a change you accept or reject |
| New Note from a Prompt (**⌃⌘N**) | writes or researches a note you read before it is created |
| Assistant (**⇧⌘A**) | answers questions from your notes, and shows the notes it read |

Nothing is written until you say so: a summary when you choose **Save to Properties**,
a tag or link when you tap it, and rewrites and new notes when you accept them.

## The Assistant

The Assistant is at the top of the sidebar, and opens as a tab beside your notes. Select
some text and choose **Ask the Assistant** to ask it about that passage.

With **Use my notes** on, it searches your notes — the words in them, any section of a
long note, and to the end of it — reads what it finds, and the conversation shows each
search and each note it read. With it off, it answers from the model alone and reads
nothing. When a conversation grows
longer than the model can hold, its earlier messages are summarised so it can go on.

It is **experimental**. It reads a few notes at a time, so it is not a full chat
assistant, and it doesn't change your notes: copy what you want from its reply into a
note yourself.

## Reporting a response

What the AI writes stays with you — in your notes, and the Assistant's conversations in
HelloNotes' own storage on this device. Nothing is posted anywhere, and there is no one else
to see it. If something it wrote is wrong or offensive, **Report…** is beside its answers
and suggestions: an Assistant reply, a rewrite, a new note's draft, a summary, and
suggested tags or links. It opens your mail app with a message
to us holding the response, what you asked, the model in use and the app's version — you
read it, and can change or delete any of it, before you send. HelloNotes sends nothing
itself. Anything else it wrote — a suggestion shown as grey text (**Suggest as I type**),
say — is reported by writing to us from **Settings ▸ Support ▸ Contact**.

Local (Apple) applies Apple's safeguards, and Cloud (Apple) is Apple's own model on
Apple's servers. An MLX model is the one you chose, and HelloNotes does not
filter what it writes.

## Open models with MLX

HelloNotes suggests no models: choosing one is the advanced end of the app.

MLX models live in one place, the **models folder**. Until you say otherwise that is
HelloNotes' own storage.

On a Mac your models are probably already here, in the Hugging Face cache
`~/.cache/huggingface/hub` that `mlx_lm` and the other MLX tools share — but macOS keeps
HelloNotes out of it until you allow it. **Access MLX Models…** opens that folder; one
click on **Allow** — no need to choose a model — and everything in it that HelloNotes can
run is listed, downloads join
it rather than making a second copy, and it stays allowed. **Change…** points the folder
somewhere else afterwards.

To add a model, give the name of an MLX language model on Hugging Face, like
`mlx-community/…`, and download it into the models folder. If Hugging Face isn't reachable
where you are, put a model into the folder another way.

Each model in the folder is an entry in the **Default model** picker, so you pick a model
the same way you pick Local (Apple). The Assistant's menu lists them too, so a
conversation can run a different model from the default. Each model in use is loaded into
memory, so two at once need room for both.

Not every open model can use tools. With one that can't, the AI settings say so: the
Assistant chats without reading your notes, and Research isn't available.

There are no API keys and no third-party AI services.
