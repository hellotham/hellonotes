```swift
let vault = try Vault(root: url)
for await note in vault.notes(matching: "marmalade") {
    print(note.title)
}
```

That is the whole API for the common case. `Vault` is `Sendable`, so it can be
held on an actor; `Note` is not, so do the work with it where you got it.

Two things the snippet hides:

- The first call walks the folder. Call `index()` at launch if the latency
  matters.
- The stream finishes. It does not stay open for notes written later — use
  `changes()` for that.
