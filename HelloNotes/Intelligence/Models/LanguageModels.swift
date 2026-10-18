//
//  LanguageModels.swift
//  HelloNotes
//
//  Created by Chris Tham on 15/9/2026.
//
//  The one place a `ModelChoice` becomes a model.
//
//  Everything a feature needs to know about a model is *asked of the model*:
//  whether it can run (`availability`), how much it can read (`contextSize`: 8,192 tokens for Core Advanced on this
//  generation, 32,768 for Private Cloud Compute), and what it can do
//  (`capabilities`). The provider layer this replaced kept those answers in
//  hand-written tables that were wrong the week after they were written; the
//  CLAUDE.md rule "a context window is a thing you ask for, never a thing you
//  remember" is now simply how the API works.
//

import Foundation
import FoundationModels
import MLXFoundationModels
import Observation
#if os(macOS)
import Security
#endif

@MainActor
@Observable
final class LanguageModels {

    static let shared = LanguageModels()

    /// What a request is for, which decides the on-device configuration.
    enum Purpose {
        /// Generating something new: chat, composing, answering.
        case general
        /// Reworking the person's own text — summaries, rewrites, continuations.
        /// Uses the guardrail mode Apple provides for exactly that, so a note
        /// that *discusses* a difficult subject can still be summarised.
        ///
        /// There is deliberately no tagging purpose. Apple's content-tagging
        /// adapter was tried and measured: it extracts key *phrases* ("bikes
        /// along the Kamo river") whatever the schema's guide asks for, and it
        /// refused a sourdough-baking note as sensitive. The general model,
        /// asked for topics, did both jobs properly.
        case transforming
    }

    let onDevice = SystemLanguageModel.default
    let onDeviceTransforming = SystemLanguageModel(useCase: .general,
                                                   guardrails: .permissiveContentTransformations)
    /// `nil` unless this build may use Private Cloud Compute — see
    /// `privateCloudComputeEnabled`. Not merely unused when it may not: never
    /// created, so nothing can reach it by accident.
    let privateCloud: PrivateCloudComputeLanguageModel?
    let mlx: MLXModelStore

    /// Whether this build holds Apple's managed Private Cloud Compute entitlement.
    ///
    /// **The framework will not tell you, and guessing is fatal.** Without the
    /// entitlement, `PrivateCloudComputeLanguageModel.availability` still reports
    /// `.available` — and the first request ends the process with
    /// `fatalError("Missing entitlement: com.apple.developer.private-cloud-compute")`
    /// inside Foundation Models. Measured in the signed app on 15 September 2026;
    /// an unsandboxed command-line probe reports the same availability and does
    /// not crash, which is what made it look safe.
    ///
    /// So it is decided at build time: the `PRIVATE_CLOUD_COMPUTE` compilation
    /// condition is added in the same change as the entitlement, and
    /// `PrivateCloudComputeEntitlementTests` fails if the two disagree. On the
    /// Mac the signed entitlement is also checked at runtime, because a Developer
    /// ID export can be signed without an entitlement the App Store profile has.
    /// iOS offers no public way to read an app's own entitlements, which is why
    /// the flag exists at all.
    nonisolated static let privateCloudComputeEnabled: Bool = {
        #if PRIVATE_CLOUD_COMPUTE
        return signedEntitlement("com.apple.developer.private-cloud-compute")
        #else
        return false
        #endif
    }()

