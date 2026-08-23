> A programme that produces incorrect results twice as fast is infinitely
> slower.
>
> — attributed to John Ousterhout, probably wrongly

I have been carrying this around all week because of the index.

The walk is genuinely twice as fast as it was in 2.3. It is also skipping every
file it cannot read, silently, which means the index is now *confidently*
incomplete rather than slowly complete.

- 2.3: 41 seconds, every note indexed
- 2.4: 19 seconds, 38 notes missing, no warning

The fix is not to make it slow again. The fix is to count what was skipped and
say so.
