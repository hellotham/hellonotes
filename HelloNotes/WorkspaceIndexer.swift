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

        setVault(url)
        #endif
    }

    /// Adopt a vault folder: remember it for next launch and index it.
    func setVault(_ url: URL) {
        // On sandboxed platforms (iOS) a user-selected folder must have its
        // security scope started before it can be read. Harmless elsewhere;
        // held for the app's lifetime (the vault stays open).
        _ = url.startAccessingSecurityScopedResource()
        selectedVaultURL = url
        persistVaultBookmark(for: url)
        scanVault()
    }

    // MARK: - File operations

    /// Create a new empty Markdown note in the vault and return it. The
    /// filename is derived from `title`, disambiguated if it already exists.
    @discardableResult
    func createNote(title: String = "Untitled") -> Note? {
        guard let vaultURL = selectedVaultURL else { return nil }

        let fileManager = FileManager.default
        let base = title.isEmpty ? "Untitled" : title
        var candidate = vaultURL.appendingPathComponent("\(base).md")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = vaultURL.appendingPathComponent("\(base) \(counter).md")
            counter += 1
        }

        do {
            try Data().write(to: candidate, options: .withoutOverwriting)
        } catch {
            return nil
        }

        scanVault()
        return notes.first { $0.fileURL == candidate }
    }

    /// Return the note at `relativePath` inside the vault, creating the file
    /// (and any intermediate folders) with `content` if it doesn't exist yet.
    /// Used for daily notes, which reuse today's file if it's already there.
    @discardableResult
    func note(atRelativePath relativePath: String, creatingWith content: @autoclosure () -> String) -> Note? {
        guard let vaultURL = selectedVaultURL else { return nil }
        let url = vaultURL.appendingPathComponent(relativePath)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try Data(content().utf8).write(to: url, options: .withoutOverwriting)
            } catch {
                return nil
            }
            scanVault()
        }
        return notes.first { $0.fileURL.standardizedFileURL == url.standardizedFileURL }
    }

    /// Move a note to the Trash (never a hard delete) and re-index.
    func deleteNote(_ note: Note) {
        try? FileManager.default.trashItem(at: note.fileURL, resultingItemURL: nil)
        scanVault()
    }

    // MARK: - Vault persistence (security-scoped bookmark)

    private static let bookmarkDefaultsKey = "vaultBookmark"

    /// Resolve and re-open the previously selected vault, if any. Call once at launch.
    func restoreVault() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkDefaultsKey) else { return }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }

        _ = url.startAccessingSecurityScopedResource()
        selectedVaultURL = url
        scanVault()

        // Refresh a stale bookmark so it keeps resolving after the folder moves.
        if isStale {
            persistVaultBookmark(for: url)
        }
    }

    private func persistVaultBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: Self.bookmarkDefaultsKey)
    }
}
