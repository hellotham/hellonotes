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

    @FocusState private var inputFocused: Bool

    private var models: LanguageModels { model.settings.models }

    /// Whether this conversation can read and change notes: agent mode, on a
    /// model that can call tools.
    private var usesTools: Bool { model.agentMode && model.canUseTools }

    var body: some View {
        VStack(spacing: 0) {
            header
            ChromeDivider()
            transcript
            ChromeDivider()
            composer
        }
        .onAppear { inputFocused = true }
        .overlay {
            if let broker = model.permissions, let prompt = broker.prompt {
                EditApprovalView(prompt: prompt, broker: broker)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        // No title and no Done: the right panel's header (`SidePanelHeader`)
        // names the panel and closes it, on both platforms.
        HStack(spacing: 10) {
            Spacer()
            Toggle(isOn: $model.agentMode) {
                Image(systemName: usesTools ? "wrench.and.screwdriver.fill" : "bubble.left")
            }
            .toggleStyle(ChromeToggleButtonStyle())
            .disabled(!model.canUseTools)
            .help(model.canUseTools
                  ? (model.agentMode ? "Can read and change the collection" : "Chat only")
                  : "\(model.modelName) can't use tools, so the Assistant chats only")
            .accessibilityLabel(usesTools ? "Agent mode on" : "Agent mode off")
            modelMenu
            Button {
                model.clear()
            } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(ChromeBorderlessStyle())
                .help("New conversation")
                .accessibilityLabel("New conversation")
                .disabled(model.entries.isEmpty && !model.isResponding)
            Button {
                onOpenSettings()
            } label: { Image(systemName: "gearshape") }
                .buttonStyle(ChromeBorderlessStyle())
                .help("AI settings")
                .accessibilityLabel("AI settings")
        }
        .padding(.horizontal).padding(.vertical, 10)
    }

    private var modelMenu: some View {
        ChromePullDown(model.modelTitle, systemImage: models.systemImage(of: model.modelChoice)) {
            ForEach(models.options) { option in
                Button {
                    model.settings.choose(option)
                } label: {
                    Label(models.title(of: option),
                          systemImage: option == model.settings.option(for: model.modelChoice)
                              ? "checkmark" : models.systemImage(of: option))
                }
                .disabled(!models.isAvailable(option))
            }
            Divider()
            Button("AI Settings…", action: onOpenSettings)
        }
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
                            .font(Chrome.Style.callout)
                            .foregroundStyle(Chrome.Colour.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.entries.isEmpty && !model.isResponding { emptyState }
                    ForEach(AssistantRow.rows(model.entries)) { row in
                        RowView(row: row)
                    }
                    if model.isResponding, let status = progressText {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(status).foregroundStyle(Chrome.Colour.secondaryLabel)
                        }
                        .font(Chrome.Style.callout)
                    }
                    if let error = model.errorText {
                        ErrorText(message: error, font: Chrome.Style.callout,
                                  systemImage: "exclamationmark.triangle", tint: Chrome.Colour.orange)
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
                .font(Chrome.Style.headline)
            Text("The AI service you set up in an earlier version is no longer supported, and any API key HelloNotes stored for it has been removed from this device. The Assistant now uses \(model.modelName). You can choose \(LanguageModels.largerModels) in AI settings.")
                .foregroundStyle(Chrome.Colour.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("AI Settings…", action: onOpenSettings)
                Button("OK") { model.settings.acknowledgeRetiredProvider() }
                    .buttonStyle(ChromePushStyle(prominent: true))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Chrome.Colour.quaternaryLabel.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var emptyState: some View {
        if let reason = model.availability.reason {
            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(Chrome.Style.largeTitle)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                Text("\(model.modelName) isn't available")
                    .font(Chrome.Style.title3.bold())
                Text(reason)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                    .multilineTextAlignment(.center)
                Button("AI Settings…", action: onOpenSettings)
                    .buttonStyle(ChromePushStyle(prominent: true))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Chat with \(model.modelName)")
                    .font(Chrome.Style.title3.bold())
                Label(models.privacySummary(of: model.modelChoice),
                      systemImage: model.modelChoice.runsOnDevice ? "lock" : "lock.icloud")
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                Text(usesTools
                     ? "Ask about your notes, or ask for changes — you approve every change before it's saved."
                     : "Chat only: the Assistant won't read or change your notes.")
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 40)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // In its own well, so no field box — only the app's placeholder.
            TextField("", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit { if model.canSend { model.send() } }
                .chromePlaceholder("Message…", showing: model.input.isEmpty, alignment: .topLeading)
                .accessibilityLabel("Message")
                .padding(8)
                .background(Chrome.Colour.quaternaryLabel.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            if model.isResponding {
                Button { model.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(Chrome.Style.title2)
                }
                .buttonStyle(ChromeBorderlessStyle())
                .help("Stop")
                .accessibilityLabel("Stop")
            } else {
                Button { model.send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(Chrome.Style.title2)
                }
                .buttonStyle(ChromeBorderlessStyle())
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
                Image(systemName: "person.circle.fill").foregroundStyle(.tint).frame(width: 20)
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .response(_, let text):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(Chrome.Colour.purple).frame(width: 20)
                // `AnswerMarkdown`, not `Text(LocalizedStringKey(text))`, which
                // renders inline Markdown only and drops every line break.
                Text(answer.attributed(text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .reasoning(_, let text):
            DisclosureGroup {
                Text(text).font(Chrome.Style.callout).foregroundStyle(Chrome.Colour.secondaryLabel).textSelection(.enabled)
            } label: {
                Label("Thinking", systemImage: "brain").font(Chrome.Style.caption).foregroundStyle(Chrome.Colour.secondaryLabel)
            }
            .padding(.leading, 30)
        case .toolCall(_, let name, let arguments):
            Label("\(name) \(arguments)", systemImage: "wrench.and.screwdriver")
                .font(Chrome.Style.caption.monospaced()).foregroundStyle(Chrome.Colour.secondaryLabel)
                .lineLimit(3)
                .padding(.leading, 30)
        case .toolOutput(_, _, let text):
            Label(text, systemImage: "arrow.turn.down.right")
                .font(Chrome.Style.caption.monospaced())
                .foregroundStyle(Chrome.Colour.secondaryLabel)
                .lineLimit(4)
                .padding(.leading, 30)
        }
    }
}
