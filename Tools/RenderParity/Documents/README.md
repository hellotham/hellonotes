# widget-kit

A small library for widgets.

## Install

1. Add the dependency:

   ```swift
   .package(url: "https://example.com/widget-kit", from: "1.0.0")
   ```

2. Import it where you need it:

   ```swift
   import WidgetKit
   ```

3. Done.

## Options

| Option | Type | Default |
| --- | --- | ------- |
| `verbose` | `Bool` | `false` |
| `retries` | `Int` | `3` |
| `timeout` | `Duration` | `.seconds(30)` |

## Notes

- Works on macOS and iOS.
  - Requires Swift 6.
  - No other dependencies.
- See [the manual](https://example.com/manual) for details.

> **Warning**
> The `legacy` flag is removed in 2.0.
