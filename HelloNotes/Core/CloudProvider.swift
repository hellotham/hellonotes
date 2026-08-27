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

nonisolated enum CloudProvider {

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
    ///
    /// Platform-split for the reason `ObsidianVault.browseStartDirectory` is:
    /// `RealHome` resolves through `getpwuid_r`, which on iOS *is* the app's
    /// own container — so the Mac's path would send the iOS picker inside our
    /// sandbox, where there is no iCloud Drive and nothing to choose. iOS gets
    /// the device's fixed absolute location instead, which the picker resolves
    /// out of process (we cannot read it ourselves, and do not try).
    static var iCloudDriveDirectory: URL {
        #if os(macOS)
        RealHome.path("Library/Mobile Documents/com~apple~CloudDocs")
        #else
        URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs",
            isDirectory: true)
        #endif
    }

    /// A provider whose desktop client is installed on this Mac.
    ///
    /// If it is, its files are already on disk as ordinary dataless paths and
    /// the app needs **no OAuth, no token, no cache and no sync engine** to use
    /// them — the direct API exists for the case where the client is absent, not
    /// as the front door.
    struct Installed: Identifiable, Sendable {
        var id: String { name }
        var name: String
        /// Every bundle id this client has shipped under — see `knownClients`.
        var bundleIDs: [String]
    }

    /// The clients we know how to recognise, in the order they should be offered.
    ///
    /// A provider may ship under **more than one bundle id** — the same app,
    /// renamed across versions or between the direct download and the App Store
    /// build. Microsoft's current Mac client is `com.microsoft.OneDrive-mac`,
    /// and checking only `com.microsoft.OneDrive` reported "not installed" on a
    /// Mac that was actively syncing two OneDrive accounts. One missed id here
    /// is invisible: the app simply never mentions a provider the user has.
    static let knownClients: [Installed] = [
        Installed(name: "Box", bundleIDs: ["com.box.desktop", "com.box.Box-Local-Com-Server"]),
        Installed(name: "Dropbox", bundleIDs: ["com.getdropbox.dropbox"]),
        Installed(name: "Google Drive", bundleIDs: ["com.google.GoogleDrive", "com.google.drivefs"]),
        Installed(name: "OneDrive", bundleIDs: ["com.microsoft.OneDrive-mac", "com.microsoft.OneDrive"]),
    ]

    /// Which of those are actually installed.
    ///
    /// On macOS a LaunchServices lookup, which the sandbox permits — unlike
    /// listing `~/Library/CloudStorage`, which it does not. We never need to
    /// read that directory ourselves: the open panel runs out of process and
    /// shows the user what is really there.
    ///
    /// On iOS the question has no answer, and that is not the same as "none".
    /// A provider's app being installed says nothing about whether its files are
    /// reachable: the Files picker lists whichever *File Provider extensions*
    /// are enabled, which the app cannot enumerate and does not need to — the
    /// picker runs out of process and shows the user what is really there,
    /// exactly as the Mac's open panel does. So the answer is empty, and the
    /// caller's job is to offer the picker rather than a list it built itself.
    static func installedClients() -> [Installed] {
        #if os(macOS)
        return knownClients.filter { client in
            client.bundleIDs.contains {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
            }
        }
        #else
        return []
        #endif
    }
}
