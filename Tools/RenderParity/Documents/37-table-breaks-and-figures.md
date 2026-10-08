# Line breaks and figures in a table

A table row is one line of source, so a cell that needs two lines says so
with `<br>`. The page breaks the line there, and so must the picture the
editor draws in place of the table — one line taller for every break.

| Step | What happens | Cost |
| --- | --- | ---: |
| Sign in | the token is stored<br>in the keychain | 0.00 |
| Sync | every note is listed<br/>then compared<br />then fetched | 1,204.50 |
| Retry | waits 2 s<br>then 4 s<br>then 8 s | 88.10 |
| Done | nothing left to do | 11.11 |

A break that ends a cell starts no line after it, and one that opens a cell
leaves an empty line above:

| Before | After |
| --- | --- |
| <br>opens with a break | ends with a break<br> |

Figures in a table are tabular, so a column of numbers lines up and is as
wide in the editor as on the page:

| Quarter | Accounts | Churn | Support cost |
| --- | ---: | ---: | ---: |
| Q1 | 1,111 | 1.1% | $1.11 |
| Q2 | 8,888 | 8.8% | $88.80 |
| Q3 | 10,000 | 0.0% | $100.00 |
| Q4 | 11,111 | 11.1% | $111.11 |

The prose after the tables is ordinary, so the blocks below them are measured
too.
