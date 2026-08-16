# Semantic retrieval: what to build, measured

> Decision record for 1.3 §3 ("the semantic index"). Measured 2026-08-16 against
> the 2,027-note vault at `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/My Vault`.
> Harness: `scratchpad/EmbedBench` (reproducible: `swift run -c release EmbedBench <vault>`).

**Outcome: do not build an on-device embedding index for 1.3.** A term-weighted
lexical index wins on quality *and* costs ~400× less to build. The plan said the
backend would be chosen by measurement rather than assertion; this is that
measurement returning an answer nobody expected.

---

## What was measured

Three backends, identical input, identical scoring:

- `NLEmbedding.sentenceEmbedding(for: .english)` — Apple's static sentence model
- `NLContextualEmbedding(language: .english)` — Apple's on-device transformer
- **TF-IDF (hashed, 2048-dim)** — the baseline, and the whole reason the result
  is trustworthy. The app already retrieves by keyword overlap
  (`LibraryChatView.retrieve`), so without a baseline the benchmark could only
  say which of two things we had already decided to build was better.

### Ground truth

Not hand-labelled. The vault contains **520 resolvable note-to-note links**
across 285 source notes — relatedness judgements made in context by the person
whose vault it is, which beats anything labelled from outside and is exactly the
signal auto-linking has to reproduce.

Counted from both `[[wiki-links]]` and `[text](Note.md)` links, resolved the way
Obsidian resolves them: `[[Folder/Note]]`, `[[Note#Heading]]` and `[[Note]]` all
name the same file. Getting that wrong matters enormously — matching raw targets
against titles found only 295 pairs, and in this vault the subfolder-qualified
links were *the only ones that resolved at all*.

**Validity control.** Link markup is stripped from the text every backend sees.
Without it, a note containing `[[Second Brain]]` literally contains the words
"Second Brain", and plain substring search would "win" — measuring nothing.

**What this can and cannot show.** Recall on author-authored links is a *lower
bound*: an unlinked pair is not evidence of unrelatedness, which is the entire
premise of auto-linking. Precision is **not** measured here at all and needs
human review of real proposals before §4 ships.

### Instrument check

Run before trusting any number, because a benchmark is an instrument and this
repo has lost a session to an instrument artefact before (implemented.md §17).
Six paraphrase-vs-unrelated triples:

| Backend | Paraphrase ranked above unrelated | Mean margin |
|---|---|---|
| `NLEmbedding.sentenceEmbedding` | 6/6 | 0.287 |
| `NLContextualEmbedding` | 6/6 | 0.081 |
| TF-IDF baseline | 5/6 | 0.069 |

**The neural models are not broken.** They beat the baseline decisively at the
thing embeddings are *for*. They still lose below, and that tension is the
finding — not a bug.

---

## Results

2,007 notes with ≥80 characters of prose · 29,668 chunks · 285 queries · 520 pairs

| Backend | Pooling | dim | recall@5 | recall@10 | MRR | build | search | index |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| **TF-IDF** | **mean-of-chunks** | 2048 | **42.9%** | **52.1%** | **0.324** | **2.4s** | 0.72s | 15.7 MB |
| TF-IDF | max-over-chunks | 2048 | 38.4% | 48.9% | 0.287 | 2.4s | 15.61s | 231.6 MB |
| `NLContextualEmbedding` | max-over-chunks | 512 | 30.2% | 38.3% | 0.221 | 950.9s | 3.82s | 57.9 MB |
| `NLContextualEmbedding` | mean-of-chunks | 512 | 24.6% | 30.6% | 0.201 | 950.9s | 0.54s | 3.9 MB |
| `NLEmbedding.sentence` | mean-of-chunks | 512 | 22.0% | 27.7% | 0.194 | 2090.1s | 1.41s | 3.9 MB |
| `NLEmbedding.sentence` | max-over-chunks | 512 | 20.1% | 28.1% | 0.181 | 2090.1s | 7.04s | 57.9 MB |

Extrapolated to a 10,000-note vault: TF-IDF **0.2 min**, `NLContextualEmbedding`
**79 min**, `NLEmbedding.sentenceEmbedding` **174 min**.

### Reading the table

1. **The baseline wins by 1.4× on recall@10 and 1.5× on MRR**, for 1/400th of
   the build cost. That is not a close call.
2. **`NLEmbedding.sentenceEmbedding` is both worst and slowest** — eliminated
   outright; it is a *sentence* model and note-length passages are not its job.
3. **Note-level beats chunk-level for the winner**, and is 20× faster to search
   and 15× smaller. Convenient, and not what chunk-max retrieval folklore
   predicts.
4. **Why the neural models lose here.** This vault is scholarly (Buddhist
   studies): its links are driven by rare distinctive terms — *Bronkhorst*,
   *Pāli*, *Sanskrit*, *Pali Text Society*. Rare terms are precisely where IDF
   weighting is strongest and where a small general-purpose embedding washes
   proper nouns into the background. The instrument check shows the models
   capture paraphrase; this vault's links mostly are not paraphrase.

