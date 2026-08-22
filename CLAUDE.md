//
//  CLAUDE.md
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

# HelloNotes Architecture Rules
- Target Environment: macOS 26.5+ / iOS 26.5+ / Swift 5.10+ / Xcode 26. The floor is high on
  purpose: the Intelligence features run on Foundation Models, and the Quick Look extensions
  already required 26.5 while the app claimed 15.0 — an app cannot promise an OS its own
  embedded extensions refuse to run on.
- Multiplatform: One shell, `AdaptiveShell`, chosen by the *axis of abundance* (width/height), never by device — a Mac window and an iPad of the same size get the same layout. See `docs/layout-architecture.md`.
- The window has **exactly one collapsible column**: a sidebar holding a *single tree* — Recents and Bookmarks pinned at the top, then one root per open collection, expanding into that collection's folders. SwiftUI only gives a correctly-placed sidebar toggle to column one, which is why everything navigational lives there and **no command may live inside it** (a hidden command is an unreachable command). Commands go in the toolbar: search leading, New Note / Open Quickly centre, the five inspector toggles trailing. See `docs/shell-chrome.md`.
- Anything keyed on a collection (the outline cache key, drop targets, "New Note" at a root) reads the sidebar's selection. **A cache key must name everything the cached value depends on** — keying the outline on one collection made opening or closing another invisible.
- State: Use the `@Observable` macro exclusively. DO NOT use legacy `@ObservableObject` or `@StateObject`.
- Data Source: No CoreData. The local file system directory is the absolute source of truth.
- Git Operations: Use `SwiftGitX` (Import `SwiftGitX`) utilizing native Swift async/await concurrency.
- Build Verification: After writing code, use the Xcode MCP tool to run a compilation check to ensure 0 errors.

# Layout
- App: `HelloNotes/` — `Core/` (parsing, FileIO, indexes), `State/` (@Observable services), `UI/`, `LLM/`; `UI/Shell/` holds the layout contract; `MacContentView` / `iOSContentView` supply its slots.
- Editor: `Packages/NotesEditor` (MarkdownCore / MarkdownEditor / GFMRender) — the app's only editor; the old engine fork is gone.
- Website: `website/` (Astro 7 + Tailwind 4) — see `website/CLAUDE.md` and `docs/website.md`.
- Docs: shipped work → `docs/implemented.md`; backlog only → `docs/unimplemented.md`.

# Commands
- Build (macOS, full CLI build): `xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes build` — the Xcode MCP check above is the quick per-change gate; use this for full/Release verification.
- Editor tests (macOS): `swift test --package-path Packages/NotesEditor`
- Editor tests (**iOS — run these too**): `cd Packages/NotesEditor && xcodebuild test -scheme NotesEditor-Package -destination 'platform=iOS Simulator,name=HN-iPad'` (~10s, headless, no app launch). `swift test` only ever builds the package for macOS, so the UIKit half went untested for its whole life — that is how a `UITextView` showing a document it believed was empty, a zero-width keyboard bar and a link tap that ate the caret tap all shipped at once. Create the device once with `xcrun simctl create HN-iPad com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4-8GB com.apple.CoreSimulator.SimRuntime.iOS-26-5`.
- **Look at the iOS app without the user's device**: `xcodebuild build -destination 'platform=iOS Simulator,name=HN-iPad'`, then `xcrun simctl install HN-iPad <app>`, `xcrun simctl launch HN-iPad com.hellotham.HelloNotes`, and `xcrun simctl io HN-iPad screenshot out.png` — which is readable. A whole iPad session was shipped blind (a keyboard bar that never rendered, a zero-width one, five inspector toggles that could not work at that width) because nobody looked. `simctl` has no tap injection, so driving the UI still needs the live panel — which needs `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` from the user.
- Is it running on the device? `xcrun devicectl device info processes --device <id> | grep "HelloNotes.app/HelloNotes"` — **capital H**. A lower-cased pattern matches nothing and reads exactly like a crash-on-launch; an hour went into diagnosing a crash that never happened. Cross-check against `--domain-type systemCrashLogs`: no new `.ips` means no crash, whatever the process list appears to say.
- Layout contract: `xcodebuild test -project HelloNotes.xcodeproj -scheme HelloNotes -destination 'platform=macOS' -only-testing:HelloNotesTests/ShellContractTests` (~2s, headless — run it after any shell or representable change).
- **Edit ≡ Preview**: `./scripts/render-parity.sh` — lays the same note out in TextKit and in WebKit, offscreen, and fails if any block drifts more than a point. Run it after touching `GFMBoxMetrics`, `StyleApplier`, `BlockBoxes`, `GFMLiveStyle` or `GFMPage`. It is a script, not a test, because a `WKWebView` never finishes loading under `swift test` *or* under XCTest in the app host — both were tried. See implemented.md §23.
- Live verification: run `scripts/relaunch-debug.sh` first — plain `open` reuses a stale instance and you test the wrong binary.
- Release/DMG: use the `/release` skill (`docs/production.md` Appendix A2 is authoritative).

