//
//  LLMSettingsView.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Configure LLM providers: enable them, store API keys (Keychain), set base
//  URLs for local servers, and choose the model per provider.
//

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
        .panelFrame(width: 560, height: 680)
    }
}

/// The provider/key/defaults configuration form, shared by the Assistant sheet
/// and the Preferences "AI" tab.
struct LLMSettingsForm: View {
    @Bindable var settings: LLMSettings

    /// Same key `InlineCompletionModel` reads, so the toggle takes effect in
    /// editors that are already open.
    @AppStorage(InlineCompletionModel.enabledKey) private var inlineCompletion = false

    private var ghostTextUnavailable: String? {
        InlineCompletionModel.unavailableReason(IntelligenceService(settings: settings))
    }

    /// How you take the suggestion. Different sentence per platform because it
    /// is a different gesture, and a keyboard shortcut nobody can press reads
    /// as a feature that does not work.
#if os(iOS)
    private let ghostTextHelp = "Grey text appears after the cursor when you pause at the end of a line. Tap it to accept — or ⌥⇥ with a keyboard attached; Esc dismisses it. Nothing is added to the note until you accept."
#else
    private let ghostTextHelp = "Grey text appears after the cursor when you pause at the end of a line. ⌥⇥ or → accepts it; Esc dismisses it. Nothing is added to the note until you accept."
#endif