### Round two: which lexical scheme, and how simple can it be

The first round had exactly one lexical entrant, which only proves it beat the
neural ones — not that it was the best lexical scheme. Two follow-ups, both cheap
because the lexical path builds in seconds:

| Scheme | recall@5 | recall@10 | MRR | build |
|---|---:|---:|---:|---:|
| **TF-IDF, capped note, one vector per note** | **43.2%** | 51.0% | 0.320 | 7.6s |
| TF-IDF, mean of chunk vectors | 42.9% | **52.1%** | **0.324** | 2.6s |
| TF-IDF, whole note, uncapped | 40.3% | 50.4% | 0.307 | 44.3s |
| TF-IDF, max over chunk vectors | 38.4% | 48.9% | 0.287 | 2.6s |
| BM25, note-level | 25.3% | 36.7% | 0.207 | 20.0s |

**BM25 loses badly, which is worth explaining** because it is the textbook
choice and would have been shipped on that reputation. BM25 is built for *short
queries*: its term saturation and asymmetric query/document treatment assume a
handful of query terms scored against many documents. Here the "query" is an
entire note — thousands of terms — and those assumptions stop paying. Cosine
between two normalised document vectors is the right tool for document-to-document
similarity, and the measurement says so by 17 points.

**Chunking does not earn its complexity.** Capped-note and mean-of-chunks are
statistically indistinguishable (43.2%/51.0% against 42.9%/52.1%). Splitting the
two effects apart shows why: mean-of-chunks was doing *two* things — capping how
much of a note is read, and normalising each chunk — and it is the **cap** that
carries the win, since uncapped whole-note loses 2.6 points and takes 6× longer
to build. So the shipping index stores **one sparse vector per note** and no
per-chunk state at all, which matters enormously for an index that has to update
incrementally.

### How much needs an index at all

Of the 520 pairs, **209 (40%) already have the target's title verbatim in the
source note** after link stripping — the existing unlinked-mention scan finds
those with no index of any kind. Only the remaining **311 (60%)** are pairs a
retrieval method has to earn. Auto-linking should therefore run the exact,
already-built mention scan *first* and spend retrieval only on the rest.

---

## What was built

`Core/RelatednessIndex.swift` — TF-IDF over hashed terms, **one L2-normalised
sparse vector per note**, ranked by cosine over an inverted index. An `actor`,
because building it reads and tokenises every note and none of that may run on
the main actor. `Core/RetrievalText.swift` holds the text preparation, including
the length cap that the measurement showed carries the win.

Built **lazily, on first use** rather than at launch: building reads every note
once, which is ~12 seconds of coordinated I/O on the measured iCloud vault, and
a session may never ask for a suggestion. It is pure derived data, so building
late costs nothing but the first call.

The first payoff is link suggestion. It previously handed the model *every* note
title, so it silently degraded as a vault grew — past a context window the
candidates were whichever titles happened to sort first. It now retrieves the 40
nearest notes and asks the model to judge those: retrieval narrows, the model
decides.

- **`RelatednessIndex` is a protocol, and that is load-bearing.** Second-brain
  frameworks are coming, and a Zettelkasten collection does not mean the same
  thing by "related" as a PARA one — that is a different scorer over the same
  corpus, chosen per collection. It also pairs with
  `LLM/ProviderCapabilities.swift`: when a better on-device model ships, re-run
  this harness. The decision becomes a re-measurement, not a rewrite.
- **The paraphrase limitation is pinned by a test**, not left as folklore.
  `paraphraseWithoutSharedTermsIsNotFound` asserts what this scheme genuinely
  cannot do. If a future model changes that, the test starts failing — and that
  failure is the signal to re-run the benchmark, not to delete the test.
- **A hard character ceiling on chunks, enforced after tokenisation.** Not
  defensive padding — load-bearing. A PDF-converted note in this vault contains
  no sentence-ending punctuation, so `NLTokenizer` returns the whole note as one
  "sentence": the longest chunk produced was **327,680 characters** against a
  median of 839, and embedding it aborts the process with `std::bad_alloc`. Two
  full 30-minute runs died at the same chunk index before the length histogram
  was actually looked at. Any chunker that ships needs this, plus a sub-split for
  single "words" longer than the ceiling (converted notes contain base64 blobs).

## Limits of this measurement

- **One vault, one domain.** A vault of conceptual essays rather than
  terminological scholarship could plausibly flip the ranking. The harness takes
  a path argument; re-running it on a second vault is minutes of work and is the
  right response to any doubt.
- **520 pairs** detects a 1.4× gap comfortably; it would not settle a 5% one.
- **Precision unmeasured.** §4's precision floor needs human review of real
  proposals, not this.
- **Hybrid untested.** TF-IDF for candidates with neural re-ranking might beat
  either alone. Not measured, and hard to justify at 79 minutes of build cost per
  10,000 notes.
