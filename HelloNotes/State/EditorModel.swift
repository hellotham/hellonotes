//
//  EditorModel.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation
import MarkdownCore
import Observation

/// A note's text as a view's input — compared by its version, never by its
/// characters.
///
/// SwiftUI compares a view's `Equatable` inputs to decide whether to redraw
/// it, so a view handed the note as a `String` compared the whole note on the
/// main actor at every redraw of its parent: 206ms for a 2 MB note that
/// differed at its end — two comparisons of 103ms — and once a keystroke in
/// Markdown mode with the inspector showing. A version moves whenever the text
/// is set, so equal versions are equal texts.
nonisolated struct NoteText: Equatable, Sendable {
    let text: String
    /// `nil` when no editor holds a note; the text is then empty.
    let version: EditorModel.TextVersion?

    static let none = NoteText(text: "", version: nil)

    static func == (a: NoteText, b: NoteText) -> Bool { a.version == b.version }
}

/// Owns the currently-open note's editing buffer and persists edits back to
/// disk. The file system is the source of truth: this model loads a note's
/// text, tracks whether the buffer diverges from what's on disk, and writes
/// changes atomically after a short debounce so no keystroke is ever lost.
@MainActor
@Observable
final class EditorModel {
    /// This editor's address on the command bus (`EditorBus`): the Format menu,
    /// the find bar, ⌘F and the outline's jumps are posted to it, and only the
    /// views showing this editor answer.
    ///
    /// The editor's, never the note's. The bus was addressed by the note's path
    /// — and the find bar's messages by nothing at all — so two editors on one
    /// note (two windows, or Open in New Window: a buffer each) both answered,
    /// and a Replace All in one rewrote the note open in the other.
    let editorID = UUID().uuidString
    /// The note currently loaded in the editor, if any.
    private(set) var note: Note?

    /// Every editor in the process, held weakly — every window's tabs and every
    /// note window — so "which notes are open?" has one answer wherever it is
    /// asked. A cloud collection's cache asks before it evicts anything
    /// (`Collection.hydrateIfNeeded`): each window keeps its own tabs, and a
    /// note open in one of them is as open as one in the window at hand.
    private static let everyEditor = NSHashTable<EditorModel>.weakObjects()

    /// The files of the notes every editor holds, in any window.
    static var openNoteURLs: [URL] { everyEditor.allObjects.compactMap { $0.note?.fileURL } }

    /// Every editor holding the note at `url`, in any window.
    static func editors(holding url: URL) -> [EditorModel] {
        everyEditor.allObjects.filter { $0.note?.fileURL == url }
    }

    /// A note, or a folder of notes, has moved from `old` to `new` — renamed,
    /// or moved into another folder: every editor holding a note there, in
    /// any window, follows it, in place. The buffer is the same note's, so
    /// nothing is loaded; a renamed note takes `title`.
    ///
    /// A note's identity is its file, and editors held the old one: the next
    /// prune took a tab that held nothing unsaved, so a renamed note's tab
    /// went to the end of the strip — a new one, made for the new file — and
    /// a moved note's background tab closed without a word (tabs.md §2.5,
    /// items 13 and 14; implemented.md §51.36). Called in the turn the move
    /// is taken into the picture, before anything can prune.
    static func itemMoved(from old: URL, to new: URL, title: String? = nil) {
        let from = old.standardizedFileURL.path
        let to = new.standardizedFileURL.path
        for editor in everyEditor.allObjects {
            guard let note = editor.note else { continue }
            let path = note.fileURL.standardizedFileURL.path
            let moved: URL
            if path == from {
                moved = new
            } else if path.hasPrefix(from + "/") {
                moved = URL(fileURLWithPath: to + path.dropFirst(from.count))
            } else {
                continue
            }
            editor.note = Note(title: path == from ? (title ?? note.title) : note.title, fileURL: moved,
                               lastModified: note.lastModified, fileSize: note.fileSize,
                               isOnlineOnly: note.isOnlineOnly)
        }
    }

    /// Whether the buffer is the note: loaded, and not being loaded again.
    var isLoaded: Bool { loadFailure == nil && loadsInFlight == 0 }

    init() {
        // In a pool of its own: the weak table's `add` retains and autoreleases
        // what it is given, so an editor otherwise lived until the run loop's
        // pool drained — whatever owned it had let go (implemented.md §51.36).
        autoreleasepool { Self.everyEditor.add(self) }
        settledText = NoteText(text: "", version: textVersion)
    }

    /// Whether the buffer has unsaved changes relative to the last write.
    ///
    /// Counted, never compared: the buffer's generation against the one the
    /// file holds. `text != lastSavedText` was a pass over the whole note on the
    /// main actor whenever the buffer changed — on every keystroke in Markdown
    /// and Split mode, which write through — at 31–57 ms a megabyte when the
    /// buffer is an editor's bridged copy. A count can only err towards dirty:
    /// a buffer typed back to what the file says reads as dirty until the next
    /// save finds, off the main actor, that there is nothing to write.
    var isDirty: Bool { textGeneration != savedGeneration }

