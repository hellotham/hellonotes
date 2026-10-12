//
//  PrivacyLineTests.swift
//  HelloNotesTests
//
//  What the app says about where notes go is true of the feature it is said on.
//
//  Under the Assistant, and in the AI settings, both on-device models said
//  "Runs on this device. Your notes never leave it." — true of the model, and
//  printed on an Assistant that searches the web with terms the model writes
//  after reading notes. The website's privacy page said so; the app's own line
//  did not (found by fact-checking that page against the source,
//  implemented.md §51.44).
//
//  The line about the model is about the model now, and what a web search
//  sends is a line of its own, shown wherever the web tools are. These hold
//  the two together: the day a tool set gains or loses the web, the test that
//  fails names the sentence to change.
//

import Foundation
import FoundationModels
import Testing
@testable import HelloNotes

@MainActor
struct PrivacyLineTests {

    /// No line about a model promises what the web tools can break.
    @Test(.scratchDefaults) func noModelsLinePromisesNotesNeverLeave() {
        let models = LanguageModels(mlx: MLXModelStore(defaults: ScratchDefaults.suite()))
        for choice in [ModelChoice.onDevice, .mlx] {
            let line = models.privacySummary(of: choice)
            #expect(!line.localizedCaseInsensitiveContains("never leave"),
                    "\(choice): “\(line)” — untrue of an Assistant that searches the web")
            #expect(line.contains("on this device"), "\(choice) no longer says where it runs: “\(line)”")
        }
    }

    /// The Assistant shows the web line whenever it has tools — so every set
    /// of tools it can be given must reach the web, or that line claims a
    /// search the model cannot make; and the reverse, which is the defect: a
    /// set that reaches the web with no line saying so.
    @Test func everyToolSetTheAssistantCanHaveReachesTheWeb() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivacyLine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = Collection(rootURL: root)
        let context = ToolContext(collection: collection, search: collection.search, git: collection.git,
                                  permissions: PermissionBroker())
        // The on-device window, and one large enough for the full set.
        for window in [8_192, 32_768] {
            let names = NoteTools.tools(for: context, contextTokens: window).map(\.name)
            #expect(NoteTools.reachesTheWeb(names),
                    "at \(window) tokens the Assistant has no web tool, and says it can search the web: \(names)")
        }
        // The control: the names are the tools' own, so a renamed tool is seen.
        #expect(NoteTools.reachesTheWeb([WebSearchTool().name]))
        #expect(!NoteTools.reachesTheWeb(["search_notes", "read_note", "edit_note"]))
    }

    /// The line is shown in both places a model is described, and only where
    /// the model has tools.
    @Test func theWebLineIsShownWhereverAModelWithToolsIsDescribed() throws {
        let assistant = try Self.source("UI/Assistant/AssistantView.swift")
        let settings = try Self.source("UI/Assistant/IntelligenceSettingsView.swift")
        #expect(Self.shows(assistant, after: "if usesTools {"),
                "the Assistant's opening no longer says what a web search sends")
        #expect(Self.shows(settings, after: "if models.supportsTools(choice) {"),
                "the AI settings no longer say what a web search sends")
        #expect(LanguageModels.webSummary.contains("DuckDuckGo") && LanguageModels.webSummary.contains("your notes"))
    }

    /// Whether `webSummary` is drawn within the few lines after `condition`.
    private static func shows(_ source: String, after condition: String) -> Bool {
        var rest = source[...]
        while let found = rest.range(of: condition) {
            let block = rest[found.upperBound...].split(separator: "\n", omittingEmptySubsequences: false).prefix(4)
            if block.contains(where: { $0.contains("LanguageModels.webSummary") }) { return true }
            rest = rest[found.upperBound...]
        }
        return false
    }

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "HelloNotes")
            .appending(path: name), encoding: .utf8)
    }
}
