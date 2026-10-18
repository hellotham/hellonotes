//
//  DeepResearch.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Deep research as an orchestrator and researchers: plan the question into
//  focused sub-questions, research each in its own session with web and note
//  tools, then synthesise one cited answer.
//
//  Three things changed with Foundation Models, each for a reason:
//
//  * **The plan is generated, not parsed.** It was a numbered list the code
//    split on newlines and stripped of digits — which turned "2026 goals" into
//    "goals". It is a `@Generable` list now, so it arrives as a list.
//  * **Each researcher is a session.** The tool loop the app used to run by hand
//    — stream, collect calls, run them, append results, go again, with an
//    iteration cap and a final tool-less turn — is what a `LanguageModelSession`
//    does. What is left here is the part that is actually research.
//  * **It needs a window to research in** — 8,000 tokens. Tool output is scaled
//    to the window (`ToolLimits`: a fetched page is cut to about 4,000
//    characters on an 8K model), so AFM 3 Core Advanced and an MLX model on
//    iPhone can research; AFM 3 Core's 4,096 cannot, and the sheet says so
//    rather than failing several researchers in. A sub-question that still
//    overflows is reported in the notes the synthesis reads, not fatal.
//

import Foundation
import FoundationModels

@Generable
nonisolated struct ResearchPlan {
    @Guide(description: "Focused, non-overlapping questions that together answer the original question.",
           .count(1...4))
    var questions: [String]
}

@MainActor
struct DeepResearch {
    /// The smallest window research is offered on. It was 16,000 — which, with
    /// Private Cloud Compute not yet available, took Research away from every
    /// iPhone, every iPad and every Mac without an MLX model.
    static let minimumContextTokens = 8_000

    let settings: IntelligenceSettings
    let context: ToolContext
    /// The model asked for: an Assistant conversation's own, when the
    /// Assistant's tool runs it — the Settings default, which it used, sent a
    /// conversation kept on this device to Cloud (Apple) — or `nil` for the
    /// default.
    var requested: ModelOption? = nil
    /// Told the model each run starts on, again after a fallback, so the
    /// result can say which model made it.
    var onModel: (ModelOption) -> Void = { _ in }
    /// A running account of what is happening, for a person watching a task
    /// that takes minutes. "Researching…" on its own reads as a hang.
    var onProgress: (String) -> Void = { _ in }

    private var models: LanguageModels { settings.models }
    /// The chosen model, or Local (Apple) while Cloud (Apple)'s allowance for
    /// today is spent (`LanguageModels.serving`).
    private var option: ModelOption {
        models.serving(option: requested ?? settings.option(for: settings.model))
    }

    /// Why research can't run on the chosen model, or `nil` when it can.
    static func unavailableReason(settings: IntelligenceSettings, requested: ModelOption? = nil) -> String? {
        let models = settings.models
        let asked = requested ?? settings.option(for: settings.model)
        let option = models.serving(option: asked)
        return reason(on: option, models: models, standingIn: option != asked)
    }

    /// Why research can't run on `option`, or `nil` when it can. `standingIn`:
    /// `option` is answering for Cloud (Apple), whose allowance for today is
    /// spent — so the answer is not "choose Cloud (Apple)", which the person
    /// did.
    private static func reason(on option: ModelOption, models: LanguageModels, standingIn: Bool) -> String? {
        let choice = option.choice
        if case .unavailable(let why) = models.availability(ofOption: option) { return why }
        guard models.supportsTools(option: option) else {
            return "Research searches the web with tools, and \(models.title(of: option)) can't use tools. Choose \(LanguageModels.appleModels(joinedBy: "or")) in AI settings, or an MLX model it doesn't mark \"Can't use tools\"."
        }
        guard models.knownContextSize(of: choice) >= minimumContextTokens else {
            if standingIn {
                return LanguageModels.limitReached(resets: models.privateCloudResetDate, fallingBack: false)
                    + " Research reads whole web pages, which needs a larger model than \(models.title(of: option)), so it can run again once the limit resets."
            }
            return "Research reads whole web pages, which needs a larger model than \(models.title(of: option))."
                + (LanguageModels.largerModels(than: choice).map { " Choose \($0) in AI settings." } ?? "")
        }
        return nil
    }

    func run(question: String, depth: Int) async throws -> String {
        if let reason = Self.unavailableReason(settings: settings, requested: requested) {
            throw IntelligenceError.unavailable(reason)
        }
        var option = option
        while true {
            do {
                onModel(option)
                return try await research(question, depth: depth, on: option)
            } catch let refusal as FellBack {
                // Cloud (Apple) refused a step for today's limit: the whole
                // run again, from its plan, on this device — if research can
                // run there at all. It started there unchecked, and on a
                // device whose own window is too small for research every
                // step then failed.
                if let reason = Self.reason(on: refusal.option, models: models, standingIn: true) {
                    throw IntelligenceError.unavailable(reason)
                }
                option = refusal.option
            }
        }
    }

