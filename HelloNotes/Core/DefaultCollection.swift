//
//  DefaultCollection.swift
//  HelloNotes
//

import Foundation

/// The collection that ships with the app.
///
/// HelloNotes had nothing to open on first launch. That is a poor welcome —
/// "choose a folder" is a strange first instruction for someone who has not yet
/// seen what the app does with one — and it also cost an App Store rejection:
/// the reviewer was told a demo collection existed and could not find it,
/// because it lived in the source repository and had never been bundled.
///
/// So it ships, as a folder reference in Resources: a guided tour plus the user
/// manual, written in HelloNotes and demonstrating the features it describes.
///
/// **It is an ordinary collection.** It is copied out of the bundle into
/// Documents on first run and opened; after that it is a folder of files like
/// any other. The user can edit it, and can close it — which is why
/// `seedIfNeeded` restores the files when they are missing but never overwrites
/// files that are there.
enum DefaultCollection {

    static let folderName = "DefaultCollection"

    /// Where the copy lives once it has been seeded.
    static var installedURL: URL {
        URL.documentsDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The read-only original inside the app bundle.
    static var bundledURL: URL? {
        Bundle.main.url(forResource: folderName, withExtension: nil)
    }

    /// Whether the app has ever seeded it. Distinct from "the folder exists":
    /// a user who closes the collection *and* deletes the folder should not have
    /// it silently reappear on the next launch, but **Open Default Collection**
    /// must still be able to bring it back on request.
    private static let seededKey = "defaultCollectionSeeded"

    static var hasSeeded: Bool {
        UserDefaults.standard.bool(forKey: seededKey)
    }

    /// Copy the bundled collection into Documents if it is not already there.
    ///
    /// Never overwrites: a returning user's edits to these notes are their
    /// notes. Copies file by file so a partially deleted collection is
    /// completed rather than skipped.
    @discardableResult
    static func seedIfNeeded() -> URL? {
        guard let source = bundledURL else { return nil }
        let destination = installedURL
        let fm = FileManager.default

        do {
            if !fm.fileExists(atPath: destination.path) {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            }
            let items = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey])
            while let item = items?.nextObject() as? URL {
                let relative = item.path.replacingOccurrences(of: source.path + "/", with: "")
                let target = destination.appendingPathComponent(relative)
                let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory {
                    if !fm.fileExists(atPath: target.path) {
                        try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    }
                } else if !fm.fileExists(atPath: target.path) {
                    try fm.createDirectory(at: target.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    try fm.copyItem(at: item, to: target)
                }
            }
            UserDefaults.standard.set(true, forKey: seededKey)
            return destination
        } catch {
            return nil
        }
    }
}
