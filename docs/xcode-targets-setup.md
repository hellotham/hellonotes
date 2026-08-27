# Adding Xcode targets — Widgets, Quick Look, and the App Group

> **Status: done — kept as historical reference, not a to-do list.** Every target this
> document walks through creating already exists in `project.pbxproj`
> (`HelloNotesWidgetsExtension`, `HelloNotesPreview` + `HelloNotesPreview-iOS`,
> `HelloNotesThumbnail` + `HelloNotesThumbnail-iOS`), and the App Group is live in
> `HelloNotes/HelloNotes.entitlements`. Two things below no longer match current
> reality and are corrected here rather than throughout: **macOS deployment target is
> now 26.5** everywhere (this doc's "15.0" predates the bump described in
> `docs/production.md` §1a — Quick Look/Widget extensions need to match the app, and
> the app itself moved), and the bundle ids the project actually shipped with differ
> from the ones planned below — see the table. Treat the rest of this file as "how it
> was done", useful if you're adding a *new* extension target, not as the current
> state of the ones it describes; `project.pbxproj` is the source of truth for that.

Step-by-step for the Phase D roadmap items that needed **new Xcode targets** and a **shared
App Group container**. Do these in Xcode's UI (not by hand-editing `project.pbxproj` —
Xcode has repeatedly reset this project to the SwiftData template when its own model of the
project drifts). Everything here is scoped to this project's real settings:

| Setting | Value |
|---|---|
| App bundle id | `com.hellotham.HelloNotes` |
| Team | `RPL5R637DS` |
| Signing | Automatic |
| macOS deployment | ~~15.0~~ **26.5** (raised after this doc was written — see status note above) · iOS deployment | 26.5 |
| App group (new) | `group.com.hellotham.HelloNotes` |
| Widget bundle id (new) | ~~`com.hellotham.HelloNotes.Widgets`~~ → shipped as `com.hellotham.HelloNotes.HelloNotesWidgets` |
| Preview ext bundle id (new) | ~~`com.hellotham.HelloNotes.QuickLookPreview`~~ → shipped as `com.hellotham.HelloNotes.HelloNotesPreview` (+ `-iOS` variant) |
| Thumbnail ext bundle id (new) | ~~`com.hellotham.HelloNotes.Thumbnail`~~ → shipped as `com.hellotham.HelloNotes.HelloNotesThumbnail` (+ `-iOS` variant) |

