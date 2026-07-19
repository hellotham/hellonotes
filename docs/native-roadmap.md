# Native-platform adoption roadmap

*Written 2026-07-17, from a documentation-verified review of Apple's system-integration
surface (App Intents, text/content APIs, macOS 26 platform expectations). Every item
below was checked against live Apple docs — minimum-OS versions and API names are
verified, not recalled. Execute phases in order; items within a phase are independent.*

**Starting point:** HelloNotes uses almost no system-integration surface yet — no App
Intents, widgets, Spotlight *donation* (it *reads* Spotlight for full-text search, but
doesn't publish `NoteEntity`s), URL scheme, extensions, Handoff, tips, or state
restoration. The editor is a real `NSTextView`/`UITextView` on TextKit 2 (the in-repo
`Packages/NotesEditor`), which makes several "features" nearly free — **Writing Tools and
system inline predictions are already wired** (see Phase A).

**Update (post editor rewrite):** the greenfield TextKit 2 editor shipped, so the
"Writing Tools config" quick win below is **done**; the rest of this roadmap is unchanged
— it targets system integration the app still lacks.

**Update (2026-07-19, roadmap implementation pass):** Phase A is essentially complete and
**Phase B's strategic core landed** — all build green on macOS + iOS with the full test
suite passing. Shipped: **URL scheme + router** (`Core/URLRouter.swift`, `State/NavigationRouter.swift`,
`onOpenURL`), **state restoration** (`@SceneStorage` for collection + note),
**Services menu** ("New Note from Selection" → `ServicesProvider` + `NSServices`),
**VoiceOver headings rotor** (`MarkdownTextView` `.heading` rotor over `EditorDocument.headings()`),
**App Intents core** (`NoteEntity` + `CreateNote`/`AppendToDailyNote`/`OpenNote`/`SearchNotes`
intents + `AppShortcutsProvider`, all with complete `parameterSummary`), and **MenuBarExtra
quick capture** (append to the daily note without switching apps). Everything routes through
`NavigationRouter`, so widgets/Spotlight/intents share one navigation path. **Remaining**
(status below): IndexedEntity Spotlight donation, global hotkey, and Phases C/D — several of
which need new Xcode targets, entitlements, artwork, or on-device hardware (called out inline).

---

## Phase A — Quick wins (~1 sprint, all in-app, mostly S effort)

| Item | API / approach | Min OS | Notes & gotchas |
|---|---|---|---|
| **Writing Tools config** ✅ **(done)** | `NSTextView.writingToolsBehavior = .complete`; `allowedWritingToolsResultOptions = [.plainText]` | macOS 15.1 | **Shipped** in the editor rewrite (`MarkdownTextView.swift`), alongside `inlinePredictionType = .default`. `.plainText` is used so rewrites can't return rich text and corrupt Markdown; restyling pauses during an external text session. |
| **Continuity Camera routing** ✅ **(routed; verify on device)** | `NSTextView` context menu "Insert from iPhone → Scan Documents" | works today | The editor's paste path (`onPasteMarkdown` → `ImagePaste`) already saves pasted/inserted images to the attachments folder + inserts `![[…]]`, so Continuity Camera images route through it. Only remaining: exercise it on a Mac paired with an iPhone. |
| **Print (⌘P)** | Render note into an off-screen `NSTextView`/`NSPrintOperation` | any | PDF "export via print panel" falls out for free. Wire to `CommandGroup(replacing: .printItem)`. |
| **Services menu** ✅ **(done)** | `NSServices` Info.plist entry + `NSApp.servicesProvider`: "New HelloNotes Note from Selection" | any | Shipped: `ServicesProvider.newNoteFromSelection` creates a note from the selection via `NavigationRouter.captureNote`, registered in `TerminationGuard.applicationDidFinishLaunching`. |
| **UTI import fix (latent bug)** ✅ **(done)** | `UTImportedTypeDeclarations` for `net.daringfireball.markdown` | any | Shipped in the production-hardening pass (Info.plist `UTImportedTypeDeclarations`, imported not exported). |
| **URL scheme + router** ✅ **(done)** | `CFBundleURLTypes` → `hellonotes://note?collection=…&path=…`, `onOpenURL` router | any | Shipped: `URLRouter` (parse) + `NavigationRouter` (resolve against the open library) + `onOpenURL` on both platforms. Grammar covers note (path/title), collection, search, new, daily. Everything in Phase B deep-links through it. |
| **State restoration** ✅ **(done)** | `@SceneStorage` for selected collection / note | any | Shipped: `restoredCollectionID` + `restoredNotePath` (stable path identifiers) restore the focused collection + note on launch. |
| **Accessibility: headings rotor** ✅ **(done)** | `NSAccessibilityCustomRotor(rotorType: .heading, …)` over `EditorDocument.headings()` | any | Shipped: `MarkdownTextView` exposes the standard VoiceOver Headings rotor; on-device VoiceOver audit still recommended (per unimplemented.md §5). |

## Phase B — System presence (M effort)

Order matters: **App Intents core → IndexedEntity donation → MenuBarExtra capture.**

1. **App Intents core** ✅ **(done)** — the keystone. Shipped `NoteEntity: AppEntity`
   (id = collection name + relative path; display = title + collection) with a
   `NoteEntityQuery`, four intents (`CreateNoteIntent`, `AppendToDailyNoteIntent`,
   `OpenNoteIntent`, `SearchNotesIntent`), and `HelloNotesShortcuts: AppShortcutsProvider`
   with natural phrases. Each intent has a **complete `parameterSummary`** (needed for
   macOS 26 ⌘Space actions). Intents run on the main actor via `NavigationRouter.shared`;
   navigation intents `openAppWhenRun`. *(All in the main app target; when widgets land
   they'll need `NoteEntity` moved to a shared framework target — see Phase D.)*
   Remaining polish: adopt `supportedModes` (26+) for explicit foreground/background.
2. **IndexedEntity Spotlight donation** ✅ **(done)** — `NoteEntity` conforms to
   `IndexedEntity` (with a `CSSearchableItemAttributeSet`); `NavigationRouter.donateNotesToSpotlight()`
   re-donates via `CSSearchableIndex.indexAppEntities` on every note-set change. Notes are
   findable in system Spotlight with a `hellonotes://` deep link back.
3. **MenuBarExtra quick capture** ✅ **(done)** — `QuickCaptureView` in a
   `MenuBarExtra(.window)`. **Global hotkey** ✅ **(done)** — `GlobalHotKey` (Carbon
   `RegisterEventHotKey`, ⌥⌘N) activates the app and starts a fresh note; registered in
   `TerminationGuard`. (Runtime verification on a device still recommended.)

## Phase C — Platform polish (M effort)

- **Liquid Glass audit** — the one *required-ish* item. Apps built with Xcode 26 get
  the new material mostly automatically, but custom chrome fights it: audit custom
  toolbar/background fills, adopt `ToolbarSpacer` grouping, respect new safe areas.
  The `UIDesignRequiresCompatibility` opt-out is documented as **temporary** — don't
  ship relying on it.
- **Icon Composer layered icon** — macOS/iOS 26 layered app icon (specular/dark/tinted
  variants) from the existing artwork.
- **TipKit** ✅ **(done)** — `Tips.swift` defines Open-Quickly / wiki-link / transclusion /
  graph / rescan tips; `HelloNotesTips.configure()` runs at launch; the Graph tip is
  attached via `.popoverTip`. Attach the remaining tips to their controls as desired
  (one `.popoverTip(_:)` line each).
- **iCloud KV store** — `NSUbiquitousKeyValueStore` for preferences sync (editor mode,
  recent collections). One entitlement, no CloudKit schema. 1 MB/1024-key limits are
  fine for prefs; never put note content in it.

## Phase D — Bigger bets (M each)

- **SpeechAnalyzer voice capture** — the new on-device engine (macOS/iOS 26 —
  matches our floor exactly; no legacy `SFSpeechRecognizer` fallback needed).
  `SpeechAnalyzer` + `SpeechTranscriber` streaming into a new note / daily note.
  Models download on demand via `AssetInventory`.
- **Foundation Models upgrade** — on-device LLM (macOS 26): `@Generable` guided
  generation for structured outputs (note titles, tag suggestions) and a vault-search
  `Tool` so Ask Library can answer grounded questions offline. Works today on
  Apple-silicon + Apple Intelligence enabled; keep the existing cloud providers as the
  quality tier.
- **WidgetKit** ✅ **(done)** — recent-notes widget (`HelloNotesWidgets`, small/medium/large).
  The app writes a JSON snapshot (`WidgetSnapshot`) to the App Group container on every
  note change (`Library.writeWidgetSnapshot` + `WidgetCenter.reloadAllTimelines`); the
  widget reads it (`WidgetSnapshot.load`) — solving the bookmark problem — and each row
  deep-links via `.widgetURL(hellonotes://…)`. *(Runtime verify: run the app once so the
  snapshot exists, then add the widget.)*
- **Quick Look extensions** ✅ **(done)** — Preview (`QLPreviewingController`) + Thumbnail
  (`QLThumbnailProvider`) on macOS **and** iOS, each with a self-contained native Markdown
  render (headings/bullets/code; thumbnail draws a note "card"). `QLSupportedContentTypes`
  set to the Markdown UTIs. *(Can later swap the lightweight renderer for `GFMRender` full
  fidelity by linking that SPM product to the QL targets.)* **Per-platform embed fix
  applied**: `platformFilters` on the app's Embed phase so macOS embeds only macOS
  extensions and iOS only iOS ones.

## Skip / defer (decided, with reasons)

- **Share extension** — sandboxed extensions can't resolve the app's security-scoped
  folder bookmarks; needs an app-group inbox the main app drains. Services menu covers
  the Mac use case far more cheaply. Revisit when iOS becomes a daily driver.
- **Genmoji** — `NSAdaptiveImageGlyph` can't round-trip through plain Markdown files.
- **Focus filters** — low value for a notes app of this shape.
- **BGAppRefresh (iOS)** — the index cache made cold launch fast; background refresh
  adds complexity for seconds of benefit.
- **PencilKit** — wait for iOS 27-era handwriting-recognition APIs before investing.
- **Handoff** — until iOS is a daily driver; requires activity plumbing on both ends
  to be useful.

---

## Sequencing rationale

Phase A first: small, independent, high "feels native" density, and the URL router
de-risks everything in B and D. Phase B is the biggest strategic unlock (one entity
model feeds Shortcuts, ⌘Space, and Apple Intelligence). Phase C tracks the macOS 26
platform expectation (Liquid Glass). Phase D items are each independently shippable
marquee features — pick by appetite.
