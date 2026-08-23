# Migration log

Running notes, newest at the bottom, because that is the order they happened
in and re-sorting them lies about what I knew when.

## 4 August

Started the backfill on staging. It ran for six hours and stopped, and the
stopping is the interesting part: no error, no log line, exit code zero.

```text
backfill: 41,208 rows
backfill: done
```

Forty-one thousand of three million.

## 5 August

Found it. The cursor is a `LIMIT`/`OFFSET` pair and the table is being written
to underneath it, so rows shift past the offset and the walk terminates early
when a page comes back short.

- [x] Reproduce with a synthetic write load
- [x] Confirm the short page is the exit condition
- [ ] Replace with a keyset cursor

> A short page is not the end of the table. It is the end of *this page*.
> Everything else in that loop was correct.

## 6 August

Keyset cursor written. It is faster as well, which I did not expect:

| Cursor | Rows/s | Wall clock |
| --- | ---: | ---: |
| Offset | 1,900 | 6h+ (incomplete) |
| Keyset | 4,400 | 11m |

The offset version was re-scanning from the start of the table on every page,
which is obvious in hindsight and invisible in the code.

## 7 August

Ran clean on staging twice. Starting the production dry run tonight:

```bash
ferrymark backfill --dry-run --from 2026-01-01 --workers 4
```

Ana asked what happens if it stops early again, and the honest answer is that
the keyset cursor cannot stop early for that reason but can certainly stop
early for a reason I have not thought of. So:

1. The worker records its last key every thousand rows
2. A run that ends without reaching the end key exits non-zero
3. The wrapper alerts on non-zero, rather than on "no rows written"

---

Next entry when the dry run finishes.
