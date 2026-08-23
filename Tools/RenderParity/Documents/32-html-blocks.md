# The status page

Most of this page is Markdown. Three parts of it are not, because a table with
a merged header cell is not something GFM can express.

<div align="center">
  <img src="badge.png" alt="status">
  <br>
  <b>All systems normal</b>
</div>

## Current

<table>
  <tr><th colspan="2">Ingest</th></tr>
  <tr><td>Queue depth</td><td>412</td></tr>
  <tr><td>Error rate</td><td>0.02%</td></tr>
</table>

The numbers come from the same place the dashboards read, so they move together
or they are both wrong.

## Notice

<details>
<summary>Why the queue depth looks high on Thursdays</summary>

Thursday is the deploy day, and every deploy pauses ingest for about ninety
seconds while the readers reconnect. The queue drains within five minutes and
nothing is lost.

</details>

Back to ordinary Markdown, which should sit at the ordinary distance below the
block above it.

- One
- Two
