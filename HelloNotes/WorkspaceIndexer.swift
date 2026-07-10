//
//  WorkspaceIndexer.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

/// Observable state manager that treats a local directory (the "vault") as the
/// absolute source of truth and indexes the Markdown files it contains.
@Observable
final class WorkspaceIndexer {
    /// The root folder the user has selected as their vault.
    var selectedVaultURL: URL?

    /// The Markdown notes discovered inside the vault.
    var notes: [Note] = []

    /// The Uniform Type Identifier used to recognise Markdown files. `UTType`
    /// has no built-in `.markdown` constant, so we resolve the system-declared
    /// Markdown type (`net.daringfireball.markdown`), falling back to the `md`
    /// filename extension.
    private static let markdownType: UTType =
        UTType("net.daringfireball.markdown")
        ?? UTType(filenameExtension: "md")
        ?? .plainText

    /// Scans `selectedVaultURL` for Markdown files and populates `notes`.
    func scanVault() {
        guard let vaultURL = selectedVaultURL else {
            notes = []
            return
        }

        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .contentTypeKey, .isRegularFileKey]

        guard let enumerator = fileManager.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            notes = []
            return
        }

        var discovered: [Note] = []

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(resourceKeys)),
                  resourceValues.isRegularFile == true else {
                continue
            }

            // Match Markdown files either by declared content type or by extension.
            let isMarkdown = resourceValues.contentType?.conforms(to: Self.markdownType) == true
                || UTType(filenameExtension: fileURL.pathExtension)?.conforms(to: Self.markdownType) == true

            guard isMarkdown else { continue }

            let note = Note(
                title: fileURL.deletingPathExtension().lastPathComponent,
                fileURL: fileURL,
                lastModified: resourceValues.contentModificationDate ?? .distantPast
            )
            discovered.append(note)
        }

        notes = discovered.sorted { $0.lastModified > $1.lastModified }
    }

    /// Presents an `NSOpenPanel` so the user can choose a vault folder, then scans it.
    func requestVaultAccess() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Vault"
        panel.message = "Choose a folder to use as your HelloNotes vault."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        selectedVaultURL = url
        scanVault()
        #endif
    }
}
