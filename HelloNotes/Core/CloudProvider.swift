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
}
