//
//  OpenQuicklyView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import SwiftUI

/// A command-palette-style sheet (⇧⌘O) for jumping to a note or heading by
/// fuzzy-matching its name. Type to filter, press Return to open the top hit,
/// or tap any row.
///
/// Cross-platform since the parity audit. iPad had a list of its own that
/// filtered `notes` by substring — no headings, no ranking, no debounce — so
/// ⇧⌘O found a different set of things on each platform. One view, one
/// `quickOpenResults`, and one drawing: the field, the rows and the panel are
/// the app's, so the palette is the same picture on both.
struct OpenQuicklyView: View {
    let search: CollectionSearchModel
    let onOpen: (Note) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppearanceSettings.self) private var appearance
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
            // Scored off the main actor (`quickOpenResultsOffMain`).
            let found = await search.quickOpenResultsOffMain(query: q)
            guard !Task.isCancelled else { return }
            results = found
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("", text: $query)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .focused($fieldFocused)
                .onSubmit(openSelected)
                .autocorrectionDisabled()
                // A search field, not prose: no capitalisation, and the return
                // key says what it does. Only iOS has either to set.
                .plainSearchField()
                .accessibilityLabel("Open note or heading")
                // The app's placeholder, not the field's: a system one is a
                // different grey on each platform.
                .chromePlaceholder("Open note or heading…", showing: query.isEmpty)
                .font(Chrome.Style.title3)
                .padding(12)

            ChromeDivider()

            // Nothing scrolls to the selection on its own — and the arrow keys
            // below assign it from outside, because the search field keeps
            // focus. Without this the highlight walks off the bottom of the
            // visible rows and Return opens a note the reader cannot see.
            ScrollViewReader { scroller in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { item in
                            // A Button, not onTapGesture — the same fix as the
                            // command palette, which had the same idiom. A bare
                            // tap recogniser carries no button trait, so
                            // VoiceOver read the row without saying it could be
                            // activated, and its activate action had nothing to
                            // fire.
                            Button { open(item) } label: {
                                PaletteRow(isSelected: item.id == selection,
                                           accent: appearance.resolvedAccent) {
                                    row(item)
                                }
                            }
                            .buttonStyle(ChromePlainStyle())
                            .id(item.id)
                            .accessibilityAddTraits(item.id == selection ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }
                .viewport()
                .background(Chrome.Colour.content)
                .onChange(of: selection) { _, id in
                    guard let id else { return }
                    scroller.scrollTo(id)
                }
            }
        }
        // A palette, not a document: it is sized once — the same panel on
        // both platforms — rather than to whatever the results happen to be,
        // and Escape must always dismiss even when the field has lost
        // first-responder status.
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
                .foregroundStyle(Chrome.Colour.secondaryLabel)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                ChromeLine(item.title, size: Chrome.Style.points(13))
                if let subtitle = item.subtitle {
                    ChromeLine(subtitle, size: Chrome.Style.points(10), colour: Chrome.Colour.secondaryLabel)
                }
            }
            Spacer(minLength: 8)
        }
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
/// treatment, its chrome and dismiss key, its selection keys, and its row
/// (`PaletteRow`, below). Shared rather than private because both palettes need
/// all of them, and every one of them has drifted between the two at some
/// point: the command palette hand-rolled `paletteChrome`'s `#if`, Open Quickly
/// had no iOS Escape, only one of them suppressed autocorrect, and only one
/// gave its glyphs a column. A contract two surfaces are meant to share cannot
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

    /// A palette's own size and its dismiss key.
    ///
    /// The size is the Mac's on both platforms: `chromeSheetFrame` fits the
    /// iPad's sheet to it, where the iPad used to size the sheet itself — so
    /// the same palette was a different shape on each. Only the key differs,
    /// because each platform spells Escape its own way.
    ///
    /// This was `private`, so the command palette could not call it and hand-rolled
    /// the same `#if` instead — the drift the comment above names, left in place by
    /// the change that named it. Making it shared closes it, and closing it hands
    /// Open Quickly the iOS Escape route the command palette already had: both
    /// palettes focus their search field on appear, so `onKeyPress` has a focus
    /// chain to travel on either platform.
    @ViewBuilder
    func paletteChrome(dismiss: @escaping () -> Void) -> some View {
        let sized = chromeSheetFrame(width: 540, height: 420)
        #if os(macOS)
        // Escape must dismiss even when the field has lost first responder.
        sized.onExitCommand(perform: dismiss)
        #else
        // A hardware keyboard still expects Escape. `onKeyPress` is the iOS
        // spelling of `onExitCommand`.
        sized.onKeyPress(.escape) { dismiss(); return .handled }
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

/// A palette's row: the sidebar's row frame — its hover, and the selection as
/// the accent at 30% — at a note row's height, grown with the text size so a
/// larger title cannot spill into the next row.
///
/// Both palettes were a `List(selection:)`, which is the platform's drawing:
/// its row height, its insets and its selection highlight, each the
/// platform's own.
struct PaletteRow<Content: View>: View {
    var isSelected: Bool
    var accent: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        ChromeRowFrame(height: Chrome.Style.points(Chrome.Metric.rowNote),
                       isSelected: isSelected, accent: accent, content: content)
    }
}
