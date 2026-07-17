# GFM Compatibility Test

## Headings

# H1 heading
## H2 heading
### H3 heading
#### H4 heading
##### H5 heading
###### H6 heading

Setext H1
=========

Setext H2
---------

## Inline emphasis

Normal, **bold**, *italic*, ***bold italic***, `inline code`, ~~strikethrough~~.

Nested: **bold with *italic* inside**, and *italic with `code`*.

Escapes: \*not italic\*, \`not code\`, \# not heading.

## Blockquotes

> A single-line blockquote.

> A multi-line blockquote
> that continues here.
>
> With a second paragraph.

> Nested:
> > inner quote
> > > deeper

## Lists

Unordered:

- First item
- Second item
  - Nested item
  - Another nested
    - Deeper
- Third item

Ordered:

1. One
2. Two
   1. Two-a
   2. Two-b
3. Three

Loose list:

- Item with

  a second paragraph.

- Another item.

Task list:

- [ ] Unchecked task
- [x] Checked task
- [ ] Task with **bold** and `code`

## Code

Inline `code` and `let x = 1`.

```swift
func greet(name: String) -> String {
    return "Hello, \(name)!"
}
```

```python
def add(a, b):
    return a + b  # comment
```

    Indented code block
    stays monospace.

## Tables

| Left | Center | Right |
|:-----|:------:|------:|
| a    | b      | c     |
| long cell | x | 100 |
| **bold** | `code` | ~~strike~~ |

## Links and images

Inline [link](https://example.com), reference [link][ref], autolink <https://github.com>.

Bare URL https://www.github.com and email user@example.com.

[ref]: https://reference.example.com

## Thematic breaks

Above.

---

Below.

## Hard line break

Line one with two trailing spaces  
Line two after a hard break.

## Combined

1. A list item with a table? No — with `code`, **bold**, and a [link](https://x.com).
2. > A quote inside a list.
3. Item with a nested fence:
   ```js
   console.log("nested");
   ```

End of test.
