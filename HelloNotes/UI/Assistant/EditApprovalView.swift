//
//  EditApprovalView.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  The approval card shown when a tool wants to change a file. Presents the
//  proposed diff and Approve / Deny / Allow-all controls. Rendered as an overlay
//  inside the assistant window (avoids nested sheets).
//

import SwiftUI

struct EditApprovalView: View {
    let prompt: PermissionBroker.Prompt
    let broker: PermissionBroker

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Chrome.Colour.orange)
                    Text(prompt.title).font(Chrome.Style.headline)
                }
                Text(prompt.detail).font(Chrome.Style.callout).foregroundStyle(Chrome.Colour.secondaryLabel)
                // The model can propose several changes at once; they queue, and
                // saying so stops the next card reading as the same one again.
                if broker.queuedCount > 0 {
                    Text(broker.queuedCount == 1 ? "1 more change is waiting." : "\(broker.queuedCount) more changes are waiting.")
                        .font(Chrome.Style.caption).foregroundStyle(Chrome.Colour.secondaryLabel)
                }

                if let diff = prompt.diff { DiffPreview(diff: diff, requestID: prompt.id) }

                HStack {
                    Button("Allow all this session") {
                        broker.respond(approved: true, allowAll: true)
                    }
                    .help("Approve the rest of this conversation's changes without asking. Deleting a note still asks.")
                    Spacer()
                    Button("Deny", role: .cancel) { broker.respond(approved: false) }
                        .keyboardShortcut(.cancelAction)
                    Button("Approve") { broker.respond(approved: true) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(ChromePushStyle(prominent: true))
                }
            }
            .padding(18)
            .frame(maxWidth: 460)
            // A card of the content colour, not a material: `.regularMaterial`
            // is a different blur and tint on each platform.
            .background(Chrome.Colour.content, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Chrome.Colour.separator))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
    }
}

/// The proposed change as a line diff.
///
/// **Computed once per request, off the main actor, and laid out lazily.**
/// This used to diff inside `body` and give every line its own `Text` in a plain
/// `VStack`, and `delete_note` and `write_note` put the whole note in the diff:
/// measured, a 2,000-line note took 162 ms to lay out and a 10,000-line one
/// 898 ms — a frozen app each time the card appeared, and again each time the
/// count of waiting changes moved. Rows are capped as well; the opening of a
/// long note identifies it, and nobody reads ten thousand lines on a card.
private struct DiffPreview: View {
    let diff: EditDiff
    let requestID: UUID

    @State private var lines: [DiffLine] = []
    @State private var hiddenCount = 0

    private static let rowLimit = 1_000

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(diff.path, systemImage: "doc.text").font(Chrome.Style.caption.monospaced()).foregroundStyle(Chrome.Colour.secondaryLabel)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        let line = lines[index]
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(Chrome.Style.sized(10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(line.kind.background)
                            .foregroundStyle(line.kind.foreground)
                    }
                    if hiddenCount > 0 {
                        Text(hiddenCount == 1 ? "1 more line not shown" : "\(hiddenCount) more lines not shown")
                            .font(Chrome.Style.caption).foregroundStyle(Chrome.Colour.secondaryLabel)
                            .padding(6)
                    }
                }
            }
            .frame(maxHeight: 260)
            .background(Chrome.Colour.quaternaryLabel.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        }
        .task(id: requestID) {
            let diff = diff
            let all = await offMain { DiffLine.lines(for: diff) }
            lines = Array(all.prefix(Self.rowLimit))
            hiddenCount = max(0, all.count - Self.rowLimit)
        }
    }
}

// MARK: - Minimal line diff

private nonisolated struct DiffLine: Sendable {
    enum Kind: Sendable { case same, add, remove }
    let text: String
    let kind: Kind

    /// A cheap prefix/suffix-anchored line diff — good enough to preview an edit.
    static func lines(for diff: EditDiff) -> [DiffLine] {
        if diff.isCreation { return split(diff.after).map { DiffLine(text: "+ " + $0, kind: .add) } }
        if diff.isDeletion { return split(diff.before).map { DiffLine(text: "- " + $0, kind: .remove) } }
        let before = split(diff.before), after = split(diff.after)
        var head = 0
        while head < before.count && head < after.count && before[head] == after[head] { head += 1 }
        var tail = 0
        while tail < (before.count - head) && tail < (after.count - head)
            && before[before.count - 1 - tail] == after[after.count - 1 - tail] { tail += 1 }

        var out: [DiffLine] = []
        for line in before.prefix(head).suffix(3) { out.append(DiffLine(text: "  " + line, kind: .same)) }
        for line in before[head..<(before.count - tail)] { out.append(DiffLine(text: "- " + line, kind: .remove)) }
        for line in after[head..<(after.count - tail)] { out.append(DiffLine(text: "+ " + line, kind: .add)) }
        for line in after.suffix(tail).prefix(3) { out.append(DiffLine(text: "  " + line, kind: .same)) }
        return out.isEmpty ? [DiffLine(text: "(no textual change)", kind: .same)] : out
    }

    private static func split(_ text: String) -> [String] {
        text.isEmpty ? [] : text.components(separatedBy: "\n")
    }
}

private extension DiffLine.Kind {
    var background: Color {
        switch self {
        case .same: .clear
        case .add: Chrome.Colour.green.opacity(0.18)
        case .remove: Chrome.Colour.red.opacity(0.18)
        }
    }
    var foreground: Color {
        switch self {
        case .same: Chrome.Colour.secondaryLabel
        case .add: Chrome.Colour.green
        case .remove: Chrome.Colour.red
        }
    }
}
