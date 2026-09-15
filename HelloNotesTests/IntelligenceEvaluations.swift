//
//  IntelligenceEvaluations.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 15/9/2026.
//
//  Measured quality for the writing tools and the Assistant, on the real
//  on-device model, with Apple's Evaluations framework.
//
//  Unit tests prove the plumbing; these prove the *answers*: tags that are about
//  the note, links drawn only from real notes, rewrites that keep a note's
//  links, a long note summarised whole, and an Assistant that reads before it
//  answers and never edits what it was not asked to.
//
//  **Opt-in, and local.** Each run is dozens of model requests — minutes, not
//  the app suite's seconds — and needs Apple Intelligence, which no CI runner
//  has. Run with:
//
//      TEST_RUNNER_HN_EVALUATIONS=1 ./scripts/run-tests.sh -only-testing:HelloNotesTests/IntelligenceEvaluationTests
//
//  and read the report under the test run in Xcode's Report navigator. Every
//  sample is synthetic: nothing here reads a real vault, so a Foundation Models
//  trace of a run holds nothing private.
//

import Testing
import Foundation
import Evaluations
import FoundationModels
@testable import HelloNotes

/// Whether evaluations were asked for, and can run here.
private let evaluationsEnabled =
    ProcessInfo.processInfo.environment["HN_EVALUATIONS"] == "1"
    && SystemLanguageModel.default.isAvailable

/// The features under test, on the on-device model, with settings kept out of
/// the person's own preferences.
@MainActor
private enum Features {
    static let settings: IntelligenceSettings = {
        let defaults = UserDefaults(suiteName: "HelloNotesEvaluations")!
        defaults.set(true, forKey: IntelligenceMigration.doneKey)
        let settings = IntelligenceSettings(defaults: defaults)
        settings.featuresModel = .onDevice
        settings.assistantModel = .onDevice
        return settings
    }()

    static var service: IntelligenceService { IntelligenceService(settings: settings) }

    static func tags(_ note: String) async throws -> [String] {
        try await service.suggestTags(for: note, existing: [])
    }

    static func links(_ note: String, candidates: [String]) async throws -> [String] {
        try await service.suggestLinks(for: note, candidates: candidates)
    }

    static func rewrite(_ text: String, instruction: String) async throws -> String {
        try await service.rewrite(text, instruction: instruction)
    }

    static func summary(_ note: String) async throws -> String {
        try await service.summarize(note)
    }
}

// MARK: - Tags

struct TagEvaluation: Evaluation {
    let wellFormed = Metric("WellFormed")
    let onTopic = Metric("OnTopic")

    /// `expected` holds words any one of which marks a tag as on topic.
    let dataset = ArrayLoader(samples: [
        ModelSample(prompt: "Sourdough starter log: fed the starter with rye flour and kept it at 24°C. The loaf rose well. Next time, try a longer autolyse before shaping.",
                    expected: ["baking", "sourdough", "bread", "fermentation", "cooking", "recipe", "food"]),
        ModelSample(prompt: "Quarterly planning: finalise the Q3 roadmap, hire two engineers, and review the budget with finance on Friday.",
                    expected: ["planning", "roadmap", "work", "business", "hiring", "budget", "management", "meeting", "project", "quarterly"]),
        ModelSample(prompt: "Swift concurrency notes: actors isolate mutable state, Sendable marks values that are safe to share, and task groups give structured parallelism.",
                    expected: ["swift", "concurrency", "programming", "actors", "code", "development", "software", "parallelism"]),
        ModelSample(prompt: "Kyoto itinerary: Fushimi Inari at dawn, bikes along the Kamo river, and a kaiseki dinner in Gion.",
                    expected: ["travel", "kyoto", "japan", "trip", "vacation", "itinerary", "food", "planning", "cycling"]),
        ModelSample(prompt: "读书笔记：《三体》讨论了宇宙社会学与黑暗森林法则，人物刻画深刻，结尾令人震撼。",
                    expected: ["读书", "科幻", "三体", "书", "小说", "阅读", "文学", "宇宙", "社会", "黑暗森林", "人物",
                               "reading", "books", "fiction", "literature"]),
    ])

    func subject(from sample: ModelSample<[String]>) async throws -> ModelSubject<[String]> {
        ModelSubject(value: try await Features.tags(sample.promptDescription))
    }

