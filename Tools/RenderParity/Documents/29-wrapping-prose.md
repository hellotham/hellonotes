# On the length of a paragraph

There is a particular kind of paragraph that only appears in software writing, and it is the one where the author has decided that the reader needs the entire history of a decision before they are permitted to know what the decision was, so the sentence accumulates clauses the way a rolling stone is famously supposed not to accumulate moss, and by the time the verb finally arrives the reader has forgotten which of the four nouns it is meant to attach to.

I write these constantly. I am writing one now.

The cure is not shorter sentences as a rule, because a rule about length is a rule about the wrong thing, and prose written to a word count reads like prose written to a word count. The cure is to notice when a sentence has started explaining *why* before it has finished saying *what*, and to move the why afterwards, where it belongs, and where it can be skipped by anyone who already agrees.

Compare. Here is the same claim twice, once with the why first and once with the what first, and the difference is not length.

Because a cache that sits behind the coordinator has to pay coordination on every hit, and because coordination on a warm file is a syscall and a context switch rather than a network round trip, and because the vast majority of reads in a working session are warm, the cache was moved in front of the coordinator in 2.4.

The cache moved in front of the coordinator in 2.4. Behind it, every hit paid for coordination — a syscall and a context switch, even on a warm file — and almost every read in a working session is warm.

Same facts. Same length, near enough. The second one can be stopped after the first sentence and the reader still has the point, which is the only test of ordering that matters.
