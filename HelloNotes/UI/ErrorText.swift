//
//  ErrorText.swift
//  HelloNotes
//
//  Created by Chris Tham on 27/8/2026.
//
//  An error message you can actually get out of the app.
//
//  Six places rendered a failure as
//  `Text(message).lineLimit(3).help(message)` and none of them were
//  selectable. That shape fails twice over. `.help()` is a **macOS tooltip**,
//  so on iPhone and iPad the truncated two-thirds of a message had no route to
//  the screen at all; and on the Mac, where hovering did reveal it, a tooltip
//  cannot be selected — so the one thing a person wants to do with a provider
//  error, paste it into a bug report or a search, was the one thing the app
//  would not let them do. A user hitting two different provider failures in a
//  row could describe neither.
//
//  So: no truncation, selectable, and a **Copy button**. The button is not
//  belt-and-braces — selecting a `.caption2` run with a fingertip is miserable,
//  and `.textSelection` in a `List` row is unreliable on both platforms. One
//  tap is the only affordance that works everywhere, which is why it is the one
//  that is always present.
//

import SwiftUI

/// A failure, shown in full and copyable on both platforms.
///
/// The appearance knobs exist so this can replace six *differently styled*
/// call sites without flattening them into one look: the inspector's panes are
/// dense red `.caption2` with no icon, the AI sheets are orange `.callout`
/// behind a warning triangle. Those differences are deliberate — what they
/// should never have differed on is whether the text could be read and copied.
struct ErrorText: View {
    let message: String
    /// Matches the surrounding density — the inspector's panes run at
    /// `.caption2`, the AI sheets at `.callout`.
    var font: Font = .caption2
    /// A leading glyph, where the site had one.
    var systemImage: String? = nil
    var tint: Color = .red

    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(font)
                    .foregroundStyle(tint)
            }
            Text(message)
                .font(font)
                .foregroundStyle(tint)
                .textSelection(.enabled)
                // Wrap rather than truncate. A provider error's useful half is
                // usually its tail — the HTTP status and the model's own
                // explanation — which is exactly what `lineLimit(3)` removed.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Clipboard.copy(message)
                copied = true
                // Long enough to notice, short enough that the control is
                // ready again if the first paste went somewhere wrong.
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "document.on.document")
                    .font(font)
                    .foregroundStyle(copied ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityLabel(copied ? "Error copied" : "Copy error message")
            .help(copied ? "Copied" : "Copy this message")
        }
    }
}