    /// Whether the running app was signed with `name`, where the platform lets
    /// an app ask.
    nonisolated private static func signedEntitlement(_ name: String) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, name as CFString, nil)
        else { return false }
        return (value as? Bool) == true
        #else
        // iOS has no public API for an app's own entitlements, so the build
        // flag is the whole check there — which is why it must only ever be
        // set alongside the entitlement.
        return true
        #endif
    }

    /// The choices this build can offer. Private Cloud Compute is left out
    /// entirely rather than shown as unavailable: a choice that can never work in
    /// this build is not a choice.
    nonisolated static var offeredChoices: [ModelChoice] {
        privateCloudComputeEnabled ? ModelChoice.allCases : [.onDevice, .mlx]
    }

    var offeredChoices: [ModelChoice] { Self.offeredChoices }

    /// The models worth suggesting when `choice` is too small — named only if
    /// this build can offer them and they read more at once — or `nil` when
    /// there are none.
    ///
    /// It was one sentence for every model, which was harmless while there
    /// were two: Private Cloud Compute, the largest window the app can reach
    /// (32,768), was then told to choose itself, or an MLX model with half its
    /// window. An MLX model is offered from System because a Mac gives one
    /// 16,384 tokens, and on a device whose System model has 4,096 so does the
    /// 8,192 an iPhone gives it.
    nonisolated static func largerModels(than choice: ModelChoice) -> String? {
        switch choice {
        case .onDevice: privateCloudComputeEnabled ? "Cloud (Apple) or a local MLX model" : "a local MLX model"
        case .mlx: privateCloudComputeEnabled ? "Cloud (Apple)" : nil
        case .privateCloud: nil
        }
    }

    /// Apple's models this build offers, by name, for a sentence about
    /// something every one of them can do: "Local (Apple)", or "Local (Apple)
    /// and Cloud (Apple)" (with "or", for a choice).
    nonisolated static func appleModels(joinedBy conjunction: String) -> String {
        privateCloudComputeEnabled ? "Local (Apple) \(conjunction) Cloud (Apple)" : "Local (Apple)"
    }

    private static let privateCloudNotInThisBuild =
        "Cloud (Apple) isn't available in this version of HelloNotes."

    /// Private Cloud Compute's window, once asked. It is `async throws` on the
    /// model, so it is fetched once and remembered for the process.
    private var privateCloudContext: Int?

    /// `nil` rather than a `.shared` default: a default argument is evaluated
    /// in the caller's context, which need not be the main actor.
    init(mlx: MLXModelStore? = nil) {
        self.mlx = mlx ?? .shared
        privateCloud = Self.privateCloudComputeEnabled ? PrivateCloudComputeLanguageModel() : nil
    }

    // MARK: - Resolving

    func model(for choice: ModelChoice, purpose: Purpose = .general) throws -> any LanguageModel {
        if case .unavailable(let why) = availability(of: choice) {
            throw IntelligenceError.unavailable(why)
        }
        switch choice {
        case .onDevice:
            switch purpose {
            case .general: return onDevice
            case .transforming: return onDeviceTransforming
            }
        case .privateCloud:
            guard let privateCloud else { throw IntelligenceError.unavailable(Self.privateCloudNotInThisBuild) }
            return privateCloud
        case .mlx:
            return try mlx.languageModel()
        }
    }

    func availability(of choice: ModelChoice) -> IntelligenceAvailability {
        switch choice {
        case .onDevice: IntelligenceAvailability(onDevice.availability)
        case .privateCloud:
            privateCloud.map { IntelligenceAvailability($0.availability) }
                ?? .unavailable(Self.privateCloudNotInThisBuild)
        case .mlx: mlx.availability
        }
    }

    // MARK: - Describing

    /// The model's name: **where it runs, then whose it is** — "Local
    /// (Apple)", "Cloud (Apple)", "Local (gemma-4-31b-it-4bit)" — in a sentence
    /// and in a menu alike (the person's decision, 2026-10-18).
    ///
    /// It was "System" and "Private Cloud Compute": two of Apple's models set
    /// against each other, when the choice that matters is whether the text
    /// leaves the device. Not the on-device variant ("AFM 3 Core Advanced")
    /// either — the hardware decides it, and naming a model nobody can choose
    /// made people ask where the other one was.
    func name(of choice: ModelChoice) -> String {
        switch choice {
        case .onDevice: "Local (Apple)"
        case .privateCloud: "Cloud (Apple)"
        case .mlx: "Local (\(mlx.modelName))"
        }
    }

    /// The name as an entry, for pickers and the Assistant's header — the same
    /// words, so a menu and a sentence never disagree.
    func title(of choice: ModelChoice) -> String { name(of: choice) }

    // MARK: - Picker entries

    /// What a model picker offers: Apple's on-device model, Private Cloud
    /// Compute where this build has it, and **each MLX model on this device**
    /// that the loader can run, by name. Never a model that isn't here.
    ///
    /// There is one System entry because an app cannot choose between AFM 3
    /// Core and AFM 3 Core Advanced: `SystemLanguageModel` has no initialiser
    /// that takes a variant, and `variant` is read-only — the system runs the
    /// one this hardware has.
    var options: [ModelOption] {
        var result: [ModelOption] = [.onDevice]
        if Self.privateCloudComputeEnabled { result.append(.privateCloud) }
        // Every model the folder holds and the loader can run — the folder
        // decides what is here, not this list, and the app names no model it
        // cannot see.
        result.append(contentsOf: mlx.models.map { ModelOption.mlx($0.id) })
        return result
    }

    /// What an entry is called. MLX entries carry the model's own name, and the
    /// two ways an entry can name a model that isn't in the folder — an empty
    /// folder, or a choice whose model has been removed — say so rather than
    /// reading as a bare "MLX" that looks the same as a working one.
    func title(of option: ModelOption) -> String {
        guard let id = option.mlxModelID else { return title(of: option.choice) }
        if let model = mlx.models.first(where: { $0.id == id }) { return "Local (\(model.name))" }
        if mlx.models.isEmpty { return "Local (MLX) · no model in the models folder" }
        return id.isEmpty ? "Local (MLX) · no model chosen" : "Local (MLX) · model not in this folder"
    }

    func systemImage(of option: ModelOption) -> String { systemImage(of: option.choice) }

    // MARK: - An entry, for a conversation of its own

    /// The model an entry names — for an MLX entry that model, whichever the
    /// store has chosen as the default's — once it can run.
    func model(forOption option: ModelOption, purpose: Purpose = .general) throws -> any LanguageModel {
        guard let id = option.mlxModelID, !id.isEmpty else { return try model(for: option.choice, purpose: purpose) }
        if case .unavailable(let why) = availability(ofOption: option) { throw IntelligenceError.unavailable(why) }
        guard let local = mlx.models.first(where: { $0.id == id }) else {
            throw IntelligenceError.unavailable(Self.notInFolder)
        }
        return mlx.languageModel(for: local)
    }

    /// Whether an entry's model can call tools — an MLX entry's own template.
    func supportsTools(option: ModelOption) -> Bool {
        guard let id = option.mlxModelID else { return supportsTools(option.choice) }
        return mlx.models.first { $0.id == id }?.rendersTools ?? true
    }

    /// Whether an entry's model can run, and why not. The store follows the
    /// default's MLX model only — and an entry naming none (`.mlx("")`, the
    /// default with no model chosen) is the store's own answer; another in the
    /// folder is runnable while it is there, and says what is wrong on its
    /// first request if anything is.
    func availability(ofOption option: ModelOption) -> IntelligenceAvailability {
        guard let id = option.mlxModelID else { return availability(of: option.choice) }
        if id.isEmpty || id == mlx.chosenID { return availability(of: .mlx) }
        #if targetEnvironment(simulator)
        return availability(of: .mlx)
        #else
        return mlx.models.contains { $0.id == id } ? .available : .unavailable(Self.notInFolder)
        #endif
    }

    nonisolated static let notInFolder = "That MLX model isn't in the models folder any more."

    /// `option` as the folder holds it now. An MLX entry is named by its
    /// snapshot, which a new revision of the same model replaces — so an entry
    /// kept with a conversation is matched to its repository's current
    /// snapshot rather than dropped, which put a conversation kept on this
    /// device back on the Settings default, Cloud (Apple) perhaps. An entry
    /// the folder no longer has at all is kept, and says so where it is used.
    func resolved(_ option: ModelOption) -> ModelOption {
        guard let id = option.mlxModelID, !id.isEmpty, !mlx.models.contains(where: { $0.id == id }),
              let range = id.range(of: "/snapshots/") else { return option }
        let repository = String(id[..<range.lowerBound])
        guard let current = mlx.models.first(where: { $0.folder.standardizedFileURL.path == repository }) else { return option }
        return .mlx(current.id)
    }

    /// The entry a request asked of `option` runs on: `option`, or Local
    /// (Apple) while Cloud (Apple)'s allowance is spent (`serving`).
    func serving(option: ModelOption) -> ModelOption {
        serving(option.choice) == option.choice ? option : .onDevice
    }

    /// Whether an entry can be chosen now.
    ///
    /// An MLX entry is about *that* model. The store's live availability
    /// describes the model **in use** — "no model chosen", "is downloading" —
    /// so asking it about the others would disable every model in the folder
    /// whenever the one in use wasn't ready, including before anything has been
    /// chosen at all. A model that is here and runnable can always be chosen.
    func isAvailable(_ option: ModelOption) -> Bool { availability(ofOption: option).isAvailable }

    /// Where the text goes to be *processed*, in one sentence. The HIG is
    /// explicit that people must be able to tell whether a feature sends their
    /// data to a server.
    ///
    /// About the model and nothing else. Both on-device lines ended "Your
    /// notes never leave it", under an Assistant that searches the web with
    /// terms the model writes after reading notes — true of the model, untrue
    /// of the feature it was printed on. What the web tools send is
    /// `webSummary`, shown beside this wherever those tools are
    /// (implemented.md §51.44).
    func privacySummary(of choice: ModelChoice) -> String { Self.privacySummary(of: choice) }

    /// The same line, for what has a choice and no `LanguageModels` — a
    /// result's `ModelStamp`.
    nonisolated static func privacySummary(of choice: ModelChoice) -> String {
        switch choice {
        case .onDevice:
            "Runs on this device. Your notes are not sent to any AI service."
        case .privateCloud:
            "Sent to Apple's Private Cloud Compute to process. It isn't stored, and it isn't accessible to Apple."
        case .mlx:
            "Runs on this device with an open model you downloaded. Your notes are not sent to any AI service."
        }
    }

    /// What the chosen model is used for, as the AI settings say under the
    /// picker. Suggestions as you type run only on a model on this device
    /// (`IntelligenceService.supportsInlineCompletion`) — a round trip cannot
    /// keep up with typing — so the line does not promise them on one off it.
    nonisolated static func uses(of choice: ModelChoice) -> String {
        choice.runsOnDevice
            ? "The Assistant, Summarise, Suggest Tags and Links, Rewrite, Compose, Research and the suggestions as you type."
            : "The Assistant, Summarise, Suggest Tags and Links, Rewrite, Compose and Research. Suggestions as you type need a model on this device."
    }

    /// What each message of a conversation under way sends, on a model off
    /// the device — or `nil` on one on it. The Assistant said where text goes
    /// only on an empty conversation, and a conversation switched to Private
    /// Cloud Compute partway carries everything before the switch with it,
    /// what the tools read from notes on the device included.
    func conversationPrivacy(of choice: ModelChoice) -> String? {
        switch choice {
        case .onDevice, .mlx: nil
        case .privateCloud:
            "Each message sends the conversation so far to Apple's Private Cloud Compute, with what it has read from your notes. It isn't stored, and it isn't accessible to Apple."
        }
    }

    /// What does leave the device, whichever model runs: a web search. Shown
    /// wherever the model has the web tools — the Assistant with tools on, and
    /// the AI settings for a model that can call them (`NoteTools.reachesTheWeb`).
    nonisolated static let webSummary = "The Assistant and Research can search the web. What they search for goes to DuckDuckGo, and can include words from your question or your notes."

    func systemImage(of choice: ModelChoice) -> String {
        switch choice {
        case .onDevice: "apple.intelligence"
        case .privateCloud: "lock.icloud"
        case .mlx: "cpu"
        }
    }

    // MARK: - Capabilities

    /// Tokens the model can hold — instructions, tools, history and reply.
    func contextSize(of choice: ModelChoice) async -> Int {
        switch choice {
        case .onDevice:
            return onDevice.contextSize
        case .privateCloud:
            if let privateCloudContext { return privateCloudContext }
            guard let privateCloud else { return 32_768 }
            let size = (try? await privateCloud.contextSize) ?? 32_768
            privateCloudContext = size
            return size
        case .mlx:
            return MLXModelStore.contextTokens
        }
    }

    /// The context size without waiting: exact on-device and for MLX, and for
    /// Private Cloud Compute the size last reported (32,768 until it has been
    /// asked). For deciding whether to *offer* something; a request itself
    /// plans against `contextSize(of:)`.
    func knownContextSize(of choice: ModelChoice) -> Int {
        switch choice {
        case .onDevice: onDevice.contextSize
        case .privateCloud: privateCloudContext ?? 32_768
        case .mlx: MLXModelStore.contextTokens
        }
    }

    /// Whether `choice` can call the Assistant's tools. Apple's models can; an
    /// MLX model can only if its chat template shows it the tools
    /// (`MLXChatTemplate`).
    func supportsTools(_ choice: ModelChoice) -> Bool {
        switch choice {
        case .onDevice, .privateCloud: true
        case .mlx: mlx.toolsSupported
        }
    }

    /// Whether `choice` accepts a reasoning level. Asking a model that does not
    /// reason to think harder is an error, not a no-op.
    func supportsReasoning(_ choice: ModelChoice) -> Bool {
        switch choice {
        case .onDevice: onDevice.capabilities.contains(.reasoning)
        case .privateCloud: privateCloud?.capabilities.contains(.reasoning) ?? false
        case .mlx: mlx.reasons
        }
    }

    /// The level to send for `reasoning`, or `nil` where the model does not
    /// reason or the person left it to the model.
    func reasoningLevel(_ reasoning: ReasoningChoice, for choice: ModelChoice) -> ContextOptions.ReasoningLevel? {
        guard supportsReasoning(choice) else { return nil }
        switch reasoning {
        case .automatic: return nil
        case .light: return .light
        case .moderate: return .moderate
        case .deep: return .deep
        }
    }

    // MARK: - Private Cloud Compute quota

    /// The model a request asked of `choice` runs on: `choice` — or, once
    /// Cloud (Apple) has used today's allowance, Local (Apple), when it can
    /// run. A fallback towards the device and never away from it, so nothing
    /// goes anywhere the person did not choose to send it; and asked of the
    /// framework each time (`quotaUsage`), never remembered.
    func serving(_ choice: ModelChoice) -> ModelChoice {
        // `quotaUsage` is read only for Cloud (Apple): nothing else has one.
        guard choice == .privateCloud else { return choice }
        return Self.serving(choice, limitReached: privateCloudLimitReached,
                            localAvailable: availability(of: .onDevice).isAvailable)
    }

    nonisolated static func serving(_ choice: ModelChoice, limitReached: Bool, localAvailable: Bool) -> ModelChoice {
        choice == .privateCloud && limitReached && localAvailable ? .onDevice : choice
    }

    /// The model to ask again when a request on `choice` failed with `error`:
    /// Local (Apple), when Cloud (Apple) refused it for today's limit — the
    /// request that finds the allowance spent, before `quotaUsage` says so —
    /// and `nil` for every other failure, which a second model would not mend.
    func fallback(after error: any Error, on choice: ModelChoice) -> ModelChoice? {
        Self.fallback(after: error, on: choice, localAvailable: availability(of: .onDevice).isAvailable)
    }

    nonisolated static func fallback(after error: any Error, on choice: ModelChoice, localAvailable: Bool) -> ModelChoice? {
        guard choice == .privateCloud, localAvailable,
              let error = error as? PrivateCloudComputeLanguageModel.Error,
              case .quotaLimitReached = error else { return nil }
        return .onDevice
    }

    /// A line about today's Cloud (Apple) allowance, or `nil` while there is
    /// nothing to say. Persistent and quiet by design — Apple's guidance is to
    /// show the quota where the feature is, never as an alert.
    var privateCloudQuotaNote: String? {
        guard let usage = privateCloud?.quotaUsage else { return nil }
        let localAvailable = availability(of: .onDevice).isAvailable
        switch usage.status {
        case .belowLimit(let below):
            return below.isApproachingLimit
                ? "You're close to today's limit for Cloud (Apple)."
                    + (localAvailable ? " After it, Local (Apple) is used until it resets." : "")
                : nil
        case .limitReached:
            return Self.limitReached(resets: usage.resetDate, fallingBack: localAvailable)
        @unknown default:
            return nil
        }
    }

    /// Whether today's allowance is spent.
    var privateCloudLimitReached: Bool {
        privateCloud?.quotaUsage.isLimitReached ?? false
    }

    /// When today's allowance comes back, when that is known.
    var privateCloudResetDate: Date? { privateCloud?.quotaUsage.resetDate }

    /// What reaching the limit says, wherever it is said: the note in Settings
    /// and the Assistant while Local (Apple) stands in, and the failure when
    /// nothing can.
    nonisolated static func limitReached(resets: Date?, fallingBack: Bool) -> String {
        let when = resets.map { " It resets \($0.formatted(.relative(presentation: .named)))." } ?? ""
        return fallingBack
            ? "You've reached today's limit for Cloud (Apple), so Local (Apple) is being used instead.\(when)"
            : "You've reached today's limit for Cloud (Apple).\(when)"
    }
}

