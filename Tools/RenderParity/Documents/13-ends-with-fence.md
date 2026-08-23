# Reproducing the crash

It only happens on a cold start, and only when the vault has more than about
four thousand notes. Warm, it never happens; small, it never happens.

The shortest reproduction I have found is to clear the index and then ask for a
note that sorts last:

```bash
rm -rf ~/Library/Caches/ferrymark
ferrymark serve ~/Notes --port 8080 &
sleep 0.2
curl -s localhost:8080/note/zzz-last.md
```
