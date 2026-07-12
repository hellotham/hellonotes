//
//  DeepResearchTool.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Deep research as an orchestrator + sub-agents: decompose the question into
//  focused sub-questions, run a web-research sub-agent (search → fetch → observe)
//  for each, then synthesize a single cited answer. Sub-agents use the headless
//  AgentRunner with a scoped, read-only + web tool set.
//

import Foundation

struct DeepResearchTool: AgentTool {
    let name = "deep_research"
    let description = "Research a question in depth on the web: it decomposes the question, searches and reads multiple sources, and returns a synthesized, cited answer. Use for anything needing current or external information."
    var parameters: JSONValue {
        .objectSchema(
            properties: [
                "question": .stringSchema("The research question to investigate."),
                "depth": .intSchema("How many sub-questions to explore (1–4, default 3)."),
            ],
            required: ["question"]
        )
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let question = arguments.string("question") else { throw ToolError.badArguments("`question` is required.") }
        guard let settings = context.settings else { throw ToolError.failed("Research is unavailable (no provider configured).") }
        let kind = settings.activeProvider
        guard kind.supportsTools else { throw ToolError.failed("Deep research needs a tool-capable provider; \(kind.displayName) can't call tools.") }
        let (provider, model): (LLMProvider, String)
        do { (provider, model) = try ProviderFactory.make(for: kind, settings: settings) }
        catch { throw ToolError.failed(error.localizedDescription) }

        let depth = max(1, min(4, arguments.int("depth") ?? 3))
        let researchTools: [AgentTool] = [WebSearchTool(), WebFetchTool(), SearchNotesTool(), ReadNoteTool()]

        // 1. Decompose into focused sub-questions.
        let planner = AgentRunner(
            provider: provider, model: model, tools: [], context: context,
            systemPrompt: "You plan web research. Break the user's question into \(depth) focused, non-overlapping sub-questions. Reply with each sub-question on its own line and nothing else.",
            maxIterations: 1)
        let plan = (try? await planner.run(question)) ?? ""
        var subQuestions = plan.split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-*0123456789. \t")) }
            .filter { !$0.isEmpty }
        if subQuestions.isEmpty { subQuestions = [question] }
        subQuestions = Array(subQuestions.prefix(depth))

        // 2. Research each sub-question with its own web-research sub-agent.
        var findings: [String] = []
        for sub in subQuestions {
            let researcher = AgentRunner(
                provider: provider, model: model, tools: researchTools, context: context,
                systemPrompt: "You are a web researcher. Use web_search to find sources, then web_fetch to read the most promising ones. Return a concise, factual summary of what you found, including the source URLs you used.",
                maxIterations: 6)
            let report = (try? await researcher.run(sub)) ?? "(no findings)"
            findings.append("### \(sub)\n\(report)")
        }

        // 3. Synthesize a single cited answer.
        let synthesizer = AgentRunner(
            provider: provider, model: model, tools: [], context: context,
            systemPrompt: "Synthesize the research notes into one clear, well-structured answer to the user's question. Cite source URLs inline. Note any uncertainty or gaps.",
            maxIterations: 1)
        let synthesis = try await synthesizer.run(
            "Question: \(question)\n\nResearch notes:\n\n" + findings.joined(separator: "\n\n"))
        return synthesis.isEmpty ? findings.joined(separator: "\n\n") : synthesis
    }
}
