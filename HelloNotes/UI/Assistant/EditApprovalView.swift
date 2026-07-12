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

#if os(macOS)
import SwiftUI

struct EditApprovalView: View {
    let prompt: PermissionBroker.Prompt
    let broker: PermissionBroker

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    Text(prompt.title).font(.headline)
                }
                Text(prompt.detail).font(.callout).foregroundStyle(.secondary)

                if let diff = prompt.diff { diffView(diff) }

                HStack {
                    Button("Allow all this session") {
                        broker.respond(approved: true, allowAll: true)
                    }
                    .help("Auto-approve every change for the rest of this chat")
                    Spacer()
                    Button("Deny", role: .cancel) { broker.respond(approved: false) }
                        .keyboardShortcut(.cancelAction)
                    Button("Approve") { broker.respond(approved: true) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(18)
            .frame(width: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
            .shadow(radius: 20)
        }
    }

    @ViewBuilder
    private func diffView(_ diff: EditDiff) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(diff.path, systemImage: "doc.text").font(.caption.monospaced()).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diffLines(diff).enumerated()), id: \.offset) { _, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(line.kind.color)
                            .foregroundStyle(line.kind.fg)
                    }
                }
            }
            .frame(maxHeight: 260)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Minimal line diff

    private struct DiffLine { enum Kind { case same, add, remove
        var color: Color { switch self { case .same: return .clear; case .add: return .green.opacity(0.18); case .remove: return .red.opacity(0.18) } }
        var fg: Color { switch self { case .same: return .secondary; case .add: return .green; case .remove: return .red } }
    }
        let text: String; let kind: Kind
    }

    /// A cheap prefix/suffix-anchored line diff — good enough to preview an edit.
    private func diffLines(_ diff: EditDiff) -> [DiffLine] {
        if diff.isCreation { return diff.after.lines.map { DiffLine(text: "+ " + $0, kind: .add) } }
        if diff.isDeletion { return diff.before.lines.map { DiffLine(text: "- " + $0, kind: .remove) } }
        let before = diff.before.lines, after = diff.after.lines
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
}

private extension String {
    var lines: [String] { isEmpty ? [] : components(separatedBy: "\n") }
}
#endif
