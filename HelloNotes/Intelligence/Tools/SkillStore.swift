//
//  SkillStore.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Agent Skills (Anthropic's standard): a `SKILL.md` file anywhere in the collection
//  with YAML front matter (name, description) plus a Markdown body. Progressive
//  disclosure — the name and description of each skill are listed by the
//  `load_skill` tool, and a body is loaded only when the model asks for it.
//
//  The list used to be written into the system prompt. It no longer is: a
//  skill's description is text from a file in the vault, and Foundation Models'
//  guidance is unambiguous that content from outside the app never goes in the
//  instructions, where the model trusts it as the app's own voice. As tool
//  output it is data the model reads, which is what it is.
//

import Foundation
import FoundationModels
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
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Re-read the collection's `SKILL.md` files, off the main actor.
    ///
    /// This runs whenever the note list changes, so it must never read on the
    /// main actor, and it reads only files whose content is on this device: a
    /// cloud-only `SKILL.md` would otherwise download on every refresh, and a
    /// mirror's zero-byte placeholder would load as a skill with no
    /// instructions. A newer refresh cancels an older one, so a slow read can't
    /// land last with a stale list. Returns the refresh, for a caller that
    /// needs to wait for it.
    @discardableResult
    func refresh(from notes: [Note]) -> Task<Void, Never> {
        let candidates = notes.filter { $0.fileURL.lastPathComponent.lowercased() == "skill.md" }
        refreshTask?.cancel()
        let task = Task { [weak self] in
            var parsed: [Skill] = []
            if !candidates.isEmpty {
                parsed = await offMain {
                    candidates.filter(FileIO.hasContentAvailable).compactMap { SkillStore.parse($0.fileURL) }
                }
            }
            guard !Task.isCancelled else { return }
            self?.skills = parsed.sorted { $0.name.lowercased() < $1.name.lowercased() }
        }
        refreshTask = task
        return task
    }

    func skill(named name: String) -> Skill? {
        skills.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The name and description of every skill, served by `load_skill` when it
    /// is called with no name — never written into the instructions.
    var discoveryList: String {
        skills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
    }

    private nonisolated static func parse(_ url: URL) -> Skill? {
        guard let text = try? FileIO.readString(at: url) else { return nil }
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

nonisolated struct LoadSkillTool: Tool {
    let context: ToolContext
    let name = "load_skill"
    let description = "Load step-by-step instructions saved as a skill in this collection. Give an empty name to list the skills."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The skill's name, or an empty string to list the skills.")
        var skill: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        try await ToolOutcome.run { try await context.loadSkill(arguments.skill) }
    }
}
