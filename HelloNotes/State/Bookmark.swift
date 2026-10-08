//
//  Bookmark.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Security-scoped bookmark helpers, so sandboxed access to user-picked folders
//  (local, iCloud Drive, Obsidian vaults) survives relaunches. Shared by the
//  library, recents, and saved-libraries stores.
//

import Foundation

/// `nonisolated`: resolving a bookmark can mount a volume and minting one asks
/// the sandbox, so neither belongs on the main actor — launch resolves the
/// whole list off it, and Try Again and Relocate do theirs there too
/// (implemented.md §51.36). Unannotated, this target made them main-actor.
nonisolated enum Bookmark {
    /// Bookmark data for `url`, security-scoped on macOS.
    static func data(for url: URL) -> Data? {
        #if os(macOS)
        return try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    /// Resolve bookmark `data` back to a URL (does not start the security scope),
    /// reporting whether the bookmark has gone **stale**.
    ///
    /// `isStale` must not be dropped. Apple's contract is that a stale bookmark
    /// still resolves *this* time and the caller is expected to mint a
    /// replacement from the resolved URL. This used to declare the flag, pass
    /// its address, and never read it — so bookmarks decayed silently until one
    /// failed to resolve at all, at which point the collection simply vanished
    /// from the sidebar at launch with nothing said. `cloud-native-roadmap.md`
    /// §5 called for re-minting on stale; this is what makes that possible.
    ///
    /// `mounting: false` resolves without mounting a volume that is not there
    /// — a network share gone away — which Try Again asks for: mount it in the
    /// Finder and try again.
    static func resolve(_ data: Data, mounting: Bool = true) -> Resolved? {
        var isStale = false
        #if os(macOS)
        var options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        var options: URL.BookmarkResolutionOptions = []
        #endif
        if !mounting { options.insert(.withoutMounting) }
        guard let url = try? URL(resolvingBookmarkData: data, options: options,
                                 relativeTo: nil, bookmarkDataIsStale: &isStale)
        else { return nil }
        return Resolved(url: url, isStale: isStale)
    }

    struct Resolved: Sendable {
        let url: URL
        /// True when the bookmark resolved but should be replaced — re-mint from
        /// `url` and persist, or it will eventually stop resolving.
        let isStale: Bool
    }

    /// Resolve, and re-mint when stale. Returns the URL and, when a fresh
    /// bookmark was minted, the data the caller should persist in place of the
    /// old blob.
    static func resolveRefreshing(_ data: Data, mounting: Bool = true) -> (url: URL, refreshed: Data?)? {
        guard let resolved = resolve(data, mounting: mounting) else { return nil }
        guard resolved.isStale else { return (resolved.url, nil) }
        // Minting needs the security scope open on macOS, or the new bookmark is
        // made without the access it is meant to carry.
        let scoped = resolved.url.startAccessingSecurityScopedResource()
        defer { if scoped { resolved.url.stopAccessingSecurityScopedResource() } }
        return (resolved.url, self.data(for: resolved.url))
    }
}
