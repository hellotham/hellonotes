//
//  FolderConventionSettings.swift
//  HelloNotes
//
//  Created by Chris Tham on 21/8/2026.
//
//  Where pasted images go, and the daily-note / template folder conventions —
//  three settings written once and shown by both platforms' settings screens.
//
//  They were written twice. The Mac's `GeneralSettingsView` offers "Pasted
//  images" as a two-way picker with a remembered subfolder name and a worked
//  example of the Markdown it produces; iOS offered a bare text field whose
//  empty state means "same folder as the note" — true, and discoverable only by
//  reading the placeholder. Same `@AppStorage` key, same effect on disk, two
//  different things to understand. The Mac also previews what today's daily
//  note would be called, which is the only feedback the date-format field has;
//  iOS had none, so a wrong format looked exactly like a right one until a note
//  appeared under the wrong name.
//
//  One view rather than two, because that difference is not a platform
//  difference — it is one screen having been improved and the other not.
//

import SwiftUI

/// The Attachments / Daily notes / Templates sections, for a `Form` on either
/// platform.
///
/// Emits bare `Section`s rather than its own `Form`, so each platform's
/// settings screen keeps its own container, grouping and navigation.
struct FolderConventionSections: View {
    /// Folder (relative to the note) where pasted images are saved. Empty means
    /// the same folder as the note.
    @AppStorage("attachmentFolder") private var attachmentFolder = "assets"
    @AppStorage("dailyNoteFolder") private var dailyNoteFolder = ""
    @AppStorage("dailyDateFormat") private var dailyDateFormat = "yyyy-MM-dd"
    @AppStorage("templatesFolder") private var templatesFolder = "Templates"

    /// Remembers the last subfolder name so toggling to "same folder" and back
    /// restores it instead of clearing the field.
    @State private var subfolderName = "assets"

    private enum AttachmentLocation { case subfolder, sameFolder }

    private var location: AttachmentLocation {
        attachmentFolder.trimmingCharacters(in: .whitespaces).isEmpty ? .sameFolder : .subfolder
    }

    var body: some View {
        Section("Attachments") {
            Picker("Pasted images", selection: Binding(
                get: { location },
                set: { newValue in
                    switch newValue {
                    case .sameFolder:
                        attachmentFolder = ""
                    case .subfolder:
                        let name = subfolderName.trimmingCharacters(in: .whitespaces)
                        attachmentFolder = name.isEmpty ? "assets" : name
                    }
                })) {
                Text("Store in a subfolder").tag(AttachmentLocation.subfolder)
                Text("Same folder as the note").tag(AttachmentLocation.sameFolder)
            }

            if location == .subfolder {
                LabeledField(label: "Subfolder name", text: $attachmentFolder, prompt: "assets", isPath: true)
                    .onChange(of: attachmentFolder) { _, newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { subfolderName = trimmed }
                    }
                caption("Pasted images go in “\(attachmentFolder)” beside each note — e.g. `![](\(attachmentFolder)/Pasted-….png)`. The folder is created on first paste.")
            } else {
                caption("Pasted images are saved next to each note — e.g. `![](Pasted-….png)`.")
            }
        }
        // Restore the remembered subfolder name from whatever is stored, so
        // switching to "same folder" and back offers the name you had rather
        // than an empty field.
        .onAppear {
            let trimmed = attachmentFolder.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { subfolderName = trimmed }
        }

        Section("Daily notes") {
            LabeledField(label: "Folder", text: $dailyNoteFolder, prompt: "Collection root", isPath: true)
            LabeledField(label: "Date format", text: $dailyDateFormat, prompt: "yyyy-MM-dd", isPath: true)
            // The only feedback this field has: the format is applied live, so a
            // typo names a note wrongly *here* rather than tomorrow morning.
            caption("Uses date tokens — yyyy (year), MM (month), dd (day). Today would be “\(TemplateExpander.dailyNoteName(for: .now, format: dailyDateFormat))”.")
        }

        Section("Templates") {
            LabeledField(label: "Folder", text: $templatesFolder, prompt: "Templates", isPath: true)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
