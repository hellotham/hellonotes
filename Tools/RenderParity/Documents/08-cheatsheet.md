# Shell cheatsheet

## Finding things

```bash
rg --files-with-matches 'TODO' Sources/
fd -e swift -x wc -l {} \;
```

## Git

```bash
git log --oneline --graph --decorate --all
git diff --stat HEAD~1
git worktree add ../hotfix release/2.4
```

Use `git switch -c` for a new branch and `git restore` for a file — `checkout`
does both jobs and neither one obviously.

## Processes

| Want | Command |
| --- | --- |
| What is on port 8080 | `lsof -nP -iTCP:8080 -sTCP:LISTEN` |
| What a process is doing | `sample <pid> 5` |
| Kill it politely | `kill -TERM <pid>` |

## JSON

```json
{
  "port": 8080,
  "watch": true,
  "theme": "auto"
}
```

Pipe through `jq -S .` to sort keys before diffing two of them.

## Regular expressions

```
^(?<key>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?<value>.*)$
```

Named groups work in `rg` and in Swift's `Regex`, and in neither `sed` nor
`grep -E`.
