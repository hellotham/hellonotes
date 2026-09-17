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
//  To evaluate an MLX model instead, add the **absolute** path of its folder — an
//  MLX model folder, or a model's folder in a Hugging Face cache — which is
//  loaded through the same path as the app's "Choose a Model Folder…" (a `~`
//  would expand to the test host's sandbox container, not your home):
//
//      TEST_RUNNER_HN_EVAL_MLX_FOLDER=/Users/you/.cache/huggingface/hub/models--org--name
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

/// The MLX model to evaluate instead of the on-device model, if one was given.
private let mlxFolder: URL? = ProcessInfo.processInfo.environment["HN_EVAL_MLX_FOLDER"]
    .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

/// Whether the evaluated model can call tools: the on-device model can; an MLX
/// model can if its chat template shows it tools — the same test the app makes.
private let evaluatedModelUsesTools: Bool = {
    guard let mlxFolder else { return true }
    let directory = MLXModelFolder.currentSnapshot(of: mlxFolder) ?? mlxFolder
    return MLXChatTemplate.rendersTools(in: directory) ?? true
}()

/// Whether evaluations were asked for, and can run here.
private let evaluationsEnabled =
    ProcessInfo.processInfo.environment["HN_EVALUATIONS"] == "1"
    && (mlxFolder != nil || SystemLanguageModel.default.isAvailable)

/// The features under test, with settings kept out of the person's own
/// preferences — including an MLX store of its own, so the person's chosen MLX
/// model is neither read nor replaced.
@MainActor
private enum Features {
    static let choice: ModelChoice = mlxFolder == nil ? .onDevice : .mlx

    static let settings: IntelligenceSettings = {
        let defaults = UserDefaults(suiteName: "HelloNotesEvaluations")!
        defaults.set(true, forKey: IntelligenceMigration.doneKey)
        defaults.removeObject(forKey: MLXModelStore.Keys.model)
        defaults.removeObject(forKey: MLXModelStore.Keys.folder)
        let settings = IntelligenceSettings(
            defaults: defaults, models: LanguageModels(mlx: MLXModelStore(defaults: defaults)))
        settings.featuresModel = choice
        settings.assistantModel = choice
        return settings
    }()

    private static var preparation: Task<Void, Error>?

    /// Choose the MLX model, once, and fail with the app's own explanation if
    /// it cannot run — before any evaluation reports a model failure that is
    /// really a missing folder.
    ///
    /// One shared task, not a flag: separate suites run in parallel, and two
    /// callers each choosing the folder would each mark the model "Checking…"
    /// while the other's evaluation was using it.
    static func prepare() async throws {
        if preparation == nil {
            preparation = Task { @MainActor in
                if let mlxFolder {
                    let store = settings.mlx
                    await store.use(folder: mlxFolder)
                    if let reason = store.availability.reason { throw IntelligenceError.unavailable(reason) }
                    print("EVAL model: MLX \(store.modelName) from \(store.chosen?.directory.path ?? mlxFolder.path)")
                } else {
                    print("EVAL model: on-device \(settings.models.name(of: .onDevice))")
                }
            }
        }
        try await preparation?.value
    }

    static var service: IntelligenceService { IntelligenceService(settings: settings) }

    static func tags(_ note: String) async throws -> [String] {
        try await prepare()
        return try await service.suggestTags(for: note, existing: [])
    }

    static func links(_ note: String, candidates: [String]) async throws -> [String] {
        try await prepare()
        return try await service.suggestLinks(for: note, candidates: candidates)
    }

    static func rewrite(_ text: String, instruction: String) async throws -> String {
        try await prepare()
        return try await service.rewrite(text, instruction: instruction)
    }

