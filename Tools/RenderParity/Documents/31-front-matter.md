---
title: Retry policy
status: draft
owner: chandra
reviewers:
  - ana
  - bo
tags: [backfill, reliability]
---

# Retry policy

Every retrying component in the system currently invents its own policy, and
three of the four invented "forever".

## Proposal

One `RetryPolicy` value, configured per subsystem:

```swift
struct RetryPolicy: Sendable {
    var limit: Int
    var backoff: Duration
    var jitter: Double
}
```

| Subsystem | Limit | Backoff |
| --- | ---: | --- |
| Ingest | 3 | 500 ms |
| Index | 5 | 200 ms |
| Serve | 1 | none |

## Open questions

- Does the limit count the first attempt? (I say no.)
- What does the *caller* see when the limit is hit — an error, or a partial
  result with a flag on it?

> Chandra's view is that a partial result is always a mistake, because
> everything downstream ignores the flag. I have not found a counter-example.
