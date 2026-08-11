//
//  NoteHistoryView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

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

    /// How this view is being presented. A sheet has room for the revision
    /// list and the preview side by side; the inspector rail (280pt) does not,
    /// so there they stack — and the size comes from the rail, never from a
    /// hard-coded frame that would overflow it.
    enum Presentation { case sheet, rail }
    var presentation: Presentation = .sheet

    var body: some View {
        VStack(spacing: 0) {
            if presentation == .sheet {
                header
                Divider()
            }
            content
            Divider()
            footer
        }
        .frame(width: presentation == .sheet ? 720 : nil,
               height: presentation == .sheet ? 480 : nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            #if os(macOS)
            if presentation == .sheet {
                HSplitView {
                    revisionList
                        .frame(minWidth: 240, idealWidth: 280)
                    previewPane
                        .frame(minWidth: 300)
                }
            } else {
                // Rail: stacked, because 280pt cannot hold two columns.
                VSplitView {
                    revisionList.frame(minHeight: 120)
                    previewPane.frame(minHeight: 120)
                }
            }
            #else
            // H/VSplitView are AppKit-only, and a draggable divider is a
            // pointer affordance anyway — touch gets a fixed split.
            VStack(spacing: 0) {
                revisionList
                Divider()
                previewPane
            }
            #endif
        }
    }

    private var revisionList: some View {
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
            // The rail has no "close" — it is a place, not a modal.
            if presentation == .sheet {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            Button(presentation == .sheet ? "Restore This Version" : "Restore") {
                if selectedRevision != nil {
                    onRestore(preview)
                    if presentation == .sheet { dismiss() }
                }
            }
            .keyboardShortcut(presentation == .sheet ? .defaultAction : nil)
            .disabled(selectedRevision == nil || isLoadingPreview)
        }
        .padding(presentation == .sheet ? 12 : 8)
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
