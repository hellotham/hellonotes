//
//  HeldFileTests.swift
//  HelloNotesTests
//
//  A file its provider holds holds a lane, never a thread of the pool — and
//  never another file's lane.
//
//  A coordinated read or write waits for as long as another process holds the
//  file — a cloud provider writing it, another app saving it. On the
//  concurrency pool, which has a thread a core, each such wait held a thread;
//  and every sleeping task in the process wakes through the pool, the main
//  actor's too. So with as many files held as the pool has threads, and a
//  wait on each, nothing else ran: CI's three-core runner showed it with
//  three loading notes (implemented.md §51.62), and the app's saves, looks at
//  the disk, appends and searches all waited the same way (§51.63). Moved onto
//  lanes, a held file then held up whatever else shared its lane — so an
//  editor asks on a lane of its own, and loops over many files on lanes of
//  theirs.
//

import CoreGraphics
import Foundation
import MarkdownEditor
import PDFKit
import Synchronization
import Testing
@testable import HelloNotes

/// One test at a time: the first two hold more files than the pool has
/// threads, and run side by side one's breakers freed the pool for the other —
/// under the negative control, the save test passed on the look test's
/// release.
@Suite(.serialized) @MainActor
struct HeldFileTests {

    /// **Saves waiting on held files hold no thread of the pool.** Each note
    /// is loaded and typed into, its file held, and saved: the save waits on
    /// its lane for the file to be let go. Meanwhile a task that sleeps keeps
    /// waking. Written on the pool (`offMain`), each save held a thread until
    /// its file was let go, and with more held than there are threads nothing
    /// woke until the breaker let them go.
    @Test(.timeLimit(.minutes(2)))
    func savesWaitingOnHeldFilesHoldNoThreadOfThePool() async throws {
        try await whileHeld(typing: true, { editor in await editor.save() }, then: { editor in
            let url = try #require(editor.note?.fileURL)
            #expect(try String(contentsOf: url, encoding: .utf8).hasSuffix("Typed while it was held.\n"),
                    "the save did not write once the file was let go")
            #expect(!editor.isDirty)
        })
    }

    /// **Looks at the disk waiting on held files hold no thread of the pool**
    /// — the editor's, when the folder says a note changed
    /// (`EditorModel.reconcileWithDisk`), which reads the file to compare.
    @Test(.timeLimit(.minutes(2)))
    func looksAtHeldFilesHoldNoThreadOfThePool() async throws {
        try await whileHeld(typing: false, { editor in await editor.reconcileWithDisk() }, then: { editor in
            #expect(!editor.hasConflict, "an unchanged note was taken for a change")
        })
    }

    /// **A save never waits behind another file's hold.** The other file is on
    /// the app's lane this note's path falls on, held, with a read waiting on
    /// it — and the save goes, on the editor's own lane. On the app's lanes it
    /// queued behind the other file for as long as that file's provider held
    /// it, and at quit, past the five seconds a flush is given, it was lost
    /// (implemented.md §51.63).
    @Test(.timeLimit(.minutes(1)))
    func aSaveNeverWaitsBehindAnotherFilesHold() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (mine, other) = try twoFilesOnOneLane(in: folder, lanes: FileIO.ProviderCalls.live)
        let editor = EditorModel()
        await editor.open(Note(title: "Mine", fileURL: mine, lastModified: Date(), fileSize: 8))
        try #require(editor.isLoaded)

        let hold = ProviderHold(other, breaker: .seconds(50))
        defer { hold.release() }
        let reading = Task { await FileIO.onLane(for: other) { try? FileIO.readString(at: other) } }
        try await waitUntilBusy(FileIO.ProviderCalls.live.lane(for: other))

        editor.text += "Typed beside a held file.\n"
        try await finishes("the save waited behind another file's hold") { await editor.save() }
        #expect(!hold.isLetGo, "the save went only once the other file was let go")
        hold.release()
        _ = await reading.value
        #expect(try String(contentsOf: mine, encoding: .utf8).hasSuffix("Typed beside a held file.\n"))
    }

    /// **A scan waiting on a held file holds up no one-file operation** — a
    /// rename, an append, an open — of another file on the lane it would
    /// share. The scans ask on lanes of their own; on one set for everything,
    /// one file in sixteen waited behind whatever a background scan was
    /// waiting on (implemented.md §51.63).
    @Test(.timeLimit(.minutes(1)))
    func aScanWaitingOnAHeldFileHoldsUpNoOneFileOperation() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // On the same lane in either set: the two are the same size and hash
        // the same way.
        let (mine, other) = try twoFilesOnOneLane(in: folder, lanes: FileIO.ProviderCalls.live)

        let hold = ProviderHold(other, breaker: .seconds(50))
        defer { hold.release() }
        let scanning = Task { await FileIO.onScanLane(for: other) { try? FileIO.readString(at: other) } }
        try await waitUntilBusy(FileIO.ProviderCalls.scans.lane(for: other))

        try await finishes("a one-file read waited behind a scan of another file") {
            _ = await FileIO.onLane(for: mine) { try? FileIO.readString(at: mine) }
        }
        #expect(!hold.isLetGo, "the read went only once the scan's file was let go")
        hold.release()
        _ = await scanning.value
    }

    // MARK: - Through FileIO (implemented.md §51.64)

    /// **A note is trashed under coordination**: held by its provider, it is
    /// not taken away until the provider lets go. `Trash.item` was called bare,
    /// on the pool, and moved a file its provider was still writing.
    @Test(.timeLimit(.minutes(1)))
    func aNoteIsTrashedOnlyOnceItsProviderLetsGo() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Going.md")
        try Data("# Going\n".utf8).write(to: url)
        let collection = Collection(rootURL: folder)
        await collection.scanOffMain()
        let note = try #require(collection.notes.first { $0.title == "Going" })

        let hold = ProviderHold(url, breaker: .seconds(50))
        defer { hold.release() }
        let deleting = Task { await collection.deleteNote(note) }
        try await waitUntilBusy(FileIO.ProviderCalls.live.lane(for: url))
        #expect(FileManager.default.fileExists(atPath: url.path), "the note was taken away while its provider held it")

        hold.release()
        await deleting.value
        #expect(!FileManager.default.fileExists(atPath: url.path), "the note was not trashed once it was let go")
    }

    /// **A folder is made under coordination**: at a path something holds, it
    /// is not made until the hold lets go. `FileManager.createDirectory` made
    /// it at once, behind the presenters' backs.
    @Test(.timeLimit(.minutes(1)))
    func aFolderIsMadeOnlyOnceItsPathIsLetGo() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let collection = Collection(rootURL: folder)
        await collection.scanOffMain()
        // The name the folder will be given, held before it exists.
        let expected = folder.appending(path: "Projects", directoryHint: .isDirectory)

        let hold = ProviderHold(expected, breaker: .seconds(50))
        defer { hold.release() }
        let making = Task { await collection.createFolder(named: "Projects") }
        try await waitUntilBusy(FileIO.ProviderCalls.live.lane(for: folder))
        #expect(!FileManager.default.fileExists(atPath: expected.path), "the folder was made at a path something held")

        hold.release()
        let made = await making.value
        #expect(made?.lastPathComponent == "Projects")
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: expected.path, isDirectory: &isFolder) && isFolder.boolValue)
    }

    /// **A PDF is read under coordination, off the main actor**: held by its
    /// provider, it is not shown until the provider lets go — and the main
    /// actor goes on meanwhile, which this test, running on it, is. It was
    /// `PDFDocument(url:)`, raw and on the main thread.
    @Test(.timeLimit(.minutes(1)))
    func aPDFIsShownOnlyOnceItsProviderLetsGo() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Paper.pdf")
        try Self.onePagePDF().write(to: url)

        let hold = ProviderHold(url, breaker: .seconds(50))
        defer { hold.release() }
        let view = FilePDFView()
        view.show(url)
        try await waitUntilBusy(FilePDFView.calls.lane(for: url))
        #expect(view.document == nil, "the PDF was read while its provider held it")

        hold.release()
        var patience = Waits.Patience(.seconds(10))
        while view.document == nil, patience.lasts { try await Task.sleep(for: .milliseconds(10)) }
        #expect(view.document?.pageCount == 1, "the PDF was not shown once it was let go")
    }

    /// **An embedded picture is read under coordination**: held by its
    /// provider, it is not drawn until the provider lets go. It was read raw
    /// (`NSImage(contentsOf:)`), on the render adapter's thread of the pool.
    @Test(.timeLimit(.minutes(1)))
    func anEmbeddedPictureIsDrawnOnlyOnceItsProviderLetsGo() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Picture.png")
        try #require(Data(base64Encoded: Self.onePixelPNG)).write(to: url)
        let adapter = BlockRenderAdapter(resolve: { _ in url })

        let hold = ProviderHold(url, breaker: .seconds(50))
        defer { hold.release() }
        let drawn = Counter()
        let drawing = Task {
            let image = await adapter.render(.image(target: "Picture.png"), maxWidth: 200, darkMode: false)
            if image != nil { drawn.add() }
            return image != nil
        }
        try await waitUntilBusy(FileIO.ProviderCalls.scans.lane(for: url))
        #expect(drawn.value == 0, "the picture was read while its provider held it")

        hold.release()
        #expect(await drawing.value, "the picture was not drawn once it was let go")
    }

    /// **A PDF that cannot be opened says so.** Bytes that are not a PDF, or
    /// a read that failed, left an empty view — what a PDF still coming looks
    /// like.
    @Test(.timeLimit(.minutes(1)))
    func aPDFThatCannotBeOpenedSaysSo() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Paper.pdf")
        try Data("Not a PDF at all.".utf8).write(to: url)

        let view = FilePDFView()
        var why: String?
        view.onUnreadable = { why = $0 }
        view.show(url)
        var patience = Waits.Patience(.seconds(10))
        while why == nil, patience.lasts { try await Task.sleep(for: .milliseconds(10)) }
        #expect(why?.isEmpty == false, "a file that is not a PDF said nothing")
        #expect(view.document == nil)
    }

    /// **A PDF read for a view that has gone is not made into a document.**
    /// The view is let go of while its read waits on the file; what the read
    /// brings back is dropped, unparsed.
    @Test(.timeLimit(.minutes(1)))
    func aPDFIsNotOpenedForAViewThatHasGone() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Paper.pdf")
        try Self.onePagePDF().write(to: url)

        let hold = ProviderHold(url, breaker: .seconds(50))
        defer { hold.release() }
        let view = FilePDFView()
        view.show(url)
        try await waitUntilBusy(FilePDFView.calls.lane(for: url))
        view.stop()
        hold.release()
        // The lane's next turn comes after the read: a marker that has run
        // says the read is over.
        let after = Counter()
        FilePDFView.calls.lane(for: url).async { after.add() }
        var patience = Waits.Patience(.seconds(10))
        while after.value == 0, patience.lasts { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))    // and its answer back on the main actor
        #expect(after.value == 1, "the read never finished")
        #expect(view.document == nil, "a PDF was opened for a view that had gone")
    }

    /// **One read for a picture, however many draw it at once.** The render
    /// adapter is an actor, and it lets the next caller in while a read
    /// waits: each of three drawings of one picture read it for itself. The
    /// download wait's question is asked once a read (`isMaterialized`), so
    /// it counts them.
    @Test(.timeLimit(.minutes(1)))
    func aPictureIsReadOnceHoweverManyDrawItAtOnce() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Picture.png")
        try #require(Data(base64Encoded: Self.onePixelPNG)).write(to: url)
        let adapter = BlockRenderAdapter(resolve: { _ in url })
        let asked = Counter()
        FileIO.materialisedProbes.withLock { $0[url.path] = { _ in asked.add() } }
        defer { _ = FileIO.materialisedProbes.withLock { $0.removeValue(forKey: url.path) } }

        let hold = ProviderHold(url, breaker: .seconds(50))
        defer { hold.release() }
        let drawings = (0..<3).map { _ in
            Task { await adapter.render(.image(target: "Picture.png"), maxWidth: 200, darkMode: false) != nil }
        }
        try await waitUntilBusy(FileIO.ProviderCalls.scans.lane(for: url))
        hold.release()
        for drawing in drawings { #expect(await drawing.value, "a drawing of the picture came back empty") }
        #expect(asked.value == 1, "one picture was read \(asked.value) times for three drawings of it at once")
    }

    /// **A folder that is there is left alone**, uncoordinated, as
    /// `FileManager` leaves it: a coordinated write on it is a change to it
    /// for every presenter of it — on iOS the collection's own — when nothing
    /// changes. Held, it is not waited for.
    @Test(.timeLimit(.minutes(1)))
    func aFolderThatIsThereIsLeftAlone() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let assets = folder.appending(path: "assets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        let hold = ProviderHold(assets, breaker: .seconds(50))
        defer { hold.release() }
        try await finishes("making a folder that was there waited for its hold: it was written") {
            _ = await FileIO.onLane(for: assets) { try? FileIO.createDirectory(at: assets) }
        }
        #expect(!hold.isLetGo)
    }

    /// **A look at the collection's folder waits for no other file.** It is
    /// taken in the collection's turns, on a lane of the collection's own
    /// (`Collection.onRootLane`): on the scans' lanes it waited behind a scan
    /// held on another file there — and every event after it with it, an
    /// unmount or an edit made elsewhere.
    @Test(.timeLimit(.minutes(1)))
    func aLookAtTheFolderWaitsForNoOtherFile() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let collection = Collection(rootURL: folder)
        await collection.scanOffMain()
        defer { collection.deactivate() }
        // On the scans' lane the folder's own path falls on; not a note, so
        // the walk the look asks for does not read it.
        let other = try aFile(onTheLaneOf: collection.rootURL, in: folder, lanes: FileIO.ProviderCalls.scans)

        let hold = ProviderHold(other, breaker: .seconds(50))
        defer { hold.release() }
        let scanning = Task { await FileIO.onScanLane(for: other) { try? FileIO.readData(at: other) } }
        try await waitUntilBusy(FileIO.ProviderCalls.scans.lane(for: collection.rootURL))

        try await finishes("a look at the folder waited behind a scan of another file") {
            await collection.receive(.rootChanged) {}.value
        }
        #expect(collection.state == .ready)
        #expect(!hold.isLetGo, "the look went only once the other file was let go")
        hold.release()
        _ = await scanning.value
    }

    /// A PDF of one page, drawn here rather than kept as a fixture.
    private static func onePagePDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// A PNG of one pixel.
    private static let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    // MARK: - Helpers

    /// Open an editor on each of more files than the pool has threads, hold
    /// every file, start `step` on each, and see whether a task that sleeps
    /// off the main actor goes on waking while every step waits; then let the
    /// files go, and `check` each editor once its step is done. Each editor
    /// asks on a lane of its own (`EditorModel.provider`), so the test holds
    /// none of the app's.
    private func whileHeld(typing: Bool,
                           _ step: @escaping @MainActor (EditorModel) async -> Void,
                           then check: (EditorModel) throws -> Void) async throws {
        let count = ProcessInfo.processInfo.activeProcessorCount + 2
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var editors: [EditorModel] = []
        for i in 0..<count {
            let body = "# Note \(i)\n"
            let url = folder.appending(path: "Note \(i).md")
            try Data(body.utf8).write(to: url)
            let editor = EditorModel()
            await editor.open(Note(title: "Note \(i)", fileURL: url, lastModified: Date(), fileSize: body.utf8.count))
            try #require(editor.isLoaded && editor.text == body, "note \(i) did not open")
            if typing { editor.text += "Typed while it was held.\n" }
            editors.append(editor)
        }

        // Held, with a breaker the stopped process cannot hold up.
        let holds = try editors.map { ProviderHold(try #require($0.note?.fileURL), breaker: .seconds(60)) }
        defer { holds.forEach { $0.release() } }
        let steps = editors.map { editor in Task { @MainActor in await step(editor) } }

        // A task that sleeps, off the main actor: every wake-up goes through the pool.
        let ticks = Counter()
        let ticker = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                ticks.add()
            }
        }
        defer { ticker.cancel() }
        let from = ticks.value
        var patience = Waits.Patience(.seconds(30))
        while ticks.value < from + 20, patience.lasts { try await Task.sleep(for: .milliseconds(10)) }

        let woke = ticks.value - from
        let stillHeld = holds.filter { !$0.isLetGo }.count
        #expect(woke >= 20 && stillHeld == count,
                "the process stopped while \(count) files were held: \(woke) wake-ups, \(stillHeld) files still held")
        // The premise, while the files are still held — after a stop the
        // breaker has let them go: every step is on its file's lane, waiting.
        // A marker put on each lane after it cannot run until the file is let
        // go; a step that never reached its lane lets its marker run, and
        // would pass this test whatever held the pool.
        if stillHeld == count {
            let markers = Counter()
            for editor in editors {
                guard let url = editor.note?.fileURL else { continue }
                editor.provider.lane(for: url).async { markers.add() }
            }
            var grace = Waits.Patience(.milliseconds(300))
            while markers.value == 0, grace.lasts { try await Task.sleep(for: .milliseconds(10)) }
            #expect(markers.value == 0, "the premise: \(markers.value) of \(count) steps were not waiting on their files")
        }

        holds.forEach { $0.release() }
        for step in steps { await step.value }
        for editor in editors { try check(editor) }
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "hn-held-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Two notes whose paths fall on one lane of `lanes` — the second found by
    /// trying names, since a path's hash is the process's own.
    private func twoFilesOnOneLane(in folder: URL, lanes: FileIO.ProviderCalls) throws -> (URL, URL) {
        let mine = folder.appending(path: "Mine.md")
        try Data("# Mine\n".utf8).write(to: mine)
        for i in 0..<1_000 {
            let other = folder.appending(path: "Other \(i).md")
            guard lanes.lane(for: other) === lanes.lane(for: mine) else { continue }
            try Data("# Other\n".utf8).write(to: other)
            return (mine, other)
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// A file in `folder` whose path falls on the lane of `lanes` that
    /// `target`'s does — found by trying names, since a path's hash is the
    /// process's own.
    private func aFile(onTheLaneOf target: URL, in folder: URL, lanes: FileIO.ProviderCalls) throws -> URL {
        for i in 0..<1_000 {
            let file = folder.appending(path: "Held \(i).bin")
            guard lanes.lane(for: file) === lanes.lane(for: target) else { continue }
            try Data([0]).write(to: file)
            return file
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// Wait until `lane` is busy — a marker put on it does not run for a
    /// look of 150 ms — which a body waiting on a held file makes it, and a
    /// moment's other work on the lane does not: a shorter look let a scan of
    /// another test's file stand in for the wait, and a test pass whatever
    /// its step did.
    private func waitUntilBusy(_ lane: DispatchQueue, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        var patience = Waits.Patience(.seconds(10), every: .milliseconds(150))
        while patience.lasts {
            let ran = Counter()
            lane.async { ran.add() }
            try await Task.sleep(for: .milliseconds(150))
            if ran.value == 0 { return }
        }
        Issue.record("the lane never waited on the held file, so this tests nothing", sourceLocation: sourceLocation)
    }

    /// Run `step` and wait for it with the test's patience, counted in looks.
    private func finishes(_ why: Comment, _ step: @escaping @MainActor () async -> Void,
                          sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let done = Counter()
        Task { @MainActor in
            await step()
            done.add()
        }
        var patience = Waits.Patience(.seconds(10))
        while done.value == 0, patience.lasts { try await Task.sleep(for: .milliseconds(10)) }
        #expect(done.value == 1, why, sourceLocation: sourceLocation)
    }

    /// A count kept across tasks and lanes — a `Mutex` is not copyable, so a
    /// closure cannot capture one itself.
    private final class Counter: Sendable {
        private let count = Mutex(0)
        func add() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }
}
