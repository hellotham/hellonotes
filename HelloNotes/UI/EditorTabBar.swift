//
//  EditorTabBar.swift
//  HelloNotes
//
//  The strip of open notes — one view, both platforms.
//
//  There were two: this file, gated to macOS, and `tabStrip` written inline in
//  `iOSContentView`. Same job, and they had drifted in three ways.
//
//  The close button carries an accessibility label on iPad and carried none on
//  the Mac, so VoiceOver there announced a row of unlabelled buttons.
//
//  Neither read `ShellContext.tabBarHeight`. The contract defines it —
//  `prefersTouch ? 44 : 32`, "tab bars are never removed; they only change
//  height (HIG: 44pt touch)" — and the Mac hard-coded 30 while iPad used
//  padding, so the one number the contract states about this view was consulted
//  by nothing. That is the same shape as `sortOrder`: a value with a rule and no
//  reader.
//
//  And the selection tint: `selectedContentBackgroundColor` on one side,
//  `.selection` on the other. `.selection` is the cross-platform spelling of the
//  same idea, so it is what both use.
//

import SwiftUI

struct EditorTabBar: View {
    let notes: [Note]
    let activeID: Note.ID?
    let onSelect: (Note.ID) -> Void
    /// Closing goes through the caller so a *background* tab closing cannot
    /// move the selection off the note being read.
    let onClose: (Note.ID) -> Void

    @Environment(\.shell) private var shell

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(notes) { tab($0) }
            }
            .padding(.horizontal, 2)
        }
        // The contract's number, not a literal: 44pt where a finger is doing the
        // tapping, 32 where a pointer is.
        .frame(height: shell.tabBarHeight)
        .background(.bar)
    }

    private func tab(_ note: Note) -> some View {
        let isActive = note.id == activeID
        return HStack(spacing: 4) {
            Text(note.title)
                .lineLimit(1)
                .font(.subheadline)
                .fontWeight(isActive ? .semibold : .regular)

            Button { onClose(note.id) } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(note.title)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minHeight: shell.tabBarHeight - 8)
        .background(isActive ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 7))
        .foregroundStyle(isActive ? Color.primary : .secondary)
        // The whole tab selects, padding and vertical slack included. Wrapping
        // only the `Text` in a `Button` shrank the target to the title's glyph
        // box — about 17pt tall inside a 44pt touch bar — and left this
        // `contentShape` with no gesture attached to it, so tapping beside a
        // title or anywhere in the margin did nothing.
        .contentShape(.rect)
        .onTapGesture { onSelect(note.id) }
    }
}
