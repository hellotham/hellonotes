//
//  GeneralSettingsView.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  The app's Preferences window (⌘,). Hosts vault-wide preferences that aren't
//  tied to the LLM or Git sheets — where pasted attachments go, and the daily-
//  note / template folder conventions. All values are persisted via @AppStorage.
//

#if os(macOS)
import SwiftUI

struct GeneralSettingsView: View {
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
        Form {
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
                    TextField("Subfolder name", text: $attachmentFolder, prompt: Text("assets"))
                        .onChange(of: attachmentFolder) { _, newValue in
                            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty { subfolderName = trimmed }
                        }
                    Text("Pasted images go in “\(attachmentFolder)” beside each note — e.g. `![](\(attachmentFolder)/Pasted-….png)`. The folder is created on first paste.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Pasted images are saved next to each note — e.g. `![](Pasted-….png)`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Daily notes") {
                TextField("Folder", text: $dailyNoteFolder, prompt: Text("Vault root"))
                TextField("Date format", text: $dailyDateFormat, prompt: Text("yyyy-MM-dd"))
            }

            Section("Templates") {
                TextField("Folder", text: $templatesFolder, prompt: Text("Templates"))
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            let trimmed = attachmentFolder.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { subfolderName = trimmed }
        }
    }
}
#endif
