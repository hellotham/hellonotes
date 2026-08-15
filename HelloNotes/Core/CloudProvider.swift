//
//  CloudProvider.swift
//  HelloNotes
//
//  Created by Chris Tham on 21/7/2026.
//
//  Identifies which cloud service a collection's folder belongs to, from its
//  path alone. On macOS the File Provider clients mount under
//  `~/Library/CloudStorage/<Mount>` (e.g. `Dropbox`, `GoogleDrive-me@x`,
//  `OneDrive-Personal`, `OneDrive-<Tenant>`, `Box-Box`); iCloud Drive lives
//  under `~/Library/Mobile Documents/…`. Used to label a collection so the user
//  knows a folder is cloud-backed (and which provider).
//

import Foundation
#if os(macOS)
import AppKit
#endif

enum CloudProvider {

    /// A human-readable provider name for a file/collection URL, or `nil` for an
    /// ordinary local folder.
    static func name(for url: URL) -> String? {
        let components = url.pathComponents

        if let idx = components.firstIndex(of: "CloudStorage"), idx + 1 < components.count {
            let mount = components[idx + 1]
            if mount.hasPrefix("GoogleDrive") { return "Google Drive" }
            if mount.hasPrefix("OneDrive")    { return "OneDrive" }
            if mount.hasPrefix("Box")         { return "Box" }
            if mount.hasPrefix("Dropbox")     { return "Dropbox" }
            if mount.hasPrefix("pCloud")      { return "pCloud" }
            // Unknown provider: use the mount name up to the first "-".
            return mount.split(separator: "-").first.map(String.init) ?? mount
        }

        if components.contains("Mobile Documents") { return "iCloud Drive" }
        return nil
    }

    /// The SF Symbol to badge a cloud-backed collection with.
    static let symbol = "cloud"

    // MARK: - Mounted providers

    /// Where the File Provider clients mount on macOS. In the **real** home, not
    /// the sandbox container (see `RealHome`).
    static var cloudStorageDirectory: URL { RealHome.path("Library/CloudStorage") }

    /// iCloud Drive's own, older location.
    static var iCloudDriveDirectory: URL {
        RealHome.path("Library/Mobile Documents/com~apple~CloudDocs")
    }

    /// A provider whose desktop client is installed on this Mac.
    ///
    /// If it is, its files are already on disk as ordinary dataless paths and
    /// the app needs **no OAuth, no token, no cache and no sync engine** to use
    /// them — the direct API exists for the case where the client is absent, not
    /// as the front door.
    struct Installed: Identifiable, Sendable {
        var id: String { bundleID }
        var name: String
        var bundleID: String
    }

    /// The clients we know how to recognise, in the order they should be offered.
    static let knownClients: [Installed] = [
        Installed(name: "Box", bundleID: "com.box.desktop"),
        Installed(name: "Dropbox", bundleID: "com.getdropbox.dropbox"),
        Installed(name: "Google Drive", bundleID: "com.google.GoogleDrive"),
        Installed(name: "OneDrive", bundleID: "com.microsoft.OneDrive"),
    ]

    #if os(macOS)
    /// Which of those are actually installed.
    ///
    /// A LaunchServices lookup, which the sandbox permits — unlike listing
    /// `~/Library/CloudStorage`, which it does not. We never need to read that
    /// directory ourselves: the open panel runs out of process and shows the
    /// user what is really there.
    static func installedClients() -> [Installed] {
        knownClients.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
        }
    }
    #endif
}
