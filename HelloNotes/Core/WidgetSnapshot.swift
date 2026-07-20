//
//  WidgetSnapshot.swift
//  HelloNotes
//
//  The app can't hand the widget its security-scoped vault access, so it writes
//  a small JSON snapshot of recent-note metadata into the shared App Group
//  container; the widget reads that and deep-links back via `hellonotes://`.
//  The mirror of this model lives in `HelloNotesWidgets/WidgetShared.swift`
//  (synchronized folder targets can't share one file) — keep them in sync.
//

import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

enum AppGroup {
    static let id = "group.com.hellotham.HelloNotes"
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }
    static var snapshotURL: URL? { containerURL?.appendingPathComponent("widget-snapshot.json") }
}

struct WidgetSnapshot: Codable {
    struct Item: Codable {
        let title: String
        let collectionName: String
        let relativePath: String
        let modified: Date

        var deepLink: String {
            var comps = URLComponents()
            comps.scheme = "hellonotes"
            comps.host = "note"
            comps.queryItems = [
                URLQueryItem(name: "collection", value: collectionName),
                URLQueryItem(name: "path", value: relativePath),
            ]
            return comps.url?.absoluteString ?? "hellonotes://daily"
        }
    }
    var recents: [Item]
    var focusedCollection: String?
    var generatedAt: Date
}

extension Library {
    /// Publish a fresh recent-notes snapshot to the App Group + reload widgets.
    /// Cheap (metadata only) and debounced by the caller (`allNotes` change).
    func writeWidgetSnapshot() {
        let items = collections
            .flatMap { coll in coll.notes.map { (coll, $0) } }
            .sorted { $0.1.lastModified > $1.1.lastModified }
            .prefix(8)
            .map { WidgetSnapshot.Item(title: $0.1.title,
                                       collectionName: $0.0.rootURL.lastPathComponent,
                                       relativePath: $0.0.relativePath(of: $0.1),
                                       modified: $0.1.lastModified) }
        let snapshot = WidgetSnapshot(recents: Array(items),
                                      focusedCollection: focused?.rootURL.lastPathComponent,
                                      generatedAt: Date())
        guard let url = AppGroup.snapshotURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        // Write off the main actor. A synchronous file write can block when the
        // target volume stalls (a wedged container, a slow network mount) — on
        // the main thread that would hang the whole UI. Encoding above is cheap
        // main-actor metadata; only the blocking write moves off.
        Task.detached(priority: .utility) {
            try? data.write(to: url, options: .atomic)
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        }
    }
}
