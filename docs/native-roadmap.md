# Native-platform adoption roadmap

*Written 2026-07-17, from a documentation-verified review of Apple's system-integration
surface (App Intents, text/content APIs, macOS 26 platform expectations). Every item
below was checked against live Apple docs — minimum-OS versions and API names are
verified, not recalled. Execute phases in order; items within a phase are independent.*

**Starting point:** HelloNotes currently uses zero system-integration surface — no
intents, widgets, Spotlight donation, URL scheme, extensions, Handoff, tips, or state
restoration. The editor is a real `NSTextView` on TextKit 2, which makes several
"features" nearly free.

---

## Phase A — Quick wins (~1 sprint, all in-app, mostly S effort)

| Item | API / approach | Min OS | Notes & gotchas |
|---|---|---|---|
| **Writing Tools config** | `NSTextView.writingToolsBehavior = .complete`; `allowedWritingToolsResultOptions = [.plainText]` | macOS 15.1 | ~90% free because the editor is native TextKit 2. `.plainText` is **required** — otherwise rewrites return rich text and corrupt Markdown syntax. Pause the syntax highlighter in `textViewWritingToolsWillBegin/DidEnd` and restyle once on end. Apple has a known stale-accept bug; handle the session lifecycle in the editor's Writing Tools coordinator (`Packages/NotesEditor`). |
| **Continuity Camera routing** | `NSTextView` context menu already offers "Insert from iPhone → Scan Documents" | works today | Only work needed: route the incoming image through the existing paste-to-attachment path (save to collection's attachments folder + insert `![[…]]`) instead of embedding rich text. |
| **Print (⌘P)** | Render note into an off-screen `NSTextView`/`NSPrintOperation` | any | PDF "export via print panel" falls out for free. Wire to `CommandGroup(replacing: .printItem)`. |
| **Services menu** | `NSServices` Info.plist entry + `NSApp.servicesProvider`: "New HelloNotes Note from Selection" | any | Cheap system-wide capture on Mac; covers most of what a share extension would give us (see Skip list). |
| **UTI import fix (latent bug)** | `UTImportedTypeDeclarations` for `net.daringfireball.markdown`, conforming to `public.utf8-plain-text` | any | Info.plist currently *references* the UTI but never imports the declaration — on a Mac where no other app declares it, `.md` files won't bind to the type. **Import, never export** (exporting would claim ownership and can hijack the system default handler). |
| **URL scheme + router** | `CFBundleURLTypes` → `hellonotes://note?collection=…&path=…`, `onOpenURL` router in the app | any | De-risks Phase B: Spotlight donation, widgets, and intents all deep-link through this. Percent-encode paths; resolve via the existing wiki-link resolver for title-based links. |
| **State restoration** | `@SceneStorage` for selected collection / note / editor mode / sidebar state | any | Reopen exactly where you left off — a core "native citizen" behavior. Store stable identifiers (relative paths), not URLs. |
| **Accessibility: headings rotor** | `.accessibilityRotor` exposing document headings (we already extract them) | any | VoiceOver users navigate a note by heading like a web page. Cheap because `fastHeadings(in:)` already exists. |

## Phase B — System presence (M effort)

Order matters: **App Intents core → IndexedEntity donation → MenuBarExtra capture.**

1. **App Intents core** — the keystone. One framework feeds four surfaces on our OS
   targets: Shortcuts/Siri, **macOS 26 Spotlight actions** (run "New Note" /
   "Append to Daily Note" from ⌘Space with inline parameters), system-Spotlight
   donation, and Apple Intelligence (indexed entities/intents become available to it
   automatically).
   - Model `NoteEntity: AppEntity` (id = collection + relative path; display
     representation = title + snippet) in a target shared with future widgets.
   - Four intents: `CreateNoteIntent`, `AppendToDailyNoteIntent`, `OpenNoteIntent`,
     `SearchNotesIntent`; an `AppShortcutsProvider` with natural phrases.
   - macOS 26 Spotlight actions require a **complete `parameterSummary`** on each
     intent (incomplete summaries silently don't appear in ⌘Space). Adopt
     `supportedModes` (26+) for foreground/background behavior.
2. **IndexedEntity Spotlight donation** — conform `NoteEntity` to `IndexedEntity`
   (macOS 15+): every note becomes findable in ⌘Space with a deep link back
   (via the Phase A URL router). Nearly free once the entity exists. Re-donate from
   the existing index-cache refresh path (we know exactly which notes changed).
3. **MenuBarExtra quick capture + global hotkey** — flagged in research as the single
   highest-daily-value Mac feature. `MenuBarExtra(.window)` with a small capture field
   appending to the daily note. Runs in-app: no sandbox/bookmark issues. Global hotkey
   via `NSEvent.addGlobalMonitorForEvents` (or KeyboardShortcuts-style
   `RegisterEventHotKey`) — needs no special entitlement for a hotkey that activates
   our own app.

## Phase C — Platform polish (M effort)

- **Liquid Glass audit** — the one *required-ish* item. Apps built with Xcode 26 get
  the new material mostly automatically, but custom chrome fights it: audit custom
  toolbar/background fills, adopt `ToolbarSpacer` grouping, respect new safe areas.
  The `UIDesignRequiresCompatibility` opt-out is documented as **temporary** — don't
  ship relying on it.
- **Icon Composer layered icon** — macOS/iOS 26 layered app icon (specular/dark/tinted
  variants) from the existing artwork.
- **TipKit** — 3–5 tips max (wiki-link autocomplete, transclusion, graph view,
  Open Quickly, Rescan). Use event/parameter rules so tips appear in context, not as a
  launch tour.
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
- **WidgetKit** — daily-note / recent-notes widgets. Widgets **cannot resolve
  security-scoped bookmarks** to user-chosen folders: requires an app group container
  with a snapshot (JSON of recent/daily note metadata) written by the app on index
  refresh. Deep-link via the URL scheme.
- **Quick Look extensions** — preview + thumbnail extensions so `.md` files render in
  Finder space-bar preview and get real thumbnails. Reuse the HTML preview renderer;
  extension is sandboxed but QL hands it the file directly (no bookmark issue).

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
