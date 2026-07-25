# Native-platform adoption roadmap

*Written 2026-07-17, from a documentation-verified review of Apple's system-integration
surface (App Intents, text/content APIs, macOS 26 platform expectations). Every item
below was checked against live Apple docs — minimum-OS versions and API names are
verified, not recalled. Execute phases in order; items within a phase are independent.*

> ## ✅ Status: this roadmap is complete (2026-07-19/20)
>
> Everything below shipped — URL scheme + router, state restoration, Services menu,
> VoiceOver headings rotor, App Intents (`NoteEntity` + 4 intents + `AppShortcutsProvider`),
> MenuBarExtra quick capture, global hotkey (⌃⌥⌘N), IndexedEntity **Spotlight donation**
> (with stale-id retraction), **WidgetKit** recent-notes widget + App Group, **Quick Look**
> preview *and* thumbnail extensions, TipKit, iCloud KV preference sync, **Foundation Models**
> `@Generable`, **SpeechAnalyzer** dictation, and an **Icon Composer** app icon.
> See [implemented.md](implemented.md) for the record, and
> [cloud-native-roadmap.md](cloud-native-roadmap.md) for the storage work that followed.
> *The historical narrative below is kept as-written for context — the "Starting point" and
> per-phase "Remaining" notes describe the state at the time of writing, not today.*

**Starting point (as of 2026-07-17):** HelloNotes uses almost no system-integration surface yet — no App
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

- **Liquid Glass audit** ✅ **(code audit done; only the subjective look needs eyes)** —
  Audited: (1) the app does **not** set the temporary `UIDesignRequiresCompatibility` opt-out,
  so it opts into Liquid Glass via the Xcode 26 SDK; (2) all chrome uses the **standard
  adaptive `.background(.bar)` material** — a repo-wide grep finds **no** hardcoded-color /
  opaque custom fills that would fight the material. Posture is correct. The only thing left
  is a subjective *visual* review on real macOS 26 (a design judgment, not a code defect);
  `ToolbarSpacer` grouping is an optional refinement to apply once it can be seen.
- **Icon Composer layered icon** ✅ **(done — built into the app)** — `HelloNotes/AppIcon.icon`
  is a valid Icon Composer asset built from the existing 1024 artwork; `actool` compiles it as
  the app icon (`AppIcon_Assets/Color-*` renditions in `Assets.car`, `CFBundleIconName = AppIcon`)
  and the signed build passes. It's currently a single base layer — open `AppIcon.icon` in Icon
  Composer to add specular/foreground/background depth + hand-tuned dark/tinted variants when
  desired (a design refinement, not a blocker).
- **TipKit** ✅ **(done)** — `Tips.swift` defines Open-Quickly / wiki-link / transclusion /
  graph / rescan tips; `HelloNotesTips.configure()` runs at launch; the Graph tip is
  attached via `.popoverTip`. Attach the remaining tips to their controls as desired
  (one `.popoverTip(_:)` line each).
- **iCloud KV store** ✅ **(done — signed build passes)** — `CloudPrefs` mirrors a small
  allow-list of preference keys via `NSUbiquitousKeyValueStore` (pull on launch + external
  change, push on local change, loop-guarded); started in `HelloNotesApp`. Entitlement
  `com.apple.developer.ubiquity-kvstore-identifier` added, and the iCloud capability declared
  in the target's `SystemCapabilities` so automatic signing provisions it — the **signed build
  succeeds on both platforms** (`-allowProvisioningUpdates`), no manual Xcode step. Never
  stores note content.

## Phase D — Bigger bets (M each)

- **SpeechAnalyzer voice capture** ✅ **(code done; runtime needs a mic + device)** —
  `VoiceCapture` (actor) streams the mic through `SpeechAnalyzer` + `SpeechTranscriber`
  (on-demand model install via `AssetInventory`), converting buffers to the analyzer's
  preferred format. `DictationController` drives it from the UI (⌥⌘D "Dictate to Daily
  Note" in the Note menu) and appends the transcript to today's daily note on stop. Added
  the mic entitlement + `NSMicrophoneUsageDescription`/`NSSpeechRecognitionUsageDescription`.
  Availability-gated; compiles on both platforms. Runtime verification needs a device with a
  microphone.
- **Foundation Models upgrade** ✅ **(code done; runtime needs Apple Intelligence hardware)** —
  `FoundationModelsIntelligence` (macOS/iOS 26, `canImport`+`@available` gated so the macOS 15
  floor still builds): `@Generable NoteSuggestion` (title + tags) via guided generation —
  now the tag-suggestion path on the on-device model, replacing reply-parsing — plus a
  `VaultSearchTool: Tool` and `answer(question:search:)` for grounded offline Ask-Library
  Q&A (ready; wire into `LibraryChatView`'s offline branch). Cloud providers stay the
  quality tier. Runtime verification needs Apple-silicon + Apple Intelligence enabled.
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