    static func summary(_ note: String) async throws -> String {
        try await prepare()
        return try await service.summarize(note)
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

        try await Features.prepare()
        let models = Features.settings.models
        let window = models.knownContextSize(of: Features.choice)
        let tools = NoteTools.tools(for: context, contextTokens: window)
        let profile = AssistantProfile(
            model: try models.model(for: Features.choice),
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

    @Test(.evaluates(Self.assistant, recordTranscripts: true),
          .enabled(if: evaluationsEnabled && evaluatedModelUsesTools, "the model can't call tools"))
    func assistantReadsBeforeItAnswersAndNeverEditsUnasked() {
        let result = EvaluationContext.current.result
        #expect(result.aggregateValue(.mean(of: .toolsAllPass)) >= 0.66)
        #expect(result.aggregateValue(.mean(of: Self.assistant.answered)) >= 0.66)
    }
}

/// A model that can't call tools is given none. Found on Gemma 3 27B, whose
/// template drops tool definitions: offered the Assistant's tools it wrote
/// `read_note("Welcome")` in a code block as its answer, and nothing ran. This
/// drives the real `AssistantModel` — the same session, instructions and tool
/// decision the app makes — and requires an answer in words.
@Suite(.serialized)
struct AssistantWithoutToolsEvaluation {
    @Test(.enabled(if: evaluationsEnabled && !evaluatedModelUsesTools, "the model can call tools"),
          .timeLimit(.minutes(10)))
    @MainActor
    func aModelWithoutToolsAnswersInsteadOfImitatingCalls() async throws {
        try await Features.prepare()
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("ChatOnlyEval-\(UUID().uuidString)", isDirectory: true)
        let vault = base.appendingPathComponent("SampleVault", isDirectory: true)
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        try manager.copyItem(at: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SampleVault"), to: vault)
        defer { try? manager.removeItem(at: base) }

        let collection = Collection(rootURL: vault)
        collection.scan()
        let assistant = AssistantModel(settings: Features.settings)
        assistant.toolContext = ToolContext(collection: collection, search: collection.search,
                                            git: GitService(), permissions: PermissionBroker())
        assistant.sessionStore = ChatSessionStore(collectionURL: vault, baseDirectory: base)
        #expect(assistant.agentMode && !assistant.canUseTools)

        assistant.input = "What are the section headings in my Welcome note?"
        assistant.send()
        let deadline = ContinuousClock.now + .seconds(8 * 60)
        while assistant.isResponding && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }

        #expect(!assistant.isResponding, "no answer within eight minutes")
        #expect(assistant.errorText == nil, "\(assistant.errorText ?? "")")
        let calls = assistant.entries.filter { if case .toolCalls = $0 { true } else { false } }
        let reply = assistant.entries.compactMap { entry -> String? in
            guard case .response(let response) = entry else { return nil }
            return response.segments.map(\.description).joined()
        }.joined()
        print("EVAL chat-only reply:", reply.prefix(400))
        #expect(calls.isEmpty)
        #expect(!reply.isEmpty)
        #expect(!reply.contains("tool_code") && !reply.contains("read_note("),
                "the model imitated a tool call instead of answering")
        // And it must not describe a note it cannot see. The first version of
        // this passed while the model listed four headings the note lacks.
        let admits = ["can't", "cannot", "can not", "unable", "don't have access", "do not have access", "not able"]
            .contains { reply.localizedCaseInsensitiveContains($0) }
        #expect(admits, "the reply did not say the note can't be read: \(reply.prefix(300))")
        #expect(!reply.localizedCaseInsensitiveContains("Getting Started"),
                "the reply named a heading it could not have read")
    }
}

/// The whole change path on the chosen model: the Assistant calls an editing
/// tool with arguments it worked out itself, the person approves, and the note
/// on disk changes — and nothing else in it does.
///
/// The trajectory evaluation denies every approval on purpose, so until this
/// ran, no model had ever changed a file through the app's tools.
@Suite(.serialized)
struct AssistantEditEvaluation {
    @Test(.enabled(if: evaluationsEnabled && evaluatedModelUsesTools, "the model can't call tools"),
          .timeLimit(.minutes(10)))
    @MainActor
    func anApprovedEditReachesTheFile() async throws {
        try await Features.prepare()
        let manager = FileManager.default
        let vault = manager.temporaryDirectory.appendingPathComponent("EditEval-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: vault) }
        let note = vault.appendingPathComponent("Shopping.md")
        try FileIO.write("# Shopping\n\n- apples\n- pears\n- flour\n", to: note)

        let collection = Collection(rootURL: vault)
        collection.scan()
        let assistant = AssistantModel(settings: Features.settings)
        let permissions = PermissionBroker()
        assistant.toolContext = ToolContext(collection: collection, search: collection.search,
                                            git: GitService(), permissions: permissions)
        assistant.sessionStore = ChatSessionStore(collectionURL: vault, baseDirectory: vault)

        // A person clicking Approve. Sleeps rather than yields: every tool hops
        // to the main actor, and a yield loop here would starve them.
        let approver = Task { @MainActor in
            while !Task.isCancelled {
                if permissions.prompt != nil { permissions.respond(approved: true) }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { approver.cancel() }

        assistant.input = "In my Shopping note, change pears to plums. Leave everything else exactly as it is."
        assistant.send()
        let deadline = ContinuousClock.now + .seconds(8 * 60)
        while assistant.isResponding && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }

        #expect(!assistant.isResponding, "no answer within eight minutes")
        #expect(assistant.errorText == nil, "\(assistant.errorText ?? "")")
        let after = try FileIO.readString(at: note)
        print("EVAL edited note:\n\(after)")
        #expect(after.contains("plums"), "the edit never reached the file")
        #expect(!after.contains("pears"))
        #expect(after.contains("apples") && after.contains("flour"), "the rest of the note was not left alone")
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