    /// What the chosen intelligence provider can actually do, and which feature
    /// that rules out.
    ///
    /// Worth showing because the honest answer is not flattering and users
    /// deserve it anyway: an on-device model reads a few thousand characters,
    /// so "Ask your library" over a long note is a different experience there
    /// than on a frontier model. Saying so beats letting someone conclude the
    /// feature is bad.
    @ViewBuilder
    private var capabilitySummary: some View {
        let kind = settings.intelligenceProvider
        let caps = ProviderCapabilities.of(kind, config: settings.config(for: kind))
        let blocked = [
            ("Ask Library", IntelligenceNeeds.askLibrary),
            ("Deep research", IntelligenceNeeds.deepResearch),
        ].filter { !$0.1.satisfied(by: caps) }.map(\.0)

        VStack(alignment: .leading, spacing: 2) {
            Label(caps.onDevice
                  ? "Runs on this device — nothing leaves it, and there is no per-use cost."
                  : "Runs in the cloud — note text is sent to \(kind.displayName).",
                  systemImage: caps.onDevice ? "lock.laptopcomputer" : "cloud")
            // Say where the number came from. A discovered budget and a fallback
            // one look identical written down and mean different things.
            Text(Self.budgetSentence(caps))
            if !blocked.isEmpty {
                Text("\(blocked.joined(separator: " and ")) work better on a provider with a larger context.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    static func budgetSentence(_ caps: ProviderCapabilities) -> String {
        let amount = caps.inputBudget.formatted()
        switch caps.budgetSource {
        case .userOverride:
            return "Reads up to \(amount) characters of a note at a time — your setting."
        case .discovered(let model):
            return "Reads up to about \(amount) characters of a note at a time, which is what \(model) reports it can hold."
        case .providerDefault:
            return "Reads up to about \(amount) characters of a note at a time. Refresh the model list below to use this model's real limit."
        }
    }

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
                capabilitySummary
                HStack {
                    Text("Creativity")
                    Slider(value: $settings.temperature, in: 0...1)
                    Text(settings.temperature, format: .number.precision(.fractionLength(1)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Text("Lower is more focused and predictable; higher is more varied. Individual providers can override this.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Inline completion") {
                Toggle("Suggest as I type", isOn: $inlineCompletion)
                    .disabled(ghostTextUnavailable != nil)
                if let ghostTextUnavailable {
                    // The toggle is off *and* disabled here, and without this
                    // line those look identical to a toggle that simply does
                    // nothing.
                    Label(ghostTextUnavailable, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(ghostTextHelp)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Providers") {
                // Sixteen providers, one row each, closed. Every one of them
                // used to be its own open `Section`, so the form was sixteen
                // stacked blocks before a single setting had been changed.
                ForEach(ProviderKind.allCases) { kind in
                    ProviderRow(settings: settings, kind: kind)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One provider, closed until you open it.
///
/// **Three levels, and the depth is the point.** Closed, a provider is one line
/// saying whether it is on and which model it uses — so the sixteen of them read
/// as a list rather than a wall. Open, it shows the two things anyone actually
/// changes: the model, and the key. The knobs that exist because the *app* needs
/// them to be honest — temperature range, context budget, reply cap — sit behind
/// **Advanced**, because a setting nobody needs to touch should not be in the
/// way of the two they do.
///
/// Every control is in `LLMSettingsForm`, which macOS Preferences (the AI tab)
/// and iOS Settings (AI ▸ Providers & API Keys) both render — so parity is
/// structural rather than remembered.
private struct ProviderRow: View {
    @Bindable var settings: LLMSettings
    let kind: ProviderKind

    @State private var apiKey = ""
    @State private var keyStored = false
    @State private var refreshing = false
    @State private var refreshError: String?
    @State private var showAdvanced = false

    private var config: ProviderConfig { settings.config(for: kind) }

    var body: some View {
        DisclosureGroup {
            Toggle("Enabled", isOn: Binding(
                get: { config.enabled },
                set: { settings.setEnabled($0, for: kind) }
            ))

            if config.enabled {
                modelRows
                connectionRows
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    advancedRows
                }
            }
        } label: {
            // The label is the disclosure's own tap target — putting the enable
            // Toggle here would make one row mean two things and arbitrate
            // badly on both platforms.
            HStack {
                Label(kind.displayName, systemImage: kind.symbol)
                Spacer(minLength: 12)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .onAppear { keyStored = LLMKeychain.hasKey(for: kind) }
    }

    /// What the row says without being opened. Enough to answer "is this on, and
    /// what is it using?" for all sixteen at a glance.
    private var status: String {
        guard config.enabled else { return "Off" }
        if kind.requiresAPIKey && !keyStored { return "Needs a key" }
        let model = config.model.trimmingCharacters(in: .whitespaces)
        return model.isEmpty ? "On" : model
    }

    // MARK: - Model

    @ViewBuilder
    private var modelRows: some View {
        // Still free text. A model ID the listing does not mention is very
        // often a fine-tune or a deployment alias that works perfectly well,
        // and the picker must not be the only way in.
        TextField("Model", text: Binding(
            get: { config.model },
            set: { settings.setModel($0, for: kind) }
        ), prompt: Text(kind.suggestedModels.first ?? "model-id"))

        HStack(spacing: 12) {
            if !config.offeredModels.isEmpty {
                Menu(config.models.isEmpty ? "Suggested models" : "Available models") {
                    ForEach(config.offeredModels) { info in
                        Button {
                            settings.setModel(info.id, for: kind)
                        } label: {
                            Text(info.contextLabel.map { "\(info.displayName) — \($0)" } ?? info.displayName)
                        }
                    }
                }
            }
            if kind.supportsModelDiscovery {
                Button(refreshing ? "Refreshing…" : "Refresh") { refresh() }
                    .disabled(refreshing)
            }
            Spacer()
        }
        .font(.caption)

        // One line, and only when it carries something the row does not: an
        // error, or the fact that a refresh has never been run.
        if let refreshError {
            Label(refreshError, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if config.models.isEmpty, kind.supportsModelDiscovery {
            Text(kind.publishesContextWindow
                 ? "Refresh to load this key’s models and the context limit each one reports."
                 : "Refresh to load this key’s models. \(kind.displayName) doesn’t publish context limits.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refresh() {
        refreshing = true
        refreshError = nil
        Task {
            do { try await settings.refreshModels(for: kind) }
            catch { refreshError = error.localizedDescription }
            refreshing = false
        }
    }

    // MARK: - Advanced

    @ViewBuilder
    private var advancedRows: some View {
        HStack {
            Text("Temperature")
            Slider(value: Binding(
                get: { settings.resolvedTemperature(for: kind) },
                set: { settings.setTemperatureOverride($0, for: kind) }
            ), in: 0...config.temperatureCeiling)
            Text(settings.resolvedTemperature(for: kind),
                 format: .number.precision(.fractionLength(2)))
                .monospacedDigit().foregroundStyle(.secondary)
            if config.temperatureOverride != nil {
                Button("Reset") { settings.setTemperatureOverride(nil, for: kind) }
                    .font(.caption)
            }
        }

        numericField("Context budget",
                     text: Binding(
                        get: { config.inputBudgetOverride.map(String.init) ?? "" },
                        set: { settings.setInputBudgetOverride(parseCount($0), for: kind) }),
                     prompt: "\(automaticBudget.formatted()) (automatic)")

        numericField("Max reply",
                     text: Binding(
                        get: { config.maxOutputTokensOverride.map(String.init) ?? "" },
                        set: { settings.setMaxOutputTokensOverride(parseCount($0), for: kind) }),
                     prompt: automaticOutputPrompt)

        // One caption for all three, rather than one each.
        Text(advancedCaption)
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var advancedCaption: String {
        let ceiling = config.temperatureCeiling
        let top = ceiling.formatted(.number.precision(.fractionLength(ceiling == ceiling.rounded() ? 0 : 1)))
        let budget: String
        switch ProviderCapabilities.of(kind, config: config).budgetSource {
        case .userOverride, .discovered:
            budget = "Budget is note text sent per request, in characters — blank uses the model’s own reported limit."
        case .providerDefault:
            budget = "Budget is note text sent per request, in characters — blank uses a conservative default, since \(kind.displayName) doesn’t report a per-model limit."
        }
        let outputCeiling = config.selectedModelInfo?.outputTokenLimit
            .map { " \(config.model) tops out at \($0.formatted())." } ?? ""
        return "\(kind.displayName) accepts a temperature of 0–\(top). \(budget) Max reply is in tokens — blank lets \(kind.displayName) choose.\(outputCeiling)"
    }

    /// Empty clears the override; anything unparseable is ignored rather than
    /// silently becoming zero, which would mean "send nothing".
    private func parseCount(_ text: String) -> Int? {
        let digits = text.filter(\.isNumber)
        guard let value = Int(digits), value > 0 else { return nil }
        return value
    }

    /// `inputBudget` as it would be *without* the user's override — which is
    /// what the placeholder should show, since the placeholder's whole job is to
    /// say what happens when the field is left empty.
    private var automaticBudget: Int {
        var probe = config
        probe.inputBudgetOverride = nil
        return ProviderCapabilities.of(kind, config: probe).inputBudget
    }

    /// Blank means the app sends no cap at all and the provider decides — so
    /// that is what the placeholder says. It used to show the model's reported
    /// ceiling, which read as a promise the empty field does not keep.
    private var automaticOutputPrompt: String { "provider default" }

    /// A labelled number field.
    ///
    /// `LabeledContent` rather than `TextField(title:)` because **a `TextField`
    /// given a `prompt:` shows no title on iOS at all** — the prompt replaces
    /// the placeholder, and the placeholder is the only place iOS was drawing
    /// the name. On the Mac the label appeared to the left and everything read
    /// correctly; on iPhone the same two rows rendered as bare grey numbers with
    /// nothing to say which was the context budget and which the reply cap.
    /// Caught by looking at it on the device, not by reading the code.
    ///
    /// Both `#if` branches return a view — a one-sided one here is what the
    /// platform parity test exists to catch.
    private func numericField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        LabeledContent(title) {
            let field = TextField("", text: text, prompt: Text(prompt))
                .multilineTextAlignment(.trailing)
            #if os(iOS)
            AnyView(field.keyboardType(.numberPad))
            #else
            AnyView(field)
            #endif
        }
    }

    // MARK: - Connection

    @ViewBuilder
    private var connectionRows: some View {
        if kind.isLocal || kind == .openrouter {
            TextField("Base URL", text: Binding(
                get: { config.baseURL },
                set: { settings.setBaseURL($0, for: kind) }
            ), prompt: Text(kind.defaultBaseURL))
                .font(.callout.monospaced())
        }

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