    var evaluators: Evaluators {
        Evaluator { _, subject in
            let tags = subject.value
            let normalised = IntelligenceService.normalizeTags(tags) == tags
            return (1...6).contains(tags.count) && normalised
                ? wellFormed.passing()
                : wellFormed.failing(rationale: "\(tags)")
        }
        Evaluator { input, subject in
            guard let words = input.expected else { return onTopic.ignore() }
            let hit = subject.value.contains { tag in
                words.contains { tag.localizedCaseInsensitiveContains($0) || $0.localizedCaseInsensitiveContains(tag) }
            }
            return hit ? onTopic.passing() : onTopic.failing(rationale: "\(subject.value)")
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: wellFormed)
        aggregator.computeMean(of: onTopic)
    }
}

// MARK: - Links

struct LinkEvaluation: Evaluation {
    let onlyCandidates = Metric("OnlyCandidates")
    let findsRelated = Metric("FindsRelated")

    static let candidates = [
        "Sourdough Basics", "Q3 Roadmap", "Hiring Plan", "Swift Actors", "Kyoto Trip",
        "Garden Journal", "Budget Review", "Reading List", "Bread Hydration Table", "Team Offsite",
    ]

    let dataset = ArrayLoader(samples: [
        ModelSample(prompt: "Today's loaf: 78% hydration rye blend. The crumb was tighter than last week, so next bake I'll extend bulk fermentation.",
                    expected: ["Sourdough Basics", "Bread Hydration Table"]),
        ModelSample(prompt: "Offsite agenda draft: review the roadmap, discuss open headcount, and agree the budget split for next quarter.",
                    expected: ["Q3 Roadmap", "Hiring Plan", "Budget Review", "Team Offsite"]),
        ModelSample(prompt: "Isolating shared state with actors fixed the data race in the sync engine; everything crossing an actor boundary now has to be Sendable.",
                    expected: ["Swift Actors"]),
    ])

    func subject(from sample: ModelSample<[String]>) async throws -> ModelSubject<[String]> {
        ModelSubject(value: try await Features.links(sample.promptDescription, candidates: Self.candidates))
    }

    var evaluators: Evaluators {
        Evaluator { _, subject in
            subject.value.allSatisfy(Self.candidates.contains)
                ? onlyCandidates.passing()
                : onlyCandidates.failing(rationale: "\(subject.value)")
        }
        Evaluator { input, subject in
            guard let related = input.expected else { return findsRelated.ignore() }
            return subject.value.contains(where: related.contains)
                ? findsRelated.passing()
                : findsRelated.failing(rationale: "\(subject.value)")
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: onlyCandidates)
        aggregator.computeMean(of: findsRelated)
    }
}

// MARK: - Rewrite

struct RewriteEvaluation: Evaluation {
    let keepsLinks = Metric("KeepsLinks")
    let followsInstruction = Metric("FollowsInstruction")

    /// The prompt is the passage; `expected` is the instruction.
    let dataset = ArrayLoader(samples: [
        ModelSample(prompt: "i think we shuold move the launch to [[Q3 Roadmap]] becuase the [design review](https://example.com/review) isnt done",
                    expected: "Fix grammar, spelling and punctuation only. Change nothing else."),
        ModelSample(prompt: "We need to book the venue, confirm catering with [[Team Offsite]] notes, send invitations, and arrange transport from the station.",
                    expected: "Convert into a well-organized Markdown bullet list of the key points."),
        ModelSample(prompt: "The **hydration** of the dough, which as I mentioned in [[Sourdough Basics]] is something that really matters quite a lot, should be around seventy-five percent for this particular loaf.",
                    expected: "Make this significantly more concise without losing key information."),
    ])

    func subject(from sample: ModelSample<String>) async throws -> ModelSubject<String> {
        ModelSubject(value: try await Features.rewrite(sample.promptDescription, instruction: sample.expected ?? ""))
    }

