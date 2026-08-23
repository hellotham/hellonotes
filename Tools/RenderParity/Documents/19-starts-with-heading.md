## Rollback plan

If the flag has to come off, the order matters: reads first, then the flag,
then the backfill.

1. Point the read path back at the old table
2. Flip the flag off for every account
3. Stop the backfill worker
4. **Do not** truncate the new table — we will want the rows next time

Erin owns the decision. Anyone can execute it.
