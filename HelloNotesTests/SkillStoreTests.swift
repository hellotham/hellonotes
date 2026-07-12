//
//  SkillStoreTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 12/7/2026.
//

import Testing
import Foundation
@testable import HelloNotes

@MainActor
struct SkillStoreTests {

    private func sampleVault() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SampleVault")
    }

    @Test
    func discoversAndParsesSkillFrontMatter() throws {
        let indexer = Collection(rootURL: sampleVault())
        indexer.scan()

        let store = SkillStore()
        store.refresh(from: indexer.notes)

        let skill = try #require(store.skill(named: "weekly-review"))
        #expect(skill.description.contains("weekly review"))
        #expect(skill.body.contains("Weekly Review"))
        // Front matter must be stripped from the body.
        #expect(!skill.body.contains("description:"))
        // The discovery list (level-1 disclosure) names the skill.
        #expect(store.discoveryList.contains("weekly-review"))
    }
}
