//
//  IntelligenceSettingsView.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Which model does what: the Assistant's model, the writing tools' model, the
//  MLX models on this device, and ghost text.
//
//  This screen used to configure sixteen providers — enable toggles, API keys,
//  base URLs, model discovery, temperature ceilings, context budgets. None of
//  that exists any more. What a person decides now is small and legible: for
//  each of the two roles, *which of three models*, with a sentence under each
//  saying where the text goes. That sentence is the part the Human Interface
//  Guidelines insist on, and it is why the choice is shown as where a model runs
//  ("On-Device", "Private Cloud Compute", "MLX") before what it is called.
//

import SwiftUI
import MLXFoundationModels
import UniformTypeIdentifiers

/// The settings sheet opened from the Assistant and from the editor's AI menu.
/// The same form is the AI tab of Preferences on the Mac and AI in Settings on iOS.
struct IntelligenceSettingsView: View {
    @Bindable var settings: IntelligenceSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("AI Settings", systemImage: "sparkles").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            IntelligenceSettingsForm(settings: settings)
        }
        .panelFrame(width: 560, height: 680)
    }
}

/// The form itself — already a `Form`, so never wrap it in another one. Nested
/// forms collapse to a clipped stub; that is how the iOS AI screen shipped in
/// build 11 having never drawn (see `ScreenRenderTests`).
struct IntelligenceSettingsForm: View {
    @Bindable var settings: IntelligenceSettings

    /// Same key `InlineCompletionModel` reads, so the toggle takes effect in
    /// editors that are already open.
    @AppStorage(InlineCompletionModel.enabledKey) private var inlineCompletion = false

    @State private var customModel = ""
    @State private var choosingFolder = false

    private var models: LanguageModels { settings.models }
    private var mlx: MLXModelStore { settings.mlx }

    #if os(iOS)
    private let ghostTextHelp = "Grey text appears after the cursor when you pause at the end of a line. Tap it to accept — or ⌥⇥ with a keyboard attached; Esc dismisses it. Nothing is added to the note until you accept."
    #else
    private let ghostTextHelp = "Grey text appears after the cursor when you pause at the end of a line. ⌥⇥ or → accepts it; Esc dismisses it. Nothing is added to the note until you accept."
    #endif

    private var ghostTextUnavailable: String? {
        InlineCompletionModel.unavailableReason(IntelligenceService(settings: settings))
    }

    var body: some View {
        Form {
            modelsSection
            assistantSection
            mlxSection
            inlineCompletionSection
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { mlx.choose(folder: url) }
        }
    }

    // MARK: - Models

    private var modelsSection: some View {
        Section {
            modelPicker("Assistant", selection: $settings.assistantModel)
            modelCaption(for: settings.assistantModel,
                         role: "Chat, and changes to your notes that you approve.")

            modelPicker("Writing tools", selection: $settings.featuresModel)
            modelCaption(for: settings.featuresModel,
                         role: "Summarise, Suggest Tags and Links, Rewrite, Compose and Ask Library.")

            if settings.assistantModel == .privateCloud || settings.featuresModel == .privateCloud,
               let quota = models.privateCloudQuotaNote {
                VStack(alignment: .leading, spacing: 6) {
                    Label(quota, systemImage: "gauge.with.dots.needle.67percent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if models.canSuggestLimitIncrease {
                        Button("Request More") { models.suggestLimitIncrease() }
                            .font(.caption)
                    }
                }
            }
        } header: {
            Text("Models")
        } footer: {
            Text("AI can make mistakes. Check anything important before you rely on it.")
        }
    }

    private func modelPicker(_ title: String, selection: Binding<ModelChoice>) -> some View {
        Picker(title, selection: selection) {
            ForEach(models.offeredChoices) { choice in
                Label(models.title(of: choice), systemImage: models.systemImage(of: choice))
                    .tag(choice)
            }
        }
    }

