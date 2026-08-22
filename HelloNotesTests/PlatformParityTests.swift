//
//  PlatformParityTests.swift
//  HelloNotesTests
//
//  The parity check that reads the source, because the bug it guards against is
//  invisible at runtime.
//
//  `AppActions` is the app's whole command surface, and most of its fields are
//  **optional closures**: a command whose field is nil still appears in the menu
//  bar and in the palette, still draws, still enables, and does nothing when
//  chosen. Nothing crashes and no test fails. Three shipped that way at once —
//  "Open in New Window", "New Window" and "Connect Over the Web" were all nil on
//  iOS while the capability behind each existed on that platform.
//
//  Two audits missed them, both by asking "does iOS have an equivalent?" of each
//  `#if os(macOS)` gate. That question finds features which are *absent*; these
//  were *present and unwired*. This test asks the question that catches them:
//  for every field of `AppActions`, is it supplied on both platforms?
//
//  Source-scanning rather than runtime, because both shells' `appActions` are
//  private computed properties on view structs and there is no instance to
//  inspect. It reads the two files the way a reviewer would, and it is precise
//  enough to be useful: the failure names the field.
//

import Foundation
import Testing
@testable import HelloNotes

struct PlatformParityTests {

    /// Fields that are genuinely one-platform, each with the reason. Anything
    /// *not* on this list must be wired on both — so adding a Mac-only command
    /// is a deliberate act with a justification beside it, not an omission.
    private static func source(_ name: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()   // …/HelloNotesTests
            .deletingLastPathComponent()   // …/<repo root>
            .appending(path: "HelloNotes")
            .appending(path: name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every command the menu bar can show is wired on both platforms.
    @Test func everyAppActionIsSuppliedOnBothShells() throws {
        let commands = try Self.source("UI/AppCommands.swift")
        // One shell. This used to compare two files and pass whenever a field
        // was missing from *both* — which is how `templates`, `quickCapture`
        // and `insertTemplate` could be declared and wired nowhere at all. With
        // one shell the question is simply whether the field is supplied, and
        // the companion test in `ShellComplianceTests` proves nothing in that
        // file is behind a one-sided gate, so "supplied" means "on both".
        let shell = try Self.source("ContentView.swift")

        // The fields of the action structs only — `AppActions` and the nested
        // `…Actions` it carries. Scoped rather than every `var` in the file,
        // because `CloudBrowser.displayName` is also a `var` here and iOS
        // referring to it is not a parity signal. (It failed exactly that way
        // on the first run, which is the sort of thing a scan should be made to
        // prove about itself.)
        let structOpens = /^struct ([A-Za-z_][A-Za-z0-9_]*)/
        let declaration = /^\s*var ([A-Za-z_][A-Za-z0-9_]*)\s*:/
        var fields: Set<String> = []
        var insideActions = false
        for line in commands.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if let opened = try? structOpens.firstMatch(in: text) {
                insideActions = String(opened.1).hasSuffix("Actions")
            }
            guard insideActions, let match = try? declaration.firstMatch(in: text) else { continue }
            fields.insert(String(match.1))
        }
        #expect(fields.count > 30, "the scan found no fields — the declaration shape changed")

        let missing = fields.sorted().filter { !shell.contains("\($0):") }

        #expect(missing.isEmpty, """
            These commands are declared and never wired. An unwired optional \
            still draws an enabled menu item that does nothing, so wire it — \
            there is no allowlist to add it to. The one entry this test used to \
            carry (`revealInFinder`, "iOS has no Finder") was retired by asking \
            the capability question instead of the API question: iOS has Files, \
            and `FileReveal` opens it.
            \(missing.joined(separator: "\n"))
            """)
    }
}
