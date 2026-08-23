# Coordinated reads on a dataless file

A note on why `String(contentsOf:)` is the wrong call in a cloud-backed vault,
and what to do instead.

## The failure

A file that iCloud has evicted is *dataless*: the directory entry is there, the
size is there, the bytes are not. An uncoordinated read of one blocks in the
kernel while the daemon materialises it — and if the daemon is itself waiting
on the reading process, the kernel notices the cycle and fails the read with
`EDEADLK`.[^1]

[^1]: `man 2 open`, under `ERRORS`. The same code comes back from `read`.

The symptom is a file that reads fine on the machine that wrote it and fails on
every other one, which is the worst shape a bug can have.

## The fix

Every read goes through a file coordinator, which tells the daemon what is
about to happen and waits for materialisation properly:

```swift
var error: NSError?
NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { url in
    text = try? String(contentsOf: url, encoding: .utf8)
}
```

See the [coordination guide][guide] and the [eviction notes][evict] for the
rest. The short version is that the *only* safe raw read is of a file you
created in this process and have not closed.

[guide]: https://example.com/coordination
[evict]: https://example.com/eviction

## Measured

<div align="center">
  <img src="diagram.png" alt="read latency">
  <br>
  <b>Cold read latency, coordinated vs not</b>
</div>

The uncoordinated line is missing its tail because those reads did not return.

![A trace of the failing read](screenshot.png)

## Checklist

- [x] All vault reads go through `FileIO`
- [x] A reviewer agent checks new call sites
- [ ] The same rule for writes
