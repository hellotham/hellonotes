//
//  CompactShell.swift
//  HelloNotes
//
//  The phone (and the 320pt iPad slice): the editor is the screen.
//
//  Rails and a list column mean nothing at this width, so this is not the wide
//  shell rearranged — it is the Apple Music model (decision 6). A bottom tab
//  bar carries the app's *places*; the note being edited persists above it as a
//  mini strip, one tap from full screen, where it covers both (decision 11) so
//  writing gets the whole display without losing the way back.
//
//  Ungated, and drawn by the app: the tab bar, each place's bar and the
//  expanded note's bar are the app's own, so a Mac window squeezed to this
//  width and an iPhone draw the same picture. It once used three iOS-only
//  modifiers — `fullScreenCover`, `.topBarLeading`,
//  `navigationBarTitleDisplayMode` — with a macOS stand-in for each; there is
//  nothing left to stand in for.
//
//  The gate was doing something the contract forbids:
//  `ShellKind` resolves `.compact` at 250pt on *either* platform (it is in the
//  contract's own scene table as "Stage Mgr tiny"), and at that size the iPad
//  got this architecture while the Mac's `compact:` slot got the editor alone.
//  A Mac window squeezed into a Stage Manager tile therefore had no way to
//  reach another note at all.
//
//  Both platforms pass this now, `tagList` and `aiPlace` included: one
//  `ContentView` fills the places on both.
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

    /// Places already opened. Each stays built once visited, as a `TabView`'s
    /// tabs do, so coming back to one keeps its scroll position and search.
    @State private var visited: Set<CompactPlace> = []

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(CompactPlace.allCases) { candidate in
                    if candidate == place || visited.contains(candidate) {
                        places(candidate)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .opacity(candidate == place ? 1 : 0)
                            .allowsHitTesting(candidate == place)
                            .accessibilityHidden(candidate != place)
                    }
                }
            }
            if let openNoteTitle {
                // Directly above the tab bar, like the now-playing bar.
                miniStrip(title: openNoteTitle)
            }
            CompactTabBar(selection: $place)
        }
        .overlay {
            if noteIsExpanded {
                expandedNote
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.snappy(duration: 0.22), value: noteIsExpanded)
        .onChange(of: place, initial: true) { _, now in visited.insert(now) }
    }

    // MARK: - The mini strip

    private func miniStrip(title: String) -> some View {
        Button {
            noteIsExpanded = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                ChromeLine(title, size: 12, weight: .medium)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up")
                    .font(Chrome.Style.footnote.weight(.semibold))
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
            }
            .padding(.horizontal, 14)
            .frame(height: ShellMetrics.miniStrip)
            .frame(maxWidth: .infinity)
            .background(Chrome.Colour.chrome)
            .overlay(alignment: .top) { ChromeDivider() }
            .contentShape(.rect)
        }
        .buttonStyle(ChromePlainStyle())
        .accessibilityIdentifier("shell.miniStrip")
        .accessibilityLabel("Open \(title)")
        .accessibilityHint("Shows the note you are editing full screen")
    }

    // MARK: - The note, full screen

    /// Expanded, the note *is* the screen — there is no room to spend on
    /// anything else, and text outranks everything under pressure.
    ///
    /// Drawn over the shell rather than presented: a `fullScreenCover` on iOS
    /// and a sheet on the Mac (which has no full-screen cover) were two
    /// presentations with two navigation bars. This is one view with the app's
    /// own bar on both, and the tab bar and strip beneath it are simply
    /// covered — retracted, not compressed (decision 11).
    private var expandedNote: some View {
        VStack(spacing: 0) {
            ZStack {
                ChromeLine(openNoteTitle ?? "", size: 13, weight: .semibold)
                    .padding(.horizontal, 90)
                HStack {
                    Button {
                        noteIsExpanded = false
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                            Text("Back")
                        }
                        .contentShape(.rect.inset(by: -8))
                    }
                    .buttonStyle(ChromeLinkStyle())
                    .accessibilityLabel("Back to \(place.title)")
                    Spacer()
                }
            }
            .padding(.horizontal, Chrome.Metric.barPadding)
            .frame(height: Chrome.Metric.barHeight)
            .background(Chrome.Colour.chrome)
            .overlay(alignment: .bottom) { ChromeDivider() }
            editor()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Chrome.Colour.content)
    }
}

/// The compact shell's tab bar, drawn: four places, a glyph over its name, the
/// chosen one in the accent. `TabView`'s bar is a different height, font and
/// material on each platform — and on the Mac a `TabView` is a segmented
/// control at the *top* of the window, not a bar at the bottom at all.
struct CompactTabBar: View {
    @Binding var selection: CompactPlace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CompactPlace.allCases) { place in
                let isOn = place == selection
                Button { selection = place } label: {
                    VStack(spacing: 3) {
                        Image(systemName: place.systemImage)
                            .font(.system(size: 17))
                            .frame(height: 21)
                        ChromeLine(place.title, size: 10, weight: .medium,
                                   colour: isOn ? Chrome.Colour.label : Chrome.Colour.secondaryLabel)
                    }
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Chrome.Colour.secondaryLabel))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(ChromePlainStyle())
                .accessibilityLabel(place.title)
                .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
            }
        }
        .frame(height: ShellMetrics.bottomTabBar)
        .background(Chrome.Colour.chrome.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { ChromeDivider() }
    }
}

/// A compact place's own bar: its title centred, its commands at the trailing
/// end — what each place's `NavigationStack` title bar was, drawn by the app.
struct CompactPlaceBar<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        ZStack {
            ChromeLine(title, size: 13, weight: .semibold)
                .padding(.horizontal, 90)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: Chrome.Metric.barSpacing) {
                Spacer()
                trailing()
            }
        }
        .padding(.horizontal, Chrome.Metric.barPadding)
        .frame(height: Chrome.Metric.barHeight)
        .background(Chrome.Colour.chrome)
        .overlay(alignment: .bottom) { ChromeDivider() }
    }
}

extension CompactPlaceBar where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}
