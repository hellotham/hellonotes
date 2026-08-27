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

            // A `List` scrolls to a selection *it* set, never to one assigned
            // from outside — and the arrow keys below assign from outside,
            // because the search field keeps focus. Without this the highlight
            // walks off the bottom of the visible rows and Return opens a note
            // the reader cannot see.
            ScrollViewReader { scroller in
                List(results, selection: $selection) { item in
                    // A Button, not onTapGesture — the same fix as the command
                    // palette, which had the same idiom. A bare
                    // tap recogniser carries no button trait, so VoiceOver read the
                    // row without saying it could be activated, and its activate
                    // action had nothing to fire.
                    Button { open(item) } label: {
                        row(item)
                            // The whole row, including the gaps between glyphs.
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .tag(item.id)
                    .id(item.id)
                }
                .listStyle(.plain)
                .onChange(of: selection) { _, id in
                    guard let id else { return }
                    scroller.scrollTo(id)
                }
            }
        }
        // A palette, not a document: on the Mac it is sized to the window
        // rather than to whatever the results happen to be, and Escape must
        // always dismiss even when the field has lost first-responder status.
        // A sheet is given its size and its cancel action, so iOS needs
        // neither.
        .paletteChrome(dismiss: { dismiss() })
        .paletteSelectionKeys(ids: results.map(\.id), selection: $selection)
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

/// Everything that makes a palette a palette — the search field's input
/// treatment, its chrome and dismiss key, and its selection keys. Shared rather
/// than private because both palettes need all three, and every one of them has
/// drifted between the two at some point: the command palette hand-rolled
/// `paletteChrome`'s `#if`, Open Quickly had no iOS Escape, and only one of them
/// suppressed autocorrect. A contract two surfaces are meant to share cannot
/// live where only one of them can reach it.
extension View {
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

    /// A palette's own chrome and its dismiss key, where the platform gives it
    /// none.
    ///
    /// This was `private`, so the command palette could not call it and hand-rolled
    /// the same `#if` instead — the drift the comment above names, left in place by
    /// the change that named it. Making it shared closes it, and closing it hands
    /// Open Quickly the iOS Escape route the command palette already had: both
    /// palettes focus their search field on appear, so `onKeyPress` has a focus
    /// chain to travel on either platform.
    @ViewBuilder
    func paletteChrome(dismiss: @escaping () -> Void) -> some View {
        #if os(macOS)
        // Escape must dismiss even when the field has lost first responder.
        self.frame(width: 540, height: 420).onExitCommand(perform: dismiss)
        #else
        // A sheet on iPad sizes itself and dismisses by drag, so the fixed frame
        // would fight the presentation — but a hardware keyboard still expects
        // Escape. `onKeyPress` is the iOS spelling of `onExitCommand`.
        self.onKeyPress(.escape) { dismiss(); return .handled }
        #endif
    }

    /// ↑/↓ step the palette's selection while the search field keeps focus.
    ///
    /// Both palettes open with the `TextField` first responder and never gave
    /// the arrow keys anywhere to go, so they moved the insertion point and
    /// never reached the `List`. `selection` was therefore only ever what the
    /// `onChange` handlers set it to — the first result — and Return ran the top
    /// hit however many rows were on screen. A palette you cannot steer has one
    /// command in it.
    ///
    /// Clamps rather than wraps: running off the end of a filtered list and
    /// reappearing at the other one loses your place.
    func paletteSelectionKeys<ID: Hashable>(ids: [ID], selection: Binding<ID?>) -> some View {
        func step(_ delta: Int) -> KeyPress.Result {
            guard !ids.isEmpty else { return .ignored }
            guard let current = selection.wrappedValue,
                  let index = ids.firstIndex(of: current) else {
                selection.wrappedValue = delta > 0 ? ids.first : ids.last
                return .handled
            }
            selection.wrappedValue = ids[min(max(index + delta, 0), ids.count - 1)]
            return .handled
        }
        return self
            // `phases:` explicitly — the two-argument `onKeyPress(_:action:)`
            // defaults to `.down` alone, so holding an arrow stepped exactly one
            // row. Every overload that takes `phases` defaults to
            // `[.down, .repeat]`; the convenience form is the odd one out, and
            // press-and-hold is how anyone scans a forty-row palette.
            .onKeyPress(keys: [.upArrow], phases: [.down, .repeat]) { _ in step(-1) }
            .onKeyPress(keys: [.downArrow], phases: [.down, .repeat]) { _ in step(1) }
    }
}
