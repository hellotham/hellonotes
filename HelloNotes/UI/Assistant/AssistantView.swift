//
//  AssistantView.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  The Assistant's window: the conversation as the session recorded it —
//  prompts, reasoning, tool calls, their results and replies — with the model
//  it is talking to, and where that model runs, always in view.
//

import SwiftUI
import FoundationModels

struct AssistantView: View {
    @Bindable var model: AssistantModel
    var onOpenSettings: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// A sheet draws its own Done; a window does not.
    @Environment(\.auxiliaryIsWindowed) private var isWindowed
    @FocusState private var inputFocused: Bool

    private var models: LanguageModels { model.settings.models }

    /// Whether this conversation can read and change notes: agent mode, on a
    /// model that can call tools.
    private var usesTools: Bool { model.agentMode && model.canUseTools }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .panelFrame(width: 620, height: 680)
        .onAppear { inputFocused = true }
        .overlay {
            if let broker = model.permissions, let prompt = broker.prompt {
                EditApprovalView(prompt: prompt, broker: broker)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            // The sheet's own bar already says Assistant, and carries the Done.
            if isWindowed {
                Label("Assistant", systemImage: "sparkles").font(.headline)
            }
            Spacer()
            Toggle(isOn: $model.agentMode) {
                Image(systemName: usesTools ? "wrench.and.screwdriver.fill" : "bubble.left")
            }
            .toggleStyle(.button)
            .disabled(!model.canUseTools)
            .help(model.canUseTools
                  ? (model.agentMode ? "Can read and change the collection" : "Chat only")
                  : "\(model.modelName) can't use tools, so the Assistant chats only")
            .accessibilityLabel(usesTools ? "Agent mode on" : "Agent mode off")
            modelMenu
            Button {
                model.clear()
            } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless)
                .help("New conversation")
                .accessibilityLabel("New conversation")
                .disabled(model.entries.isEmpty && !model.isResponding)
            Button {
                onOpenSettings()
            } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("AI settings")
                .accessibilityLabel("AI settings")
            if isWindowed {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal).padding(.vertical, 10)
    }

