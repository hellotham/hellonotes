//
//  NoteHistoryView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import SwiftUI

/// A sheet listing a note's Git history. Selecting a commit previews that
/// version's contents; **Restore** replaces the editor's text with it (which
/// then autosaves through the normal path, so it stays undoable).
struct NoteHistoryView: View {
    let fileURL: URL
    let git: GitService
    /// Called with the chosen revision's text when the user restores it.
    let onRestore: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var revisions: [GitService.NoteRevision] = []
    @State private var selected: GitService.NoteRevision.ID?
    @State private var preview: String = ""
    @State private var isLoading = true
    @State private var isLoadingPreview = false

    private var selectedRevision: GitService.NoteRevision? {
        revisions.first { $0.id == selected }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 720, height: 480)
        .task { await load() }
        .onChange(of: selected) { _, newID in
            guard let newID else { preview = ""; return }
            Task { await loadPreview(for: newID) }
        }
    }

    private var header: some View {
        HStack {
            Label("Version History", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            Spacer()
            Text(fileURL.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if revisions.isEmpty {
            ContentUnavailableView(
                "No History",
                systemImage: "clock",
                description: Text("This note has no committed versions yet. Commit changes to build up a history.")
            )
        } else {
            HSplitView {
                List(revisions, selection: $selected) { revision in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(revision.summary.isEmpty ? "(no message)" : revision.summary)
                            .font(.callout)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(revision.date, format: .dateTime.year().month().day().hour().minute())
                            Text("·")
                            Text(revision.authorName).lineLimit(1)
                            Text("·")
                            Text(revision.shortID).monospaced()
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .tag(revision.id)
                }
                .frame(minWidth: 240, idealWidth: 280)

                previewPane
                    .frame(minWidth: 300)
            }
        }
    }

    @ViewBuilder
    private var previewPane: some View {
        if selectedRevision == nil {
            ContentUnavailableView("Select a Version", systemImage: "doc.text.magnifyingglass")
        } else if isLoadingPreview {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                Text(preview)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Restore This Version") {
                if selectedRevision != nil {
                    onRestore(preview)
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedRevision == nil || isLoadingPreview)
        }
        .padding(12)
    }

    private func load() async {
        isLoading = true
        revisions = await git.history(for: fileURL)
        isLoading = false
        if selected == nil, let first = revisions.first {
            selected = first.id
        }
    }

    private func loadPreview(for id: GitService.NoteRevision.ID) async {
        isLoadingPreview = true
        let content = await git.content(ofRevision: id, for: fileURL) ?? ""
        // Drop a stale result: the user may have selected a different revision
        // while this (possibly slow) git read was in flight. Applying it would
        // show — and let "Restore" write — the wrong revision's content.
        guard selected == id else { return }
        preview = content
        isLoadingPreview = false
    }
}
#endif
