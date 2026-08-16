//
//  ComposeNoteView.swift
//  HelloNotes
//
//  Created by Chris Tham on 16/8/2026.
//
//  Ask for a note; read it before it exists.
//
//  The draft step is not politeness. Everything else the AI does in this app
//  lands in a panel — a summary, a list of tags — where a bad answer is
//  obviously a bad answer sitting in a panel. This one creates a *file*, and a
//  file in a notebook is indistinguishable from something you wrote. So the
//  draft is shown, in full and editable, and the note does not exist until the
//  Create button is pressed. Cancel leaves nothing behind.
//

import SwiftUI

struct ComposeNoteView: View {
    @Bindable var composer: NoteComposer
    /// Whether each mode can run on the configured provider, and why not.
    var availability: (NoteComposer.Mode) -> String?
    var onRun: (String, NoteComposer.Mode, Int) -> Void
    var onCreate: (NoteDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var mode: NoteComposer.Mode = .write
    @State private var depth = 3
    /// The draft as edited here. Kept separate from the composer's phase so
    /// re-running replaces it and typing in it does not.
    @State private var editedTitle = ""
    @State private var editedBody = ""
    @FocusState private var promptFocused: Bool

    private var blockedReason: String? { availability(mode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .panelFrame(width: 620, height: 560)
        .onAppear { promptFocused = true }
        .onChange(of: composer.phase) { _, phase in
            if case .ready(let draft) = phase {
                editedTitle = draft.title
                editedBody = draft.body
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Label("New Note from a Prompt", systemImage: "sparkles.square.filled.on.square")
                .font(.headline)
            Spacer()
            Button("Cancel") { composer.cancel(); dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch composer.phase {
        case .idle, .failed:
            promptForm
        case .working(let stage):
            working(stage)
        case .ready:
            draftReview
        }
    }

    private var promptForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $mode) {
                ForEach(NoteComposer.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(mode == .write
                 ? "Describe the note you want. Notes you already have on the topic are offered to the model as links."
                 : "Ask a question. It is researched on the web and lands as a cited note, linked to what you already have.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $prompt)
                .font(.body)
                .focused($promptFocused)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))

            if mode == .research {
                Stepper("Explore \(depth) sub-question\(depth == 1 ? "" : "s")", value: $depth, in: 1...4)
                    .font(.callout)
            }

            if case .failed(let message) = composer.phase {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack {
                if let blockedReason {
                    Label(blockedReason, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(mode == .write ? "Write" : "Research") {
                    onRun(prompt, mode, depth)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || blockedReason != nil)
            }
        }
        .padding(16)
    }

    private func working(_ stage: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(stage)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Stop") { composer.cancel() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    // MARK: - Draft

    @ViewBuilder
    private var draftReview: some View {
        if case .ready(let draft) = composer.phase {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Title", text: $editedTitle)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))

                Divider()

                TextEditor(text: $editedBody)
                    .font(.body.monospaced())
                    .frame(maxHeight: .infinity)

                provenance(draft)

                HStack {
                    Button("Discard") { composer.reset() }
                    Spacer()
                    Button("Create Note") {
                        onCreate(NoteDraft(title: ComposedNote.filename(editedTitle),
                                           body: editedBody))
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(editedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
        }
    }

    /// What the draft is connected to, and what it isn't.
    ///
    /// `droppedLinks` is reported rather than swallowed on purpose: the model
    /// asked to link notes that do not exist, and those links were unwrapped.
    /// Saying so is the difference between "the app checked" and "the model
    /// didn't bother" — and the second is what silence looks like.
    @ViewBuilder
    private func provenance(_ draft: NoteDraft) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !draft.linkedTitles.isEmpty {
                Label("Linked to \(list(draft.linkedTitles))", systemImage: "link")
            }
            if !draft.sources.isEmpty {
                Label("\(draft.sources.count) web source\(draft.sources.count == 1 ? "" : "s") cited",
                      systemImage: "globe")
            }
            if !draft.droppedLinks.isEmpty {
                Label("No note named \(list(draft.droppedLinks)), so \(draft.droppedLinks.count == 1 ? "that link was" : "those links were") left as plain text",
                      systemImage: "link.badge.plus")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func list(_ titles: [String]) -> String {
        let shown = titles.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
        return titles.count > 3 ? "\(shown) and \(titles.count - 3) more" : shown
    }
}
