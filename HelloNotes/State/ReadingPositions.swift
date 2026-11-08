//
//  ReadingPositions.swift
//  HelloNotes
//
//  Where the reader was in each note, kept between launches.
//
//  The editor keeps a note's place while the app runs — the character at the
//  top of the view, in the note's document (`EditorDocument.readingPosition`)
//  — and an iPhone ends a suspended app whenever it likes, so a note opened
//  after a return to the app opened at its top, every time (the person,
//  2026-11-07: "The iOS version doesn't seem to remember position in document
//  in between use"). The place is kept here as a note is left and as the app
//  leaves the foreground, and given to the note's document when it is next
//  built (`EditorHost`; implemented.md §51.69).
//
//  Two kinds of place, kept apart: a character of the note, where Edit and
//  Markdown stand — and points down Preview's page, which has no characters
//  to stand on and is what an iPhone opens a note in.
//
//  By the note's path, spelled one way: an iPhone's folders have two names
//  (`/var/…` and `/private/var/…`), and a note reached by either is one note;
//  and inside the app's own container, named from the container, which moves
//  when the app is installed again (`ContainerPath`).
//  The 500 most recently left are kept; a note left at its top has no entry.
//  Read entry by entry, leniently, as anything kept in UserDefaults is.
//

import Foundation

enum ReadingPositions {
    /// What a place is counted in, and the key it is kept under.
    enum Kind: String {
        /// A character of the note — Edit and Markdown.
        case character = "readingPositions"
        /// Points down Preview's page.
        case previewOffset = "previewReadingOffsets"
    }

    static let key = Kind.character.rawValue
    static let limit = 500

    /// Where places are kept: the app's own defaults — and in a test host a
    /// store of the run's own, in the host's temporary folder. The hosted
    /// suite opens notes in editors as the app does, and an editor keeps its
    /// place as it is left: every run wrote the places of the tests' notes
    /// into the person's preferences, 32 of them before it was seen
    /// (implemented.md §51.72). Named by a path, so its plist is kept there
    /// and never in `Library/Preferences` (`ScratchDefaults`, §51.31); a run's
    /// folder outlives the run, and a later run clears those a day old, as
    /// the test Trash does (`Trash.testBin`).
    static let store: UserDefaults = {
        guard TestEnvironment.isRunningTests else { return .standard }
        let runs = FileManager.default.temporaryDirectory
            .appending(path: "HelloNotes Test Defaults", directoryHint: .isDirectory)
        let fm = FileManager.default
        let dayAgo = Date().addingTimeInterval(-86_400)
        for folder in (try? fm.contentsOfDirectory(at: runs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let changed = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (changed ?? .distantPast) < dayAgo { try? fm.removeItem(at: folder) }
        }
        let run = runs.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? fm.createDirectory(at: run, withIntermediateDirectories: true)
        return UserDefaults(suiteName: run.appending(path: "ReadingPositions").path) ?? .standard
    }()

    /// Where the reader was in `note`, or nil for its top — and nil in a
    /// capture session, which shows the notes as they ship, never at the
    /// person's own places (§51.72).
    static func position(of note: URL, kind: Kind = .character, home: String = NSHomeDirectory(),
                         in defaults: UserDefaults = store) -> Int? {
        guard !CaptureSession.isActive else { return nil }
        let name = name(of: note, home: home)
        return entries(kind, in: defaults).last { $0.note == name }?.position
    }

    /// The places kept for `old` — a note, or every note inside a folder —
    /// kept for `new` instead. Kept by the note's path, a note renamed or
    /// moved, or the folder it is in, opened at its top (implemented.md
    /// §51.72). A place already kept under the new name gives way.
    static func moved(from old: URL, to new: URL, home: String = NSHomeDirectory(),
                      in defaults: UserDefaults = store) {
        guard !CaptureSession.isActive else { return }
        let from = name(of: old, home: home), to = name(of: new, home: home)
        guard from != to else { return }
        for kind in [Kind.character, .previewOffset] {
            var changed = false
            let renamed = entries(kind, in: defaults).map { entry -> (note: String, position: Int) in
                if entry.note == from { changed = true; return (to, entry.position) }
                guard entry.note.hasPrefix(from + "/") else { return entry }
                changed = true
                return (to + entry.note.dropFirst(from.count), entry.position)
            }
            guard changed else { continue }
            var seen = Set<String>()
            let kept = renamed.reversed().filter { seen.insert($0.note).inserted }.reversed()
            defaults.set(kept.map { ["note": $0.note, "at": $0.position] }, forKey: kind.rawValue)
        }
    }

    /// Keep `position` as where the reader was in `note` — nil, or 0, for its
    /// top. Nothing is written for a place that has not moved, and nothing at
    /// all in a capture session, which changes nothing the person keeps.
    static func keep(_ position: Int?, of note: URL, kind: Kind = .character,
                     home: String = NSHomeDirectory(), in defaults: UserDefaults = store) {
        guard !CaptureSession.isActive else { return }
        let name = name(of: note, home: home)
        let position = position.flatMap { $0 > 0 ? $0 : nil }
        var kept = entries(kind, in: defaults)
        guard kept.last(where: { $0.note == name })?.position != position else { return }
        kept.removeAll { $0.note == name }
        if let position { kept.append((name, position)) }
        if kept.count > limit { kept.removeFirst(kept.count - limit) }
        defaults.set(kept.map { ["note": $0.note, "at": $0.position] }, forKey: kind.rawValue)
    }

    /// The note's name: its path, `/private` taken off the folders an iPhone
    /// gives two names, so either name finds the place — and inside the app's
    /// container named from the container, so the place outlives the
    /// container's moving (`ContainerPath`). Text only: asked while a page is
    /// handed to Preview, it must not look at the disk, as
    /// `standardizedFileURL` does for a path spelled `/private/…`.
    nonisolated static func name(of note: URL, home: String = NSHomeDirectory()) -> String {
        ContainerPath.stableName(of: note.path, home: home)
    }

    private static func entries(_ kind: Kind, in defaults: UserDefaults) -> [(note: String, position: Int)] {
        (defaults.array(forKey: kind.rawValue) ?? []).compactMap { entry in
            guard let entry = entry as? [String: Any], let note = entry["note"] as? String,
                  let at = entry["at"] as? Int, at > 0 else { return nil }
            return (note, at)
        }
    }
}
