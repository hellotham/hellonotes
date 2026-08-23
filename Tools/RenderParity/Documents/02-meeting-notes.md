# Platform sync — 14 August

**Present:** Ana, Bo, Chandra, Dev
**Apologies:** Erin

## Decisions

> We ship the migration behind a flag and turn it on for internal accounts
> first. Nobody flips it for customers until the backfill has run clean for a
> week.

Chandra pushed back on the week, and the compromise was *five working days*
measured from the last failed backfill, not from the first clean one.

## Actions

- [x] Ana — write the flag into the config schema
- [x] Bo — backfill script, dry-run mode first
- [ ] Chandra — dashboards for the backfill error rate
- [ ] Dev — draft the customer note, **do not send it**
- [ ] Erin — review the rollback plan when she is back

## Discussion

Bo raised the read-path cost again:

> The backfill is cheap. The *read* is not — every row we have not migrated
> yet costs a second lookup, and at peak that is about forty thousand extra
> reads a second.
>
> > It is forty thousand for a week, not forever.
> >
> > — Ana, who has the numbers
>
> Fine. A week I can carry.

That settled it. The **five-day clean window** stands, and Chandra's dashboard
is what tells us the window has started.

## Next meeting

Thursday, same time. Dev owns the agenda.