    private var modelMenu: some View {
        Menu {
            ForEach(models.options) { option in
                Button {
                    model.settings.choose(option, forAssistant: true)
                } label: {
                    Label(models.title(of: option),
                          systemImage: option == model.settings.option(for: model.modelChoice)
                              ? "checkmark" : models.systemImage(of: option))
                }
                .disabled(!models.isAvailable(option))
            }
            Divider()
            Button("AI Settings…", action: onOpenSettings)
        } label: {
            Label(model.modelTitle, systemImage: models.systemImage(of: model.modelChoice))
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.isResponding)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.settings.hasRetiredProvider {
                        retiredNotice
                    }
                    if model.agentMode && !model.canUseTools && model.availability.isAvailable {
                        Label("\(model.modelName) can't use tools, so the Assistant can chat but won't read or change your notes. System can, and so can any MLX model AI settings doesn't mark \"Can't use tools\".",
                              systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.entries.isEmpty && !model.isResponding { emptyState }
                    ForEach(AssistantRow.rows(model.entries)) { row in
                        RowView(row: row)
                    }
                    if model.isResponding, let status = progressText {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(status).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    if let error = model.errorText {
                        ErrorText(message: error, font: .callout,
                                  systemImage: "exclamationmark.triangle", tint: .orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding()
            }
            .onChange(of: model.entries.count) { _, _ in
                withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: model.entries.last?.description.count) { _, _ in
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }

    private let bottomID = "assistant-bottom"

    /// What the Assistant is doing right now, in words — "Searching your
    /// notes…" rather than a spinner that could mean anything.
    private var progressText: String? {
        switch model.entries.last {
        case .response?:
            return nil
        case .toolCalls(let calls)?:
            if model.permissions?.prompt != nil { return "Waiting for your approval…" }
            switch calls.last?.toolName {
            case "search_notes", "grep_collection": return "Searching your notes…"
            case "read_note": return "Reading a note…"
            case "list_notes": return "Looking through your notes…"
            case "create_note", "edit_note", "write_note", "delete_note": return "Updating your notes…"
            case "web_search": return "Searching the web…"
            case "web_fetch": return "Reading a web page…"
            case "deep_research": return "Researching — this can take a few minutes…"
            case "load_skill": return "Loading a skill…"
            default: return "Working…"
            }
        default:
            return "Thinking…"
        }
    }

    private var retiredNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("HelloNotes now uses Apple Foundation Models", systemImage: "info.circle")
                .font(.headline)
            Text("The AI service you set up in an earlier version is no longer supported, and any API key HelloNotes stored for it has been removed from this device. The Assistant now uses \(model.modelName). You can choose \(LanguageModels.largerModels) in AI settings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("AI Settings…", action: onOpenSettings)
                Button("OK") { model.settings.acknowledgeRetiredProvider() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var emptyState: some View {
        if let reason = model.availability.reason {
            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("\(model.modelName) isn't available")
                    .font(.title3.bold())
                Text(reason)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("AI Settings…", action: onOpenSettings)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Chat with \(model.modelName)")
                    .font(.title3.bold())
                Label(models.privacySummary(of: model.modelChoice),
                      systemImage: model.modelChoice.runsOnDevice ? "lock" : "lock.icloud")
                    .foregroundStyle(.secondary)
                Text(usesTools
                     ? "Ask about your notes, or ask for changes — you approve every change before it's saved."
                     : "Chat only: the Assistant won't read or change your notes.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 40)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message…", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit { if model.canSend { model.send() } }
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            if model.isResponding {
                Button { model.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .help("Stop")
                .accessibilityLabel("Stop")
            } else {
                Button { model.send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(!model.canSend)
                .keyboardShortcut(.return, modifiers: [])
                .accessibilityLabel("Send")
            }
        }
        .padding()
    }
}

// MARK: - Rows

/// One visible piece of the conversation, flattened from transcript entries.
enum AssistantRow: Identifiable, Equatable {
    case prompt(id: String, text: String)
    case response(id: String, text: String)
    case reasoning(id: String, text: String)
    case toolCall(id: String, name: String, arguments: String)
    case toolOutput(id: String, name: String, text: String)

    var id: String {
        switch self {
        case .prompt(let id, _), .response(let id, _), .reasoning(let id, _),
             .toolCall(let id, _, _), .toolOutput(let id, _, _): id
        }
    }

    static func rows(_ entries: [Transcript.Entry]) -> [AssistantRow] {
        entries.flatMap { entry -> [AssistantRow] in
            switch entry {
            case .prompt(let prompt):
                return [.prompt(id: prompt.id, text: text(of: prompt.segments))]
            case .response(let response):
                let body = text(of: response.segments)
                return body.isEmpty ? [] : [.response(id: response.id, text: body)]
            case .reasoning(let reasoning):
                let body = text(of: reasoning.segments)
                return body.isEmpty ? [] : [.reasoning(id: reasoning.id, text: body)]
            case .toolCalls(let calls):
                return calls.map { .toolCall(id: "\(calls.id)-\($0.id)", name: $0.toolName, arguments: $0.arguments.jsonString) }
            case .toolOutput(let output):
                return [.toolOutput(id: "\(output.id)-output", name: output.toolName, text: text(of: output.segments))]
            case .instructions:
                return []
            @unknown default:
                return []
            }
        }
    }

    private static func text(of segments: [Transcript.Segment]) -> String {
        segments.map { segment -> String in
            switch segment {
            case .text(let text): text.content
            case .structure(let structure): structure.content.jsonString
            case .attachment: "[image]"
            @unknown default: ""
            }
        }.joined()
    }
}

private struct RowView: View {
    let row: AssistantRow
    /// Kept per row, so a reply that is still arriving is rendered a line at a
    /// time rather than from the top on every redraw.
    @State private var answer = AnswerMarkdown.Streaming()

    var body: some View {
        switch row {
        case .prompt(_, let text):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.circle.fill").foregroundStyle(Color.accentColor).frame(width: 20)
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .response(_, let text):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(.purple).frame(width: 20)
                // `AnswerMarkdown`, not `Text(LocalizedStringKey(text))`, which
                // renders inline Markdown only and drops every line break.
                Text(answer.attributed(text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .reasoning(_, let text):
            DisclosureGroup {
                Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            } label: {
                Label("Thinking", systemImage: "brain").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.leading, 30)
        case .toolCall(_, let name, let arguments):
            Label("\(name) \(arguments)", systemImage: "wrench.and.screwdriver")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(.leading, 30)
        case .toolOutput(_, _, let text):
            Label(text, systemImage: "arrow.turn.down.right")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .padding(.leading, 30)
        }
    }
}