    /// What the role covers, where its text goes, and — when the model cannot
    /// run — why not. Three short lines rather than a paragraph, because the
    /// middle one is the one that matters and must not be buried.
    ///
    /// The symbols are inline in the text rather than `Label`s: inside a form
    /// row a `Label` reserves an icon column, which indented the privacy line
    /// past the line above it on iOS.
    private func modelCaption(for choice: ModelChoice, role: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(role)
            Text("\(Image(systemName: choice.runsOnDevice ? "lock" : "lock.icloud")) \(models.privacySummary(of: choice))")
            if let reason = models.availability(of: choice).reason {
                Text("\(Image(systemName: "exclamationmark.circle")) \(reason)")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Assistant

    private var assistantSection: some View {
        Section("Assistant") {
            HStack {
                Text("Creativity")
                Slider(value: $settings.temperature, in: 0...1)
                Text(settings.temperature, format: .number.precision(.fractionLength(1)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            if models.supportsReasoning(settings.assistantModel) {
                Picker("Thinking", selection: $settings.reasoning) {
                    ForEach(ReasoningChoice.allCases) { Text($0.title).tag($0) }
                }
            }
            Text(models.supportsReasoning(settings.assistantModel)
                 ? "Lower creativity is more focused and predictable. More thinking gives better answers to hard questions, and takes longer."
                 : "Lower is more focused and predictable; higher is more varied.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - MLX

    private var mlxSection: some View {
        Section {
            if case .folder = mlx.source {
                LabeledContent("Folder") {
                    Label(mlx.modelName, systemImage: "checkmark")
                        .foregroundStyle(.tint)
                }
            } else if case .hub(let id) = mlx.source {
                chosenModelRow(id)
            }

            HStack {
                LabeledField(label: "Hugging Face model", text: $customModel,
                             prompt: "mlx-community/…", isPath: true)
                Button("Use") {
                    mlx.choose(repository: customModel)
                    customModel = ""
                }
                .disabled(!customModel.contains("/"))
            }

            Button("Choose a Model Folder…") { choosingFolder = true }

            Link("Browse MLX models on Hugging Face", destination: Self.mlxCommunity)

            if let caution = mlx.sizeCaution {
                Label(caution, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if mlx.source != nil && !mlx.toolsSupported {
                Label("\(mlx.modelName) can't use tools. With it the Assistant chats without reading or changing your notes, and Research isn't available.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = mlx.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("MLX Models")
        } footer: {
            Text(mlxFooter)
        }
    }

    private static let mlxCommunity = URL(string: "https://huggingface.co/mlx-community")!

    /// **No models are suggested.** The app used to list four, and they were a
    /// generation out of date within a day of being written. Naming a model is
    /// a promise about it; this screen makes none.
    #if os(macOS)
    private let mlxFooter = "Bring your own model — HelloNotes doesn't recommend one, and whether a model works, and how well, is up to the model. Type an MLX model's name on Hugging Face, or choose a folder that holds one; either downloads into this device's caches. A model already in your Hugging Face cache works too: choose its folder in ~/.cache/huggingface/hub (press ⇧⌘G in the Open panel to type the path). Where Hugging Face isn't reachable, get a model another way and choose its folder."
    #else
    private let mlxFooter = "Bring your own model — HelloNotes doesn't recommend one, and whether a model works, and how well, is up to the model. Type an MLX model's name on Hugging Face, or choose a folder that holds one; either downloads into this device's caches. Where Hugging Face isn't reachable, get a model another way and choose its folder."
    #endif

    private func chosenModelRow(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "checkmark").foregroundStyle(.tint)
                Text(id).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
            }
            downloadControls(id: id, name: MLXModelStore.shortName(ofRepository: id),
                             chosen: true, onDisk: mlx.downloaded.contains(id))
        }
    }

    @ViewBuilder
    private func downloadControls(id: String, name: String, chosen: Bool, onDisk: Bool) -> some View {
        let progress = MLXDownloadProgress.shared
        HStack(spacing: 10) {
            if mlx.downloadingID == id {
                ProgressView(value: progress.isActive ? progress.fractionCompleted : 0)
                    .frame(maxWidth: 160)
                Button("Cancel") { mlx.cancelDownload() }
            } else if chosen && !onDisk {
                Button("Download") { mlx.downloadChosenModel() }
                    .disabled(mlx.isDownloading)
            } else if !chosen {
                Button("Use") { mlx.choose(repository: id) }
            }
            if onDisk && mlx.downloadingID != id {
                Button("Remove Download", role: .destructive) {
                    Task { await mlx.removeDownload(repository: id) }
                }
            }
        }
        .font(.caption)
        .buttonStyle(.borderless)
    }

    // MARK: - Inline completion

    private var inlineCompletionSection: some View {
        Section("Inline Completion") {
            Toggle("Suggest as I type", isOn: $inlineCompletion)
                .disabled(ghostTextUnavailable != nil)
            if let ghostTextUnavailable {
                // The toggle is off *and* disabled here, and without this line
                // those look identical to a toggle that simply does nothing.
                Label(ghostTextUnavailable, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(ghostTextHelp)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
