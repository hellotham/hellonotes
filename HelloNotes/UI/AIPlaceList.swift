//
//  AIPlaceList.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  The AI place — decision 7's fourth compact tab, on both platforms.
//
//  It was `aiPlace`, a `private var` on `iOSContentView`, which is why the Mac's
//  compact shell had nothing to put in this tab and therefore no compact shell
//  at all. Everything it draws comes from `AIActions` and a handful of optional
//  closures, both of which each shell already builds for the menu bar — so this
//  is the same furniture, not a second AI surface.
//
//  Every row is disabled rather than hidden when it cannot apply, with a footer
//  saying which of "no note" or "no provider" is the reason. A row that vanishes
//  teaches you nothing; a row that is present and does nothing teaches you the
//  wrong thing.
//
//  Drawn with the compact places' own rows and headings, not a `List`: a list
//  is 13pt rows on the Mac and 17pt rows in inset boxes on iOS, so the same
//  tab was two different screens. The place's title is its `CompactPlaceBar`,
//  which the shell puts above this.
//

import SwiftUI

struct AIPlaceList: View {
    /// The note-scoped actions, or nil when there is no note open *or* no
    /// provider that can answer. Both are reasons to disable, and the footer
    /// distinguishes them.
    var ai: AIActions?
    /// Whether there are notes to ask about at all.
    var canAsk: Bool
    var askLibrary: () -> Void
    /// Nil when there is no note to review links in.
    var reviewLinks: (() -> Void)?
    /// Nil when there is no collection to write the new note into.
    var compose: (() -> Void)?
    var assistant: () -> Void
    /// Nil where the platform reaches AI settings another way — the Mac has a
    /// Preferences tab, so it does not need a row here.
    var aiSettings: (() -> Void)?

    /// Whether a note is open, for the footer's wording. Supplied separately
    /// because `ai` is nil for two different reasons.
    var hasOpenNote: Bool = true

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                row("Ask Your Library", systemImage: "sparkles.rectangle.stack") { askLibrary() }
                    .disabled(!canAsk)
                row("New Note from a Prompt…", systemImage: "sparkles.square.filled.on.square") { compose?() }
                    .disabled(compose == nil)
                footer("Answers are drawn from the notes you have open, with links back to them.")

                header("This note")
                Group {
                    row("Summarise", systemImage: "text.append") { ai?.summarize() }
                    row("Suggest Tags", systemImage: "number") { ai?.suggestTags() }
                    row("Suggest Links", systemImage: "link.badge.plus") { ai?.suggestLinks() }
                    row("Rewrite or Expand…", systemImage: "wand.and.stars") { ai?.rewriteNote() }
                }
                .disabled(ai == nil)
                // Outside the model's group: it finds links without one, as
                // the Note menu knows, and was greyed out with no model here
                // (menu.md §8, item 10; implemented.md §51.36).
                row("Review Links…", systemImage: "checklist") { reviewLinks?() }
                    .disabled(reviewLinks == nil)
                if !hasOpenNote {
                    footer("Open a note to use these.")
                } else if ai == nil {
                    footer("AI isn't available right now — AI Settings says why.")
                }

                header(nil)
                row("Assistant", systemImage: "sparkles") { assistant() }
                if let aiSettings {
                    row("AI Settings…", systemImage: "brain") { aiSettings() }
                }
            }
            .padding(.vertical, 4)
        }
        .viewport()
        .background(Chrome.Colour.chrome)
    }

    /// A command: a 12pt glyph and a 13pt title in the shell's row, dimmed
    /// when it cannot apply. A button, not a tap gesture, so `disabled` stops
    /// it as well as greying it.
    private func row(_ title: String, systemImage: String,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ChromeRowFrame(height: Chrome.Metric.rowNote, accent: .clear) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(Chrome.Typeface.rowIcon)
                        .foregroundStyle(Chrome.Colour.secondaryLabel)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    ChromeLine(title, size: 13)
                    Spacer(minLength: 8)
                }
            }
        }
        .buttonStyle(ChromePlainStyle())
    }

    /// A group's heading — or, untitled, the gap between groups — as the other
    /// compact places draw theirs.
    @ViewBuilder
    private func header(_ title: String?) -> some View {
        if let title {
            ChromeLine(title, size: 11, weight: .semibold, colour: Chrome.Colour.secondaryLabel)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)
        } else {
            Color.clear.frame(height: 12)
        }
    }

    /// What a group's footer said: why its rows are the way they are.
    private func footer(_ text: String) -> some View {
        Text(text)
            .font(Chrome.Style.subheadline)
            .foregroundStyle(Chrome.Colour.secondaryLabel)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
}
