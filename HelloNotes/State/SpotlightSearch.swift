//
//  SpotlightSearch.swift
//  HelloNotes
//
//  Created by Chris Tham on 17/7/2026.
//
//  Full-text search over *everything* in a collection via the system Spotlight
//  index (`NSMetadataQuery`). macOS already indexes file contents — PDFs,
//  Office documents, even text in images — so this finds matches inside
//  attachments the app never parses itself, at zero indexing cost.
//

#if os(macOS)
import Foundation

@MainActor
final class SpotlightSearch {
    private var activeQuery: NSMetadataQuery?
    private var activeObserver: NSObjectProtocol?
    private var finishActive: (([URL]) -> Void)?

    /// Ask the Spotlight index for files under `roots` whose content or name
    /// matches `text`. Returns every kind of file Spotlight indexed (the caller
    /// filters to what it wants). Resolves with `[]` on timeout or cancellation
    /// — Spotlight is an enrichment, never a blocker.
    func search(_ text: String, in roots: [URL]) async -> [URL] {
        cancel()   // supersede any in-flight query

        let query = NSMetadataQuery()
        query.predicate = NSPredicate(
            format: "(kMDItemTextContent CONTAINS[cd] %@) OR (kMDItemDisplayName CONTAINS[cd] %@)",
            text, text
        )
        query.searchScopes = roots.map(\.path)
        query.operationQueue = .main

        return await withCheckedContinuation { continuation in
            var resumed = false
            let finishOnce: ([URL]) -> Void = { urls in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: urls)
            }
            finishActive = finishOnce
            activeQuery = query

            // Safe despite the Sendable warning suppression: the observer is
            // registered on the main queue and the query is only ever touched
            // inside `MainActor.assumeIsolated`.
            nonisolated(unsafe) let observedQuery = query
            activeObserver = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    observedQuery.disableUpdates()
                    let urls = (0..<observedQuery.resultCount).compactMap { index -> URL? in
                        guard let item = observedQuery.result(at: index) as? NSMetadataItem,
                              let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
                        else { return nil }
                        return URL(fileURLWithPath: path)
                    }
                    self.teardown()
                    finishOnce(urls)
                }
            }

            query.start()

            // A stuck query must never wedge the search pipeline.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.activeQuery === query else { return }
                self.teardown()
                finishOnce([])
            }
        }
    }

    /// Stop any in-flight query, resolving its caller with no results.
    func cancel() {
        finishActive?([])
        finishActive = nil
        teardown()
    }

    private func teardown() {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        activeQuery?.stop()
        activeQuery = nil
    }
}
#endif
