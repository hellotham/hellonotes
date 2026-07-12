//
//  SkillStore.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Agent Skills (Anthropic's standard): a `SKILL.md` file anywhere in the collection
//  with YAML front matter (name, description) plus a Markdown body. Progressive
//  disclosure — only the name+description of each skill is injected into the
//  system prompt; the body is loaded on demand via the `load_skill` tool.
//

import Foundation
import Observation

struct Skill: Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    let description: String
    let body: String
    let url: URL
}

@MainActor
@Observable
final class SkillStore {
    private(set) var skills: [Skill] = []

    /// Re-scan the collection's notes for `SKILL.md` files.
    func refresh(from notes: [Note]) {
        skills = notes
            .filter { $0.fileURL.lastPathComponent.lowercased() == "skill.md" }
            .compactMap { Self.parse($0.fileURL) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    func skill(named name: String) -> Skill? {
        skills.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The name+description list injected into the system prompt (level 1).
    var discoveryList: String {
        skills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
    }

    private static func parse(_ url: URL) -> Skill? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var name = url.deletingLastPathComponent().lastPathComponent
        var description = ""
        var body = text

        // Parse a leading `--- ... ---` YAML front-matter block.
        if text.hasPrefix("---") {
            let scanner = text.dropFirst(3)
            if let end = scanner.range(of: "\n---") {
                let front = String(scanner[scanner.startIndex..<end.lowerBound])
                body = String(scanner[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                for line in front.split(separator: "\n") {
                    let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard parts.count == 2 else { continue }
                    let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    switch parts[0].lowercased() {
                    case "name": name = value
                    case "description": description = value
                    default: break
                    }
                }
            }
        }
        guard !name.isEmpty else { return nil }
        if description.isEmpty { description = "A skill defined in \(url.lastPathComponent)." }
        return Skill(name: name, description: description, body: body, url: url)
    }
}

// MARK: - Tool

struct LoadSkillTool: AgentTool {
    let name = "load_skill"
    let description = "Load the full instructions for one of the skills listed in your system prompt, by name."
    var parameters: JSONValue {
        .objectSchema(
            properties: ["skill": .stringSchema("The name of the skill to load.")],
            required: ["skill"]
        )
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> String {
        guard let store = context.skills else { throw ToolError.failed("No skills are available.") }
        guard let query = arguments.string("skill") else { throw ToolError.badArguments("`skill` is required.") }
        guard let skill = store.skill(named: query) else {
            let names = store.skills.map(\.name).joined(separator: ", ")
            throw ToolError.notFound("No skill named “\(query)”. Available: \(names.isEmpty ? "none" : names).")
        }
        return "# Skill: \(skill.name)\n\n\(skill.body)"
    }
}
