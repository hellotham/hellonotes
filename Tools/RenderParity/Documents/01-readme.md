# Ferrymark

[![build](badge.png)](https://example.com/ci) [![coverage](badge.png)](https://example.com/cov) [![licence](badge.png)](https://example.com/licence)

A small, fast Markdown ferry for people who keep their notes in files. It reads
a folder, watches it, and hands you the same document your editor has open —
no database, no sync service, no account.

## Install

1. Add the package to your manifest:

   ```swift
   .package(url: "https://example.com/ferrymark.git", from: "2.1.0")
   ```

2. Import it where you need it:

   ```swift
   import Ferrymark
   ```

3. Point it at a folder and start it:

   ```bash
   ferrymark serve ~/Notes --port 8080
   ```

## What it does

- Reads a folder of `.md` files
  - watches for changes with `FSEvents`
  - re-indexes only what moved
- Renders GitHub-Flavored Markdown
  - tables, task lists, strikethrough, autolinks
  - front matter, folded away
- Serves the result over HTTP

## Options

| Flag | Default | What it does |
| --- | --- | --- |
| `--port` | `8080` | Port to listen on |
| `--watch` | `true` | Re-index on change |
| `--theme` | `auto` | `light`, `dark` or `auto` |

## Contributing

Read [CONTRIBUTING](https://example.com/contributing) first, then open a pull
request against `main`. Every change needs a test.

---

Released under the MIT licence.
