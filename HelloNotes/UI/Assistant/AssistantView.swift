//
//  AssistantView.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  The Assistant's tab: the conversation as the session recorded it —
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

    /// Whether this conversation reads notes: Use my notes on, on a model that
    /// can call tools.
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
        // No title and no Done: its tab beside the notes (`EditorTabBar`)
        // names it and closes it, on both platforms.
        HStack(spacing: 10) {
            // In words: two icons that swapped said nothing about what they
            // did. Off, the Assistant never reads the notes — which is also how
            // to keep them away from a model off the device.
            Toggle("Use my notes", isOn: $model.agentMode)
                .toggleStyle(ChromeSwitchStyle())
                .disabled(!model.canUseTools)
                .help(model.canUseTools
                      ? "On, it searches and reads your notes to answer. Off, it's plain chat and never reads them."
                      : "\(model.modelName) can't use tools, so it can't read your notes")
                .fixedSize()
            Spacer()
            modelMenu
            Button {
                model.clear()
            } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(ChromeBorderlessStyle())
                .help("New conversation")
                .accessibilityLabel("New conversation")
                .disabled(model.entries.isEmpty && !model.isResponding)
        }
        .padding(.horizontal).padding(.vertical, 10)
    }

    /// The model for this conversation. It starts from the Settings default,
    /// and choosing here changes this conversation only — AI Settings… at the
    /// foot is where the default is.
    private var modelMenu: some View {
        ChromePullDown(model.modelTitle, systemImage: models.systemImage(of: model.chosenModel)) {
            ForEach(model.menuOptions) { option in
                Button {
                    model.choose(option)
                } label: {
                    Label(models.title(of: option),
                          systemImage: model.isChosen(option) ? "checkmark" : models.systemImage(of: option))
                }
                .disabled(!models.isAvailable(option))
            }
            Divider()
            Button("AI Settings…", action: onOpenSettings)
        }
        .help("The model for this conversation")
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
                        Label("\(model.modelName) can't use tools, so the Assistant can chat but won't read your notes. \(LanguageModels.appleModels(joinedBy: "and")) can, and so can any MLX model AI settings doesn't mark \"Can't use tools\".",
                              systemImage: "info.circle")
                            .font(Chrome.Style.callout)
                            .foregroundStyle(Chrome.Colour.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.entries.isEmpty && !model.isResponding { emptyState }
                    let rows = AssistantRow.rows(model.entries)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        RowView(row: row, report: report(for: row, at: index, in: rows), stamp: stamp(for: row))
                    }
                    // The message on its way, until the conversation holds it.
                    if let pending = model.pendingPrompt {
                        RowView(row: .prompt(id: "pending-prompt", text: pending))
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
            .onChange(of: model.pendingPrompt) { _, _ in
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
        // Before the message goes: the turns it pushes out of the window are
        // summarised first, which can take a few seconds.
        if model.isSummarising { return "Remembering earlier messages…" }
        if model.pendingPrompt != nil { return "Thinking…" }
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
            // `largerModels` became a function of the model in use, and this
            // line kept interpolating the function itself — "(Function)" on
            // screen, with one compiler warning to say so (§51.55).
            Text("The AI service you set up in an earlier version is no longer supported, and any API key HelloNotes stored for it has been removed from this device. The Assistant now uses \(model.modelName)."
                 + (LanguageModels.largerModels(than: model.modelChoice).map { " You can choose \($0) in AI settings." } ?? ""))
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
                Text("Ask about your notes")
                    .font(Chrome.Style.title3.bold())
                Label(models.privacySummary(of: model.modelChoice),
                      systemImage: model.modelChoice.runsOnDevice ? "lock" : "lock.icloud")
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                // With tools it has the web, whichever model runs — and says
                // so here, under the line about the model.
                if usesTools {
                    Label(LanguageModels.webSummary, systemImage: "globe")
                        .foregroundStyle(Chrome.Colour.secondaryLabel)
                }
                // Why it won't read them, of the two reasons: the switch is
                // off, or the model can't use tools — when the switch is on,
                // and greyed.
                Text(usesTools
                     ? "It searches and reads your notes to answer, and shows each one it read."
                     : model.agentMode
                        ? "\(model.modelName) can't use tools, so it won't read your notes."
                        : "Use my notes is off: it won't read your notes.")
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 40)
        }
    }

    // MARK: - Composer

    /// The person's own words for what this is (2026-10-18): a small window
    /// and a few tools, not a chat assistant.
    static let experimental = "Experimental. It answers from a few notes at a time and can't change them — it isn't a full chat assistant."

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Said wherever the Assistant is open, not only on an empty
            // conversation: it opens on the last one, so the line build 34
            // put in the empty state was never seen (the person's check).
            Text("\(Image(systemName: "flask")) \(Self.experimental)")
                .font(Chrome.Style.caption)
                .foregroundStyle(Chrome.Colour.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("assistant.experimental")
            // Once there is a conversation the empty state, which says where
            // text goes, is gone — so on a model off the device it is said
            // here, beside what is about to be sent.
            if !model.entries.isEmpty, let line = models.conversationPrivacy(of: model.modelChoice) {
                Text("\(Image(systemName: "lock.icloud")) \(line)")
                    .font(Chrome.Style.caption)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Today's Cloud (Apple) allowance, for a conversation that chose
            // it: that it is nearly spent, and once it is, that Local (Apple)
            // is answering instead (`LanguageModels.serving`) — nothing to do.
            if model.chosenModel == .privateCloud, let quota = models.privateCloudQuotaNote {
                Text("\(Image(systemName: "gauge.with.dots.needle.67percent")) \(quota)")
                    .font(Chrome.Style.caption)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            composerRow
        }
        .padding()
    }

    private var composerRow: some View {
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
    }
}

// MARK: - Rows

/// One visible piece of the conversation, flattened from transcript entries.
/// Plain data, and read off the main actor too (`AssistantModel.summaryParts`).
nonisolated enum AssistantRow: Identifiable, Equatable {
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

extension AssistantView {
    /// What "Report…" beside a reply carries: the reply, the question asked
    /// before it, and the model that wrote it (`ResponseReport`).
    fileprivate func report(for row: AssistantRow, at index: Int,
                            in rows: [AssistantRow]) -> (() -> ResponseReport)? {
        guard case .response(let id, let text) = row else { return nil }
        let asked = rows[..<index].reversed().lazy.compactMap { row -> String? in
            if case .prompt(_, let prompt) = row { return prompt }
            return nil
        }.first
        // The model that wrote it, when that was recorded; the one in use if not.
        let name = model.stamps[id]?.name ?? model.modelName
        return { ResponseReport(feature: "Assistant", model: name, response: text, prompt: asked) }
    }

    /// Where a reply was made (`ModelStamp`), when that was recorded.
    fileprivate func stamp(for row: AssistantRow) -> ModelStamp? {
        guard case .response(let id, _) = row else { return nil }
        return model.stamps[id]
    }
}

private struct RowView: View {
    let row: AssistantRow
    /// For a reply: what reporting it carries.
    var report: (() -> ResponseReport)? = nil
    /// For a reply: where it was made.
    var stamp: ModelStamp? = nil
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(Chrome.Colour.purple).frame(width: 20)
                    // `AnswerMarkdown`, not `Text(LocalizedStringKey(text))`, which
                    // renders inline Markdown only and drops every line break.
                    Text(answer.attributed(text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 12) {
                    if let stamp { ModelStampLabel(stamp: stamp) }
                    if let report { ReportResponseButton(report: report).font(Chrome.Style.caption) }
                }
                .padding(.leading, 30)
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
