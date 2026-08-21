//
//  Templates.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  Insert a template into the note you are writing.
//
//  Settings ▸ Folders has always offered a "Templates folder", defaulting to
//  `Templates`, and `CloudPrefs` syncs the key across devices. Nothing read it.
//  `MacContentView` held `templateNotes` and `insertTemplate` — correct, and
//  with **no caller**: no menu item, no palette entry, no toolbar button. iOS
//  had neither. So the setting could be configured, moved and synced, and the
//  feature behind it did not exist on either platform.
//
//  That is the pattern this session keeps finding: a value with a rule and no
//  reader. It is worse than an absent feature, because the settings screen
//  promises it works.
//
//  Here so both platforms read it from one place, and `AppActions` carries it
//  into the one menu both platforms build (`HelloNotesCommands`).
//

import Foundation

/// A template the user can insert: a note inside the templates folder.
struct TemplateRef: Identifiable, Hashable, Sendable {
    let url: URL
    let title: String
    var id: URL { url }
}

@MainActor
enum Templates {

    /// The templates available in `collection`, by name.
    ///
    /// Empty when no folder is configured or none exists — the command then
    /// greys out rather than opening an empty submenu.
    static func available(in collection: Collection?, folder: String) -> [TemplateRef] {
        guard !folder.isEmpty, let collection else { return [] }
        let base = collection.rootURL.appendingPathComponent(folder)
            .standardizedFileURL.path + "/"
        return collection.notes
            .filter { $0.fileURL.standardizedFileURL.path.hasPrefix(base) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { TemplateRef(url: $0.fileURL, title: $0.title) }
    }

    /// The template's text, with its date and title tokens expanded.
    ///
    /// Read off the main actor: a template lives in the vault, so it can be a
    /// dataless cloud file, and the rule is that nothing folder-scale or
    /// provider-backed happens on the editor's thread.
    static func expanded(_ template: TemplateRef, noteTitle: String) async -> String? {
        let raw = await offMain { try? FileIO.readString(at: template.url) }
        guard let raw else { return nil }
        return TemplateExpander.expand(raw, title: noteTitle, date: .now)
    }
}