> **Why extensions need the App Group and a snapshot:** widget and (sandboxed) extension
> processes **cannot resolve the app's security-scoped folder bookmarks**, so they can't
> read the vault directly. The app writes a small JSON *snapshot* (recent/daily-note
> metadata) into the shared App Group container on each index refresh; the widget reads
> that. Quick Look is different — it's handed the specific `.md` file directly, so it needs
> no bookmark and no App Group (it can render the file it's given).

---

## 0 · Before you start (safety)

1. Commit first so any Xcode project-file churn is recoverable:
   ```
   git add -A && git commit -m "checkpoint before adding targets"
   ```
2. If at any point Xcode offers to **"modernize", "regenerate", or convert to SwiftData** —
   **decline**. If the app target's package links vanish or the build says *"Unable to
   resolve module dependency"*, the project file was clobbered:
   `git checkout HEAD -- HelloNotes.xcodeproj/project.pbxproj` and retry.
3. Keep **Automatic** signing and team **RPL5R637DS** on every new target. Automatic
   signing will register the new bundle ids and the App Group on the developer portal for
   you (the account must be able to create identifiers).

---

## 1 · Create the App Group container

You register the group **once**, then add it to the app and each extension.

1. Select the project in the navigator → **HelloNotes** app target → **Signing &
   Capabilities**.
2. Click **+ Capability** → **App Groups**.
3. Under App Groups click **+** and add: `group.com.hellotham.HelloNotes`.
   - This appends `com.apple.security.application-groups` to
     `HelloNotes/HelloNotes.entitlements` and registers the group with your team.
4. Repeat step 2–3 for the **iOS** flavor if the app target is multiplatform (same group id
   — App Groups are shared across the two platforms with one identifier).

The resulting entitlements addition (Xcode writes this for you):
```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.hellotham.HelloNotes</string>
</array>
```

**Accessing the container in code** (already portable across app + extensions):
```swift
enum AppGroup {
    static let id = "group.com.hellotham.HelloNotes"
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }
    static var snapshotURL: URL? { containerURL?.appendingPathComponent("widget-snapshot.json") }
}
```
The app writes `snapshotURL` on index refresh; widgets read it. (I can supply the
`WidgetSnapshot` Codable model + the writer — say the word.)

---

## 2 · Widget extension (WidgetKit)

### 2.1 Add the target
1. **File → New → Target…**
2. Choose **Widget Extension** (under *Application Extension*). Click Next.
3. Product Name: **HelloNotesWidgets**.
   - Bundle id becomes `com.hellotham.HelloNotes.Widgets` — leave it.
   - **Uncheck** "Include Live Activity" and "Include Configuration App Intent" unless you
     want a configurable widget (you can add the config intent later once `NoteEntity`
     lives in a shared framework — see §4).
   - Team **RPL5R637DS**, embed in **HelloNotes**.
4. When Xcode asks to **"Activate the HelloNotesWidgets scheme?"** → Activate.

### 2.2 Deployment + signing
- Set the widget target's **macOS Deployment Target = 26.5** and **iOS = 26.5** to match the
  app (Xcode may default the extension higher/lower).
- Signing & Capabilities → **Automatic**, team **RPL5R637DS**.
- **+ Capability → App Groups** on the widget target and tick
  `group.com.hellotham.HelloNotes` (same group as the app). This creates
  `HelloNotesWidgets/HelloNotesWidgets.entitlements` with the app-group + (on macOS) the
  sandbox keys.

### 2.3 macOS sandbox for the widget
On macOS the widget runs sandboxed. Its entitlements need:
```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.application-groups</key>
<array><string>group.com.hellotham.HelloNotes</string></array>
```
(No `files.user-selected` — the widget only reads the App Group snapshot.)

### 2.4 Code
- The generated `HelloNotesWidgets.swift` (a `Widget` + `TimelineProvider`) reads
  `AppGroup.snapshotURL`, decodes `WidgetSnapshot`, and renders recent/daily-note rows.
- Each row's `.widgetURL(URLRouter.link(...))` deep-links via the `hellonotes://` scheme
  you already shipped — tapping a row opens that note in the app.
- To reuse `URLRouter` / the snapshot model in the widget, add those **specific files** to
  the widget target's membership (File Inspector → Target Membership), **or** move them to a
  shared framework (§4). Keep the shared surface tiny (no `Library`, no `Collection`).

---

## 3 · Quick Look extensions (preview + thumbnail)

Two separate targets. Both are handed the file directly, so **no App Group, no bookmark**.

### 3.1 Preview extension
1. **File → New → Target… → Quick Look Preview Extension**. Name **HelloNotesPreview**
   (`com.hellotham.HelloNotes.QuickLookPreview`). Embed in HelloNotes, team RPL5R637DS.
2. In the target's **Info** tab, under `NSExtension → NSExtensionAttributes →
   QLSupportedContentTypes`, add the Markdown UTIs the app declares:
   ```
   net.daringfireball.markdown
   public.plain-text
   ```
   Also set `QLSupportsSearchableItems = NO` (unless you index).
3. Deployment: macOS 26.5 / iOS 26.5. Signing Automatic.
4. Entitlements: keep **app-sandbox on**; Quick Look grants read access to the previewed
   file automatically, so **no `files.user-selected` needed**.
5. Code: the generated `PreviewViewController: QLPreviewingController` implements
   `preparePreviewOfFile(at url:)`. Render the file with the app's **`GFMRender`** HTML
   pipeline into a `WKWebView` (or `NSTextView`/`UITextView`). Add `GFMRender` (the SPM
   product) to this target's **Frameworks and Libraries**, plus the CSS/JS resources.

### 3.2 Thumbnail extension
1. **File → New → Target… → Thumbnail Extension**. Name **HelloNotesThumbnail**
   (`com.hellotham.HelloNotes.Thumbnail`). Embed, team RPL5R637DS.
2. Info tab → `QLSupportedContentTypes` = the same Markdown UTIs.
3. Code: `ThumbnailProvider: QLThumbnailProvider` → `provideThumbnail(for request:)`.
   Render a small first-screen bitmap: reuse `GFMRender` → a fixed-width HTML render, or a
   quick native `NSAttributedString`/`UITextView` snapshot of the first ~20 lines. Draw into
   the `request.maximumSize` and return a `QLThumbnailReply(contextSize:currentContextDrawing:)`.
4. Deployment 26.5 / 26.5, sandbox on, Automatic signing.

> **Tip:** you can reuse one small `MarkdownThumbnailRenderer` file across both QL targets
> (target membership on both). I can write the QL controllers + the shared renderer against
> `GFMRender` — ask and I'll add the source files ready to drop in.

---

## 4 · Shared code (when you need the App Intents entity in the widget)

A **configurable** widget (pick which note/collection it shows) needs `NoteEntity` in a
target the widget can compile. App Intents entities can't just be file-shared cleanly with
the main app because of the `@MainActor` `NavigationRouter` dependency. Recommended:

1. **File → New → Target… → Framework**. Name **HelloNotesKit**
   (`com.hellotham.HelloNotes.HelloNotesKit`), platforms macOS + iOS.
2. Move the **pure, dependency-light** types into it: `URLRouter`, `Note` (value type),
   `WidgetSnapshot`, and a widget-only `NoteEntity` variant that resolves against the
   **snapshot** (not the live `Library`). Keep `NavigationRouter`, `Library`, `Collection`
   in the app target.
3. Add `HelloNotesKit` to **Frameworks and Libraries** of: the app, the widget, and (if
   they need it) the QL targets. Embed it (`Embed & Sign`) in the app; the extensions link
   against the copy the app embeds.

For a **static** widget (recent/daily snapshot, no per-widget configuration — the simpler,
recommended first version) you can **skip the framework** entirely: just give the widget
target membership of `URLRouter.swift` + the snapshot model. Do the framework only when you
add a configuration intent.

---

## 5 · Signing & provisioning checklist

- Every new target: **Automatic** signing, team **RPL5R637DS**.
- First build after adding App Groups may prompt Xcode to register the group + bundle ids —
  allow it. If it can't (account limits), create the identifiers + App Group manually at
  developer.apple.com → Identifiers, then let automatic signing pick them up.
- Do **not** change the app target's existing signing config (per repo policy). New targets
  are additive.

---

## 6 · Verify

- **Build all** (⌘B) with the HelloNotes scheme — the app should embed the 3 `.appex`
  bundles. `Contents/PlugIns/` (macOS) or the iOS app's `PlugIns/` should contain them.
- **Widget:** run the app once (so it writes the snapshot), then add the widget from the
  widget gallery; tap a row → the app opens that note via `hellonotes://`.
- **Quick Look:** in Finder, select a `.md` file → spacebar → your rendered preview; icons
  in a folder show real thumbnails. (`qlmanage -p file.md` / `qlmanage -t file.md` to test
  from the terminal.)
- Confirm the app still passes: `swift test --package-path Packages/NotesEditor` (83) and
  `xcodebuild test … -only-testing:HelloNotesTests`.

---

## 7 · Recovery

If the project file gets clobbered at any step:
```
git checkout HEAD -- HelloNotes.xcodeproj/project.pbxproj
```
then re-open Xcode and re-do the target from a clean state. Commit after each target that
builds, so each is an independent recoverable checkpoint.

---

## What I can hand you as ready-to-drop-in source

Once the targets exist (steps above create the empty scaffolds), I can write, against this
project's existing code:
- `AppGroup` + `WidgetSnapshot` (Codable) + the app-side snapshot writer (hook into the
  index-cache refresh), and the `NavigationRouter` already handles the deep links.
- The `HelloNotesWidgets` timeline provider + views (recent notes / daily note), using
  `.widgetURL(URLRouter.link(...))`.
- The `QLPreviewingController` + `QLThumbnailProvider` + a shared `MarkdownThumbnailRenderer`
  built on `GFMRender`.

Say which and I'll add the files so you only have to set target membership.
