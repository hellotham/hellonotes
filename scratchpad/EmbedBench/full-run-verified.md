# Semantic index benchmark

Vault:      /Users/christie/Library/Mobile Documents/iCloud~md~obsidian/Documents/My Vault
Notes:      2007 with ≥80 characters of prose
Chunks:     29668 (mean 14.8 per note)
Load:       12.3s (coordinated reads)

## Ground truth

Queries:    285 notes that link to at least one other note in the vault
Pairs:      520 author-authored links (mean 1.8 per query)

Link markup is stripped from the text every backend sees, so a target's title
is never present as a lexical clue. Recall here is a LOWER BOUND: an unlinked
pair is not evidence of unrelatedness, which is the premise of auto-linking.

## Instrument check

Paraphrase pairs must outrank unrelated text, or nothing below is worth reading.

- `TF-IDF (hashed, baseline)` — 5/6 paraphrase pairs ranked above unrelated, mean margin 0.069 — **marginal**
- `NLEmbedding.sentenceEmbedding` — 6/6 paraphrase pairs ranked above unrelated, mean margin 0.287 — **ok**
- `NLContextualEmbedding` — 6/6 paraphrase pairs ranked above unrelated, mean margin 0.081 — **ok**

## Results

| Backend | Pooling | dim | recall@5 | recall@10 | MRR | build | search | index size |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| TF-IDF (hashed, baseline) | mean-of-chunks | 2048 | 42.9% | 52.1% | 0.324 | 2.4s | 0.72s | 15.7 MB |
| TF-IDF (hashed, baseline) | max-over-chunks | 2048 | 38.4% | 48.9% | 0.287 | 2.4s | 15.61s | 231.6 MB |
| NLContextualEmbedding | max-over-chunks | 512 | 30.2% | 38.3% | 0.221 | 950.9s | 3.82s | 57.9 MB |
| NLContextualEmbedding | mean-of-chunks | 512 | 24.6% | 30.6% | 0.201 | 950.9s | 0.54s | 3.9 MB |
| NLEmbedding.sentenceEmbedding | max-over-chunks | 512 | 20.1% | 28.1% | 0.181 | 2090.1s | 7.04s | 57.9 MB |
| NLEmbedding.sentenceEmbedding | mean-of-chunks | 512 | 22.0% | 27.7% | 0.194 | 2090.1s | 1.41s | 3.9 MB |

### Per-note cost, extrapolated

- **TF-IDF (hashed, baseline)**: 1.2ms/note → 0.2min for a 10,000-note vault; 26 chunks returned no vector
- **NLEmbedding.sentenceEmbedding**: 1041.4ms/note → 173.6min for a 10,000-note vault
- **NLContextualEmbedding**: 473.8ms/note → 79.0min for a 10,000-note vault
