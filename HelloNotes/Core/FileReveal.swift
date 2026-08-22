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
        return handToFileManager(url)
    }

    /// Ask the platform's file manager to show `url`.
    ///
    /// One question — "put this file in front of the user" — answered with the
    /// call each platform has for it.
    ///
    /// The iOS branch used to guard on `canOpenURL`. Since iOS 9 that answers
    /// `false` for any scheme not listed in `LSApplicationQueriesSchemes`, and
    /// `shareddocuments` is an undocumented Files scheme this app has never
    /// declared — so the guard returned `false` on every device, for every file,
    /// and "Reveal in Files" was an enabled menu item that did nothing at all.
    /// The allowlist gates `canOpenURL` alone; `open(_:)` is not subject to it.
    @discardableResult
    private static func handToFileManager(_ url: URL) -> Bool {
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
        #else
        // The path is percent-encoded because a note's name may contain spaces
        // and anything else a filename allows, and an unencoded URL simply
        // fails to build.
        let encoded = url.path.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? url.path
        guard let target = URL(string: "shareddocuments://\(encoded)") else { return false }
        UIApplication.shared.open(target)
        return true
        #endif
    }

    /// The title for `openInDefaultApp`, so both shells spell it the way their
    /// platform actually behaves.
    static var openInDefaultAppTitle: String {
        #if canImport(AppKit)
        return "Open in Default App"
        #else
        return "Open in Files"
        #endif
    }

    /// Hand a non-note file to whatever the platform opens it with.
    ///
    /// The Mac's sidebar offered this on an attachment and iOS did not, on the
    /// same reasoning that kept "Reveal" macOS-only — `NSWorkspace.open` has no
    /// iOS twin.
    ///
    /// It has no *direct* twin: `UIApplication.open` does not handle `file:`
    /// URLs — no app registers for that scheme — so the previous iOS branch
    /// returned `false` unconditionally and the menu item was dead on every
    /// attachment. What iOS does have is the hand-off to Files, from where the
    /// file opens in whatever claims it. Same command, one more tap.
    @discardableResult
    static func openInDefaultApp(_ url: URL) -> Bool {
        #if canImport(AppKit)
        return NSWorkspace.shared.open(url)
        #else
        return handToFileManager(url)
        #endif
    }
}