    var evaluators: Evaluators {
        Evaluator { input, subject in
            let links = Self.links(in: input.promptDescription)
            let missing = links.filter { !subject.value.contains($0) }
            return missing.isEmpty ? keepsLinks.passing() : keepsLinks.failing(rationale: "lost \(missing)")
        }
        Evaluator { input, subject in
            let instruction = input.expected ?? ""
            if instruction.contains("bullet") {
                let bullets = subject.value.split(separator: "\n").filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
                return bullets.count >= 2 ? followsInstruction.passing() : followsInstruction.failing(rationale: subject.value)
            }
            if instruction.contains("concise") {
                return subject.value.count < input.promptDescription.count
                    ? followsInstruction.passing() : followsInstruction.failing(rationale: subject.value)
            }
            return subject.value.contains("should") && subject.value.contains("because")
                ? followsInstruction.passing() : followsInstruction.failing(rationale: subject.value)
        }
    }

    static func links(in text: String) -> [String] {
        guard let pattern = try? Regex(#"\[\[[^\]]+\]\]|\[[^\]]+\]\([^)]+\)"#) else { return [] }
        return text.matches(of: pattern).map { String(text[$0.range]) }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: keepsLinks)
        aggregator.computeMean(of: followsInstruction)
    }
}

// MARK: - Long notes

/// A note several times the on-device window, summarised through the parts.
struct LongSummaryEvaluation: Evaluation {
    let produced = Metric("Produced")
    let concise = Metric("Concise")
    let coversTheEnd = Metric("CoversTheEnd")

    static let longNote: String = {
        // 150 weeks, about 45,000 characters: several times the on-device
        // window, so the summary has to go through parts. (At 40 weeks it fit
        // in one request, and the evaluation proved nothing about chunking.)
        let sections = (1...150).map { index in
            "## Week \(index)\nThe allotment diary for week \(index): watered the tomatoes, weeded the beans, and noted slug damage on the lettuces. Harvested a small crop and composted the trimmings. The weather was changeable and the soil stayed damp through most of the week."
        }
        return "# Allotment Diary\n\n" + sections.joined(separator: "\n\n")
            + "\n\n## Final week\nThe season ended with the discovery of a hidden pumpkin, the largest of the year, which won first prize at the village show."
    }()

    let dataset = ArrayLoader(samples: [
        ModelSample(prompt: LongSummaryEvaluation.longNote, expected: "pumpkin"),
    ])

    func subject(from sample: ModelSample<String>) async throws -> ModelSubject<String> {
        ModelSubject(value: try await Features.summary(sample.promptDescription))
    }

    var evaluators: Evaluators {
        Evaluator { _, subject in
            subject.value.isEmpty ? produced.failing() : produced.passing()
        }
        Evaluator { input, subject in
            subject.value.count < input.promptDescription.count / 5
                ? concise.passing() : concise.failing(rationale: "\(subject.value.count) characters")
        }
        // The fact that matters is in the last part. Summarising only the
        // opening — what the old path did — misses it.
        Evaluator { input, subject in
            subject.value.localizedCaseInsensitiveContains(input.expected ?? "")
                ? coversTheEnd.passing() : coversTheEnd.failing(rationale: subject.value)
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: produced)
        aggregator.computeMean(of: concise)
        aggregator.computeMean(of: coversTheEnd)
    }
}

// MARK: - Assistant

/// The Assistant's tool use against a copy of the sample vault: the right tool,
/// with the right argument, and never an edit nobody asked for.
struct AssistantTrajectoryEvaluation: Evaluation {
    let answered = Metric("Answered")

    let dataset = ArrayLoader(samples: [
        ModelSample<String>(
            prompt: "What are the section headings in my Welcome note?",
            expected: "Getting Started",
            expectations: TrajectoryExpectation(
                ordered: [ToolExpectation("read_note", arguments: [.contains(argumentName: "note", substring: "Welcome")])],
                disallowed: [ToolExpectation("edit_note"), ToolExpectation("create_note")])),
        ModelSample<String>(
            prompt: "Which of my notes mention the roadmap?",
            expected: "Roadmap",
            expectations: TrajectoryExpectation(
                unordered: [ToolExpectation("search_notes")],
                disallowed: [ToolExpectation("edit_note"), ToolExpectation("create_note")])),
        ModelSample<String>(
            prompt: "In a sentence, what is a wiki link?",
            expected: nil,
            expectations: TrajectoryExpectation(
                disallowed: [ToolExpectation("edit_note"), ToolExpectation("create_note")])),
    ])

