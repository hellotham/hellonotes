//
//  FileReveal.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  Show a note where it lives, in whichever file manager the platform has.
//
//  This was "Reveal in Finder", `#if os(macOS)` in `AppCommands`, with
//  `revealInFinder` sitting on a list of divergences justified as "iOS exposes
//  no public API to reveal an arbitrary path in Files". That justification was
//  rejected, correctly: iOS has a Files app, it can be opened at a path, and
//  the command the user wants is "show me this file where it lives" — which
//  both platforms can answer. The API being differently named is not the
//  feature being absent.
//
//  So the gate moves down here, where it has an `#else` and both branches do
//  the same job, and the command above it is one command on both platforms.
//
//  On iOS this is the `shareddocuments:` scheme, which opens Files at a path.
//  It is the mechanism the platform provides and it can fail — a provider that
//  does not surface the location, a path Files will not browse — so the call
//  reports whether it worked rather than assuming, and the menu item is offered
//  only where a reveal is possible at all.
//

import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
enum FileReveal {

    /// What the platform's file manager is called, for the menu item. A system
    /// app's name, not a behaviour difference — the command is the same one.
    static var fileManagerName: String {
        #if canImport(AppKit)
        return "Finder"
        #else
        return "Files"
        #endif
    }

    /// The menu title, so both shells spell it the same way.
    static var revealTitle: String { "Reveal in \(fileManagerName)" }

    /// Whether `url` can be shown at all.
    ///
    /// macOS can always reveal a real file. iOS can only hand Files a path it
    /// is willing to browse, so a file that is not there is not revealable —
    /// and an enabled menu item that silently does nothing is worse than a
    /// disabled one.
    static func canReveal(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Show `url` in the platform's file manager.
    ///
    /// - Returns: whether the file manager was actually asked to open it.
    @discardableResult
    static func reveal(_ url: URL) -> Bool {
        guard canReveal(url) else { return false }
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
        #else
        // `shareddocuments:` is how Files is opened at a location. The path is
        // percent-encoded because a note's name may contain spaces and anything
        // else a filename allows, and an unencoded URL simply fails to build.
        let encoded = url.path.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? url.path
        guard let target = URL(string: "shareddocuments://\(encoded)"),
              UIApplication.shared.canOpenURL(target) else { return false }
        UIApplication.shared.open(target)
        return true
        #endif
    }
}
