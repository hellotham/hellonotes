## `Vault`

A folder of notes, indexed and watched.

### `init(root:)`

```swift
public init(root: URL) throws
```

Opens the folder at `root`. Throws `VaultError.notADirectory` if it is a file,
`VaultError.unreadable` if the process cannot list it.

| Parameter | Type | Notes |
| --- | --- | --- |
| `root` | `URL` | Must be a directory URL |

### `note(at:)`

```swift
public func note(at path: String) async throws -> Note
```

Reads one note. `path` is relative to the vault root, with `/` separators on
every platform. The read is coordinated, so it is safe on a dataless file.

| Error | When |
| --- | --- |
| `VaultError.missing` | No file at `path` |
| `VaultError.unreadable` | Coordination failed |
| `VaultError.notUTF8` | The bytes are not valid UTF-8 |

### `notes(matching:)`

```swift
public func notes(matching query: String) -> AsyncStream<Note>
```

Streams every note whose title or body contains `query`, case-insensitively.
The stream finishes when the index has been walked once; it does **not** stay
open for later matches.

> Calling this on a cold vault walks the whole folder. Warm it with `index()`
> first if you care about the first result's latency.

### Notes

- `Vault` is `Sendable`; `Note` is not
- The index is rebuilt on `FSEvents`, coalesced to 200 ms
- `notes(matching:)` reads the index, never the disk
