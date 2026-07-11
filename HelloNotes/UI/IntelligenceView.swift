//
//  IntelligenceView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import SwiftUI

/// A sheet offering on-device intelligence for the open note: summarize,
/// suggest tags, suggest links. Results are shown for review and applied only
/// when the user chooses.
struct IntelligenceView: View {
    let noteText: String
    let existingTags: [String]
    let linkCandidates: [String]
    var onInsertSummary: (String) -> Void
    var onAddTags: ([String]) -> Void
    var onAddLinks: ([String]) -> Void
    var onReplaceBody: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var busy = false
    @State private var errorText: String?
    @State private var summary: String?
    @State private var tags: [String] = []
    @State private var links: [String] = []
    @State private var expanded: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Intelligence", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if case .unavailable(let reason) = NoteIntelligence.availability {
                        Label(reason, systemImage: "sparkles.slash")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        actions
                    }

                    if busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Thinking on-device…").foregroundStyle(.secondary)
                        }
                    }
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                    if let summary { summarySection(summary) }
                    if !tags.isEmpty { tagsSection }
                    if !links.isEmpty { linksSection }
                    if let expanded { expandedSection(expanded) }
                }
                .padding()
            }
        }
        .frame(width: 460, height: 460)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { run { summary = try await NoteIntelligence.summarize(noteText) } } label: {
                Label("Summarize", systemImage: "text.append")
            }
            Button { run { tags = try await NoteIntelligence.suggestTags(for: noteText, existing: existingTags) } } label: {
                Label("Suggest Tags", systemImage: "number")
            }
            Button { run { links = try await NoteIntelligence.suggestLinks(for: noteText, candidates: linkCandidates) } } label: {
                Label("Suggest Links", systemImage: "link")
            }
            Button { run { expanded = try await NoteIntelligence.expand(noteText) } } label: {
                Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        }
        .disabled(busy)
    }

    private func expandedSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Expanded Note").font(.subheadline.bold())
            Text(text)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Replace Note Body") { onReplaceBody(text); dismiss() }
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
            }
        }
    }

    private func summarySection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary").font(.subheadline.bold())
            Text(text)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Insert as Callout") { onInsertSummary(text); dismiss() }
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
            }
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggested Tags").font(.subheadline.bold())
            FlowChips(items: tags.map { "#\($0)" })
            Button("Add \(tags.count) Tag\(tags.count == 1 ? "" : "s")") { onAddTags(tags); dismiss() }
        }
    }

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggested Links").font(.subheadline.bold())
            FlowChips(items: links.map { "[[\($0)]]" })
            Button("Add \(links.count) Link\(links.count == 1 ? "" : "s")") { onAddLinks(links); dismiss() }
        }
    }

    /// Run an async intelligence action with shared busy/error handling.
    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        errorText = nil
        Task {
            do { try await work() }
            catch { errorText = "Couldn't complete that. \(error.localizedDescription)" }
            busy = false
        }
    }
}

/// A simple wrapping row of pill-shaped chips.
private struct FlowChips: View {
    let items: [String]
    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(.callout, design: .rounded))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
        }
    }
}

/// Minimal flow layout so chips wrap to the available width.
private struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
#endif
