# Release notes

## 2.4.0 — 14 August 2026

### Added

- Front matter is folded away in the editor and stripped from the preview
- `--theme dark` on the command line
- A `parity` subcommand that compares the two renderers

### Changed

- The outline cache is now keyed on the collection *and* its open state
- `Vault.notes(matching:)` reads the index rather than the disk

### Fixed

- A note ending in a heading no longer clips its own rule
- Quote bars are drawn once per quote instead of once per line
- `![[embed]]` resolves in the preview, as it always did in the editor

| Issue | Reported by | Fixed in |
| --- | --- | --- |
| #412 | @ana | `a91f2c0` |
| #418 | @bo | `4c7d115` |
| #431 | @chandra | `e02b8ad` |

---

## 2.3.1 — 2 August 2026

A single fix: `Vault.init(root:)` threw the wrong error for a symlink to a
directory. See [#409](https://example.com/issues/409).
