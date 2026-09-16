//
//  ShippedContentTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 15/9/2026.
//
//  What goes inside the app, checked where it is decided — the project's
//  Resources phase, the app's own source, and the notes bundled with it.
//
//  1.3.3 re-enters the China storefront with every third-party AI service
//  removed, and "removed" has to include what ships rather than only what runs.
//  Two things were still inside the 1.3.2 bundle after the code that used them
//  was gone: the repository README, copied in as a resource since the first
//  commit and listing fourteen AI services and "your own cloud API key"; and a
//  table of those services' names in the upgrade code, kept to name the retired
//  one in a notice. Neither was visible in the running app.
//

import Testing
import Foundation

struct ShippedContentTests {

    private static let repo = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    /// Services 1.3.2 could call. Matched case-sensitively, as names are
    /// written. Open model families an MLX model may belong to — Mistral,
    /// DeepSeek, Qwen, Llama — are not services and are not listed.
    private static let services = [
        "OpenAI", "ChatGPT", "Anthropic", "Claude", "Gemini", "OpenRouter", "Groq", "Grok",
        "Perplexity", "Ollama", "LM Studio", "Cerebras", "Together AI",
    ]

    /// The app target copies exactly one resource by hand: the bundled
    /// collection. Everything else reaches the bundle through the synchronized
    /// `HelloNotes` folder, where it is visible in review.
    @Test func theAppCopiesOnlyTheBundledCollection() throws {
        let project = try String(contentsOf: Self.repo.appending(path: "HelloNotes.xcodeproj/project.pbxproj"),
                                 encoding: .utf8)
        let copied = project.split(separator: "\n").compactMap { line -> String? in
            guard line.contains(" in Resources */ = {isa = PBXBuildFile"),
                  let open = line.range(of: "/* "),
                  let close = line.range(of: " in Resources */") else { return nil }
            return String(line[open.upperBound..<close.lowerBound])
        }
        #expect(copied == ["DefaultCollection"],
                "a file was added to the app's Resources phase — is it meant to ship inside the app?")
    }

    /// No string, identifier or bundled note in the app names a third-party AI
    /// service. A Swift type name and a string literal are both compiled into
    /// the binary, so comments are the only place a name may appear.
    @Test func nothingShippedNamesAnAIService() throws {
        var offenders: [String] = []
        let manager = FileManager.default
        for folder in ["HelloNotes", "DefaultCollection"] {
            let root = Self.repo.appending(path: folder)
            let files = manager.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? []
            for file in files where ["swift", "md", "xcstrings", "plist", "strings"].contains(file.pathExtension) {
                let text = try String(contentsOf: file, encoding: .utf8)
                let lines = file.pathExtension == "swift" ? text.split(separator: "\n").map(Self.codeOnly) : [Substring(text)]
                for line in lines {
                    for name in Self.services where line.contains(name) {
                        offenders.append("\(file.lastPathComponent): \(name)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "\(Set(offenders).sorted())")
    }

    /// The app suggests no model, as it names no AI service.
    ///
    /// Four were suggested once, with a size and a sentence each, read from the
    /// Hub on one day. Within a day they were a generation behind what people
    /// were running, and not one had ever been run by anyone here. Naming a
    /// model is a promise about it. The field's placeholder — `mlx-community/…`
    /// — and the link to that organisation's page name nothing, and are the
    /// only mentions allowed.
    @Test func noModelIsSuggested() throws {
        var offenders: [String] = []
        let named = try Regex(#"mlx-community/[A-Za-z0-9]"#)
        let root = Self.repo.appending(path: "HelloNotes")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n").map(Self.codeOnly) {
                if line.contains(named) || line.contains("MLXCatalog") {
                    offenders.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// A Swift line with its comment removed. A `//` counts as a comment only
    /// outside a string literal — an even number of unescaped quotes before it —
    /// so an address like `"https://…"` is still checked.
    private static func codeOnly(_ line: Substring) -> Substring {
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return "" }
        var quotes = 0
        var previous: Character = " "
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" && previous != "\\" { quotes += 1 }
            let next = line.index(after: index)
            if character == "/", next < line.endIndex, line[next] == "/", quotes % 2 == 0 {
                return line[line.startIndex..<index]
            }
            previous = character
            index = next
        }
        return line
    }
}