    /// Bumps whenever `text` is set — loaded, taken from an editor, written by
    /// the app, typed into the Markdown pane. What follows the text follows
    /// this (`textVersion`), because comparing two versions of a note is a pass
    /// over all of it.
    private(set) var textGeneration = 0

    /// The generation of the text the file holds: the last one loaded, or
    /// written, or found to be what the file already said. `nil` when the file
    /// holds none of ours — someone else's change the person chose to overwrite
    /// (`resolveConflictKeepingMine`) — so the buffer is dirty whatever it says.
    private var savedGeneration: Int? = 0

    /// Which buffer, and which of its texts — what a view keys on to follow the
    /// text without reading it. The editor is part of it because a view can be
    /// handed another tab's model, whose count may happen to match.
    nonisolated struct TextVersion: Hashable, Sendable {
        let editor: String
        let generation: Int
    }

    var textVersion: TextVersion { TextVersion(editor: editorID, generation: textGeneration) }

    /// The text as of the last pause in typing, with its version — what
    /// follows the note without editing it keys on this: Preview, the
    /// inspector, another scene's mirror (`LiveBuffer`).
    ///
    /// They keyed on the buffer, and the Markdown pane writes the buffer on
    /// every keystroke — so in Split mode each key rendered the whole page
    /// twice, walked the note for maths and diagrams, and analysed it for the
    /// outline, all on the main actor: 700ms of main-thread CPU a keystroke in
    /// a 700 KB note (`MainActorBudgetTests`). Typing (`typed`) settles once
    /// it pauses for `settleDelay`; anything else — a load, an app write, the
    /// live editor's text carried in, a flush — settles at once. Compared by
    /// version (`NoteText`), so setting it compares no text.
    private(set) var settledText: NoteText = .none

    /// How long typing must pause before what follows the text catches up.
    static let settleDelay: Duration = .milliseconds(300)

    @ObservationIgnored private var settleTask: Task<Void, Never>?
    /// Set while a keystroke is written (`typed`), so the change settles later.
    @ObservationIgnored private var isTyping = false

    /// The most recent save failure, surfaced to the UI (nil when healthy).
    private(set) var saveError: String?

    /// True while opening an online-only (cloud) note whose bytes are still
    /// being materialized. Drives a "Downloading…" state so the editor doesn't
    /// just show blank while a slow download runs.
    private(set) var isDownloading = false

    /// Set when the note's contents could not be loaded — still downloading, or
    /// unreadable. **While this is set the editor never writes**, because the
    /// buffer is not the note: it is a blank standing in for content that was
    /// not available, and saving it would replace the note with nothing.
    private(set) var loadFailure: String?

    /// Loads under way: from the moment `open` has flushed the note it is
    /// leaving until the next note's text is in the buffer. **While any is,
    /// the editor never writes** — the buffer is not the note yet but the
    /// blank a new tab starts with, or the note this editor showed before, and
    /// the load will replace whatever is typed into it.
    ///
    /// `loadFailure` used to be that lock, and `open` cleared it before the
    /// wait — up to a minute for a cloud download, as long as the provider
    /// holds the file for the read — so a save in the wait wrote the blank, or
    /// the previous note, over the note that was arriving. It is a lock of its
    /// own because `loadFailure` is also what puts "couldn't be read" on
    /// screen: held through every ordinary read, it would flash that banner on
    /// each open. A count, so a second `open` (a retry during the first) is
    /// not unlocked when the first finishes.
    @ObservationIgnored private var loadsInFlight = 0

    /// Increments after every successful write. Observers (e.g. the link graph)
    /// use it to know a note's contents changed on disk.
    private(set) var savedRevision = 0

    /// True when the open note changed on disk *and* we have unsaved edits, so
    /// the user must choose whether to keep their version or reload.
    private(set) var hasConflict = false

    /// Called after each write with the note's URL and the text written, so
    /// the owning collection can mark the write as its own (suppressing the file
    /// watcher) and patch its index from memory without re-reading the vault.
    /// Not called for a save that found the file already saying it: nothing
    /// was written, and a write marked as our own would hide the next change
    /// made elsewhere from the watcher.
    var onSaved: (@MainActor (URL, String) -> Void)?

    /// Called once a note that was online-only has finished downloading, so the
    /// owning collection can drop the cloud badge from its row.
    ///
    /// The download is the editor's to wait for, but the badge belongs to the
    /// note in the sidebar, and `Note.isOnlineOnly` is a stored value set when
    /// the folder was walked. Nothing told it the file had arrived, so the icon
    /// sat there afterwards saying the note was still in the cloud while the
    /// note was open on screen.
    var onBecameAvailable: (@MainActor (URL) -> Void)?

    /// Called with a file the editor put beside its note — a pasted picture —
    /// so the note's collection has it too: in a cloud collection, uploaded.
    /// A picture pasted into a note there was written to this device's copy
    /// alone, and the note that showed it everywhere else pointed at nothing.
    var onFileMade: (@MainActor (URL) -> Void)?

    /// Asked before every write; a non-nil return refuses the save and becomes
    /// `saveError`. Set by the shell, which knows whether the note's collection
    /// is still readable.
    ///
    /// Refusing matters more than it looks: the buffer stays dirty, so the edit
    /// survives in memory and is written the moment the folder comes back. A
    /// write attempted into a vanished folder would fail anyway — this makes it
    /// fail *legibly*, and guarantees we never conjure a directory to hold a
    /// note whose real home has gone.
    var saveBlockedReason: (@MainActor (URL) -> String?)?

