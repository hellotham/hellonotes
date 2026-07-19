//
//  URLRouter.swift
//  HelloNotes
//
//  Parses `hellonotes://` deep links. The scheme is registered in Info.plist;
//  Spotlight donations, App Intents, widgets, and the Services menu all
//  deep-link back into the app through here.
//
//  Grammar:
//    hellonotes://note?collection=<name-or-path>&path=<relative>
//    hellonotes://note?collection=<name-or-path>&title=<title>
//    hellonotes://collection?name=<name-or-path>
//    hellonotes://search?q=<query>
//    hellonotes://new?collection=<name>&title=<title>
//    hellonotes://daily
//

import Foundation

enum URLRouter {
    static let scheme = "hellonotes"

    enum Destination: Equatable {
        case note(collection: String, ref: NoteRef)
        case collection(String)
        case search(String)
        case newNote(collection: String?, title: String?)
        case dailyNote
    }

    enum NoteRef: Equatable {
        case path(String)     // collection-relative path
        case title(String)    // note title (resolved case-insensitively)
    }

    /// Parse a `hellonotes://` URL into a `Destination`, or nil if it isn't one.
    static func destination(for url: URL) -> Destination? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let host = (url.host ?? "").lowercased()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.removingPercentEncoding
                ?? items.first { $0.name == name }?.value
        }
        switch host {
        case "note":
            guard let collection = value("collection") else { return nil }
            if let path = value("path") { return .note(collection: collection, ref: .path(path)) }
            if let title = value("title") { return .note(collection: collection, ref: .title(title)) }
            return nil
        case "collection":
            guard let name = value("name") ?? value("path") else { return nil }
            return .collection(name)
        case "search":
            guard let query = value("q") ?? value("query") else { return nil }
            return .search(query)
        case "new", "newnote":
            return .newNote(collection: value("collection"), title: value("title"))
        case "daily", "dailynote":
            return .dailyNote
        default:
            return nil
        }
    }

    /// Build a deep link to a note (used by Spotlight donation / widgets / intents).
    static func link(toNote note: Note, in collection: Collection) -> URL {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = "note"
        comps.queryItems = [
            URLQueryItem(name: "collection", value: collection.rootURL.lastPathComponent),
            URLQueryItem(name: "path", value: collection.relativePath(of: note)),
        ]
        return comps.url ?? URL(string: "\(scheme)://daily")!
    }
}
