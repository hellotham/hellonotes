---
name: weekly-review
description: Produce a structured weekly review from the notes changed this week.
---

# Weekly Review

When the user asks for a weekly review:

1. Use `search_notes` and `grep_vault` to find notes mentioning this week's dates
   and any notes tagged with active projects.
2. Read the most relevant ones with `read_note`.
3. Summarise into these sections:
   - **Done** — what was completed
   - **In progress** — what's still open
   - **Blocked** — anything waiting on someone/something
   - **Next week** — the top 3 priorities
4. Offer to save the review as a new note named `Weekly Review <date>` with
   `create_note` (the user will approve the write).

Keep it concise and skimmable — bullet points, not prose.