    func subject(from sample: ModelSample<String>) async throws -> ModelSubject<String> {
        try await AssistantHarness.run(sample.promptDescription)
    }

    var evaluators: Evaluators {
        ToolCallEvaluator(allPass: .toolsAllPass, percentagePass: .toolsPercentagePass)
        Evaluator { input, subject in
            guard let expected = input.expected else {
                return subject.value.isEmpty ? answered.failing() : answered.passing()
            }
            return subject.value.localizedCaseInsensitiveContains(expected)
                ? answered.passing() : answered.failing(rationale: subject.value)
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: .toolsAllPass)
        aggregator.computeMean(of: answered)
    }
}

/// One Assistant turn, built exactly as `AssistantModel` builds it, against a
/// throwaway copy of the sample vault with every approval denied.
@MainActor
private enum AssistantHarness {
    static func run(_ prompt: String) async throws -> ModelSubject<String> {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssistantEval-\(UUID().uuidString)", isDirectory: true)
        let sample = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SampleVault")
        try FileManager.default.copyItem(at: sample, to: vault)
        defer { try? FileManager.default.removeItem(at: vault) }

        let collection = Collection(rootURL: vault)
        collection.scan()
        await collection.search.refresh(from: collection.notes)
        let context = ToolContext(collection: collection, search: collection.search,
                                  git: GitService(), permissions: PermissionBroker())
        // Deny anything that asks: an evaluation must never write, even to a
        // copy. Polls with a sleep, not `Task.yield()` — a yield loop on the
        // main actor starves every tool, because every tool hops here to work.
        let denier = Task { @MainActor in
            while !Task.isCancelled {
                if context.permissions.prompt != nil { context.permissions.respond(approved: false) }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { denier.cancel() }

        let models = Features.settings.models
        let window = models.knownContextSize(of: .onDevice)
        let tools = NoteTools.tools(for: context, contextTokens: window)
        let profile = AssistantProfile(
            model: models.onDevice,
            instructions: AssistantInstructions.text(toolNames: Set(tools.map(\.name)),
                                                     collectionName: "SampleVault",
                                                     noteCount: collection.notes.count),
            tools: tools, temperature: 0.2, reasoning: nil,
            historyTokens: window / 2, toolBudget: ToolCallBudget(limit: 16))
        let session = LanguageModelSession(profile: profile)
        let response = try await session.respond(to: prompt)
        if ProcessInfo.processInfo.environment["HN_EVAL_VERBOSE"] == "1" {
            for entry in session.transcript {
                switch entry {
                case .instructions(let i): print("EVAL-TRACE instructions tools:", i.toolDefinitions.map(\.name))
                case .toolCalls(let calls): print("EVAL-TRACE calls:", calls.map { "\($0.toolName) \($0.arguments.jsonString)" })
                case .toolOutput(let output): print("EVAL-TRACE output:", output.toolName, output.segments.map(\.description).joined().prefix(80))
                case .response(let r): print("EVAL-TRACE response:", r.segments.map(\.description).joined().prefix(80))
                default: break
                }
            }
        }
        return ModelSubject(value: response.content, transcript: session.transcript.structuredTranscript)
    }
}

// MARK: - Running

@Suite(.serialized)
struct IntelligenceEvaluationTests {
    static let tags = TagEvaluation()
    static let links = LinkEvaluation()
    static let rewrite = RewriteEvaluation()
    static let longSummary = LongSummaryEvaluation()
    static let assistant = AssistantTrajectoryEvaluation()

    @Test(.evaluates(Self.tags), .enabled(if: evaluationsEnabled))
    func tagsAreWellFormedAndOnTopic() {
        let result = EvaluationContext.current.result
        #expect(result.aggregateValue(.mean(of: Self.tags.wellFormed)) == 1)
        #expect(result.aggregateValue(.mean(of: Self.tags.onTopic)) >= 0.8)
    }

    @Test(.evaluates(Self.links), .enabled(if: evaluationsEnabled))
    func linksComeOnlyFromRealNotes() {
        let result = EvaluationContext.current.result
        // A schema, not a request: this one is a guarantee, so it must be 1.
        #expect(result.aggregateValue(.mean(of: Self.links.onlyCandidates)) == 1)
        #expect(result.aggregateValue(.mean(of: Self.links.findsRelated)) >= 0.66)
    }

    @Test(.evaluates(Self.rewrite), .enabled(if: evaluationsEnabled))
    func rewritesKeepLinksAndFollowInstructions() {
        let result = EvaluationContext.current.result
        #expect(result.aggregateValue(.mean(of: Self.rewrite.keepsLinks)) == 1)
        #expect(result.aggregateValue(.mean(of: Self.rewrite.followsInstruction)) >= 0.66)
    }

    @Test(.evaluates(Self.longSummary), .enabled(if: evaluationsEnabled))
    func longNotesAreSummarisedWhole() {
        let result = EvaluationContext.current.result
        #expect(result.aggregateValue(.mean(of: Self.longSummary.produced)) == 1)
        #expect(result.aggregateValue(.mean(of: Self.longSummary.coversTheEnd)) == 1)
    }

    @Test(.evaluates(Self.assistant, recordTranscripts: true), .enabled(if: evaluationsEnabled))
    func assistantReadsBeforeItAnswersAndNeverEditsUnasked() {
        let result = EvaluationContext.current.result
        #expect(result.aggregateValue(.mean(of: .toolsAllPass)) >= 0.66)
        #expect(result.aggregateValue(.mean(of: Self.assistant.answered)) >= 0.66)
    }
}

// MARK: - Private Cloud Compute, as the app sees it

/// What Private Cloud Compute reports inside the signed, sandboxed app — which
/// is not what an unsandboxed command-line probe reports. One tiny request, so
/// it costs a sliver of the day's allowance; opt-in with `HN_PCC_PROBE=1`.
@Suite struct PrivateCloudComputeProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HN_PCC_PROBE"] == "1"))
    func reportsWhatTheAppCanReach() async {
        // Never without the entitlement: Foundation Models reports the model
        // available and then terminates the process on the first request.
        print("PCC-PROBE enabled in this build:", LanguageModels.privateCloudComputeEnabled)
        guard LanguageModels.privateCloudComputeEnabled else { return }
        let model = PrivateCloudComputeLanguageModel()
        print("PCC-PROBE availability:", model.availability)
        print("PCC-PROBE quota limitReached:", model.quotaUsage.isLimitReached)
        guard model.isAvailable else { return }
        do {
            let session = LanguageModelSession(model: model, instructions: "Reply with one word.")
            let reply = try await session.respond(to: "Say OK.")
            print("PCC-PROBE reply:", reply.content)
        } catch {
            print("PCC-PROBE error:", type(of: error), error.localizedDescription)
        }
    }
}

// MARK: - Research, end to end

/// One real research run on the on-device model: plan, search, read, synthesise.
/// Opt-in with `HN_RESEARCH_PROBE=1` — it searches the web and takes a minute or
/// two. The question is general knowledge; nothing from a vault is involved.
@Suite struct ResearchProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HN_RESEARCH_PROBE"] == "1"
                   && SystemLanguageModel.default.isAvailable),
          .timeLimit(.minutes(5)))
    @MainActor
    func researchesAQuestionOnTheOnDeviceModel() async throws {
        let defaults = UserDefaults(suiteName: "HelloNotesResearchProbe")!
        defaults.set(true, forKey: IntelligenceMigration.doneKey)
        let settings = IntelligenceSettings(defaults: defaults)
        settings.assistantModel = .onDevice
        #expect(DeepResearch.unavailableReason(settings: settings) == nil,
                "research should be offered on an 8K on-device model")

        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResearchProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let collection = Collection(rootURL: vault)
        collection.scan()
        let context = ToolContext(collection: collection, search: collection.search,
                                  git: GitService(), permissions: PermissionBroker(), settings: settings)

        var steps: [String] = []
        var research = DeepResearch(settings: settings, context: context)
        research.onProgress = { steps.append($0) }
        let answer = try await research.run(
            question: "How does the Swift programming language use actors to prevent data races?", depth: 2)
        print("RESEARCH-PROBE steps:", steps)
        print("RESEARCH-PROBE answer:", answer.prefix(600))
        #expect(!answer.isEmpty)
        #expect(answer.localizedCaseInsensitiveContains("actor"))
        #expect(steps.contains { $0.hasPrefix("Researching") })
    }
}
