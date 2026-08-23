

Started this one on the train and lost the first paragraph to a dead battery,
so it begins in the middle.

The point I was making is that the retry loop in the backfill script is not a
resilience feature. It is a way of turning a loud failure into a quiet one.

> Retry forever, log nothing, and the script never fails. It also never
> finishes, and nobody finds out until the backfill window closes.

- Bound the retries
- Log every one of them
- Fail the run when the bound is hit
