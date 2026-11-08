//
//  ContainerPath.swift
//  HelloNotes
//
//  A name for a path that outlives the app's container.
//
//  An iOS app's data container is a folder named by a UUID, and the folder
//  moves: on the simulator at every install, measured — the sample collection
//  was at `…/Application/ADE7D338…/Documents` and then at
//  `…/Application/2CE3E666…/Documents`, its bookmark following it. Anything
//  kept by a path inside the container was kept under the old name and found
//  by nobody: every note opened at its top, and the collection, its index
//  cache missed, was walked as if it had never been seen (implemented.md
//  §51.69). So a path inside the container is named from the container
//  (`~/Documents/…`), and one outside it keeps its path, `/private` taken off
//  the folders an iPhone gives two names. And the names a path had before
//  (`formerNames`, `earlierHome`), so what was kept under one is found by
//  the stores that kept it (`ContainerMoves`, implemented.md §51.70); and
//  what a path kept under one is called today (`todaysPath`, `placeName`),
//  so Open Recent and a window's last note, folders and place find what they
//  named (§51.71).
//
//  Text only — no look at the disk — so it can be asked while drawing.
//

import Foundation

nonisolated enum ContainerPath {

    /// `path`'s name, the same whatever the container is called today:
    /// `~/…` inside `home` (the app's container on iOS and in the Mac's
    /// sandbox), the path itself outside it.
    static func stableName(of path: String, home: String = NSHomeDirectory()) -> String {
        let path = oneSpelling(path)
        var home = oneSpelling(home)
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        guard home.count > 1 else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// `/private/var/…` as `/var/…`: one folder with two names, and Foundation
    /// hands out either (AGENTS.md, "One directory, two names").
    static func oneSpelling(_ path: String) -> String {
        for twin in ["/private/var/", "/private/tmp/", "/private/etc/"] where path.hasPrefix(twin) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    /// Both of `path`'s names when it has two — `/var/…` and `/private/var/…`
    /// — and otherwise itself.
    static func spellings(of path: String) -> [String] {
        let one = oneSpelling(path)
        for twin in ["/var/", "/tmp/", "/etc/"] where one.hasPrefix(twin) {
            return [one, "/private" + one]
        }
        return [one]
    }

    /// Every absolute name `path` may have been kept under before it had a
    /// stable one: inside the container, its place under the container's name
    /// today and under each of `earlierHomes`; outside it, the path itself —
    /// each in both spellings, since the stores named a path through
    /// `standardizedFileURL`, which gives either (AGENTS.md).
    static func formerNames(of path: String, home: String = NSHomeDirectory(),
                            earlierHomes: [String] = []) -> [String] {
        let stable = stableName(of: path, home: home)
        guard stable.hasPrefix("~") else { return spellings(of: path) }
        let inside = stable.dropFirst()   // "" or "/…"
        var names: [String] = []
        for container in [home] + earlierHomes {
            for name in spellings(of: withoutTrailingSlash(container) + inside) where !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    /// What the container was called when `old` was kept for the folder now
    /// at `now`: `old` with `now`'s place inside the container taken off its
    /// end. Only a sibling of today's container — another UUID in the same
    /// folder — counts: anything else is a folder that moved, not a container
    /// that did. A container is named by a UUID, an iPhone's and the
    /// simulator's alike; the Mac's (`…/Data`) is not and never moves, and an
    /// unsandboxed home (`/Users/…`) is no container — without that, a folder
    /// moved from `/Users/Shared` into it taught "the container was
    /// `/Users/Shared`" (§51.71). `nil` when `now` is outside the container,
    /// or nothing moved.
    static func earlierHome(of old: String, now: String, home: String = NSHomeDirectory()) -> String? {
        let stable = stableName(of: now, home: home)
        guard stable.hasPrefix("~") else { return nil }
        let inside = String(stable.dropFirst())
        let old = withoutTrailingSlash(oneSpelling(old))
        let home = withoutTrailingSlash(oneSpelling(home))
        guard old.hasSuffix(inside) else { return nil }
        let earlier = String(old.dropLast(inside.count))
        let folder = parent(of: home)
        guard earlier != home, folder.count > 1, parent(of: earlier) == folder,
              isContainer(earlier), isContainer(home) else { return nil }
        return earlier
    }

    /// `path` as today's container names it: a path kept under one of the
    /// container's earlier names (`earlierHomes`) moved into today's, in the
    /// spelling it was kept in; any other path as it is.
    static func todaysPath(of path: String, home: String = NSHomeDirectory(),
                           earlierHomes: [String]) -> String {
        let one = oneSpelling(path)
        let today = withoutTrailingSlash(oneSpelling(home))
        for earlier in earlierHomes.map({ withoutTrailingSlash(oneSpelling($0)) })
        where earlier.count > 1 && earlier != today && (one == earlier || one.hasPrefix(earlier + "/")) {
            let moved = spellings(of: today + one.dropFirst(earlier.count))
            return path.hasPrefix("/private/") ? moved[moved.count - 1] : moved[0]
        }
        return path
    }

    /// The name of the place `path` names, whatever the container was called
    /// when it was kept and in either spelling: two paths with one place name
    /// are one folder or one file.
    static func placeName(of path: String, home: String = NSHomeDirectory(),
                          earlierHomes: [String]) -> String {
        stableName(of: todaysPath(of: path, home: home, earlierHomes: earlierHomes), home: home)
    }

    /// Which of `paths` names the place `kept` named — kept, perhaps, under an
    /// earlier name of the container, or in the other spelling. Only a path
    /// ending in the same name is worked out.
    static func index(of kept: String, in paths: [String], home: String = NSHomeDirectory(),
                      earlierHomes: [String]) -> Int? {
        let place = placeName(of: kept, home: home, earlierHomes: earlierHomes)
        let last = lastComponent(of: place)
        return paths.firstIndex {
            lastComponent(of: $0) == last && placeName(of: $0, home: home, earlierHomes: earlierHomes) == place
        }
    }

    private static func isContainer(_ path: String) -> Bool {
        UUID(uuidString: lastComponent(of: path)) != nil
    }

    private static func lastComponent(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func withoutTrailingSlash(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }
}
