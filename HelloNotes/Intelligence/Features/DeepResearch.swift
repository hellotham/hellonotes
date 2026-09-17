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
    /// A running account of what is happening, for a person watching a task
    /// that takes minutes. "Researching…" on its own reads as a hang.
    var onProgress: (String) -> Void = { _ in }

    private var models: LanguageModels { settings.models }
    private var choice: ModelChoice { settings.assistantModel }

    /// Why research can't run on the Assistant's model, or `nil` when it can.
    static func unavailableReason(settings: IntelligenceSettings) -> String? {
        let models = settings.models
        let choice = settings.assistantModel
        if case .unavailable(let why) = models.availability(of: choice) { return why }
        guard models.supportsTools(choice) else {
            return "Research searches the web with tools, and \(models.name(of: choice)) can't use tools. Choose System, or an MLX model AI settings doesn't mark \"Can't use tools\", for the Assistant."
        }
        guard models.knownContextSize(of: choice) >= minimumContextTokens else {
            return "Research reads whole web pages, which needs a larger model than \(models.name(of: choice)). Choose \(LanguageModels.largerModels) for the Assistant in AI settings."
        }
        return nil
    }

    func run(question: String, depth: Int) async throws -> String {
        if let reason = Self.unavailableReason(settings: settings) {
            throw IntelligenceError.unavailable(reason)
        }
        let model = try models.model(for: choice)
        let name = models.name(of: choice)
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
        } catch {
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
        return try await DeepResearch(settings: settings, context: self).run(question: question, depth: depth)
    }
}
