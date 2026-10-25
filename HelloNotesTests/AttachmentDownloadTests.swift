//
//  AttachmentDownloadTests.swift
//  HelloNotesTests
//
//  An attachment that is not on this device yet — an image or a PDF in an
//  iCloud Drive folder the system holds online-only, or a cloud collection's
//  stand-in — is fetched, said to be downloading while it comes, and said not
//  to have come when it does not. Never a blank preview, and never a spinner
//  with no end (docs/implemented.md §51.52). Control: the decision as it was,
//  ported verbatim and run under these, failed four expectations — the file
//  never asked for and never said to be downloading, a silent provider and
//  an unfetched stand-in both "shown".
//
//  Driven as the shell wires the viewer (`ContentView`): `isPlaceholder` says
//  whether a *cloud collection* holds a stand-in, and is false for anything
//  else, and `prepare` is the collection's fetch, a no-op for anything else.
//

import Foundation
import Testing
@testable import HelloNotes

@Suite @MainActor
struct AttachmentDownloadTests {

    private let url = URL(fileURLWithPath: "/tmp/attachment-download-tests/Slides.pdf")

    /// Every state the model passes through until `done`, looked at every 10ms.
    private func watch(_ bytes: AttachmentBytes, until done: (AttachmentBytes.State) -> Bool) async -> [AttachmentBytes.State] {
        var seen: [AttachmentBytes.State] = [bytes.state]
        var patience = Waits.Patience(.seconds(20))
        while !done(bytes.state), patience.lasts {
            try? await Task.sleep(for: .milliseconds(10))
            if bytes.state != seen.last { seen.append(bytes.state) }
        }
        return seen
    }

    private func isMissing(_ state: AttachmentBytes.State) -> Bool {
        if case .missing = state { return true }
        return false
    }

    /// **An attachment in an iCloud Drive folder that is not on this device is
    /// asked for, and shown when it comes.** The viewer called the shell's
    /// `prepare` — the cloud collection's fetch, a no-op for a Files folder —
    /// and returned: the wait for iCloud below it was never reached, so the
    /// file was never asked for and its empty stand-in was previewed, blank.
    @Test func anAttachmentNotOnThisDeviceIsAskedForAndShownWhenItComes() async throws {
        let provider = StandInProvider(here: false)
        let bytes = AttachmentBytes()
        bytes.provider = provider.calls
        bytes.patience = .seconds(30)
        let fetching = Task { await bytes.fetch(url, isPlaceholder: { _ in false }, prepare: { _ in }) }
        // Said while it is not here — which it is not until the test says.
        _ = await watch(bytes) { $0 == .downloading || $0 == .here || isMissing($0) }
        #expect(bytes.state == .downloading, "nothing said it was downloading: \(bytes.state)")
        #expect(provider.askCount > 0, "the attachment was never asked for")
        provider.arrive()
        _ = await watch(bytes) { $0 == .here || isMissing($0) }
        await fetching.value

        #expect(bytes.state == .here, "it ended \(bytes.state)")
        #expect(provider.mainThreadCalls == 0, "the file provider was asked on the main thread")
    }

    /// **And the wait ends, whatever the provider does** — with the reason,
    /// not a blank page, and never on the main thread.
    @Test func anAttachmentNothingAnswersForEndsInAMessage() async throws {
        let provider = StandInProvider(silent: true)
        defer { provider.release() }
        let bytes = AttachmentBytes()
        bytes.provider = provider.calls
        bytes.patience = .seconds(1)
        let fetching = Task { await bytes.fetch(url, isPlaceholder: { _ in false }, prepare: { _ in }) }
        let seen = await watch(bytes) { $0 == .here || isMissing($0) }
        await fetching.value

        guard case .missing(let why) = bytes.state else {
            Issue.record("it ended \(bytes.state), having been \(seen)")
            return
        }
        #expect(why.contains("didn’t answer"), "it said: \(why)")
        #expect(provider.mainThreadCalls == 0, "the file provider was asked on the main thread")
    }

    /// A file that is here is shown without a word about downloading: the
    /// first answer comes before anything is said.
    @Test func anAttachmentThatIsHereShowsWithoutSayingItDownloads() async throws {
        let provider = StandInProvider(here: true)
        let bytes = AttachmentBytes()
        bytes.provider = provider.calls
        let fetching = Task { await bytes.fetch(url, isPlaceholder: { _ in false }, prepare: { _ in }) }
        let seen = await watch(bytes) { $0 == .here || isMissing($0) }
        await fetching.value

        #expect(bytes.state == .here)
        #expect(!seen.contains(.downloading), "a file that was here was said to be downloading: \(seen)")
        #expect(provider.askCount == 0, "a file that was here was asked for")
    }

    /// A cloud collection's stand-in is fetched by its collection, and shown.
    @Test func aCloudCollectionsStandInIsFetchedAndShown() async throws {
        let provider = StandInProvider(here: true)
        let bytes = AttachmentBytes()
        bytes.provider = provider.calls
        var fetched = false
        let before = bytes.revision
        let fetching = Task {
            await bytes.fetch(url, isPlaceholder: { _ in !fetched }, prepare: { _ in fetched = true })
        }
        _ = await watch(bytes) { $0 == .here || isMissing($0) }
        await fetching.value

        #expect(fetched && bytes.state == .here)
        #expect(bytes.revision != before, "the viewer was not told its bytes had changed")
    }

    /// **And one its collection could not fetch says so**: the stand-in is an
    /// empty file, and previewed it is a blank page.
    @Test func aCloudCollectionsStandInThatCouldNotBeFetchedSaysSo() async throws {
        let provider = StandInProvider(here: true)
        let bytes = AttachmentBytes()
        bytes.provider = provider.calls
        let fetching = Task { await bytes.fetch(url, isPlaceholder: { _ in true }, prepare: { _ in }) }
        _ = await watch(bytes) { $0 == .here || isMissing($0) }
        await fetching.value

        guard case .missing(let why) = bytes.state else {
            Issue.record("a stand-in that was never fetched ended \(bytes.state)")
            return
        }
        #expect(why.contains("couldn’t be downloaded"), "it said: \(why)")
    }

    /// The selection moves on mid-download: the wait that was cancelled says
    /// nothing over the file shown now.
    @Test func aWaitLeftBehindSaysNothingOverTheNextFile() async throws {
        let slow = StandInProvider(silent: true)
        defer { slow.release() }
        let bytes = AttachmentBytes()
        bytes.provider = slow.calls
        bytes.patience = .seconds(1)
        let first = Task { await bytes.fetch(url, isPlaceholder: { _ in false }, prepare: { _ in }) }
        try await Task.sleep(for: .milliseconds(300))
        first.cancel()
        // Its question let go, or the next file — on its lane one time in
        // sixteen, the provider being the same — would wait behind it.
        slow.release()

        let next = StandInProvider(here: true)
        bytes.provider = next.calls
        let second = Task {
            await bytes.fetch(url.deletingLastPathComponent().appending(path: "Photo.png"),
                              isPlaceholder: { _ in false }, prepare: { _ in })
        }
        await second.value
        await first.value
        // Past the first wait's deadline, and its timer's.
        try await Task.sleep(for: .milliseconds(2_500))
        #expect(bytes.state == .here, "the wait left behind said \(bytes.state) over the file shown now")
    }
}
