//
//  AttachmentBytes.swift
//  HelloNotes
//
//  Getting an attachment's bytes onto this device, and what the viewer says
//  while it does — apart from `FileViewerView`, so a test can watch it.
//

import Foundation
import Observation

@Observable
final class AttachmentBytes {
    /// What the viewer shows.
    enum State: Equatable {
        /// Not known yet — nothing is drawn for the moment it takes to ask.
        case checking
        case downloading
        case here
        /// Not here, and why — said, rather than a blank preview.
        case missing(String)
    }

    private(set) var state: State = .checking
    /// Bumped when the bytes have changed under the viewer: PDFKit and Quick
    /// Look cache by URL, and the URL is exactly what does not change.
    private(set) var revision = 0

    /// How long to wait for a download before saying it has not come.
    @ObservationIgnored var patience: Duration = .seconds(60)
    /// The file provider's calls — a test's stand-in, or the real ones.
    @ObservationIgnored var provider: FileIO.ProviderCalls = .live

    /// A wait still out after a newer one began says nothing over it.
    @ObservationIgnored private var attempt = 0
    /// How long the first answer may take before "Downloading" is said: a
    /// file that is here answers sooner, and saying it of one would be a lie.
    static let quiet: Duration = .milliseconds(250)

    /// Get the bytes of the file at `url` here, saying what is happening.
    ///
    /// **One decision for both kinds of collection.** It was two: the shell's
    /// `prepare` if there was one, and otherwise a wait for iCloud. The shell
    /// always passes `prepare` — the cloud collection's fetch, a no-op for a
    /// Files folder — so the wait was never reached: an image or a PDF in an
    /// iCloud Drive folder that the system held online-only was never asked
    /// for, and its empty stand-in was previewed, blank, for good. And a cloud
    /// collection's stand-in that could not be fetched was previewed the same
    /// way (implemented.md §51.52). Now a cloud collection's stand-in is
    /// fetched by its collection, anything else is waited for as the system
    /// holds it, and either way the wait has an end and says how it ended.
    func fetch(_ url: URL, isPlaceholder: (@MainActor (URL) -> Bool)?,
               prepare: (@MainActor (URL) async -> Void)?) async {
        attempt &+= 1
        let mine = attempt
        state = .checking

        // A cloud collection's stand-in: its collection fetches it, for no
        // longer than a download is waited for.
        if isPlaceholder?(url) == true {
            state = .downloading
            let finished = await finishes(within: patience) { await prepare?(url) }
            guard !Task.isCancelled, attempt == mine else { return }
            if isPlaceholder?(url) == true {
                state = .missing(finished ? "It couldn’t be downloaded from the cloud."
                                          : "It is still on its way from the cloud.")
            } else {
                revision &+= 1
                state = .here
            }
            return
        }

        // Anything else may be a file the system holds in the cloud — an
        // iCloud Drive folder's, or another provider's in Files. Its newest
        // version: a preview is not refreshed when a newer one lands.
        let saying = Task { [weak self] in
            try? await Task.sleep(for: Self.quiet)
            guard !Task.isCancelled, let self, self.attempt == mine, self.state == .checking else { return }
            self.state = .downloading
        }
        let wait = await FileIO.waitForDownload(at: url, timeout: patience, needing: .latest, using: provider)
        saying.cancel()
        guard !Task.isCancelled, attempt == mine else { return }
        switch wait {
        case .arrived:
            revision &+= 1
            state = .here
        case .notYet:
            state = .missing("It hasn’t finished downloading from the cloud.")
        case .noAnswer:
            state = .missing("Its cloud provider didn’t answer when asked for it.")
        }
    }
}
