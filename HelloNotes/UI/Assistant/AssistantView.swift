//
//  AssistantView.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  The streaming chat window for the multi-provider assistant. Renders messages
//  as parts (text / thinking / tool calls), streams the active provider's reply
//  live, and lets the user switch provider/model from the toolbar.
//

#if os(macOS)
import SwiftUI

struct AssistantView: View {
    @Bindable var model: AssistantModel
    var onOpenSettings: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .frame(width: 620, height: 680)
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
            Label("Assistant", systemImage: "sparkles").font(.headline)
            Spacer()
            if model.registry != nil {
                Toggle(isOn: $model.agentMode) {
                    Image(systemName: model.agentMode ? "wrench.and.screwdriver.fill" : "bubble.left")
                }
                .toggleStyle(.button)
                .help(model.agentMode ? "Agent mode: can read & edit the collection" : "Chat only")
            }
            providerPicker
            Button {
                model.clear()
            } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless)
                .help("New chat")
                .disabled(model.messages.isEmpty)
            Button {
                onOpenSettings()
            } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Assistant settings")
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal).padding(.vertical, 10)
    }

    private var providerPicker: some View {
        let ready = model.settings.enabledProviders.filter { model.settings.isReady($0) }
        return Menu {
            if ready.isEmpty {
                Button("Add a provider…") { onOpenSettings() }
            }
            ForEach(ready) { kind in
                Button {
                    model.settings.activeProvider = kind
                } label: {
                    Label("\(kind.displayName) · \(model.settings.config(for: kind).model)",
                          systemImage: kind == model.activeProvider ? "checkmark" : kind.symbol)
                }
            }
        } label: {
            Label(model.activeProvider.displayName, systemImage: model.activeProvider.symbol)
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.messages.isEmpty { emptyState }
                    ForEach(model.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if let error = model.errorText {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding()
            }
            .onChange(of: model.messages.last?.parts.count) { _, _ in
                withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: model.messages.count) { _, _ in
                withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
        }
    }

    private let bottomID = "assistant-bottom"

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chat with \(model.activeProvider.displayName)")
                .font(.title3.bold())
            Text("Ask anything. Switch providers from the menu above. Your API keys stay in the Keychain.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 40)
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

            if model.isStreaming {
                Button { model.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .help("Stop")
            } else {
                Button { model.send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(!model.canSend)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding()
    }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let message: LLMMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                    partView(part)
                }
                if message.role == .assistant, message.parts.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func partView(_ part: MessagePart) -> some View {
        switch part {
        case .text(let text):
            Text(LocalizedStringKey(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking(let text):
            DisclosureGroup {
                Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            } label: {
                Label("Reasoning", systemImage: "brain").font(.caption).foregroundStyle(.secondary)
            }
        case .toolCall(let call):
            Label("\(call.name)(\(call.arguments))", systemImage: "wrench.and.screwdriver")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(3)
        case .toolResult(let result):
            Label(result.output, systemImage: result.isError ? "xmark.octagon" : "arrow.turn.down.right")
                .font(.caption.monospaced())
                .foregroundStyle(result.isError ? .red : .secondary)
                .lineLimit(4)
        }
    }

    private var icon: String {
        switch message.role {
        case .user: return "person.circle.fill"
        case .assistant: return "sparkles"
        case .tool: return "wrench.and.screwdriver.fill"
        case .system: return "gearshape"
        }
    }
    private var iconColor: Color {
        message.role == .user ? .accentColor : .purple
    }
}
#endif
