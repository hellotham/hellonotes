//
//  LLMSettingsView.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Configure LLM providers: enable them, store API keys (Keychain), set base
//  URLs for local servers, and choose the model per provider.
//

#if os(macOS)
import SwiftUI

/// The Assistant's own settings sheet (opened from the Assistant window). Wraps
/// the shared `LLMSettingsForm` with a titled header and a Done button. The same
/// form also appears as the "AI" tab of the Preferences window (⌘,).
struct LLMSettingsView: View {
    @Bindable var settings: LLMSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Assistant Settings", systemImage: "sparkles").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            LLMSettingsForm(settings: settings)
        }
        .frame(width: 560, height: 680)
    }
}

/// The provider/key/defaults configuration form, shared by the Assistant sheet
/// and the Preferences "AI" tab.
struct LLMSettingsForm: View {
    @Bindable var settings: LLMSettings

    var body: some View {
        Form {
            Section("Defaults") {
                Picker("Chat provider", selection: $settings.activeProvider) {
                    ForEach(ProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Intelligence provider", selection: $settings.intelligenceProvider) {
                    ForEach(ProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                Text("“Intelligence provider” powers Summarize, Suggest Tags/Links, Expand and Ask Library. Defaults to on-device Apple Intelligence.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Temperature")
                    Slider(value: $settings.temperature, in: 0...1)
                    Text(settings.temperature, format: .number.precision(.fractionLength(1)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }

            ForEach(ProviderKind.allCases) { kind in
                ProviderSection(settings: settings, kind: kind)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderSection: View {
    @Bindable var settings: LLMSettings
    let kind: ProviderKind

    @State private var apiKey = ""
    @State private var keyStored = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.config(for: kind).enabled },
                set: { settings.setEnabled($0, for: kind) }
            )) {
                Label(kind.displayName, systemImage: kind.symbol)
            }

            if settings.config(for: kind).enabled {
                // Model
                TextField("Model", text: Binding(
                    get: { settings.config(for: kind).model },
                    set: { settings.setModel($0, for: kind) }
                ), prompt: Text(kind.suggestedModels.first ?? "model-id"))

                if !kind.suggestedModels.isEmpty {
                    Menu("Suggested models") {
                        ForEach(kind.suggestedModels, id: \.self) { m in
                            Button(m) { settings.setModel(m, for: kind) }
                        }
                    }
                    .font(.caption)
                }

                // Base URL for local / self-hosted
                if kind.isLocal || kind == .openrouter {
                    TextField("Base URL", text: Binding(
                        get: { settings.config(for: kind).baseURL },
                        set: { settings.setBaseURL($0, for: kind) }
                    ), prompt: Text(kind.defaultBaseURL))
                        .font(.callout.monospaced())
                }

                // API key
                if kind.requiresAPIKey {
                    SecureField("API key", text: $apiKey, prompt: Text(keyStored ? "•••••• (stored)" : "Paste your API key"))
                    HStack(spacing: 10) {
                        if let url = kind.tokenPageURL {
                            Link(destination: url) { Label("Get a key", systemImage: "arrow.up.right.square") }
                                .font(.caption)
                        }
                        Button("Save Key") {
                            LLMKeychain.setKey(apiKey, for: kind)
                            apiKey = ""
                            keyStored = LLMKeychain.hasKey(for: kind)
                        }
                        .font(.caption)
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        if keyStored {
                            Button(role: .destructive) {
                                LLMKeychain.deleteKey(for: kind); keyStored = false
                            } label: { Text("Remove").font(.caption) }
                        }
                    }
                } else if kind.isLocal {
                    Text(localHint).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { keyStored = LLMKeychain.hasKey(for: kind) }
    }

    private var localHint: String {
        switch kind {
        case .ollama: return "Run Ollama locally (ollama serve). No key needed."
        case .lmstudio: return "Start the LM Studio local server. No key needed."
        case .apple: return "Uses Apple Intelligence on-device (macOS 26+). No key needed."
        case .mlx: return "Runs a downloaded MLX model on-device. No key needed."
        default: return ""
        }
    }
}
#endif
