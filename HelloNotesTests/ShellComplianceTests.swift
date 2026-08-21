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

    /// Whether an argument's value is a closure literal.
    ///
    /// There is no allowlist here and there is not meant to be one. The slot
    /// arguments — `sidebar:`, `pane:`, `inspector:`, `compact:` — differ
    /// because they *are* the two shells' presentations, which is the whole
    /// reason `AdaptiveShell` takes them as closures; naming them in a set
    /// would be an exemption list by another name, and every exemption in this
    /// project has been withdrawn. Recognising a closure structurally says the
    /// same thing without granting anything: a value passed as `{ … }` is the
    /// caller's own view, and a value passed any other way is configuration
    /// that both callers must agree on.
    private static func isClosure(_ value: String) -> Bool {
        value.hasPrefix("{")
    }

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
            let a = mac[label] ?? "<absent>"
            let b = ios[label] ?? "<absent>"
            guard !(Self.isClosure(a) && Self.isClosure(b)) else { continue }
            if a != b { divergences.append("\(label): macOS `\(a)` vs iOS `\(b)`") }
        }

        #expect(divergences.isEmpty, """
            The two shells hand `AdaptiveShell` different arguments, so a Mac \
            window and an iPad of the same size can render different layouts — \
            which the layout contract forbids. Make them agree — the only \
            arguments allowed to differ are the slot closures, and those are \
            recognised by being closures rather than by being named:
            \(divergences.joined(separator: "\n"))
            """)
    }

    /// The slot closures may differ — they are the presentations — but the
    /// **compact** slot may not be a different *kind of thing*.
    ///
    /// This is the blind spot that let a real defect through. `ShellKind`
    /// resolves `.compact` at 250pt on either platform, and the Mac handed that
    /// slot `EditorPaneContainer { editorColumn }` — the editor alone, no way to
    /// reach another note — while iPad handed it the compact shell. The test
    /// above skipped both because both are closures, which was right about the
    /// sidebar and the pane (an outline against a `List`) and wrong here:
    /// compact is not a rearrangement of the wide shell, it is a different
    /// information architecture, and `CompactShell` *is* that architecture.
    /// Either shell rendering something else at compact size is not laying out
    /// differently, it is not being compact.
    @Test("Both shells hand the compact slot the compact shell")
    func bothShellsUseTheCompactShell() throws {
        for file in ["MacContentView.swift", "iOSContentView.swift"] {
            let source = try Self.source(file)
            let slot = try #require(Self.shellArguments(in: source)["compact"],
                                    "\(file) passes no compact slot")
            // Follow one level of indirection: both shells name a property
            // rather than inlining the shell.
            let referenced = slot.trimmingCharacters(in: CharacterSet(charactersIn: "{} \n"))
            let body = referenced.hasSuffix("Shell") || referenced.hasSuffix("shell")
                ? Self.propertyBody(named: referenced, in: source) ?? slot
                : slot
            #expect(body.contains("CompactShell("), """
                \(file) fills the compact slot with `\(referenced)`, which does \
                not render `CompactShell`. Compact is not the wide shell \
                rearranged — it is a different information architecture, and a \
                shell that renders something else at 250pt is not being compact.
                """)
        }
    }

    /// The body of a `private var name: some View { … }`, for following the one
    /// hop each shell puts between the slot and the view.
    private static func propertyBody(named name: String, in source: String) -> String? {
        guard let start = source.range(of: "var \(name): some View {") else { return nil }
        var depth = 0
        var index = start.upperBound
        var body = ""
        for character in source[start.upperBound...] {
            if character == "{" { depth += 1 }
            if character == "}" {
                if depth == 0 { break }
                depth -= 1
            }
            body.append(character)
            index = source.index(after: index)
        }
        return body
    }

    /// The specific subversion that shipped: handing the shared shell a constant
    /// where it expects live state. It renders every arithmetic test green and
    /// the layout wrong.
    @Test("Neither shell hands the layout engine a constant")
    func neitherShellPinsAShellArgument() throws {
        for file in ["MacContentView.swift", "iOSContentView.swift"] {
            let arguments = Self.shellArguments(in: try Self.source(file))
            for (label, value) in arguments where !Self.isClosure(value) {
                #expect(!value.contains(".constant("),
                        "\(file) pins `\(label)` to \(value) — the shell can no longer decide it")
            }
        }
    }

    /// The sidebar tree is one cache under one key.
    ///
    /// It used to be two, and neither key was a superset of the other, so each
    /// platform silently ignored an input the other honoured: the Mac's key
    /// omitted `showsNonNoteFiles` (toggling it did nothing) and the iPad's
    /// omitted the text scale, the bookmark count and the focused collection,
    /// then rebuilt the whole tree in `body` on every render to compensate.
    /// Neither was found by review; both were found by putting the two keys
    /// side by side.
    ///
    /// This asserts the arrangement that makes that unrepeatable: neither shell
    /// computes a key or builds a tree, and both go through
    /// `SidebarTree.inputs` — the one construction — so an input added to the
    /// build appears in the key for both platforms or neither.
    @Test("Neither shell owns a sidebar-tree cache or key")
    func sidebarTreeIsOneCache() throws {
        for file in ["MacContentView.swift", "iOSContentView.swift"] {
            let source = try Self.source(file)
            for forbidden in ["CollectionTree.build(", "SidebarTree.roots(",
                              "cachedRoots", "cachedTrees",
                              "outlineInputsKey", "treeInputsKey"] {
                #expect(!source.contains(forbidden),
                        "\(file) still builds or caches the sidebar tree itself (\(forbidden)), which is the second key the other platform will not have")
            }
            #expect(source.contains("SidebarTree.inputs("),
                    "\(file) does not build its sidebar inputs through the shared construction")
            #expect(source.contains("SidebarTreeModel.key(sidebarInputs)"),
                    "\(file) does not key its rebuild on the shared key")
        }
    }

    /// The sidebar's commands are one list, and one implementation.
    ///
    /// `NoteOutlineList` is one type, but its two branches used to take
    /// *disjoint* parameter sets — the AppKit branch built its own `NSMenu`
    /// inside the coordinator and the SwiftUI branch asked the shell for a view
    /// builder, each declaring the other's parameters with defaults. Both
    /// compiled; neither ran the other's code. That is how a note on the Mac
    /// lost Review Links and Export, a collection on the Mac lost Rescan and
    /// Show Non-Note Files, and an attachment on iPad ended up with no menu at
    /// all.
    ///
    /// Both shells now hand it one `SidebarMenu.Actions`, and neither builds a
    /// menu or reimplements a command.
    @Test("Neither shell owns a sidebar command list")
    func sidebarCommandsAreShared() throws {
        for file in ["MacContentView.swift", "iOSContentView.swift"] {
            let source = try Self.source(file)
            #expect(source.contains("actions: actions.sidebarMenu"),
                    "\(file) does not hand the outline the shared command list")
            for forbidden in ["collectionMenu:", "folderMenu:", "onNewNote:", "onNewFolder:",
                              "onDeleteFolder:", "onRename:", "onDuplicate:", "onMoveItem:",
                              "onToggleBookmark:", "onFocusCollection:"] {
                #expect(!source.contains(forbidden),
                        "\(file) still passes `\(forbidden)` to the outline, which is a command list the other platform will not have")
            }
        }
    }

    /// The commands themselves are `ShellActions`, not a copy per shell.
    ///
    /// Rename, delete, duplicate, move and create existed twice under names
    /// that differed just enough to hide it — `performRename()` against
    /// `renameNote(_:to:)`, `moveItem(at:into:)` against
    /// `moveItems(_:into:of:)` — and only one copy of each carried the comment
    /// explaining the rule it had to keep.
    @Test("Neither shell reimplements a sidebar operation")
    func sidebarOperationsAreShared() throws {
        for file in ["MacContentView.swift", "iOSContentView.swift"] {
            let source = try Self.source(file)
            #expect(source.contains("private var actions: ShellActions"),
                    "\(file) does not go through ShellActions")
            for forbidden in ["func performRename(", "func renameNote(", "func moveItem(",
                              "func moveItems(", "func beginRename(", "func expandFolder(",
                              "func beginNewFolder(", "func renameSelectedNote("] {
                #expect(!source.contains(forbidden),
                        "\(file) still has its own `\(forbidden)` — the other platform has the twin, and they drift")
            }
        }
    }

    /// An auxiliary surface is presented by the canvas, not by the platform.
    ///
    /// The Mac opened a `Window` for Graph, Ask Library, Assistant, the mind
    /// map and the cloud browsers; the iPad presented a sheet for each. Two
    /// lists, independently maintained, either of which could gain a surface
    /// the other never heard about — and it had already produced a behaviour
    /// difference, since the Mac's mind-map window read the note's file and
    /// showed the last saved version while the iPad's sheet was handed the live
    /// buffer.
    ///
    /// Both shells now call one `AuxiliaryOpener`, which chooses a window or a
    /// sheet from the shell's width. Neither may hold presentation state of its
    /// own for these surfaces.
    @Test("Neither shell decides how an auxiliary surface is presented")
    func auxiliarySurfacesArePresentedByWidth() throws {
        for file in ["MacContentView.swift", "iOSContentView.swift"] {
            let source = try Self.source(file)
            #expect(source.contains("AuxiliaryOpener(openWindow: openWindow, width: shellWidth)"),
                    "\(file) does not route auxiliary surfaces through the shared opener")
            #expect(source.contains(".sheet(item: $auxiliarySheet)"),
                    "\(file) has no narrow-canvas fallback, so its surfaces are window-only")
            for forbidden in ["showGraph", "showMindMap", "showAssistant", "showLibraryChat",
                             "cloudBrowser"] {
                #expect(!source.contains(forbidden),
                        "\(file) still owns presentation state for an auxiliary surface (\(forbidden))")
            }
        }
    }

    /// The mind map shows what you are typing, not what was last saved.
    ///
    /// It read the note's file unconditionally, which was invisible while it
    /// was a sheet on iPad — a sheet lives in the editor's own scene and was
    /// handed the buffer directly. Once both platforms opened a window, that
    /// read became the only source, and unifying the two presentations would
    /// have settled the difference by taking the worse of them.
    @Test("An auxiliary window prefers the live buffer to the file")
    func mindMapReadsTheLiveBuffer() throws {
        let source = try String(contentsOf: URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "HelloNotes/UI/AuxiliaryWindows.swift"), encoding: .utf8)
        #expect(source.contains("liveBuffer.text(for: rootURL) ?? fileText"),
                "MindMapWindowView no longer prefers the editor's buffer")
        #expect(source.contains("guard liveBuffer.text(for: rootURL) == nil else { return }"),
                "MindMapWindowView reads the file even when the buffer has the note")
    }

    /// A folder-pick request is answered with what it asked for.
    ///
    /// `Library.FolderPickRequest` was a bare two-case enum that the Mac never
    /// consulted — it ran its own `NSOpenPanel` inline, with its own start
    /// directory and message — while the iPad answered every case by opening
    /// the same picker at Obsidian's iCloud folder. So on iPad "add a mounted
    /// cloud folder" opened nowhere near the providers, and "choose a
    /// subfolder" of a folder too large to index reopened the picker outside
    /// the folder it was narrowing.
    @Test("Both shells present the picker the request asked for")
    func folderPickRequestsCarryTheirDestination() throws {
        for file in ["MacContentView.swift", "iOSContentView.swift"] {
            let source = try Self.source(file)
            #expect(source.contains("startingAt: request.startDirectory"),
                    "\(file) opens the picker somewhere other than where the request named")
            #expect(source.contains("message: request.message"),
                    "\(file) does not say what the request asked for")
            #expect(!source.contains("showImporter"),
                    "\(file) still has a second folder-picking route beside the request channel")
        }
    }

    /// Nothing walks the link graph in a view body.
    ///
    /// The Mac computed backlinks, outgoing links and unlinked mentions once,
    /// off the typing path, keyed on the selection and the collection's
    /// revision. The iPad computed the mentions the same way — a near-identical
    /// function — and built the other two **inline in `body`**: two O(notes)
    /// walks per evaluation, on a view the inspector re-evaluates every
    /// keystroke. The feature was present on both, which is why review never
    /// caught it; only the cost differed.
    @Test("Neither shell derives references in a view body")
    func referencesAreComputedOffTheTypingPath() throws {
        for file in ["MacContentView.swift", "iOSContentView.swift"] {
            let source = try Self.source(file)
            #expect(!source.contains("linkGraph.backlinks("),
                    "\(file) walks the link graph itself instead of reading NoteReferences")
            #expect(!source.contains("linkGraph.outgoingLinks("),
                    "\(file) walks the link graph itself instead of reading NoteReferences")
            #expect(source.contains("NoteReferences.key(note:"),
                    "\(file) does not key its reference refresh on the shared key")
        }
    }
}
