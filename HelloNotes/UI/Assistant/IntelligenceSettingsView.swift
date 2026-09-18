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
//  ("System", "Private Cloud Compute", "MLX") before what it is called.
//

import SwiftUI
import MLXFoundationModels
import UniformTypeIdentifiers

/// The AI page of Settings — the Mac's AI tab and iOS's Settings ▸ AI, and the
/// only AI settings screen: every "AI Settings…" opens Settings here
/// (`SettingsPage.ai`). Already a `Form`, so never wrap it in another one.
/// Nested forms collapse to a clipped stub; that is how the iOS AI screen
/// shipped in build 11 having never drawn (see `ScreenRenderTests`).
struct IntelligenceSettingsForm: View {
    @Bindable var settings: IntelligenceSettings

    /// Same key `InlineCompletionModel` reads, so the toggle takes effect in
    /// editors that are already open.
    @AppStorage(InlineCompletionModel.enabledKey) private var inlineCompletion = false

    @State private var customModel = ""
    @State private var choosingFolder = false
    /// The model waiting on "Remove", which deletes files and so asks first.
    @State private var removing: MLXLocalModel?

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
        startingInHuggingFaceCache(Form {
            modelsSection
            assistantSection
            mlxSection
            inlineCompletionSection
        }
        .formStyle(.grouped))
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { mlx.chooseFolder(url) }
        }
        .confirmationDialog(
            "Remove \(removing?.name ?? "this model")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { model in
            Button("Remove", role: .destructive) { Task { await mlx.remove(model) } }
        } message: { model in
            Text("This deletes \(model.bytes.formatted(.byteCount(style: .file))) from the models folder. Other MLX tools that use the folder will need to download it again.")
        }
    }

    #if os(macOS)
    /// The folder panel opens straight where other MLX tools keep models. It
    /// runs outside the sandbox, so it can show a folder the app cannot yet read.
    private func startingInHuggingFaceCache(_ form: some View) -> some View {
        form.fileDialogDefaultDirectory(Self.huggingFaceCache)
    }
    #else
    /// No Hugging Face cache on iOS to start in: the picker opens where Files does.
    private func startingInHuggingFaceCache(_ form: some View) -> some View { form }
    #endif

    // MARK: - Models

    private var modelsSection: some View {
        Section {
            modelPicker
            modelCaption(for: settings.model,
                         role: "The Assistant, Summarise, Suggest Tags and Links, Rewrite, Compose, Ask Library and Research.")

            if settings.model == .privateCloud, let quota = models.privateCloudQuotaNote {
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
            Text("System is Apple's model on this device — whichever one Apple Intelligence runs here. AI can make mistakes. Check anything important before you rely on it.")
        }
    }

    /// Apple's model, and MLX where there is a model to run. A setting still on
    /// MLX with nothing in the models folder keeps its entry, saying so, rather
    /// than silently reading as System.
    private var modelPicker: some View {
        let current = settings.option(for: settings.model)
        var options = models.options
        if !options.contains(current) { options.append(current) }
        return Picker("Model", selection: Binding(
            get: { current },
            set: { settings.choose($0) }
        )) {
            ForEach(options) { option in
                Label(optionTitle(option), systemImage: models.systemImage(of: option))
                    .tag(option)
            }
        }
    }

    private func optionTitle(_ option: ModelOption) -> String {
        if option == .mlx, mlx.models.isEmpty {
            return "MLX · no model in the models folder"
        }
        return models.title(of: option)
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

    /// The Assistant's generation options — **the framework's knobs, and no
    /// others**. `GenerationOptions` has four: temperature, sampling mode,
    /// maximum response tokens and (through `ContextOptions`) reasoning level.
    /// Anything else here would be a control the model never sees.
    private var assistantSection: some View {
        Section {
            HStack {
                Text("Creativity")
                Slider(value: $settings.temperature, in: 0...2)
                Text(settings.temperature, format: .number.precision(.fractionLength(1)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }

            Picker("Sampling", selection: $settings.sampling) {
                ForEach(SamplingChoice.allCases) { Text($0.title).tag($0) }
            }
            switch settings.sampling {
            case .topK:
                Stepper(value: $settings.samplingTopK, in: 1...100) {
                    LabeledContent("Words to sample from", value: "\(settings.samplingTopK)")
                }
            case .topP:
                HStack {
                    Text("Probability")
                    Slider(value: $settings.samplingThreshold, in: 0.05...1)
                    Text(settings.samplingThreshold, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            case .automatic, .greedy:
                EmptyView()
            }
            if settings.sampling == .topK || settings.sampling == .topP {
                LabeledField(label: "Seed", text: seedText, prompt: "Random", isPath: true)
            }
            Text(settings.sampling.caption).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledField(label: "Maximum reply", text: maximumReplyText, prompt: "No limit", isPath: true)

            if models.supportsReasoning(settings.model) {
                Picker("Thinking", selection: $settings.reasoning) {
                    ForEach(ReasoningChoice.allCases) { Text($0.title).tag($0) }
                }
            }
            Text(models.supportsReasoning(settings.model)
                 ? "Lower creativity is more focused and predictable. More thinking gives better answers to hard questions, and takes longer."
                 : "Lower creativity is more focused and predictable; higher is more varied. These are the model's own settings, and they apply to the Assistant — the writing tools ask for what each task needs.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Assistant")
        }
    }

    /// The seed as text, because "no seed" is empty rather than a number.
    private var seedText: Binding<String> {
        Binding(get: { settings.samplingSeed.map(String.init) ?? "" },
                set: { settings.samplingSeed = UInt64($0.filter(\.isNumber)) })
    }

    /// Maximum response tokens, likewise: empty means the framework's own limit.
    private var maximumReplyText: Binding<String> {
        Binding(get: { settings.maximumReplyTokens.map(String.init) ?? "" },
                set: { settings.maximumReplyTokens = Int($0.filter(\.isNumber)).map { max(1, $0) } })
    }

    // MARK: - MLX

    private var mlxSection: some View {
        Section {
            LabeledContent("Models folder") {
                HStack {
                    Text(mlx.folderName)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Change…") { choosingFolder = true }
                }
            }

            ForEach(mlx.models) { model in modelRow(model) }
            if mlx.models.isEmpty {
                Text("No MLX models in this folder yet.").foregroundStyle(.secondary)
            }

            HStack {
                LabeledField(label: "Hugging Face model", text: $customModel,
                             prompt: "mlx-community/…", isPath: true)
                if mlx.isDownloading {
                    ProgressView(value: MLXDownloadProgress.shared.isActive ? MLXDownloadProgress.shared.fractionCompleted : 0)
                        .frame(maxWidth: 80)
                    Button("Cancel") { mlx.cancelDownload() }
                } else {
                    Button("Download") {
                        mlx.download(repository: customModel)
                        customModel = ""
                    }
                    .disabled(!customModel.contains("/") || mlx.modelsFolder == nil)
                }
            }
            Link("Browse MLX models on Hugging Face", destination: Self.mlxCommunity)

            if let caution = mlx.sizeCaution {
                Label(caution, systemImage: "exclamationmark.triangle")
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

    #if os(macOS)
    /// `~/.cache/huggingface/hub` in the person's real home — the sandbox gives
    /// the app a different home of its own.
    private static var huggingFaceCache: URL? {
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home)).appending(path: ".cache/huggingface/hub")
    }

    private let mlxFooter = "Bring your own model — HelloNotes doesn't recommend one. MLX models live in one place, the models folder: your Hugging Face cache, ~/.cache/huggingface/hub, where mlx_lm and every other MLX tool keeps them. Models already there are listed, downloads go into it, and each copy is shared. One MLX model runs at a time, so the Assistant and the writing tools share it."
    #else
    private let mlxFooter = "Bring your own model — HelloNotes doesn't recommend one. MLX models live in one place, the models folder: HelloNotes' own storage, or a folder you choose. One MLX model runs at a time, so the Assistant and the writing tools share it."
    #endif

    private func modelRow(_ model: MLXLocalModel) -> some View {
        let inUse = mlx.chosenID == model.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                if inUse { Image(systemName: "checkmark").foregroundStyle(.tint) }
                Text(model.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(model.bytes.formatted(.byteCount(style: .file)))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if model.rendersTools == false {
                Text("Can't use tools — with it the Assistant chats only, and Research isn't available.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if !inUse { Button("Use") { mlx.use(model) } }
                Button("Remove…", role: .destructive) { removing = model }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
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
