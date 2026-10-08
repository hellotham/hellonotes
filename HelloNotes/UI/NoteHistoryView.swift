//
//  NoteHistoryView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// A sheet listing a note's Git history. Selecting a commit previews that
/// version's contents; **Restore** replaces the editor's text with it (which
/// then autosaves through the normal path, so it stays undoable).
struct NoteHistoryView: View {
    let fileURL: URL
    let git: GitService
    /// Called with the chosen revision's text when the user restores it.
    let onRestore: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppearanceSettings.self) private var appearance

    @State private var revisions: [GitService.NoteRevision] = []
    @State private var selected: GitService.NoteRevision.ID?
    @State private var preview: String = ""
    @State private var isLoading = true
    @State private var isLoadingPreview = false
    /// The revision list's width beside the preview, as dragged.
    @State private var listWidth: Double = 280
    @FocusState private var listHasFocus: Bool

    private var selectedRevision: GitService.NoteRevision? {
        revisions.first { $0.id == selected }
    }

    /// How this view is being presented: a sheet, with its own bar, or the
    /// inspector rail, which is a place rather than a modal and so has no way
    /// out — only Restore, at the foot.
    ///
    /// The presentation decides the chrome, not the layout. Whether the list
    /// and the preview sit side by side is a question of *room*
    /// (`sideBySideWidth`): the 720pt sheet has it, the 280pt rail and a
    /// phone's sheet do not, so there they stack — and the size comes from
    /// wherever the view is placed, never from a hard-coded frame that would
    /// overflow it.
    enum Presentation { case sheet, rail }
    var presentation: Presentation = .sheet

    /// The list's floor, the rule, and the preview's floor — below this the
    /// two stack.
    private static let listMinimum: CGFloat = 240
    private static let previewMinimum: CGFloat = 300
    private static var sideBySideWidth: CGFloat { listMinimum + 1 + previewMinimum }

    var body: some View {
        Group {
            switch presentation {
            case .sheet:
                // Close and Restore at the top, as every sheet in the app has
                // them, with the note named in the bar between.
                VStack(spacing: 0) {
                    ChromeSheetBar("Version History — \(fileURL.lastPathComponent)") {
                        Button("Close") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    } trailing: {
                        Button("Restore This Version", action: restore)
                            .buttonStyle(ChromePushStyle(prominent: true))
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canRestore)
                    }
                    content
                }
                .chromeSheetFrame(width: 720, height: 480)
            case .rail:
                // The rail has no "close" — it is a place, not a modal.
                VStack(spacing: 0) {
                    content
                    ChromeDivider()
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Restore", action: restore)
                            .disabled(!canRestore)
                    }
                    .padding(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
        .onChange(of: selected) { _, newID in
            guard let newID else { preview = ""; return }
            Task { await loadPreview(for: newID) }
        }
    }

    private var canRestore: Bool { selectedRevision != nil && !isLoadingPreview }

    private func restore() {
        guard selectedRevision != nil else { return }
        onRestore(preview)
        if presentation == .sheet { dismiss() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if revisions.isEmpty {
            ChromeEmptyState(
                "No History",
                systemImage: "clock",
                description: Text("This note has no committed versions yet. Commit changes to build up a history.")
            )
        } else {
            // One layout on both platforms. It was an `HSplitView` (or, in the
            // rail, a `VSplitView`) on the Mac — AppKit's own dividers — and a
            // fixed stack on iOS, so the same sheet was two columns on one and
            // two rows on the other. The rules here are the app's, and both
            // drag, with a finger or a pointer.
            GeometryReader { proxy in
                if proxy.size.width >= Self.sideBySideWidth {
                    let upper = max(proxy.size.width - 1 - Self.previewMinimum, Self.listMinimum)
                    HStack(spacing: 0) {
                        revisionList
                            .frame(width: min(max(CGFloat(listWidth), Self.listMinimum), upper))
                        ResizableDivider(width: $listWidth, range: Self.listMinimum...upper, edge: .leading,
                                         label: "Version list width")
                        previewPane
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    // Stacked, because the width cannot hold two columns.
                    StackedSplit {
                        revisionList
                    } bottom: {
                        previewPane
                    }
                }
            }
        }
    }

    /// The revisions, drawn as the sidebar draws its rows: the accent at 30%
    /// behind the selected one, the arrow keys to move through them.
    private var revisionList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(revisions) { revision in
                        revisionRow(revision)
                    }
                }
                .padding(.vertical, 4)
            }
            .viewport()
            .background(Chrome.Colour.content)
            .focusable()
            .focused($listHasFocus)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(by: 1, proxy: proxy); return .handled }
            .onKeyPress(.upArrow) { move(by: -1, proxy: proxy); return .handled }
        }
    }

    private func revisionRow(_ revision: GitService.NoteRevision) -> some View {
        let isSelected = selected == revision.id
        let select = {
            listHasFocus = true
            selected = revision.id
        }
        // The row grows with the Text Size setting, as its two lines do.
        return ChromeRowFrame(height: Chrome.Metric.rowNote * ChromeTextScale.shared.factor,
                              isSelected: isSelected, accent: appearance.resolvedAccent) {
            VStack(alignment: .leading, spacing: 2) {
                Text(revision.summary.isEmpty ? "(no message)" : revision.summary)
                    .font(Chrome.Style.callout)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(revision.date, format: .dateTime.year().month().day().hour().minute())
                    Text("·")
                    Text(revision.authorName).lineLimit(1)
                    Text("·")
                    Text(revision.shortID).monospaced()
                }
                .font(Chrome.Style.caption2)
                .foregroundStyle(Chrome.Colour.secondaryLabel)
            }
        }
        .id(revision.id)
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
    }

    /// The arrow keys, as the `List` gave them: the next or previous revision,
    /// scrolled into view.
    private func move(by step: Int, proxy: ScrollViewProxy) {
        guard !revisions.isEmpty else { return }
        let next: Int
        if let current = revisions.firstIndex(where: { $0.id == selected }) {
            next = min(max(current + step, 0), revisions.count - 1)
        } else {
            next = step > 0 ? 0 : revisions.count - 1
        }
        selected = revisions[next].id
        proxy.scrollTo(revisions[next].id)
    }

    @ViewBuilder
    private var previewPane: some View {
        if selectedRevision == nil {
            ChromeEmptyState("Select a Version", systemImage: "doc.text.magnifyingglass")
        } else if isLoadingPreview {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                Text(preview)
                    .font(Chrome.Style.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .viewport()
        }
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

// MARK: - The stacked split

/// Two panes, one above the other, with a rule between them that drags —
/// `ResizableDivider` turned on its side, for wherever the history is too
/// narrow for two columns. The height is clamped at use, so a short rail never
/// squeezes either pane below `minimum`, the floor the `VSplitView` it
/// replaces gave them.
struct StackedSplit<Top: View, Bottom: View>: View {
    private let top: Top
    private let bottom: Bottom

    /// The top pane's height as dragged; `nil` until then, which is half.
    @State private var topHeight: CGFloat?
    /// The height when this drag began, so the gesture is absolute rather than
    /// accumulating rounding.
    @State private var startHeight: CGFloat?

    private static var minimum: CGFloat { 120 }
    /// Taller than the rule: a 1pt target is unhittable with a finger and mean
    /// with a pointer.
    private static var grabHeight: CGFloat { 10 }
    /// The space a drag is measured in: the split's own, which stays where it
    /// is while the rule moves inside it — `AdaptiveSplit.space`, for the same
    /// half-speed rule.
    private static var space: String { "StackedSplit" }

    init(@ViewBuilder top: () -> Top, @ViewBuilder bottom: () -> Bottom) {
        self.top = top()
        self.bottom = bottom()
    }

    var body: some View {
        GeometryReader { proxy in
            let room = max(proxy.size.height - 1, 0)
            let upper = max(room - Self.minimum, Self.minimum)
            let height = min(max(topHeight ?? room / 2, Self.minimum), upper)
            VStack(spacing: 0) {
                top
                    .frame(height: height)
                ChromeDivider()
                    .overlay {
                        Color.clear
                            .frame(height: Self.grabHeight)
                            .contentShape(.rect)
                            .gesture(drag(from: height, upper: upper))
                            .verticalResizeCursor()
                            .accessibilityElement()
                            .accessibilityLabel("Split")
                            .accessibilityValue("\(Int(height)) points")
                            .accessibilityAdjustableAction { direction in
                                let step: CGFloat = 20
                                let next = height + (direction == .increment ? step : -step)
                                topHeight = min(max(next, Self.minimum), upper)
                            }
                    }
                    // Above the pane below, so the lower half of the grab area
                    // is the rule's and not the preview's.
                    .zIndex(1)
                bottom
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .coordinateSpace(.named(Self.space))
    }

    private func drag(from height: CGFloat, upper: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let start = startHeight ?? height
                if startHeight == nil { startHeight = start }
                topHeight = min(max(start + value.translation.height, Self.minimum), upper)
            }
            .onEnded { _ in startHeight = nil }
    }
}

private extension View {
    /// The pointer says "drag this up or down" where there is a pointer to say
    /// it to — `ResizableDivider`'s cursor, for a rule that lies flat. On touch
    /// the grab area is the whole affordance.
    func verticalResizeCursor() -> some View {
        #if canImport(AppKit)
        return onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        #else
        return self
        #endif
    }
}
