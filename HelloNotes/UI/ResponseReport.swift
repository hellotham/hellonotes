//
//  ResponseReport.swift
//  HelloNotes
//
//  Reporting something a model wrote.
//
//  App Review Guideline 1.2, as revised on 16 October 2026, names "AI content
//  creation apps" among the apps that must offer "a mechanism to report
//  offensive content". What HelloNotes' models write stays in the person's own
//  notes — there is no one else to see it, and nothing is posted — but a
//  response can still be wrong in a way worth telling us about, and every
//  place the app shows one offers this (`AIReportSurfacesTests` holds the
//  list).
//
//  **A `mailto:`, like the support request** (`SupportRequestSection`): the
//  app sends nothing. It composes the message in the person's own mail app,
//  where they read every word before deciding to send — which matters here,
//  because the response may quote their notes. Nothing else of their notes
//  goes in it: the response, the question that produced it, which feature and
//  which model, and the versions.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ResponseReport: Equatable {
    /// Where the text came from — "Assistant", "Summary", …
    let feature: String
    /// The model that made the response, as the app names it — "Local
    /// (Apple)", "Cloud (Apple)", "Local (<MLX model>)" — from the result's
    /// `ModelStamp`, or the model in use where a result has none.
    let model: String
    /// What it wrote.
    let response: String
    /// What it was asked, when there was a question.
    var prompt: String? = nil

    /// How much of a response goes in — enough to see what was wrong, and a
    /// `mailto:` some mail apps still read whole.
    static let responseLimit = 1_000
    static let promptLimit = 300

    /// Where a report goes when there is no mail app to compose it in.
    static let supportPage = URL(string: "https://hellotham.com/hellonotes/support")!

    var mailURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = SupportRequestSection.supportAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: "HelloNotes: reporting a response (\(feature))"),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }

    var body: String {
        var parts = [
            "What was wrong with it?",
            "",
            "",
            "",
            "——— the response ———",
            Self.excerpt(response, limit: Self.responseLimit),
        ]
        if let prompt, !prompt.isEmpty {
            parts += ["", "——— what it was asked ———", Self.excerpt(prompt, limit: Self.promptLimit)]
        }
        parts += [
            "",
            "——— sent from HelloNotes ———",
            "Feature: \(feature)",
            "Model: \(model)",
            SupportRequestSection.versionLines,
            "",
            "Read this through before sending: the response may quote your notes.",
        ]
        return parts.joined(separator: "\n")
    }

    /// The first `limit` characters, and how many more there were.
    static func excerpt(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "… (\(trimmed.count - limit) more characters)"
    }
}

/// "Report…", beside text a model wrote.
struct ReportResponseButton: View {
    /// Made when pressed, so a reply still arriving is reported as it stands.
    let report: () -> ResponseReport

    var body: some View {
        Button {
            Self.open(report())
        } label: {
            Label("Report…", systemImage: "flag")
        }
        .buttonStyle(ChromeBorderlessStyle())
        .help("Report this response to HelloNotes — your mail app opens with it, and you read it before sending")
        .accessibilityLabel("Report this response")
        .accessibilityIdentifier("ai.reportResponse")
    }

    /// The person's mail app with the report in it; failing that — no mail
    /// app set up — the support page, which says where to write.
    static func open(_ report: ResponseReport) {
        guard let url = report.mailURL else {
            ExternalURL.open(ResponseReport.supportPage)
            return
        }
        #if canImport(AppKit)
        if !NSWorkspace.shared.open(url) { NSWorkspace.shared.open(ResponseReport.supportPage) }
        #else
        UIApplication.shared.open(url) { opened in
            if !opened { UIApplication.shared.open(ResponseReport.supportPage) }
        }
        #endif
    }
}
