//
//  ContainerMoves.swift
//  HelloNotes
//
//  What the app keeps for a collection in its own folders, kept through a
//  move of the app's container.
//
//  An iOS app's data container is a folder named by a UUID, and it moves:
//  on the simulator at every install, measured; on a device perhaps at an
//  update, which nothing here has measured (implemented.md §51.70). The
//  stores the app keeps per collection — the Assistant's conversation, the
//  links declined, a walk's resume point, the index cache — were each named
//  from the collection's absolute path, so for a collection inside the
//  container a move left what they kept under a name nothing asked for: the
//  conversation was gone, and the declined links came back.
//
//  Each is named now from the path's `ContainerPath.stableName`, which no
//  move changes, and the first time one is asked for, what was kept under a
//  name the path had before is moved to it (`place(for:in:names:named:)`):
//  its name under the container as it is today — a device whose container
//  did not move — or as the container was called before, learnt at launch
//  from the paths the last run kept (`learn(from:now:in:)`).
//

import CryptoKit
import Foundation

/// The container's name today, and the names it had before that the app has
/// learnt (`ContainerMoves.learn`).
nonisolated struct ContainerNames: Equatable, Sendable {
    var home: String
    var earlier: [String]

    init(home: String = NSHomeDirectory(), earlier: [String] = []) {
        self.home = home
        self.earlier = earlier
    }

    /// The app's own: its home, and the earlier names it has learnt.
    static var now: ContainerNames {
        ContainerNames(earlier: ContainerMoves.earlierHomes())
    }
}

nonisolated enum ContainerMoves {

    /// The place `named(stableName)` in `folder` — a file, or a folder if
    /// `isDirectory` — for what is kept for `path`. If nothing is there yet,
    /// what was kept under one of the path's former names
    /// (`ContainerPath.formerNames`) is moved there first. Nothing is moved
    /// over something already there, and nothing is copied: a store has one
    /// place, and a moved one is where it was, renamed.
    static func place(for path: String, in folder: URL, isDirectory: Bool = false,
                      names: ContainerNames = .now, named: (String) -> String) -> URL {
        let place = folder.appending(path: named(ContainerPath.stableName(of: path, home: names.home)),
                                     directoryHint: isDirectory ? .isDirectory : .notDirectory)
        let files = FileManager.default
        guard !files.fileExists(atPath: place.path) else { return place }
        for former in ContainerPath.formerNames(of: path, home: names.home, earlierHomes: names.earlier) {
            let kept = folder.appending(path: named(former),
                                        directoryHint: isDirectory ? .isDirectory : .notDirectory)
            guard kept.path != place.path, files.fileExists(atPath: kept.path) else { continue }
            try? files.createDirectory(at: folder, withIntermediateDirectories: true)
            if (try? files.moveItem(at: kept, to: place)) != nil {
                MainActorWatchdog.note("\(folder.lastPathComponent): \(kept.lastPathComponent), kept under a former name, moved to \(place.lastPathComponent)")
                break
            }
        }
        return place
    }

    /// The preferences key a setting kept per collection is stored under:
    /// `prefix` and the path's stable name. Text only.
    static func key(_ prefix: String, for path: String, home: String = NSHomeDirectory()) -> String {
        prefix + ContainerPath.stableName(of: path, home: home)
    }

    /// `key(prefix, for: path)`, with a value kept under one of the path's
    /// former names — to 1.3.5 every such key held the absolute path — moved
    /// to it first if nothing is under it yet. Two settings were left behind
    /// by a move of the container that way: the notes a collection had
    /// pinned, and whether it shows files that are not notes (implemented.md
    /// §51.72). A capture session moves nothing of the person's.
    @MainActor @discardableResult
    static func adoptKey(_ prefix: String, for path: String, in defaults: UserDefaults = .standard,
                         names: ContainerNames = .now) -> String {
        let key = key(prefix, for: path, home: names.home)
        guard !CaptureSession.isActive, defaults.object(forKey: key) == nil else { return key }
        for former in ContainerPath.formerNames(of: path, home: names.home, earlierHomes: names.earlier) {
            let kept = prefix + former
            guard kept != key, let value = defaults.object(forKey: kept) else { continue }
            defaults.set(value, forKey: key)
            defaults.removeObject(forKey: kept)
            break
        }
        return key
    }

    /// The first eight bytes of `name`'s SHA-256, in hex: the name the stores
    /// give a path (`ChatSessionStore`, `DeclinedLinkStore`,
    /// `CollectionIndexCache`) — a path makes a terrible file name.
    static func digest(_ name: String) -> String {
        SHA256.hash(data: Data(name.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The container's earlier names

    static let earlierHomesKey = "earlierContainerHomes"

    /// Enough for every move a device sees between two launches, and then
    /// some: a name is only needed for what was kept before this build.
    static let earlierHomesLimit = 8

    /// The names the container had before today's, oldest first.
    static func earlierHomes(in defaults: UserDefaults = .standard) -> [String] {
        (defaults.array(forKey: earlierHomesKey) as? [String]) ?? []
    }

    /// Learn what the container was called from `old`, a path the last run
    /// kept for the folder now at `now` (`ContainerPath.earlierHome`), and
    /// remember it. Only the first launch after a move can: the last paths
    /// are written again with today's name as soon as the folders are found.
    /// A capture session keeps nothing of the person's, this included.
    @MainActor @discardableResult
    static func learn(from old: String, now: String, home: String = NSHomeDirectory(),
                      in defaults: UserDefaults = .standard) -> String? {
        guard !CaptureSession.isActive,
              let earlier = ContainerPath.earlierHome(of: old, now: now, home: home) else { return nil }
        var homes = earlierHomes(in: defaults)
        guard !homes.contains(earlier) else { return earlier }
        homes.append(earlier)
        defaults.set(Array(homes.suffix(earlierHomesLimit)), forKey: earlierHomesKey)
        MainActorWatchdog.note("the container was called \(earlier) — learnt from a path the last run kept")
        return earlier
    }
}
