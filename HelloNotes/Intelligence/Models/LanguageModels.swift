//
//  LanguageModels.swift
//  HelloNotes
//
//  Created by Chris Tham on 15/9/2026.
//
//  The one place a `ModelChoice` becomes a model.
//
//  Everything a feature needs to know about a model is *asked of the model*:
//  whether it can run (`availability`), what it is called (`variant.displayName`
//  on-device — "AFM 3 Core" or "AFM 3 Core Advanced", decided by the hardware),
//  how much it can read (`contextSize`: 8,192 tokens for Core Advanced on this
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

    /// The models worth suggesting when the chosen one is too small, named only
    /// if this build can offer them.
    nonisolated static var largerModels: String {
        privateCloudComputeEnabled ? "Private Cloud Compute or an MLX model" : "an MLX model"
    }

    private static let privateCloudNotInThisBuild =
        "Private Cloud Compute isn't available in this version of HelloNotes."

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

    /// The model's own name: "AFM 3 Core Advanced", "Private Cloud Compute",
    /// "Qwen3 4B".
    func name(of choice: ModelChoice) -> String {
        switch choice {
        case .onDevice:
            // A device that cannot run Apple Intelligence has no variant to
            // name, so it is not asked for one.
            if case .unavailable(.deviceNotEligible) = onDevice.availability {
                "Apple Intelligence"
            } else {
                onDevice.variant.displayName
            }
        case .privateCloud: "Private Cloud Compute"
        case .mlx: mlx.modelName
        }
    }

    /// The name with where it runs, for pickers and the Assistant's header.
    func title(of choice: ModelChoice) -> String {
        switch choice {
        case .onDevice: "On-Device · \(name(of: choice))"
        case .privateCloud: "Private Cloud Compute"
        case .mlx: "MLX · \(name(of: choice))"
        }
    }

    /// Where the text goes, in one sentence. The HIG is explicit that people
    /// must be able to tell whether a feature sends their data to a server.
    func privacySummary(of choice: ModelChoice) -> String {
        switch choice {
        case .onDevice:
            "Runs on this device. Your notes never leave it."
        case .privateCloud:
            "Sent to Apple's Private Cloud Compute to process. It isn't stored, and it isn't accessible to Apple."
        case .mlx:
            "Runs on this device with an open model you downloaded. Your notes never leave it."
        }
    }

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
            return MLXCatalog.contextTokens
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
        case .mlx: MLXCatalog.contextTokens
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

    /// A line about today's Private Cloud Compute allowance, or `nil` while
    /// there is nothing to say. Persistent and quiet by design — Apple's
    /// guidance is to show the quota where the feature is, never as an alert.
    var privateCloudQuotaNote: String? {
        guard let usage = privateCloud?.quotaUsage else { return nil }
        switch usage.status {
        case .belowLimit(let below):
            return below.isApproachingLimit
                ? "You're close to today's Private Cloud Compute limit."
                : nil
        case .limitReached:
            if let reset = usage.resetDate {
                return "You've reached today's Private Cloud Compute limit. It resets \(reset.formatted(.relative(presentation: .named)))."
            }
            return "You've reached today's Private Cloud Compute limit."
        @unknown default:
            return nil
        }
    }

    /// Offer the system's own way to raise the limit, when it has one.
    var canSuggestLimitIncrease: Bool {
        privateCloud?.quotaUsage.limitIncreaseSuggestion != nil
    }

    func suggestLimitIncrease() {
        privateCloud?.quotaUsage.limitIncreaseSuggestion?.show()
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
                if let reset = limit.resetDate {
                    return "You've reached today's Private Cloud Compute limit. It resets \(reset.formatted(.relative(presentation: .named)))."
                }
                return "You've reached today's Private Cloud Compute limit."
            case .networkFailure:
                return "Couldn't reach Private Cloud Compute. Check your internet connection."
            case .serviceUnavailable:
                return "Private Cloud Compute is unavailable right now. Try again later."
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
