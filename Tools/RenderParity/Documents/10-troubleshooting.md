# When the index will not build

## Symptom

`ferrymark serve` starts, prints `indexing…`, and never prints anything else.
The port is open and every request hangs.

## First, check whether it is the watcher

```bash
lsof -nP -p "$(pgrep -x ferrymark)" | grep -c fsevents
```

Zero means the watcher never started, which is a permissions problem and not an
index problem.

## Then check the folder

> If the vault is on a network volume, or on an external disk that has spun
> down, the first walk can take minutes. That is not a hang.
>
> To tell the difference, watch the file count:
>
> ```bash
> while true; do
>   ferrymark status --json | jq .indexed
>   sleep 2
> done
> ```
>
> A number that moves is progress. A number that does not is a hang.

## Common causes

1. **A symlink loop.** The walker follows symlinks and does not remember where
   it has been.

   ```bash
   fd --type symlink . ~/Notes -x readlink -f {} \;
   ```

   Anything pointing at an ancestor of the vault root is the problem.

2. **A file the process cannot read.** The walk stops at the first `EPERM`
   rather than skipping it.

   > This is a bug, and it is fixed in 2.4.1. Until then:
   >
   > - move the file out of the vault
   > - or run with `--skip-unreadable`

3. **A dataless file that will not materialise.** Almost always iCloud, almost
   always because the account is signed out.

## If none of that helps

Collect a sample and open an issue:

```bash
sample "$(pgrep -x ferrymark)" 10 -file /tmp/ferrymark.txt
```

Attach `/tmp/ferrymark.txt` and the output of `ferrymark status --json`.
