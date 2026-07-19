//
//  WidgetShared.swift
//  HelloNotesWidgets
//
//  Widget-side mirror of the App Group snapshot model (synchronized folder
//  targets can't share one source file). Must match
//  `HelloNotes/Core/WidgetSnapshot.swift`.
//

import Foundation

enum AppGroup {
    static let id = "group.com.hellotham.HelloNotes"
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }
    static var snapshotURL: URL? { containerURL?.appendingPathComponent("widget-snapshot.json") }
}

struct WidgetSnapshot: Codable {
    struct Item: Codable, Identifiable {
        let title: String
        let collectionName: String
        let relativePath: String
        let modified: Date

        var id: String { "\(collectionName)\u{1}\(relativePath)" }
        var deepLink: URL {
            var comps = URLComponents()
            comps.scheme = "hellonotes"
            comps.host = "note"
            comps.queryItems = [
                URLQueryItem(name: "collection", value: collectionName),
                URLQueryItem(name: "path", value: relativePath),
            ]
            return comps.url ?? URL(string: "hellonotes://daily")!
        }
    }
    var recents: [Item]
    var focusedCollection: String?
    var generatedAt: Date

    static var empty: WidgetSnapshot { WidgetSnapshot(recents: [], focusedCollection: nil, generatedAt: .now) }

    /// Load the app-written snapshot from the shared container.
    static func load() -> WidgetSnapshot {
        guard let url = AppGroup.snapshotURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return .empty }
        return decoded
    }
}
