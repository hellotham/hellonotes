//
//  ModelDiscoveryTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 27/8/2026.
//

import Testing
import Foundation
@testable import HelloNotes

/// Asking the provider instead of remembering.
///
/// These pin the *rules*, not any provider's numbers — the numbers move, which
/// is the entire reason the app stopped hard-coding them.
struct ModelDiscoveryTests {

    // MARK: - The floor/ceiling split

    /// The defect this work exists to fix.
    ///
    /// `IntelligenceNeeds.inputBudget` was read as a floor by `satisfied(by:)`
    /// and as a cap by `IntelligenceService.budget(for:)`, and the floor was
    /// always the smaller of the two — so a million-token model was fed 12,000
    /// characters for Ask Library and raising the provider's declared budget
    /// changed nothing. A ceiling of `nil` is what makes the provider's number
    /// mean something.
    @Test func contentFeaturesDeclareNoCeiling() {
        let contentFeatures: [(String, IntelligenceNeeds)] = [
            ("summarise", .summarise), ("rewrite", .rewrite),
            ("suggestTags", .suggestTags), ("suggestLinks", .suggestLinks),
            ("compose", .compose), ("askLibrary", .askLibrary),
            ("deepResearch", .deepResearch),
        ]
        for (name, feature) in contentFeatures {
            #expect(feature.inputCeiling == nil,
                    "\(name) caps its own input again — the provider's budget stops mattering")
        }
    }

    /// The exception, and it is about the feature rather than the provider:
    /// ghost text races a keystroke, so a wider window is a slower answer.
    @Test func inlineCompletionKeepsItsCeiling() {
        #expect(IntelligenceNeeds.inlineCompletion.inputCeiling == 2_000)
    }

    /// The floor still gates eligibility — splitting the field must not have
    /// quietly made every feature available everywhere.
    @Test func theFloorStillGatesEligibility() {
        let tiny = ProviderCapabilities(inputBudget: 4_000, structuredOutput: true,
                                        toolUse: true, onDevice: false, isFree: false)
        #expect(IntelligenceNeeds.summarise.satisfied(by: tiny))
        #expect(!IntelligenceNeeds.askLibrary.satisfied(by: tiny))
        #expect(!IntelligenceNeeds.deepResearch.satisfied(by: tiny))
    }

    // MARK: - Resolution order

    @Test func discoveredWindowBeatsTheStaticTable() {
        var config = ProviderConfig(kind: .gemini, enabled: true, model: "gemini-3.7-flash")
        config.models = [ModelInfo(id: "gemini-3.7-flash", inputTokenLimit: 1_048_576)]

        let table = ProviderCapabilities.of(.gemini)
        let resolved = ProviderCapabilities.of(.gemini, config: config)

        #expect(resolved.inputBudget > table.inputBudget)
        #expect(resolved.budgetSource == .discovered(model: "gemini-3.7-flash"))
    }

    @Test func theUsersOwnNumberBeatsDiscovery() {
        var config = ProviderConfig(kind: .gemini, enabled: true, model: "gemini-3.7-flash")
        config.models = [ModelInfo(id: "gemini-3.7-flash", inputTokenLimit: 1_048_576)]
        config.inputBudgetOverride = 20_000

        let resolved = ProviderCapabilities.of(.gemini, config: config)
        #expect(resolved.inputBudget == 20_000)
        #expect(resolved.budgetSource == .userOverride)
    }

    /// A provider that publishes no window keeps the table's floor, and says so.
    @Test func aSilentProviderFallsBackAndAdmitsIt() {
        let config = ProviderConfig(kind: .openai, enabled: true, model: "gpt-5.6-sol")
        let resolved = ProviderCapabilities.of(.openai, config: config)
        #expect(resolved.budgetSource == .providerDefault)
        #expect(resolved.inputBudget == ProviderCapabilities.of(.openai).inputBudget)
    }

    /// Model IDs are matched leniently, because providers list a versioned ID
    /// and accept an unversioned alias (and the reverse).
    @Test func aVersionedListingMatchesAnUnversionedSelection() {
        var config = ProviderConfig(kind: .anthropic, enabled: true, model: "claude-opus-5")
        config.models = [ModelInfo(id: "claude-opus-5-20260724", inputTokenLimit: 200_000)]
        #expect(config.selectedModelInfo != nil)
    }

    // MARK: - Token arithmetic

    /// The OpenAI-compatible family reports one window covering input *and*
    /// output, so sending all of it as input is a request that gets rejected.
    @Test func aTotalWindowReservesRoomForTheReply() {
        let input = ModelDiscovery.inputTokens(total: 8_192, output: 4_096)
        #expect(input == 4_096)
    }

    /// A real case from OpenRouter's live listing: a 1,048,576-token model
    /// advertising a 943,718-token output cap. Naive subtraction leaves 104,858
    /// — a million-token model reduced to a tenth of itself.
    @Test func anAbsurdOutputCapNeverEatsMoreThanHalfTheWindow() {
        let input = ModelDiscovery.inputTokens(total: 1_048_576, output: 943_718)
        #expect(input == 524_288)
    }

    @Test func anUnstatedOutputCapReservesAModestSlice() {
        #expect(ModelDiscovery.inputTokens(total: 262_144, output: nil) == 258_048)
        #expect(ModelDiscovery.inputTokens(total: nil, output: nil) == nil)
        #expect(ModelDiscovery.inputTokens(total: 0, output: nil) == nil)
    }

    /// The tokens→characters constant errs low on purpose: erring high costs a
    /// rejected request, erring low costs a little unused window.
    @Test func characterConversionErrsBelowFourPerToken() {
        #expect(ModelInfo.charactersPerToken < 4)
        #expect(ModelInfo(id: "m", inputTokenLimit: 1_000).inputCharacterLimit == 3_500)
        #expect(ModelInfo(id: "m").inputCharacterLimit == nil)
    }

    // MARK: - Temperature

    /// One global slider pinned to 0...1 was the wrong range for Anthropic *and*
    /// half the available range for everyone else.
    @Test func temperatureIsHeldToWhatTheProviderAccepts() {
        let anthropic = ProviderConfig(kind: .anthropic, enabled: true)
        #expect(anthropic.clampedTemperature(1.8) == 1.0)

        let gemini = ProviderConfig(kind: .gemini, enabled: true)
        #expect(gemini.clampedTemperature(1.8) == 1.8)
        #expect(gemini.clampedTemperature(-1) == 0)
    }

    /// A model's own stated ceiling supersedes the provider default.
    @Test func aModelsOwnCeilingWins() {
        var config = ProviderConfig(kind: .gemini, enabled: true, model: "strict")
        config.models = [ModelInfo(id: "strict", maxTemperature: 0.5)]
        #expect(config.clampedTemperature(1.5) == 0.5)
    }

    /// A discovered ceiling must never become a *request*.
    ///
    /// `maxTokens` had sat unused on `LLMRequestOptions` for the app's whole
    /// life; the first code to set it sent the model's maximum output on every
    /// call. Groq counts prompt and completion against one window, so asking for
    /// the full `max_completion_tokens` can leave no room for the prompt, and
    /// OpenAI's o-series rejects `max_tokens` outright. Discovery fills the
    /// placeholder; only the user fills the request.
    @Test func aDiscoveredOutputCeilingIsNotSentAsARequest() {
        var config = ProviderConfig(kind: .groq, enabled: true, model: "llama-3.3-70b-versatile")
        config.models = [ModelInfo(id: "llama-3.3-70b-versatile",
                                   inputTokenLimit: 98_304, outputTokenLimit: 32_768)]
        #expect(config.maxOutputTokensOverride == nil)
        #expect(config.selectedModelInfo?.outputTokenLimit == 32_768,
                "the ceiling is still discovered — it just isn't sent")
    }

    // MARK: - Persistence

    /// The trap that would have cost every user their provider setup.
    ///
    /// `LLMSettings.init` decodes the stored blob with `try?` and falls back to
    /// defaults for *every* provider, so one throw here is not a loud failure —
    /// it is a silent reset. Synthesised `Codable` throws on a missing key for a
    /// non-optional property, which is exactly what `models: [ModelInfo] = []`
    /// is, so this is decoded by hand.
    @Test func aConfigStoredBeforeThisFeatureStillDecodes() throws {
        let legacy = """
        [{"kind":"gemini","enabled":true,"baseURL":"https://generativelanguage.googleapis.com","model":"gemini-2.5-flash"}]
        """
        let decoded = try JSONDecoder().decode([ProviderConfig].self, from: Data(legacy.utf8))
        #expect(decoded.count == 1)
        #expect(decoded[0].model == "gemini-2.5-flash")
        #expect(decoded[0].enabled)
        #expect(decoded[0].models.isEmpty)
        #expect(decoded[0].inputBudgetOverride == nil)
    }

    /// And a round trip keeps everything that was added.
    @Test func discoveredModelsSurviveARoundTrip() throws {
        var config = ProviderConfig(kind: .gemini, enabled: true, model: "gemini-3.7-flash")
        config.models = [ModelInfo(id: "gemini-3.7-flash", displayName: "Gemini 3.7 Flash",
                                   inputTokenLimit: 1_048_576, outputTokenLimit: 65_536,
                                   maxTemperature: 2.0)]
        config.inputBudgetOverride = 50_000
        config.temperatureOverride = 1.4

        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(ProviderConfig.self, from: data)
        #expect(back == config)
    }

    /// A `ModelInfo` written by a future build, missing nothing this one needs,
    /// must not take the whole array down with it.
    @Test func aModelInfoWithOnlyAnIDDecodes() throws {
        let json = #"{"id":"some-model"}"#
        let info = try JSONDecoder().decode(ModelInfo.self, from: Data(json.utf8))
        #expect(info.id == "some-model")
        #expect(info.displayName == "some-model")
        #expect(info.inputTokenLimit == nil)
    }

    // MARK: - Declarations match reality

    /// `supportsModelDiscovery` decides whether a Refresh button appears. A
    /// button that always answers "this provider does not publish a model list"
    /// is a button that should not be there.
    @Test func onlyOnDeviceProvidersLackDiscovery() {
        for kind in ProviderKind.allCases {
            // Apple and MLX are in-process: there is no endpoint to ask.
            let inProcess = kind == .apple || kind == .mlx
            #expect(kind.supportsModelDiscovery == !inProcess,
                    "\(kind): discovery flag disagrees with the adapter")
        }
    }

    /// Anything claiming to publish a window must be able to list models first.
    @Test func publishingAWindowImpliesListingModels() {
        for kind in ProviderKind.allCases where kind.publishesContextWindow {
            #expect(kind.supportsModelDiscovery, "\(kind) cannot publish what it cannot list")
        }
    }

    /// Every provider must still declare a usable temperature ceiling — a zero
    /// would pin every request to greedy decoding and look like a broken model.
    @Test func everyProviderDeclaresAWorkableTemperatureCeiling() {
        for kind in ProviderKind.allCases {
            #expect(kind.defaultMaxTemperature >= 1.0, "\(kind) ceiling too low")
            #expect(kind.defaultMaxTemperature <= 2.0, "\(kind) ceiling implausibly high")
        }
    }
}
