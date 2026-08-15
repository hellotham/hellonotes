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

enum Bookmark {
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
    static func resolve(_ data: Data) -> Resolved? {
        var isStale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(resolvingBookmarkData: data, options: options,
                                 relativeTo: nil, bookmarkDataIsStale: &isStale)
        else { return nil }
        return Resolved(url: url, isStale: isStale)
    }

    struct Resolved {
        let url: URL
        /// True when the bookmark resolved but should be replaced — re-mint from
        /// `url` and persist, or it will eventually stop resolving.
        let isStale: Bool
    }

    /// Resolve, and re-mint when stale. Returns the URL and, when a fresh
    /// bookmark was minted, the data the caller should persist in place of the
    /// old blob.
    static func resolveRefreshing(_ data: Data) -> (url: URL, refreshed: Data?)? {
        guard let resolved = resolve(data) else { return nil }
        guard resolved.isStale else { return (resolved.url, nil) }
        // Minting needs the security scope open on macOS, or the new bookmark is
        // made without the access it is meant to carry.
        let scoped = resolved.url.startAccessingSecurityScopedResource()
        defer { if scoped { resolved.url.stopAccessingSecurityScopedResource() } }
        return (resolved.url, self.data(for: resolved.url))
    }
}
