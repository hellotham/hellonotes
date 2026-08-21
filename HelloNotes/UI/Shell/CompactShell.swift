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
//  Ungated. It uses no UIKit *types*, but it did use three iOS-only SwiftUI
//  modifiers — `fullScreenCover`, `.topBarLeading` and
//  `navigationBarTitleDisplayMode` — each of which now has a macOS equivalent at
//  the bottom of this file. (Grepping for `UI…` type names said the file was
//  portable; it was the wrong question, and the compiler asked the right one.)
//
//  The gate was doing something the contract forbids:
//  `ShellKind` resolves `.compact` at 250pt on *either* platform (it is in the
//  contract's own scene table as "Stage Mgr tiny"), and at that size the iPad
//  got this architecture while the Mac's `compact:` slot got the editor alone.
//  A Mac window squeezed into a Stage Manager tile therefore had no way to
//  reach another note at all.
//
//  The Mac does not yet *pass* this — its shell has no `tagList` or `aiPlace`
//  to fill the places with, and inventing them is designing rather than
//  unifying. What is fixed here is that nothing stops it.
//
//  Worst case that must not break: with the keyboard up, roughly 350pt of
//  editor height remains. Chrome must *retract, not compress*, which is why the
//  strip and the tab bar are removed from the layout rather than shrunk.
//

import SwiftUI

/// The places the tab bar switches between. The open note is deliberately not
/// one of them — it is the now-playing track, not a destination.
///
/// The AI place is decision 7's fourth tab. It used to be absent, with the
/// reason written here: the Assistant and Ask Library views were macOS-only, and
/// a tab that led nowhere would be worse than no tab. That reason expired when
/// 1.3 brought both to iOS — the comment outlived the constraint it described,
/// which is the ordinary way a documented gap becomes a stale one.
enum CompactPlace: String, CaseIterable, Identifiable {
    case notes, search, tags, ai

    var id: String { rawValue }

    /// Where the compact shell's place is persisted.
    ///
    /// `@SceneStorage` on both. It was scene-persisted on the Mac and plain
    /// `@State` on iOS — so the platform where the compact shell is the *only*
    /// shell forgot which tab you were on every relaunch, while the platform
    /// that rarely shows it remembered.
    static let storageKey = "compactPlace"

    var title: String {
        switch self {
        case .notes: "Notes"
        case .search: "Search"
        case .tags: "Tags"
        case .ai: "AI"
        }
    }

    var systemImage: String {
        switch self {
        case .notes: "folder"
        case .search: "magnifyingglass"
        case .tags: "number"
        case .ai: "sparkles"
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
        .expandedNoteCover(isPresented: $noteIsExpanded) { expandedNote }
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
                    ToolbarItem(placement: .leadingBar) {
                        Button {
                            noteIsExpanded = false
                        } label: {
                            Label("Back", systemImage: "chevron.down")
                        }
                        .accessibilityLabel("Back to \(place.title)")
                    }
                }
                .inlineNavigationTitle()
        }
        // Retract chrome while the keyboard is up: 44pt of tab bar is 44pt the
        // caret doesn't have (decision 11).
        .onAppear { chromeRetracted = true }
        .onDisappear { chromeRetracted = false }
    }
}

// MARK: - The three modifiers this shell needs that iOS spells differently

private extension View {
    /// The open note, filling the screen.
    ///
    /// `fullScreenCover` does not exist on macOS — there is no "full screen" for
    /// a view inside a window — so a sheet is the equivalent presentation. Same
    /// modal, same dismissal, the size the platform gives it.
    @ViewBuilder
    func expandedNoteCover<Cover: View>(isPresented: Binding<Bool>,
                                        @ViewBuilder content: @escaping () -> Cover) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented, content: content)
        #endif
    }

    /// A compact title bar, where the platform has the concept.
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

private extension ToolbarItemPlacement {
    /// The leading end of the bar, under each platform's name for it.
    static var leadingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }
}
