//
//  ObsidianVault.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Locating Obsidian vaults — folders that contain a `.obsidian` config
//  directory — including those synced through iCloud Drive. The sandbox blocks
//  reading iCloud containers directly, so discovery runs over a folder the user
//  has granted access to (via the open panel / Files picker); these helpers then
//  find the vaults inside it. `.obsidian` (and other dotfiles) are hidden, so a
//  vault opened as a Collection indexes only its Markdown, not Obsidian's config.
//

import Foundation

nonisolated enum ObsidianVault {
    /// The `.obsidian` config folder marks a directory as an Obsidian vault.
    static func isVault(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let config = url.appendingPathComponent(".obsidian")
        return FileManager.default.fileExists(atPath: config.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Where the file picker should open when adding a collection.
    ///
    /// One name, because this was two: `pickerStartDirectory` on iOS and
    /// `defaultBrowseDirectory` on macOS, each `#if`-gated, each with its own
    /// caller. Two names for one question is how the two platforms come to
    /// answer it differently — and they did: the Mac checked whether Obsidian's
    /// folder actually exists and fell back to the iCloud Drive root, and iOS
    /// returned its guess unconditionally with no fallback at all.
    ///
    /// Optional on both: a hint the picker may ignore, not an access grant.
    static var browseStartDirectory: URL? {
        #if os(macOS)
        return defaultBrowseDirectory
        #else
        let obsidian = pickerStartDirectory
        // Same fallback the Mac has always had. `checkResourceIsReachable` on
        // another app's container will usually fail under the sandbox, which is
        // why an unreachable path still returns the hint rather than nil — the
        // picker resolves it out of process, and if it cannot it opens where it
        // would have anyway.
        return obsidian ?? iCloudDriveHint
        #endif
    }

    #if os(iOS)
    /// The iCloud Drive root, as a hint of last resort.
    private static var iCloudDriveHint: URL? {
        URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs",
            isDirectory: true)
    }

    /// Where the Files picker should open when adding a collection.
    ///
    /// Obsidian's iOS app keeps its vaults in its own iCloud Drive folder, and
    /// that is where almost every "open my vault" journey ends. The picker used
    /// to open wherever Files last was, so a person with one obvious
    /// destination had to navigate to it by hand every time — the app knows the
    /// answer and was not saying it.
    ///
    /// A *hint*, not an access grant: this app cannot read another app's
    /// ubiquity container, and does not try. The picker runs out of process and
    /// resolves the location itself; if it cannot, it opens at its default and
    /// nothing is worse than before. That is why the path is built literally
    /// rather than through `FileManager` — there is nothing here for us to
    /// resolve, and pretending otherwise would just fail differently.
    private static var pickerStartDirectory: URL? {
        URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/iCloud~md~obsidian/Documents",
            isDirectory: true)
    }
    #endif

    #if os(macOS)
    /// Obsidian's own iCloud Drive folder (`iCloud Drive/Obsidian`), where the
    /// iOS/iPadOS app stores vaults by default. Returned unconditionally as a
    /// browse hint — the sandbox may forbid `stat` here, but the open panel can
    /// still navigate to it. (macOS only; iOS uses the Files picker, which can't
    /// be seeded with a start directory.)
    static var iCloudObsidianDirectory: URL {
        homeMobileDocuments.appendingPathComponent("iCloud~md~obsidian/Documents", isDirectory: true)
    }

    /// The user's iCloud Drive root (`com~apple~CloudDocs`).
    static var iCloudDriveDirectory: URL {
        homeMobileDocuments.appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
    }

    /// A sensible default location for the open panel: Obsidian's iCloud folder
    /// if it exists, otherwise the iCloud Drive root.
    static var defaultBrowseDirectory: URL {
        let obsidian = iCloudObsidianDirectory
        if (try? obsidian.checkResourceIsReachable()) == true { return obsidian }
        return iCloudDriveDirectory
    }

    /// The **real** home, not the container. `homeDirectoryForCurrentUser`
    /// returns the sandbox container, so this used to build a path that had
    /// never existed — `checkResourceIsReachable()` then failed, the fallback
    /// was equally fictional, and the open panel quietly ignored the hint. See
    /// `RealHome`.
    private static var homeMobileDocuments: URL {
        RealHome.path("Library/Mobile Documents")
    }
    #endif

    /// Obsidian vaults reachable from `folder`: the folder itself if it's a
    /// vault, plus any vault folders nested within it up to `maxDepth` levels.
    /// De-duplicated and sorted by name. The caller must already have access to
    /// `folder` (e.g. it came from the open panel / Files picker).
    static func discoverVaults(in folder: URL, maxDepth: Int = 2) -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default

        func scan(_ dir: URL, depth: Int) {
            if isVault(dir) { found.append(dir); return }   // don't descend into a vault
            guard depth > 0,
                  let entries = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
            for entry in entries
            where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                scan(entry, depth: depth - 1)
            }
        }
        scan(folder, depth: maxDepth)

        var seen = Set<String>()
        return found
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
