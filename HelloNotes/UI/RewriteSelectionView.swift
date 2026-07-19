//
//  RewriteSelectionView.swift
//  HelloNotes
//
//  Created by Chris Tham on 17/7/2026.
//
//  "Rewrite with AI…" for the editor's selection: pick a canned task or
//  type an instruction, preview the provider's rewrite, then Replace the
//  selection (undoable — it applies through the editor's normal edit path)
//  or Insert Below. Complements Apple Writing Tools with the user's own
//  provider choice and free-form instructions.
//

#if os(macOS)
import SwiftUI

struct RewriteSelectionView: View {
    let intelligence: IntelligenceService
    /// The selected text being rewritten.
    let original: String
    /// Replace the selection with the rewrite.
    let onReplace: (String) -> Void
    /// Insert the rewrite on a new paragraph after the selection.
    let onInsertBelow: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var instruction = ""
    @State private var result: String?
    @State private var busy = false
    @State private var errorText: String?
    @State private var runTask: Task<Void, Never>?

    /// One-tap rewrite tasks. Each is just a saved instruction — the same
    /// path as the free-form field.
    private static let tasks: [(label: String, instruction: String)] = [
        ("Improve writing", "Improve the writing: clearer, tighter, better flow. Keep the meaning and tone."),
        ("Fix grammar", "Fix grammar, spelling and punctuation only. Change nothing else."),
        ("Make concise", "Make this significantly more concise without losing key information."),
        ("Elaborate", "Expand with more detail and explanation, keeping the author's voice."),
        ("Simplify", "Rewrite in plain, simple language a general reader understands."),
        ("To bullet points", "Convert into a well-organized Markdown bullet list of the key points."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Rewrite Selection", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Text(intelligence.providerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Done") { cancelAndDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if case .unavailable(let reason) = intelligence.availability {
                        Label(reason, systemImage: "sparkles.slash")
                            .foregroundStyle(.secondary).font(.callout)
                    }

                    // The selection being rewritten.
                    Text(original)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

                    // Canned tasks.
                    FlowLayoutish(items: Self.tasks.map(\.label)) { label in
                        guard let task = Self.tasks.first(where: { $0.label == label }) else { return }
                        run(task.instruction)
                    }
                    .disabled(busy || !intelligence.isAvailable)

                    // Free-form instruction.
                    HStack(spacing: 8) {
                        TextField("Or describe the rewrite…", text: $instruction)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { runCustom() }
                        Button("Rewrite", action: runCustom)
                            .keyboardShortcut(.defaultAction)
                            .disabled(busy || !intelligence.isAvailable
                                      || instruction.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Rewriting…").foregroundStyle(.secondary)
                        }
                    }
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.callout)
                    }
                    if let result {
                        Divider()
                        Text(result)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

                        HStack {
                            Button("Replace Selection") {
                                onReplace(result)
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Insert Below") {
                                onInsertBelow(result)
                                dismiss()
                            }
                            Spacer()
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 520, height: 480)
    }

    private func runCustom() {
        let text = instruction.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        run(text)
    }

    private func run(_ taskInstruction: String) {
        guard intelligence.isAvailable else { return }
        runTask?.cancel()
        busy = true
        errorText = nil
        result = nil
        runTask = Task {
            do {
                let rewritten = try await intelligence.rewrite(original, instruction: taskInstruction)
                guard !Task.isCancelled else { return }
                result = rewritten.isEmpty ? nil : rewritten
                if rewritten.isEmpty { errorText = "The model returned nothing. Try rephrasing the instruction." }
            } catch {
                guard !Task.isCancelled else { return }
                errorText = "Couldn't rewrite that. \(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func cancelAndDismiss() {
        runTask?.cancel()
        dismiss()
    }
}

/// A simple wrapping row of task chips (avoids depending on Layout for a
/// handful of buttons; wraps into rows of three).
private struct FlowLayoutish: View {
    let items: [String]
    let action: (String) -> Void

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 120), spacing: 8)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { label in
                Button(label) { action(label) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
#endif
