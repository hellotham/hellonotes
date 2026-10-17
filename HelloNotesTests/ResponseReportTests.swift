//
//  ResponseReportTests.swift
//  HelloNotesTests
//
//  Reporting something a model wrote, and reaching HelloNotes at all — what
//  App Review Guideline 1.2, as revised on 16 October 2026, asks of an app
//  that generates content: "a mechanism to report offensive content" and
//  "published contact information so users can easily reach you"
//  (docs/implemented.md §51.53).
//

import Foundation
import Testing
@testable import HelloNotes

@MainActor
struct ResponseReportTests {

    /// What the person's mail app is handed, read back as it reads it.
    private func decoded(_ report: ResponseReport) throws -> (address: String, subject: String, body: String) {
        let url = try #require(report.mailURL)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "mailto")
        let items = components.queryItems ?? []
        return (components.path,
                items.first { $0.name == "subject" }?.value ?? "",
                items.first { $0.name == "body" }?.value ?? "")
    }

    /// The response, the question, the feature, the model and the versions —
    /// to the published address — and a body that arrives whole: a response
    /// with an `&` or a `#` in it must not cut the message short.
    @Test func aReportCarriesTheResponseWhole() throws {
        let response = "Tea & toast? Done. #breakfast = 50% of mornings\nSecond line."
        let report = ResponseReport(feature: "Assistant", model: "System model", response: response,
                                    prompt: "What did I eat?")
        let (address, subject, body) = try decoded(report)

        #expect(address == SupportRequestSection.supportAddress)
        #expect(subject.contains("Assistant"))
        #expect(body == report.body, "the body did not survive the trip through the URL")
        #expect(body.contains(response))
        #expect(body.contains("What did I eat?"))
        #expect(body.contains("Model: System model"))
        #expect(body.contains(SupportRequestSection.versionLines))
        #expect(body.contains("Read this through before sending"))
    }

    /// A long response is cut, and says by how much; so is a long question.
    @Test func aLongResponseIsCutAndSaysSo() throws {
        let response = String(repeating: "a", count: ResponseReport.responseLimit + 250)
        let prompt = String(repeating: "q", count: ResponseReport.promptLimit + 40)
        let body = try decoded(ResponseReport(feature: "Rewrite", model: "m", response: response,
                                              prompt: prompt)).body
        #expect(body.contains(String(repeating: "a", count: ResponseReport.responseLimit) + "… (250 more characters)"))
        #expect(!body.contains(String(repeating: "a", count: ResponseReport.responseLimit + 1)))
        #expect(body.contains("… (40 more characters)"))
    }

    /// Without a question there is no section for one.
    @Test func aSuggestionHasNoQuestionSection() throws {
        let body = try decoded(ResponseReport(feature: "Summary", model: "m", response: "A note about tea.")).body
        #expect(!body.contains("what it was asked"))
    }

    /// **The address in the app is the one the website publishes** — read from
    /// the website's own source, and loudly when it cannot be found there,
    /// since a test that reads a document fails silently when the document
    /// moves (CLAUDE.md).
    @Test func theContactAddressIsTheOneTheWebsitePublishes() throws {
        let site = try String(contentsOf: URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "website/src/lib/site.ts"), encoding: .utf8)
        let published = try #require(site.firstMatch(of: /email: '([^']+)'/)?.output.1,
                                     "website/src/lib/site.ts no longer says `email: '…'`")
        #expect(String(published) == SupportRequestSection.supportAddress)
        #expect(SupportSettingsView.contactURL.absoluteString == "mailto:\(published)")
        #expect(ResponseReport.supportPage.absoluteString == "https://hellotham.com/hellonotes/support",
                "the support page moved — and a trailing slash 404s there (`SupportSettingsView.privacyURL`)")
    }
}

/// **Every place the app shows text a model wrote offers Report…** Read from
/// the source, so it catches a surface that loses the action, and cannot see
/// whether one draws — the iOS interface tests can (CLAUDE.md, "a
/// source-symmetry check cannot see whether a screen renders").
struct AIReportSurfacesTests {

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "HelloNotes/\(path)"), encoding: .utf8)
    }

    /// File, and the features in it that show a model's text.
    private static let surfaces: [(file: String, features: [String])] = [
        ("UI/Assistant/AssistantView.swift", ["Assistant"]),
        ("UI/LibraryChatView.swift", ["Ask Your Library"]),
        ("UI/RewriteSelectionView.swift", ["Rewrite"]),
        ("UI/ComposeNoteView.swift", ["New Note from a Prompt"]),
        ("UI/Shell/NoteInspector.swift", ["Summary", "Suggested Tags", "Suggested Links"]),
    ]

    @Test func everySurfaceThatShowsAModelsTextOffersAReport() throws {
        for surface in Self.surfaces {
            let text = try Self.source(surface.file)
            for feature in surface.features {
                #expect(text.contains("ResponseReport(feature: \"\(feature)\""),
                        "\(surface.file) shows what the model wrote for \(feature) with nothing to report it by")
            }
            #expect(text.components(separatedBy: "ReportResponseButton").count - 1 >= surface.features.count,
                    "\(surface.file) builds a report it offers no button for")
        }
    }
}