# Hard-won rules
- Cold builds take 30–47 min (74 targets). A long `xcodebuild` is a cold build, not a hang.
- Debug proves nothing about Release: check `-configuration Release` before archiving (a Release-only optimizer crash once broke every archive — implemented.md §13).
- A viewport must report the size it is **offered**, never the size it **contains**. Every representable wrapping a scrolling/content-sized view implements `sizeThatFits` via `viewportSizeThatFits` and never returns `nil` — `nil` means "ask the platform view", whose `fittingSize` is the whole document (3433pt for a 76-line note), which inflates every ancestor until the top of the content sits above the window, unreachable. Pair every `minWidth/minHeight` with a maximum. Details: implemented.md §17.
- Vault content I/O goes through `Core/FileIO` (coordinated), never `String(contentsOf:)`/`.write(to:)` — raw reads of dataless cloud files fail with EDEADLK. The `vault-io-reviewer` agent checks this.
- `project.pbxproj`: git is the source of truth. Never accept an Xcode regenerate/modernize prompt; recover with `git checkout HEAD -- HelloNotes.xcodeproj/project.pbxproj`.
- Secrets: `Config/Secrets.xcconfig` (git-ignored) holds provider keys; the DMG bakes in whatever it held at build time. Never touch the repo-root `.env`.
- A UIKit control added onto a `UITextView` arbitrates against the view's own recognisers. `cancelsTouchesInView = false` governs touch *delivery*, not gesture *arbitration* — a bare `UITapGestureRecognizer` wins and silently eats the caret tap. Give it its own delegate object returning `shouldRecognizeSimultaneouslyWith: true`; never make the text view that delegate, it is already UIKit's for six recognisers of its own.
- Never swap `NSTextContentStorage.textStorage` under a live `UITextView`. AppKit tolerates it; UIKit keeps a second reference and the two disagree about the document's length, which throws `NSRangeException` from inside UIKit with no app frames on the stack. Build the content storage / layout manager / container first and pass the container to `UITextView(frame:textContainer:)`.
- **One box model, two renderers.** Edit lays a note out in TextKit and Preview lays it out in WebKit; they agree only because both measure from `MarkdownCore/GFMBoxMetrics.swift`. Never write a spacing, indent or line-height number into either side — add it there, where the editor reads it as points and `GFMRenderer.page` emits it as CSS. Two rules TextKit does not have: **CSS margins collapse** (the gap is `max`, not the sum — ask `GFMBoxMetrics.gap(after:before:)`), and `paragraphSpacing` ends every *paragraph*, so a block's gap goes on its **last line** only. Line heights are whole points because WebKit does not use a fractional one as given.
- Docs describe the UI from source, not memory — verify shortcuts/menus with the `docs-fact-checker` agent (a draft once shipped two invented shortcuts).
- Commit trailer: `Co-Authored-By: Claude <model> <noreply@anthropic.com>` per repo convention.
