# Review comments, thread 4

> Two things before this can land.
>
> 1. The retry bound has to be configurable, because ingest and index want
>    different numbers:
>
>    ```swift
>    struct RetryPolicy {
>        var limit: Int = 5
>        var backoff: Duration = .milliseconds(200)
>    }
>    ```
>
>    Defaulting to five is fine. Hard-coding five is not.
>
> 2. The log line needs the attempt number in it, or the loop is invisible in
>    aggregate:
>
>    ```text
>    backfill: row 41208 failed (attempt 3/5): timeout
>    ```
>
> Everything else looks right to me.

Both fair. The first one I had already started:

- `RetryPolicy` exists on the branch
  - it is not wired into the ingest path yet
  - the index path reads it correctly

    ```swift
    let policy = config.retry(for: .index)
    ```
- the log line is a one-character change and I will do it now