    /// Asked before a change seen on disk is taken: whether the file is a
    /// stand-in the note's collection knows of — a cloud mirror's placeholder,
    /// whose emptiness is never the note's text. Set by the shell, which knows
    /// the note's collection (`Collection.isPlaceholder(at:)`), and answered
    /// from memory, because it is asked on the main actor. Whether an iCloud
    /// item has downloaded is a question for the file provider, and is asked
    /// beside the read, off it (`reconcileWithDisk`).
    var isPlaceholder: (@MainActor (URL) -> Bool)?

    /// Called before a note's file is read, so a cloud collection can fetch the
    /// bytes of a note its cache holds only as a placeholder
    /// (`Collection.hydrateIfNeeded`). Set with the others (`EditorWiring`),
    /// and asked on every open — the first, and the banner's Try Again, which
    /// read the file again without fetching anything.
    var prepareToOpen: (@MainActor (URL) async -> Void)?

    /// Called at the start of every flush, before the buffer is persisted.
    /// The new-editor host uses this to push its document's latest text into
    /// `text` first, so a flush on note switch / quit never saves a snapshot
    /// that trails the editor by a debounce interval.
    var willFlush: (@MainActor () -> Void)?

    /// The live editor's Mermaid diagrams and its caret, both read from the
    /// editor's own document — for the diagram zoom, which opens on "the one
    /// you are in". Installed by the editor host beside `willFlush` and
    /// removed with it, so it is nil whenever no live editor shows this buffer
    /// (Preview, and the Markdown pane, which keeps no document).
    ///
    /// The diagrams come from the parse the document already keeps, in the
    /// same coordinates as the caret and as a diagram button's press. The zoom
    /// used to take the editor's text into this buffer and parse it again,
    /// both on the main actor: a comparison of a bridged string and a
    /// whole-document parse, about 50ms before the sheet on a 1MB note.
    var liveDiagrams: (@MainActor () -> (diagrams: [MermaidDiagram], caret: Int)?)?

    /// Increments whenever the buffer is *loaded* (note open, external
    /// reload, conflict resolution) — never on ordinary saves. Editors that
    /// own their own buffer key their rebuild on this.
    private(set) var loadRevision = 0

    /// The external on-disk version captured when a conflict was detected.
    @ObservationIgnored private var conflictDiskText: String?
    /// Counts the conflicts raised, so work begun during one — a copy of mine
    /// being written — can tell whether the one it began in is still open.
    @ObservationIgnored private var conflictNumber = 0
    /// Where mine was kept beside the note during this conflict, what was
    /// written there, and the buffer generation it was — see
    /// `keepMineBesideTheNote`.
    @ObservationIgnored private var conflictCopy: (url: URL, text: String, generation: Int)?
    /// Keep Mine or Reload, chosen and not yet done. The banner's buttons wait
    /// for it, and a second choice is not taken: both waited on the same
    /// write, either could resume first, and the one made second could undo
    /// the one made first.
    private(set) var isResolvingConflict = false

    /// The live editing buffer bound to the text view. Any change is an edit
    /// and marks the buffer dirty, except a load (`replaceText`), which is the
    /// file's own text.
    ///
    /// Observed by hand, not by the macro. `@Observable`'s setter compares the
    /// old value with the new, to skip notifying for an equal one, and for this
    /// property that is the whole note compared on the main actor on every
    /// set — per keystroke in Markdown and Split mode, and at 31–57 ms a
    /// megabyte when the new text is an editor's bridged copy. What follows the
    /// text follows `textVersion`, which is how it knows without comparing.
    var text: String {
        get {
            access(keyPath: \.text)
            return buffer
        }
        set {
            withMutation(keyPath: \.text) { buffer = newValue }
            textDidChange()
        }
        // In place, as the macro's own `_modify` does it — `editor.text += …`
        // appends to the buffer rather than copying the note to append to it.
        _modify {
            access(keyPath: \.text)
            _$observationRegistrar.willSet(self, keyPath: \.text)
            defer {
                _$observationRegistrar.didSet(self, keyPath: \.text)
                textDidChange()
            }
            yield &buffer
        }
    }

    private func textDidChange() {
        textGeneration &+= 1
        if isTyping { settleSoon() } else { settle() }
        guard !isReplacingText else { return }
        scheduleSave()
    }

    /// A keystroke in the Markdown pane: the buffer moves now, and what
    /// follows it (`settledText`) waits for the typing to pause.
    func typed(_ newText: String) {
        isTyping = true
        defer { isTyping = false }
        text = newText
    }

    /// Bring `settledText` up to the buffer now.
    private func settle() {
        settleTask?.cancel()
        settleTask = nil
        settledText = NoteText(text: buffer, version: textVersion)
    }

