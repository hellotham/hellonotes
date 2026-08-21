//
//  OpenQuicklyView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import SwiftUI

/// A command-palette-style sheet (⌘O) for jumping to a note or heading by
/// fuzzy-matching its name. Type to filter, press Return to open the top hit,
/// or tap any row.
///
/// Cross-platform since the parity audit. iPad had a list of its own that
/// filtered `notes` by substring — no headings, no ranking, no debounce — so
/// ⌘O found a different set of things on each platform. One view, one
/// `quickOpenResults`, and the sheet chrome differs where the platform's does.
struct OpenQuicklyView: View {
    let search: CollectionSearchModel
    let onOpen: (Note) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [QuickOpenItem] = []
    @State private var queryTask: Task<Void, Never>?
    @State private var selection: QuickOpenItem.ID?
    @FocusState private var fieldFocused: Bool

    /// Recompute results, debounced so fast typing doesn't re-score the whole
    /// candidate list on every keystroke.
    private func scheduleQuery(_ q: String) {
        queryTask?.cancel()
        queryTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            results = search.quickOpenResults(query: q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Open note or heading…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($fieldFocused)
                .onSubmit(openSelected)
                .autocorrectionDisabled()
                // A search field, not prose: no capitalisation, and the return
                // key says what it does. Only iOS has either to set.
                .plainSearchField()

            Divider()

            List(results, selection: $selection) { item in
                row(item)
                    .tag(item.id)
                    .contentShape(.rect)
                    .onTapGesture { open(item) }
            }
            .listStyle(.plain)
        }
        // A palette, not a document: on the Mac it is sized to the window
        // rather than to whatever the results happen to be, and Escape must
        // always dismiss even when the field has lost first-responder status.
        // A sheet is given its size and its cancel action, so iOS needs
        // neither.
        .paletteChrome(dismiss: { dismiss() })
        .onAppear { fieldFocused = true; results = search.quickOpenResults(query: "") }
        .onChange(of: query) { _, q in scheduleQuery(q) }
        .onChange(of: results) { _, newResults in
            // Keep a valid top selection as the query narrows.
            if selection == nil || !newResults.contains(where: { $0.id == selection }) {
                selection = newResults.first?.id
            }
        }
    }

    private func row(_ item: QuickOpenItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind == .heading ? "number" : "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func open(_ item: QuickOpenItem) {
        onOpen(item.note)
        dismiss()
    }

    private func openSelected() {
        if let selection, let item = results.first(where: { $0.id == selection }) {
            open(item)
        } else if let first = results.first {
            open(first)
        }
    }
}

private extension View {
    /// A field that searches rather than writes prose.
    ///
    /// A `#if/#else` in one place, not two adjacent `#if`s at the call site.
    /// Two one-sided gates side by side are an if/else written the long way —
    /// they read as independent, and it is easy to update one and leave the
    /// other, which is the whole failure mode this codebase has been unpicking.
    @ViewBuilder
    func plainSearchField() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).submitLabel(.go)
        #else
        self
        #endif
    }

    /// A palette's own chrome, where the platform gives it none.
    @ViewBuilder
    func paletteChrome(dismiss: @escaping () -> Void) -> some View {
        #if os(macOS)
        self.frame(width: 540, height: 420).onExitCommand(perform: dismiss)
        #else
        self
        #endif
    }
}
