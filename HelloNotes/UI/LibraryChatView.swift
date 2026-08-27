//
//  LibraryChatView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

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
    /// A question to open pre-filled and asked immediately — set when the window
    /// was raised by "Ask your library about this" on a selection, where making
    /// the user press Ask again would only ask them to confirm what they just did.
    var initialQuestion: String? = nil

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
                        ErrorText(message: errorText, font: .callout,
                                  systemImage: "exclamationmark.triangle", tint: .orange)
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
                            // `.link` is macOS-only; `.plain` with the accent
                            // reads the same on both and keeps one code path.
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                        }
                    }
                }
                .padding()
            }
        }
        .panelFrame(width: 520, height: 560)
        // `.task(id:)` rather than `.onAppear`: the window takes its pending
        // question from the library *after* the first render, so an appear-only
        // hook would run while there was still nothing to ask.
        .task(id: initialQuestion) {
            guard let initialQuestion, question.isEmpty else { return }
            question = initialQuestion
            ask()
        }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        busy = true
        errorText = nil
        answer = nil
        Task {
            // Retrieval reads note files on demand (the search index no longer
            // keeps content in memory), so it runs off the main actor.
            let retrieved = await retrieve(q)
            sources = retrieved
            let context = await offMain {
                retrieved.map { note in
                    (title: note.title,
                     text: (try? FileIO.readString(at: note.fileURL)) ?? "")
                }
            }
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

    /// Full-text hits across every collection, best snippets first.
    private func fullText(_ q: String) async -> [Note] {
        var hits: [Note] = []
        for search in searches {
            hits += await search.fullTextResults(query: q).map(\.note)
        }
        return hits
    }

    /// Top notes by keyword-overlap with the question; falls back to full-text.
    /// Scans the collection's files off the main actor — a question is a
    /// user-initiated, model-latency-dominated operation, so the read pass is
    /// negligible next to the answer itself.
    private func retrieve(_ q: String) async -> [Note] {
        let stop: Set<String> = ["the", "and", "for", "with", "what", "which", "when", "where",
                                 "how", "does", "did", "are", "was", "were", "that", "this", "from", "about", "your", "have"]
        let keywords = q.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 3 && !stop.contains($0) }

        if keywords.isEmpty {
            return await Array(fullText(q).prefix(4))
        }

        let candidates = notes
        let scored = await offMain { () -> [(Note, Int)] in
            candidates.compactMap { note in
                guard let text = (try? FileIO.readString(at: note.fileURL))?.lowercased()
                else { return nil }
                let score = keywords.reduce(0) { acc, kw in
                    acc + max(0, text.components(separatedBy: kw).count - 1)
                }
                return score > 0 ? (note, score) : nil
            }
            .sorted { $0.1 > $1.1 }
        }

        if scored.isEmpty {
            return await Array(fullText(q).prefix(4))
        }
        return Array(scored.prefix(4).map(\.0))
    }
}