    /// Thrown in place of Cloud (Apple)'s refusal for today's limit, before
    /// any step has turned the error into words.
    private struct FellBack: Error { let option: ModelOption }

    private func research(_ question: String, depth: Int, on option: ModelOption) async throws -> String {
        let choice = option.choice
        let model = try models.model(forOption: option)
        let name = models.title(of: option)
        let window = await models.contextSize(of: choice)
        let depth = max(1, min(4, depth))
        let reasoning = models.supportsReasoning(choice) ? ContextOptions.ReasoningLevel.moderate : nil

        do {
            // 1. Plan.
            onProgress("Planning the research…")
            let planner = LanguageModelSession(
                model: model,
                instructions: "You plan research. Break the question into at most \(depth) focused, non-overlapping questions that together answer it.")
            let plan: [String]
            do {
                let response = try await planner.respond(to: question, generating: ResearchPlan.self)
                plan = response.content.questions
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let fallback = models.fallback(after: error, on: choice) { throw FellBack(option: settings.option(for: fallback)) }
                plan = []   // A failed plan still leaves the question itself to research.
            }
            let questions = Array((plan.isEmpty ? [question] : plan).prefix(depth))

            // 2. Research each question in its own session.
            let limits = ToolLimits(contextTokens: window)
            var findings: [String] = []
            for (index, sub) in questions.enumerated() {
                try Task.checkCancellation()
                onProgress("Researching \(index + 1) of \(questions.count): \(sub)")
                let researcher = LanguageModelSession(
                    model: model,
                    tools: [
                        WebSearchTool(),
                        WebFetchTool(limits: limits),
                        SearchNotesTool(context: context, limits: limits),
                        ReadNoteTool(context: context, limits: limits),
                    ],
                    instructions: """
                    You are a researcher. Use web_search to find sources and web_fetch to read \
                    the most promising ones; search_notes and read_note look in the person's own \
                    notes. Report what you found as concise facts, and list the address of every \
                    web page you relied on.
                    """)
                let report: String
                do {
                    report = try await researcher.respond(
                        to: sub, options: GenerationOptions(),
                        contextOptions: ContextOptions(reasoningLevel: reasoning)).content
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if let fallback = models.fallback(after: error, on: choice) { throw FellBack(option: settings.option(for: fallback)) }
                    // Say what failed, in the notes the synthesis reads, so the
                    // gap is reported rather than papered over.
                    report = "(This part of the research failed: \(IntelligenceError.describe(error, modelName: name)))"
                }
                findings.append("### \(sub)\n\(report)")
            }

            // 3. Synthesise.
            try Task.checkCancellation()
            onProgress("Writing up what was found…")
            let notes = findings.joined(separator: "\n\n")
            let budget = TokenBudget.inputTokens(context: window, instructions: Self.synthesisInstructions, reply: 2_000)
            let (brief, truncated) = await offMain { TokenBudget.prefix(notes, tokens: budget) }
            let synthesiser = LanguageModelSession(model: model, instructions: Self.synthesisInstructions)
            let synthesis = try await synthesiser.respond(
                to: "Question: \(question)\n\nResearch notes\(truncated ? " (the later notes did not fit and were left out)" : ""):\n\n\(brief)",
                options: GenerationOptions(),
                contextOptions: ContextOptions(reasoningLevel: models.supportsReasoning(choice) ? .deep : nil)
            ).content
            let answer = synthesis.trimmingCharacters(in: .whitespacesAndNewlines)
            return answer.isEmpty ? notes : answer
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as IntelligenceError {
            throw error
        } catch let refusal as FellBack {
            throw refusal
        } catch {
            if let fallback = models.fallback(after: error, on: choice) { throw FellBack(option: settings.option(for: fallback)) }
            throw IntelligenceError.failed(IntelligenceError.describe(error, modelName: name))
        }
    }

    private static let synthesisInstructions = """
    Combine the research notes into one clear, well-structured answer to the question, in \
    Markdown. Cite web sources inline by their addresses. Say plainly where the notes \
    disagree, are uncertain, or leave a gap.
    """
}

/// Deep research, offered to the Assistant as a tool on models with the room for it.
nonisolated struct DeepResearchTool: Tool {
    let context: ToolContext
    let name = "deep_research"
    let description = "Research a question thoroughly on the web: it plans sub-questions, reads several sources and returns a cited answer. Slow — use it only when a question needs current or external information in depth."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The question to research.")
        var question: String
        @Guide(description: "How many sub-questions to explore.", .range(1...4))
        var depth: Int
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        try await ToolOutcome.run {
            try await context.deepResearch(arguments.question, depth: arguments.depth)
        }
    }
}

extension ToolContext {
    func deepResearch(_ question: String, depth: Int) async throws -> String {
        guard let settings else { throw ToolError.failed("Research isn't available here.") }
        return try await DeepResearch(settings: settings, context: self, requested: modelChoice)
            .run(question: question, depth: depth)
    }
}
