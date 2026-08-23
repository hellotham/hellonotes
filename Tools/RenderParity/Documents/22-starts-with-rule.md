---

Picked this up mid-thread, so the top is missing. What follows is from Chandra,
lightly cleaned up.

> The dashboards are not the problem. The problem is that we have three
> different definitions of "error rate" and every one of them is on a different
> dashboard.

Agreed, and I would go further: the definitions are fine individually. It is
the shared *name* that does the damage.

- Ingest counts a retry as one error
- Index counts a retry as zero errors and the final failure as one
- Serve counts every 5xx, retried or not

Pick one, rename the other two.
