//
//  CompactShell.swift
//  HelloNotes
//
//  The phone (and the 320pt iPad slice): the editor is the screen.
//
//  Rails and a list column mean nothing at this width, so this is not the wide
//  shell rearranged — it is the Apple Music model (decision 6). A bottom tab
//  bar carries the app's *places*; the note being edited persists above it as a
//  mini strip, one tap from full screen. Both retract as you scroll or type
//  (decision 11) so writing gets the whole display without losing the way back.
//
//  Worst case that must not break: with the keyboard up, roughly 350pt of
//  editor height remains. Chrome must *retract, not compress*, which is why the
//  strip and the tab bar are removed from the layout rather than shrunk.
//

#if os(iOS)
import SwiftUI

/// The places the tab bar switches between. The open note is deliberately not
/// one of them — it is the now-playing track, not a destination.
///
/// The design also calls for an AI place here (decision 7). It is absent
/// because the Assistant and Ask Library views are still macOS-only; a tab that
/// led nowhere would be worse than no tab. See docs/unimplemented.md.
enum CompactPlace: String, CaseIterable, Identifiable {
    case notes, search, tags

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: "Notes"
        case .search: "Search"
        case .tags: "Tags"
        }
    }

    var systemImage: String {
        switch self {
        case .notes: "folder"
        case .search: "magnifyingglass"
        case .tags: "number"
        }
    }
}

struct CompactShell<Places: View, Editor: View>: View {
    @Binding var place: CompactPlace
    /// The note currently open, if any — what the mini strip represents.
    let openNoteTitle: String?
    /// Whether the note is filling the screen rather than sitting in the strip.
    @Binding var noteIsExpanded: Bool

    /// The tab bar's destinations, built by the caller for the selected place.
    @ViewBuilder var places: (CompactPlace) -> Places
    /// The editor for the open note.
    @ViewBuilder var editor: () -> Editor

    /// Set by the editor's scroll position and the keyboard. Chrome retracts
    /// when either says the user is reading or writing rather than navigating.
    @State private var chromeRetracted = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $place) {
                ForEach(CompactPlace.allCases) { place in
                    places(place)
                        .tabItem { Label(place.title, systemImage: place.systemImage) }
                        .tag(place)
                }
            }

            if let openNoteTitle, !chromeRetracted {
                miniStrip(title: openNoteTitle)
                    // Sits directly above the tab bar, like the now-playing bar.
                    .padding(.bottom, ShellMetrics.bottomTabBar)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: chromeRetracted)
        .fullScreenCover(isPresented: $noteIsExpanded) {
            expandedNote
        }
    }

    // MARK: - The mini strip

    private func miniStrip(title: String) -> some View {
        Button {
            noteIsExpanded = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text(title)
                    .lineLimit(1)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                Image(systemName: "chevron.up")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: ShellMetrics.miniStrip)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("shell.miniStrip")
        .accessibilityLabel("Open \(title)")
        .accessibilityHint("Shows the note you are editing full screen")
    }

    // MARK: - The note, full screen

    /// Expanded, the note *is* the screen — there is no room to spend on
    /// anything else, and text outranks everything under pressure.
    private var expandedNote: some View {
        NavigationStack {
            editor()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            noteIsExpanded = false
                        } label: {
                            Label("Back", systemImage: "chevron.down")
                        }
                        .accessibilityLabel("Back to \(place.title)")
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
        }
        // Retract chrome while the keyboard is up: 44pt of tab bar is 44pt the
        // caret doesn't have (decision 11).
        .onAppear { chromeRetracted = true }
        .onDisappear { chromeRetracted = false }
    }
}
#endif
