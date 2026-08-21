//
//  ShellComplianceTests.swift
//  HelloNotesTests
//
//  Do the two shells *obey* the contract, or merely compute it?
//
//  `ShellContractTests` asserts the rule — that `ShellKind`, `ShellMetrics` and
//  `TextWidth` decide the same thing on both platforms. That is necessary and it
//  is not sufficient, and iOS proved it: `ShellKind` resolved `.wideInspector`
//  at 1470pt on iPad exactly as on the Mac, and `iOSContentView` then handed
//  `AdaptiveShell` `inspectorPresented: .constant(false)`. The contract was
//  computed correctly and ignored. Every arithmetic test passed while a Mac
//  window and an iPad of the same size got different layouts, which is the one
//  thing the contract exists to forbid.
//
//  The tempting test is to render `AdaptiveShell` with sentinel slots and assert
//  which regions appear. That would not have caught this: `AdaptiveShell` was
//  never wrong. The defect was in a *caller* — a shell handing the shared layout
//  engine an argument that defeats it.
//
//  So this reads the two call sites and compares them. Both shells configure one
//  `AdaptiveShell`; the only arguments allowed to differ are the slot closures,
//  which are the presentation, and `prefersTouch`, which is input sizing rather
//  than arrangement (and `ShellContractTests` pins that it cannot move a
//  region). Anything else differing means one platform has been given a
//  different shell, and the failure names the argument.
//

import Foundation
import Testing
@testable import HelloNotes

struct ShellComplianceTests {

    /// Arguments that legitimately differ, each with the reason. Adding to this
    /// list is how a divergence becomes a decision instead of an oversight.
    static let mayDiffer: Set<String> = [
        // The slots — this *is* the presentation, and the whole point of the
        // shell taking them as closures.
        "sidebar", "pane", "inspector", "compact",
    ]

    // `prefersTouch` used to be listed here, on the grounds that it is input
    // sizing rather than arrangement. That was wrong:
    // `ShellContext.showsFormatBar` is `!prefersTouch && …`, so it removes a
    // region, and `tabBarHeight` changes with it. Hard-coded false on the Mac
    // and true on iPad, it made a Mac window and an iPad of the same size render
    // different shells — the exact thing the contract forbids. Both shells now
    // ask `PointerPresence`, so the argument is identical and the allowlist does
    // not need it.

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "HelloNotes")
            .appending(path: name), encoding: .utf8)
    }

    /// The argument labels and values of a shell's `AdaptiveShell(...)` call.
    private static func shellArguments(in source: String) -> [String: String] {
        guard let start = source.range(of: "AdaptiveShell(") else { return [:] }
        var depth = 0
        var end = start.upperBound
        for index in source.indices[start.upperBound...] {
            let character = source[index]
            if character == "(" { depth += 1 }
            if character == ")" {
                if depth == 0 { end = index; break }
                depth -= 1
            }
        }
        // Strip comment lines **before** splitting, not after: prose contains
        // commas, and splitting first tore an argument in half at the comma in
        // its own explanation — the label then vanished and the test reported a
        // divergence that did not exist. Found by running it.
        let body = source[start.upperBound..<end]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.drop(while: { $0 == " " }).hasPrefix("//") }
            .joined(separator: "\n")

        // Split on the commas that separate arguments at depth zero, so a
        // closure body's own commas do not split it.
        var arguments: [String] = []
        var current = ""
        var nesting = 0
        for character in body {
            if "([{".contains(character) { nesting += 1 }
            if ")]}".contains(character) { nesting -= 1 }
            if character == "," && nesting == 0 {
                arguments.append(current); current = ""
            } else {
                current.append(character)
            }
        }
        arguments.append(current)

        var labelled: [String: String] = [:]
        for code in arguments {
            guard let colon = code.firstIndex(of: ":") else { continue }
            let label = code[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !label.contains(" ") else { continue }
            labelled[label] = code[code.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return labelled
    }

    @Test("Both shells configure the same AdaptiveShell")
    func bothShellsConfigureTheSameShell() throws {
        let mac = Self.shellArguments(in: try Self.source("MacContentView.swift"))
        let ios = Self.shellArguments(in: try Self.source("iOSContentView.swift"))

        #expect(!mac.isEmpty, "no AdaptiveShell call found in MacContentView")
        #expect(!ios.isEmpty, "no AdaptiveShell call found in iOSContentView")

        var divergences: [String] = []
        for label in Set(mac.keys).union(ios.keys).sorted() {
            guard !Self.mayDiffer.contains(label) else { continue }
            let a = mac[label] ?? "<absent>"
            let b = ios[label] ?? "<absent>"
            if a != b { divergences.append("\(label): macOS `\(a)` vs iOS `\(b)`") }
        }

        #expect(divergences.isEmpty, """
            The two shells hand `AdaptiveShell` different arguments, so a Mac \
            window and an iPad of the same size can render different layouts — \
            which the layout contract forbids. Either make them agree, or add \
            the argument to `mayDiffer` with the reason:
            \(divergences.joined(separator: "\n"))
            """)
    }

    /// The specific subversion that shipped: handing the shared shell a constant
    /// where it expects live state. It renders every arithmetic test green and
    /// the layout wrong.
    @Test("Neither shell hands the layout engine a constant")
    func neitherShellPinsAShellArgument() throws {
        for file in ["MacContentView.swift", "iOSContentView.swift"] {
            let arguments = Self.shellArguments(in: try Self.source(file))
            for (label, value) in arguments where !Self.mayDiffer.contains(label) {
                #expect(!value.contains(".constant("),
                        "\(file) pins `\(label)` to \(value) — the shell can no longer decide it")
            }
        }
    }
}
