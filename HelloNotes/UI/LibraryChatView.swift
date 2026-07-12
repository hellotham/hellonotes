//
//  LibraryChatView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import SwiftUI

/// "Ask your library": retrieves the most relevant notes for a question across
/// every open collection and asks the model to answer, grounded in those notes
/// and citing them. Retrieval is keyword-overlap over each collection's search
/// index (no embeddings) — simple, local, and good enough to point the model at
/// the right notes.
struct LibraryChatView: View {
    let intelligence: IntelligenceService
    let notes: [Note]
    /// One search index per open collection (retrieval spans the whole library).
    let searches: [CollectionSearchModel]
    var onOpenNote: (Note) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var question = ""
    @State private var busy = false
    @State private var answer: String?
    @State private var sources: [Note] = []
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Ask Your Library", systemImage: "sparkles.rectangle.stack")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()

            HStack(spacing: 8) {
                TextField("Ask a question about your notes…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(ask)
                Button("Ask", action: ask)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if case .unavailable(let reason) = intelligence.availability {
                        Label(reason, systemImage: "sparkles.slash")
                            .foregroundStyle(.secondary).font(.callout)
                    }
                    if busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Searching your library and thinking…").foregroundStyle(.secondary)
                        }
                    }
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.callout)
                    }
                    if let answer {
                        Text(answer)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !sources.isEmpty {
                        Divider()
                        Text("Sources").font(.subheadline.bold())
                        ForEach(sources) { note in
                            Button { onOpenNote(note) } label: {
                                Label(note.title, systemImage: "doc.text")
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 520, height: 560)
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        busy = true
        errorText = nil
        answer = nil
        let retrieved = retrieve(q)
        sources = retrieved
        let context = retrieved.map { (title: $0.title, text: text(of: $0) ?? "") }
        Task {
            do {
                if context.isEmpty {
                    answer = "I couldn't find any notes related to that."
                } else {
                    answer = try await intelligence.answer(question: q, context: context)
                }
            } catch {
                errorText = "Couldn't answer that. \(error.localizedDescription)"
            }
            busy = false
        }
    }

    /// The note's text from whichever collection's index has it.
    private func text(of note: Note) -> String? {
        searches.lazy.compactMap { $0.text(of: note) }.first
    }

    /// Full-text hits across every collection, best snippets first.
    private func fullText(_ q: String) -> [Note] {
        searches.flatMap { $0.fullTextResults(query: q) }.map(\.note)
    }

    /// Top notes by keyword-overlap with the question; falls back to full-text.
    private func retrieve(_ q: String) -> [Note] {
        let stop: Set<String> = ["the", "and", "for", "with", "what", "which", "when", "where",
                                 "how", "does", "did", "are", "was", "were", "that", "this", "from", "about", "your", "have"]
        let keywords = q.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 3 && !stop.contains($0) }

        if keywords.isEmpty {
            return Array(fullText(q).prefix(4))
        }

        let scored: [(Note, Int)] = notes.compactMap { note in
            guard let text = text(of: note)?.lowercased() else { return nil }
            let score = keywords.reduce(0) { acc, kw in
                acc + max(0, text.components(separatedBy: kw).count - 1)
            }
            return score > 0 ? (note, score) : nil
        }
        .sorted { $0.1 > $1.1 }

        if scored.isEmpty {
            return Array(fullText(q).prefix(4))
        }
        return Array(scored.prefix(4).map(\.0))
    }
}
#endif
