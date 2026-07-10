//
//  MacContentView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import SwiftUI

/// The macOS three-column navigation shell: sidebar, note list, and detail.
struct MacContentView: View {
    @Environment(WorkspaceIndexer.self) private var indexer

    @State private var selectedNote: Note?

    var body: some View {
        NavigationSplitView {
            // Column 1 — Sidebar
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    indexer.requestVaultAccess()
                } label: {
                    Label("Select Vault Folder", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let vaultURL = indexer.selectedVaultURL {
                    Text(vaultURL.lastPathComponent)
                        .font(.headline)
                    Text("\(indexer.notes.count) notes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("HelloNotes")
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } content: {
            // Column 2 — Content list
            List(indexer.notes, selection: $selectedNote) { note in
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.title)
                        .font(.headline)
                    Text(note.lastModified, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(note)
            }
            .navigationTitle("Notes")
            .overlay {
                if indexer.notes.isEmpty {
                    ContentUnavailableView(
                        "No Notes",
                        systemImage: "doc.text",
                        description: Text("Select a vault folder to index your Markdown files.")
                    )
                }
            }
        } detail: {
            // Column 3 — Detail placeholder
            if let selectedNote {
                Text(selectedNote.title)
                    .font(.largeTitle)
                    .padding()
            } else {
                Text("Select a note")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