/// Failures the intelligence layer reports in its own words.
nonisolated enum IntelligenceError: LocalizedError {
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let why), .failed(let why): why
        }
    }

    /// A model error, in a sentence a person can act on.
    ///
    /// `modelName` is the model that was asked, so "too long" can say for
    /// which model — the same passage fits Private Cloud Compute's window
    /// four times over.
    static func describe(_ error: any Error, modelName: String) -> String {
        if let described = error as? IntelligenceError { return described.localizedDescription }
        if let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded:
                return "That's more text than \(modelName) can read at once."
            case .guardrailViolation:
                return "\(modelName) didn't process this because it may involve sensitive content."
            case .refusal:
                return "\(modelName) declined this request."
            case .unsupportedLanguageOrLocale:
                return "\(modelName) doesn't support this language yet."
            case .rateLimited:
                return "\(modelName) is busy right now. Try again in a moment."
            case .timeout:
                return "\(modelName) took too long to respond. Try again."
            case .unsupportedCapability, .unsupportedGenerationGuide, .unsupportedTranscriptContent:
                return "\(modelName) can't do this kind of request."
            @unknown default:
                return error.localizedDescription
            }
        }
        if let error = error as? PrivateCloudComputeLanguageModel.Error {
            switch error {
            case .quotaLimitReached(let limit):
                // Reached only where Local (Apple) could not stand in
                // (`LanguageModels.fallback(after:on:)`).
                return LanguageModels.limitReached(resets: limit.resetDate, fallingBack: false)
            case .networkFailure:
                return "Couldn't reach Cloud (Apple). Check your internet connection."
            case .serviceUnavailable:
                return "Cloud (Apple) is unavailable right now. Try again later."
            @unknown default:
                return error.localizedDescription
            }
        }
        if let error = error as? LanguageModelSession.ToolCallError {
            return "\(modelName) couldn't finish: \(error.underlyingError.localizedDescription)"
        }
        return error.localizedDescription
    }
}