    private func settleSoon() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.settle()
        }
    }

    @ObservationIgnored private var buffer = ""

    /// What the file holds, as far as this editor knows: the text last loaded
    /// or written. Only ever compared off the main actor (`sameBytes`), and
    /// kept out of observation for the reason `text` is: nothing watches it,
    /// and the macro's setter would compare the whole note to find that out.
    @ObservationIgnored private var lastSavedText = "" {
        didSet { lastSavedChanges &+= 1 }
    }
    /// Bumps whenever `lastSavedText` is replaced — by a load, a write, or
    /// Keep Mine — so a check against it that spans an await can tell it
    /// compared with a baseline that has since moved.
    @ObservationIgnored private var lastSavedChanges = 0
    private var isReplacingText = false
    private var saveTask: Task<Void, Never>?
    /// The most recent write, so a new save chains after it instead of racing
    /// it at the filesystem (see `save()`).
    private var writeInFlight: Task<Void, Never>?

    private static let debounce: Duration = .milliseconds(600)

    /// Adopt the note's *identity* before its content is available.
    ///
    /// A tab has to be able to draw — its title, and the banner saying the file
    /// is still downloading — while `open` is still waiting on the cloud. It
    /// marks the buffer unloaded so nothing can be written in the meantime.
    func willOpen(_ note: Note) {
        self.note = note
        loadFailure = "“\(note.title)” is still loading."
        // What the scan found, from memory: the file provider is asked off the
        // main actor, by `open`. Asked here, it was a round trip to the
        // provider on the main thread per note opened (implemented.md §51.36).
        isDownloading = note.isOnlineOnly
    }

    /// Load a note into the editor, flushing any pending save for the
    /// previous note first so switching notes never drops changes. Pass `nil`
    /// to clear the editor.
    func open(_ note: Note?) async {
        // Letting go of the note it held — unless a conflict of that note's
        // could not keep mine anywhere: opening another would drop it.
        guard await flush() else { return }
        // **What a refused save kept is not the load's to replace.** A save
        // is refused while the note is not loaded, or its folder has gone,
        // and the buffer keeps the edit for when it can be written. Replaced
        // by the load, it went: the banner's Try Again opened the note over
        // whatever was typed into the blank, and a second failure put the
        // blank back over it. So another note is not opened over it, and the
        // same note, read again, is set against it as a conflict (below).
        let keeping = isDirty && !hasConflict
        guard !keeping || note?.fileURL == self.note?.fileURL else { return }
        // Locked from here — the note it was leaving is saved, the next one is
        // not in the buffer yet — until the loaded text replaces the buffer
        // below. See `loadsInFlight`.
        loadsInFlight += 1
        defer { loadsInFlight -= 1 }

        self.note = note
        saveError = nil
        endConflict()

        let loaded: String
        loadFailure = nil
        if let note, case let url = note.fileURL {
            // **Wait for the bytes before reading them.**
            //
            // This used to read straight away and say the read would
            // materialise the file on its way past. Sometimes it does; when it
            // does not, `try?` turned the failure into `""` — and `""` is not a
            // failure, it is *an empty note*. `lastSavedText` became empty too,
            // so the first character typed made the buffer dirty against an
            // empty baseline and the next save wrote that over the original.
            // `FileIO.hasContentAvailable` says so in as many words; the editor
            // was the one place not asking it.
            // Off the main actor: for a File Provider's file this is a round
            // trip to the provider (implemented.md §51.15, §51.36).
            let online = await offMain { !FileIO.hasContentAvailable(note) }
            isDownloading = online
            // A cloud mirror's note fetched first: its cache holds a note it
            // has not downloaded as a placeholder of the note's name, and
            // reading that is reading an empty note. A no-op for a note already
            // here, and for any other collection.
            await prepareToOpen?(url)
            if online {
                let arrived = await FileIO.materialise(at: url)
                isDownloading = false
                if !arrived {
                    loadFailure = "“\(note.title)” hasn’t finished downloading from the cloud. "
                                + "It will open once the download completes."
                }
            }
            // **A placeholder is not the note** — here because the fetch
            // failed: the provider could not be reached. It was read as an
            // empty note, and what was typed into it was written over the
            // placeholder, never uploaded (the upload refuses a note it has
            // not downloaded), and written over in turn by the next download.
            // Unloaded, the buffer takes no write, and Try Again fetches.
            if loadFailure == nil, isPlaceholder?(url) == true {
                loadFailure = "“\(note.title)” couldn’t be downloaded from the cloud, so it isn’t open."
            }
            // Arrived — which a placeholder has not, however the file system
            // answers for the empty file standing in for it: told that, the
            // collection took the note's cloud badge off its row.
            if online, loadFailure == nil { onBecameAvailable?(url) }
            if loadFailure == nil {
                // Read off the main actor so opening a large note never stalls the UI.
                let outcome = await Task.detached(priority: .userInitiated) {
                    Result { try FileIO.readString(at: url) }
                }.value
                switch outcome {
                case .success(let text):
                    loaded = text
                case .failure(let error):
                    loadFailure = "“\(note.title)” couldn’t be read — \(error.localizedDescription)"
                    loaded = ""
                }
            } else {
                loaded = ""
            }
        } else {
            loaded = ""
        }

        guard keeping else { return replaceText(loaded) }
        // Still not here: the buffer stays as it is, unloaded, and keeps what
        // was typed. Here: what the file says against what was typed.
        guard loadFailure == nil else { return }
        let generation = textGeneration
        let mine = text
        let same = await offMain { Self.sameBytes(loaded, mine) }
        if same, textGeneration == generation {
            replaceText(loaded)
        } else {
            raiseConflict(theirs: loaded)
        }
    }

    /// Take an editor's text as the buffer — **only if the editor's copy was
    /// made from the load the buffer holds now.** Returns whether it was taken.
    ///
    /// An editor keeps its own document, built from `text`, and pushes it back
    /// here when editing settles (end of editing, a flush, the editor going
    /// away) on the rule "if they differ, the editor's is newer". That rule is
    /// wrong for a document built *before* the note finished loading: it holds
    /// nothing, and if the load lands without it being refreshed, its
    /// difference from the buffer is the whole note. Taking it is saving an
    /// empty note over a full one — which is what wiped "Start Here" seven
    /// seconds after build 22 launched on 19 September 2026 (a new, empty file,
    /// written by HelloNotes itself). A stale copy is refused and the note on
    /// disk is left alone.
    ///
    /// Taken without comparing it with the buffer. The host offers a copy only
    /// when it has been edited since the two last matched
    /// (`DocumentLoad.carry`), and the comparison was a pass over a bridged
    /// string on the main actor; a copy that turns out to be the file's bytes
    /// is found out by the save, off the main actor, and not written.
    @discardableResult
    func adopt(_ newText: String, fromLoad revision: Int) -> Bool {
        guard revision == loadRevision else { return false }
        text = newText
        return true
    }

    /// A change the app makes to the note: a tag, a link or a summary accepted,
    /// the link review, a property edited, a rewrite, a restored version, a
    /// template. `nil` from `transform` is no change. Returns whether the note
    /// changed.
    ///
    /// **Made to what is on screen.** What the live editor holds that the
    /// buffer has not yet taken — the typing since editing last settled — is
    /// carried first, so `transform` sees it; then the editor shows the result
    /// (`EditorHost` follows `textVersion`, and a buffer that alone has moved
    /// replaces the document). Written straight into the buffer, the change
    /// never reached the document, and the next carry wrote the document —
    /// without it — back over it.
    ///
    /// **And written** — every app write is a commit. A text change schedules
    /// no save, so each of these reached the file only at the next flush — a
    /// switch of note, mode or app, a tab closing, quitting — and a crash
    /// before one lost it; the Properties panel was the only one that saved
    /// (implemented.md §51.30, §51.36). Through the model's own save, so a
    /// conflict, a load in flight and a blocked save keep their rules. No
    /// change is no write.
    @discardableResult
    func applyEdit(_ transform: (String) -> String?) -> Bool {
        carryLiveEdits()
        guard let edited = transform(text) else { return false }
        text = edited
        Task { await save() }
        return true
    }

    /// The note's front matter set to `properties`, **and written** — the
    /// Properties panel's commit (Return, leaving a field, a toggle, Add, a
    /// row's remove button) and its one way in, from the inspector and from
    /// the note's own popover.
    ///
    /// Written as every app write is (`applyEdit`), because a text change
    /// schedules nothing: a property changed here reached the file only at
    /// the next flush — a switch of note, mode or app, a tab closing,
    /// quitting — and a crash before one lost it (§51.30).
    ///
    /// Values the note already holds are no change (`FrontMatter.applyingChanges`),
    /// and no change is no write: a field hands its value back when it gains
    /// focus, and writing that moved the buffer, so the note on screen was
    /// replaced — its undo cleared — and the panel, following the text, rebuilt
    /// the field out from under the tap.
    func setProperties(_ properties: [Property]) {
        applyEdit { FrontMatter.applyingChanges(properties, to: $0) }
    }

    /// Take what the live editor holds that the buffer has not yet taken, if
    /// an editor is showing this buffer. Before the app reads the buffer to
    /// change it or to show it elsewhere — a rewrite's original, a link review
    /// — so the change is made to what is on screen.
    func carryLiveEdits() {
        willFlush?()
    }

    /// Cancel the pending debounce and persist immediately. Call on note
    /// switch, window resignation, and app termination. Returns `false` only
    /// when a conflict is open, the buffer is being let go, and mine could not
    /// be kept anywhere — a caller about to drop the buffer must not, then.
    ///
    /// **With a conflict open, the note is not written** — Keep Mine is the one
    /// way mine reaches it — and the buffer stays dirty. `lettingGo` says the
    /// buffer may not outlive this: its tab or window closing, the editor
    /// opening another note, the app quitting, or leaving the foreground on
    /// iOS, which can then end it without a word. Then mine is kept beside the
    /// note, as a conflicted copy (`keepMineBesideTheNote`): the note keeps
    /// theirs, and the banner, if the editor survives, still asks. Not letting
    /// go — a switch of mode, a rename, the Mac going to the background — a
    /// conflict writes nothing anywhere: the buffer is still here to be chosen.
    @discardableResult
    func flush(lettingGo: Bool = true) async -> Bool {
        willFlush?()
        // Editing has stopped, which is a pause in typing.
        if settleTask != nil { settle() }
        saveTask?.cancel()
        saveTask = nil
        // Asked again after the save: a save that finds a change it has not
        // seen raises the conflict itself and writes nothing. Asked only
        // before it, the flush said the buffer was saved, and a buffer being
        // let go went — what was typed with it, and no copy of it kept.
        if !hasConflict { await save() }
        guard hasConflict, lettingGo else { return true }
        return await keepMineBesideTheNote()
    }

    /// Whether the buffer holds what the file does not once a flush has
    /// tried to write it — a save refused (the note's folder gone, the note
    /// not loaded) or failed. Letting go of the buffer then loses it, so a
    /// tab closing keeps it open (`EditorTabs.close`). A conflict's mine is
    /// the flush's to keep (`keepMineBesideTheNote`), so is not counted here.
    ///
    /// A buffer typed back to what the file says holds nothing, and is clean
    /// again: the count only ever errs towards dirty (`isDirty`), and without
    /// this a tab that once held a refused save could never be closed. The
    /// comparison is a pass over the note, so it is made off the main actor.
    func holdsUnsavedWork() async -> Bool {
        carryLiveEdits()
        guard isDirty, !hasConflict else { return false }
        let generation = textGeneration
        let baseline = lastSavedChanges
        let mine = text
        let known = lastSavedText
        let same = await offMain { Self.sameBytes(mine, known) }
        guard same, textGeneration == generation, lastSavedChanges == baseline else { return isDirty }
        savedGeneration = generation
        return false
    }

    /// React to the collection changing on disk. If the open note's file changed
    /// externally and our buffer is clean, silently reload it. If the buffer
    /// has unsaved edits, raise a conflict for the user to resolve.
    func reconcileWithDisk() async {
        guard let url = note?.fileURL else { return }
        // A load under way reads the file itself. Checked now, it would be
        // compared with the baseline of whatever the buffer held before — the
        // blank, or another note — and anything typed in the wait would put a
        // conflict over the note as it arrives.
        guard loadsInFlight == 0 else { return }
        // A stand-in is not the note. A cloud mirror's placeholder has the
        // note's name and nothing in it; taken as a change, it put an empty
        // note in a clean tab and a conflict against "" in one with edits. An
        // iCloud item not yet downloaded is the same, and is asked off the
        // main actor below: the file provider answers that one, and it can be
        // slowest exactly when it is busy syncing — when changes arrive.
        if let isPlaceholder, isPlaceholder(url) { return }
        // What is typed and not yet carried is unsaved work too, and `isDirty`
        // cannot see it until it is carried. Unseen, a change elsewhere was
        // taken as a reload — silently, over the typing on screen.
        carryLiveEdits()
        // Read the file, and compare it with what we last wrote, off the main
        // actor: both are passes over the whole note. The comparison was made
        // here, on the main actor, a character at a time whenever the last save
        // was an editor's bridged copy — 160,000 reads for a 94 KB note.
        let known = lastSavedText
        let buffer = text
        let generation = textGeneration
        let baseline = lastSavedChanges
        let found = await offMain { () -> (disk: String, unchanged: Bool, bufferIsKnown: Bool)? in
            guard FileIO.isMaterialized(at: url), let disk = try? FileIO.readString(at: url) else { return nil }
            let unchanged = Self.sameBytes(disk, known)
            // Only asked when the file did change: whether the buffer still
            // says what we last wrote, which a count cannot tell.
            return (disk, unchanged, unchanged || Self.sameBytes(buffer, known))
        }
        // A load, a write or Keep Mine landed while the file was being read,
        // so what it was compared with is no longer what we last wrote. Look
        // again.
        guard lastSavedChanges == baseline else { return await reconcileWithDisk() }
        // A load begun while the file was read reads it itself.
        guard loadsInFlight == 0 else { return }
        guard let found else { return }

        // **Arrived.** A note whose load failed — a download that ran out of
        // time, a fetch that could not reach the provider, a file that could
        // not be read — has been read now, so it is open: the banner saying
        // it is not, and the refusal of every save, go with the failure. It
        // was left, so the note's text came up under a banner saying it was
        // not open, and its saves were refused. The buffer is the blank the
        // failure left, or what was typed into it, against an empty baseline:
        // the file is taken below as any change is — into a clean buffer, or
        // as a conflict with the typing.
        if let failure = loadFailure {
            if saveError == failure { saveError = nil }
            loadFailure = nil
            onBecameAvailable?(url)
        }

        // Matches what we last wrote (includes our own saves) → nothing to do —
        // and a conflict over a file put back to it is over. (A save never
        // lands over a change it has not seen, so the file matches our last
        // write only if that is what it holds again.)
        guard !found.unchanged else {
            endConflict()
            return
        }

        // Dirty by the count and not in fact — typed back to what we last
        // wrote — is clean: nothing of the person's differs from the file we
        // knew, so the change elsewhere is taken, as it always was. A buffer
        // that moved while the file was read is an edit in progress. **And
        // never while a conflict is open**: taken then, the newer theirs moved
        // into the buffer under a banner still holding the older, and a Reload
        // afterwards put the older back.
        let edited = hasConflict || (isDirty && !(found.bufferIsKnown && textGeneration == generation))
        if edited {
            raiseConflict(theirs: found.disk)
        } else {
            replaceText(found.disk)
        }
    }

    /// The file's `theirs` set against the buffer, which is mine. Theirs
    /// moving on under an open conflict is the same conflict, with the same
    /// copy of mine; a new one starts its own.
    private func raiseConflict(theirs: String) {
        if !hasConflict {
            conflictNumber &+= 1
            conflictCopy = nil
        }
        conflictDiskText = theirs
        hasConflict = true
    }

    /// Resolve a conflict by discarding mine and taking theirs.
    ///
    /// After any write already in flight — a save begun before the conflict,
    /// a copy of mine being kept — so its bookkeeping, which follows its await
    /// unconditionally, cannot land on the baseline this sets. A save no
    /// longer writes over a change it has not seen
    /// (`FileIO.replace(_:at:ifBytesAre:)`), so the file holds theirs.
    func resolveConflictReloading() async {
        guard hasConflict, !isResolvingConflict else { return }
        isResolvingConflict = true
        defer { isResolvingConflict = false }
        await writeInFlight?.value
        guard hasConflict, let disk = conflictDiskText else { return }
        replaceText(disk)
        endConflict()
    }

    /// Resolve a conflict by keeping mine and writing it over theirs — the
    /// one way mine reaches the note while a conflict is open.
    ///
    /// After any write already in flight, for the reason Reload waits. Mine is
    /// what is on screen, so what the live editor holds that the buffer has
    /// not yet taken is carried first. The save compares with theirs: if the
    /// file has moved on again it writes nothing, and the banner comes back
    /// with the newer version to choose over.
    func resolveConflictKeepingMine() async {
        guard hasConflict, !isResolvingConflict else { return }
        isResolvingConflict = true
        defer { isResolvingConflict = false }
        await writeInFlight?.value
        guard hasConflict else { return }
        carryLiveEdits()
        // The file holds theirs now, so theirs is what the save compares with,
        // and the buffer is dirty whatever it says: mine can be, byte for byte,
        // what was last saved, and keeping it means writing it anyway.
        if let disk = conflictDiskText {
            lastSavedText = disk
            savedGeneration = nil
        }
        endConflict()
        await save()
    }

    private func endConflict() {
        hasConflict = false
        conflictDiskText = nil
        conflictCopy = nil
    }

    /// Mine, kept beside the note while a conflict is open and the buffer is
    /// being let go — the note holds theirs until the person chooses, and
    /// mine would otherwise go with the buffer. Returns whether mine is safe:
    /// kept now, kept already, or no longer needing it.
    ///
    /// A conflicted copy (`FileIO.createConflictedCopy`), never over a file
    /// already there. One per conflict: a later let-go brings that copy up to
    /// date — unless it no longer holds what was written there, when someone
    /// has changed it and it is theirs, or an editor has it open, where what
    /// that editor holds would be saved over it from the older mine; either
    /// way mine gets a copy of its own. The collection hears of it as of a
    /// save (`onSaved`), so it is a note like any other at once.
    ///
    /// **On the write queue, in its turn**, like every save: two let-gos at
    /// once — iOS drains once for resigning active and again for each change
    /// of scene phase — made two copies, and a copy landing after the
    /// conflict was resolved was recorded against the next one. Everything is
    /// looked at again when the turn comes.
    ///
    /// A failure is a save failure: said on the banner, and the buffer, still
    /// dirty, still holds mine for as long as the editor lives.
    private func keepMineBesideTheNote() async -> Bool {
        let previous = writeInFlight
        let keeping = Task { [weak self] () -> Bool in
            await previous?.value
            return await self?.performKeepMine() ?? false
        }
        writeInFlight = Task { _ = await keeping.value }
        return await keeping.value
    }

    private func performKeepMine() async -> Bool {
        guard hasConflict, let url = note?.fileURL, isDirty else { return true }
        let generation = textGeneration
        if let kept = conflictCopy, kept.generation == generation { return true }
        let conflict = conflictNumber
        let mine = text
        let previous = conflictCopy.flatMap { Self.openNoteURLs.contains($0.url) ? nil : $0 }
        do {
            let kept = try await offMain { () throws -> (url: URL, text: String) in
                var bytes = mine
                bytes.makeContiguousUTF8()
                let data = Data(bytes.utf8)
                if let previous,
                   (try? FileIO.replace(data, at: previous.url, ifBytesAre: Data(previous.text.utf8))) == true {
                    return (previous.url, bytes)
                }
                return (try FileIO.createConflictedCopy(beside: url, holding: data), bytes)
            }
            if hasConflict, conflictNumber == conflict {
                conflictCopy = (kept.url, kept.text, generation)
            }
            onSaved?(kept.url, kept.text)
            return true
        } catch {
            saveError = "Your version couldn’t be kept beside the note — \(error.localizedDescription)"
            return false
        }
    }

    /// Persist the buffer if it diverges from disk. Safe to call repeatedly.
    ///
    /// Writes are *serialized*: a new save waits for any in-flight write to
    /// finish before starting its own. `cancel()` cannot stop a `save()` that
    /// is already past its guard and awaiting the detached write, so without
    /// this chaining two atomic writes could race — and atomic rename ordering
    /// is unspecified, so an older write could land last and persist stale
    /// text. That window matters most on `flush()` at app termination, where
    /// there is no later save to converge the buffer back to disk.
    func save() async {
        guard note?.fileURL != nil else { return }
        // Fast path: nothing to persist → don't allocate a Task or touch the
        // write chain. A count, not a comparison — see `isDirty`. (performSave
        // re-checks after the await, so a change that lands while a prior write
        // is in flight is still caught.)
        guard isDirty else { return }
        let previous = writeInFlight
        let task = Task { [weak self] in
            await previous?.value
            await self?.performSave()
        }
        writeInFlight = task
        await task.value
    }

    /// The actual snapshot-and-write step, run serially by `save()`. Because it
    /// only runs after the previous write completes, it reads the *current*
    /// `text` (and the already-advanced `lastSavedText`), so the final on-disk
    /// state always matches the latest buffer.
    private func performSave() async {
        guard let url = note?.fileURL else { return }
        let generation = textGeneration
        guard generation != savedGeneration else { return }
        let snapshot = text

        // Never write while a conflict is open. The file holds theirs, and
        // only Keep Mine may put mine over it: every other save — the end of
        // editing, a tab switch, the app going to the background — did, as if
        // it had been chosen, and a Reload after it called theirs clean while
        // the file held mine. Nothing is said; the banner says it. The buffer
        // stays dirty, and a let-go keeps mine beside the note (`flush`).
        guard !hasConflict else { return }

        // Never write while a note is loading into this editor. The buffer is
        // the blank, or the note before, and it is written to `note`'s file —
        // the one arriving. Not a failure, so nothing is said: the load
        // replaces the buffer, and the lock goes with it.
        guard loadsInFlight == 0 else { return }

        // Never write a buffer that was never loaded. The blank on screen stands
        // in for content that could not be read, and persisting it is exactly
        // the data loss `FileIO.hasContentAvailable` warns about.
        if let failure = loadFailure {
            saveError = failure
            return          // buffer stays dirty on purpose — the edit is not lost
        }

        if let reason = saveBlockedReason?(url) {
            saveError = reason
            return          // buffer stays dirty on purpose — the edit is not lost
        }

        let onDisk = lastSavedText
        do {
            // Off the main actor, both passes over the note: whether its bytes
            // are the file's already, and the bytes themselves. The snapshot is
            // usually an editor's bridged copy — UTF-16 — so making it UTF-8
            // once is most of the cost, and that, a comparison and four more
            // before it were all paid on the main actor.
            //
            // Atomic write (temp file + rename) so a crash mid-write can never
            // leave a truncated note on disk — **and only over the file last
            // seen.** It replaced whatever was there, so a change made
            // elsewhere since the last look was written over at the next save,
            // and a save already past its checks when a change was noticed put
            // mine over theirs with the banner up. `nil`: the file has moved.
            let written = try await offMain { () throws -> (wrote: Bool, saved: String)? in
                var bytes = snapshot
                bytes.makeContiguousUTF8()
                guard !Self.sameBytes(bytes, onDisk) else { return (false, bytes) }
                guard try FileIO.replace(Data(bytes.utf8), at: url, ifBytesAre: Data(onDisk.utf8)) else { return nil }
                return (true, bytes)
            }
            guard let (wrote, saved) = written else {
                // Someone else's change is in the file: nothing of ours goes
                // over it. The buffer stays dirty, and the look that finds the
                // change raises the conflict — now, not when the watcher gets
                // round to it.
                await reconcileWithDisk()
                return
            }
            // The UTF-8 copy the write made, kept instead of the bridged one
            // it was made from: the next comparison, and the indexes the
            // collection patches on the main actor from `onSaved`, read it
            // without converting it again.
            lastSavedText = saved
            savedGeneration = generation
            saveError = nil
            // The file already said this: nothing was written, so there is
            // nothing new on disk for anyone to hear about.
            guard wrote else { return }
            savedRevision += 1
            onSaved?(url, saved)
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Whether two texts are the same bytes — the question a save asks, and
    /// not the one `==` answers. `==` is canonical equivalence, so a
    /// precomposed é and an e with a combining accent are equal to it and are
    /// two different files. A pass over both, so off the main actor only.
    nonisolated static func sameBytes(_ a: String, _ b: String) -> Bool {
        var a = a, b = b
        return a.withUTF8 { x in
            b.withUTF8 { y in
                x.count == y.count && (x.isEmpty || memcmp(x.baseAddress!, y.baseAddress!, x.count) == 0)
            }
        }
    }

    // MARK: - Private

    /// Load the file's text as the buffer, which is therefore clean.
    private func replaceText(_ newValue: String) {
        isReplacingText = true
        text = newValue
        isReplacingText = false
        loadRevision += 1
        lastSavedText = newValue
        savedGeneration = textGeneration
    }

    /// Nothing. A text change does not schedule a save.
    ///
    /// The buffer is written when editing *stops* — `onEndEditing`, a note
    /// switch, backgrounding, quit — because those are the moments a save is
    /// worth taking. A save during typing is out of date by the next character,
    /// and on a File Provider volume it can block the main thread for as long
    /// as the provider takes to answer, which is the freeze.
    private func scheduleSave() {}
}
