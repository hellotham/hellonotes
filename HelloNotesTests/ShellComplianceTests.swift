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

    /// Nothing in the app is one-sided.
    ///
    /// It was two — `MacContentView` and `iOSContentView`, each inside a
    /// one-sided `#if` — and that arrangement is what every divergence this
    /// suite grew a test for had in common: neither file could see the other,
    /// so a cache key, a command list, a rename or a missing pane could differ
    /// without anything failing.
    ///
    /// The rule that replaces all of those: **a gate that supplies both
    /// branches shares the behaviour; a gate that supplies one loses it.** With
    /// the shell in one file that is checkable directly, and it subsumes every
    /// "both shells do X" assertion below.
    @Test("No platform gate in the app has only one branch")
    func nothingIsOneSided() throws {
        let repo = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let roots = [repo.appending(path: "HelloNotes"),
                     repo.appending(path: "Packages/NotesEditor/Sources")]
        // The files whose split *was* the divergence. Each pair was one thing
        // written twice in two files that could not see each other, and each
        // hid something: two cache keys, two `revalidateSelection`s, two
        // `EditorProxy`s with different members, a `showMatch` on one side only.
        for gone in ["HelloNotes/MacContentView.swift",
                     "HelloNotes/iOSContentView.swift",
                     "Packages/NotesEditor/Sources/MarkdownEditor/MarkdownTextView.swift",
                     "Packages/NotesEditor/Sources/MarkdownEditor/MarkdownUITextView.swift"] {
            #expect(!FileManager.default.fileExists(atPath: repo.appending(path: gone).path),
                    "\(gone) is back — that pair is two files again")
        }

        let platform = ["os(macOS)", "os(iOS)", "os(visionOS)",
                        "canImport(AppKit)", "canImport(UIKit)", "targetEnvironment("]
        var offenders: [String] = []
        let files = roots.flatMap { root in
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" } ?? []
        }
        #expect(files.count > 50, "the scan found almost no sources — the layout changed")

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            var stack: [(line: Int, isPlatform: Bool, hasElse: Bool, body: Bool)] = []
            for (index, raw) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = raw.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("#if") {
                    stack.append((index + 1, platform.contains { text.contains($0) }, false, false))
                } else if text.hasPrefix("#else") || text.hasPrefix("#elseif") {
                    if !stack.isEmpty { stack[stack.count - 1].hasElse = true }
                } else if text.hasPrefix("#endif") {
                    if let gate = stack.popLast() {
                        if gate.isPlatform, !gate.hasElse, gate.body {
                            offenders.append("\(file.lastPathComponent):\(gate.line)")
                        }
                        // A nested gate's body is the enclosing gate's body too.
                        // Without this the scanner recorded `body` only on the
                        // *innermost* `#if`, so `#if os(macOS)` wrapping nothing
                        // but `#if DEBUG` … real code … `#endif` popped with
                        // `body == false` and passed — a genuinely one-sided
                        // platform gate the check could not see.
                        if gate.body, !stack.isEmpty { stack[stack.count - 1].body = true }
                    }
                } else if !text.isEmpty, !text.hasPrefix("//"), !text.hasPrefix("import"),
                          !stack.isEmpty {
                    // A gate whose whole body is imports or comments removes no
                    // behaviour — `import AppKit` has nothing to pair with.
                    stack[stack.count - 1].body = true
                }
            }
        }
        #expect(offenders.isEmpty, """
            These platform gates supply one branch and not the other, so \
            whatever is inside them exists on one platform only:
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// The layout engine is handed live state, not a constant.
    ///
    /// The specific subversion that shipped: handing the shared shell a
    /// constant where it expects live state renders every arithmetic test green
    /// and the layout wrong.
    @Test("The shell does not hand the layout engine a constant")
    func neitherShellPinsAShellArgument() throws {
        let arguments = Self.shellArguments(in: try Self.source("ContentView.swift"))
        #expect(!arguments.isEmpty, "ContentView.swift has no AdaptiveShell call")
        for (label, value) in arguments where !Self.isClosure(value) {
            #expect(!value.contains(".constant("),
                    "ContentView pins `\(label)` to \(value) — the shell can no longer decide it")
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
        let file = "ContentView.swift"
        do {
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
        let file = "ContentView.swift"
        do {
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
        let file = "ContentView.swift"
        do {
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
        let file = "ContentView.swift"
        do {
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
        let file = "ContentView.swift"
        do {
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
        let file = "ContentView.swift"
        do {
            let source = try Self.source(file)
            #expect(!source.contains("linkGraph.backlinks("),
                    "\(file) walks the link graph itself instead of reading NoteReferences")
            #expect(!source.contains("linkGraph.outgoingLinks("),
                    "\(file) walks the link graph itself instead of reading NoteReferences")
            #expect(source.contains("NoteReferences.key(note:"),
                    "\(file) does not key its reference refresh on the shared key")
        }
    }

    /// A scan may never close the note someone is reading.
    ///
    /// `revalidateSelection` existed in both shells under one name and was two
    /// different functions. The Mac's cleared a selection that no longer
    /// resolved and fell back to the last open tab, so a rescan that
    /// momentarily dropped a note took the reader off it — the vanished-note
    /// report. The iPad's kept the selection and reconciled the buffer, and
    /// carried the paragraph explaining why.
    ///
    /// The architecture states the rule outright: no other operation may close
    /// the current file. This asserts the shared implementation is the one both
    /// shells call, and that neither has quietly grown a clearing path back.
    @Test("Neither shell clears a selection it cannot resolve")
    func revalidationNeverClearsTheSelection() throws {
        let file = "ContentView.swift"
        do {
            let source = try Self.source(file)
            #expect(!source.contains("private func revalidateSelection"),
                    "\(file) has its own revalidation again")
            #expect(source.contains("actions.revalidateSelection()"),
                    "\(file) does not call the shared revalidation")
        }
        let shared = try String(contentsOf: URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "HelloNotes/State/ShellActions.swift"), encoding: .utf8)
        let body = shared.components(separatedBy: "func revalidateSelection()")[1]
            .components(separatedBy: "\n    }")[0]
        #expect(!body.contains("selection.wrappedValue = "),
                "revalidateSelection writes the selection — it must only ever read it")
    }

    /// Both editors answer the same command bus.
    ///
    /// `MarkdownTextView` and `MarkdownUITextView` are one view written twice —
    /// AppKit and UIKit, each inside its own file's one-sided gate, so neither
    /// can see the other. `MarkdownFormatting` catches the members it declares,
    /// but `showMatch(of:index:)` is not one of them: it existed on the AppKit
    /// side only, and nothing failed to compile.
    ///
    /// What that cost was not the find bar — iOS has `UIFindInteraction` for
    /// that — but **every jump to a heading**. `hnJumpToHeadingInEditor` posts
    /// `hn.editor.findQuery`, so tapping an outline row, a mind-map section or
    /// a `[[link#heading]]` did nothing at all on one platform.
    @Test("Both editors listen on the same editor notifications")
    func bothEditorsAnswerTheCommandBus() throws {
        let package = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Packages/NotesEditor/Sources/MarkdownEditor")
        let source = try String(contentsOf: package.appending(path: "MarkdownEditorView.swift"),
                                encoding: .utf8)
        // Both halves are in one file now, so each name must appear twice —
        // once on each side of the gate. Counting is the point: a single
        // occurrence is exactly the state this test exists to catch.
        for name in ["hn.editor.findQuery", "hn.editor.replaceCurrent",
                     "hn.editor.replaceAll", "hn.editor.clearHighlights"] {
            #expect(source.ranges(of: name).count >= 2,
                    "\(name) is observed by one editor only")
        }
        // `showMatch` lives with the rest of the `MarkdownFormatting`
        // conformance, whose two halves are also one gate now.
        let commands = try String(contentsOf: package.appending(path: "EditorCommands.swift"),
                                  encoding: .utf8)
        #expect(commands.ranges(of: "func showMatch(of query: String, index: Int) -> Int").count >= 2,
                "one editor cannot jump to a match, so no heading link can scroll to one there")
    }

    /// The host's handle on the editor offers the same thing on both.
    ///
    /// `EditorProxy` is declared once per platform, in two files that cannot
    /// see each other — so `apply(_:)` and `performAITransform(_:)` existed on
    /// one of them, and nothing failed to compile. A host holding a proxy could
    /// format on one platform and not the other.
    @Test("Both editor proxies offer the same API")
    func editorProxiesMatch() throws {
        let package = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Packages/NotesEditor/Sources/MarkdownEditor")
        let whole = try String(contentsOf: package.appending(path: "MarkdownEditorView.swift"),
                               encoding: .utf8)
        func api(_ half: Int) throws -> Set<String> {
            let source = half == 0 ? whole : String(whole[whole.range(of: "\n#else\n")!.upperBound...])
            guard let start = source.range(of: "public final class EditorProxy {") else { return [] }
            var depth = 0
            var body = ""
            for character in source[start.upperBound...] {
                if character == "{" { depth += 1 }
                if character == "}" {
                    if depth == 0 { break }
                    depth -= 1
                }
                body.append(character)
            }
            return Set(body.matches(of: /public (?:var|func) ([A-Za-z_][A-Za-z0-9_]*)/)
                .map { String($0.1) })
        }
        let appKit = try api(0)
        let uiKit = try api(1)
        #expect(appKit.count > 8, "the scan found almost nothing — the declaration shape changed")
        #expect(appKit == uiKit, """
            The two `EditorProxy` declarations differ, so a host holding one \
            can do something on one platform and not the other:
            only AppKit: \(appKit.subtracting(uiKit).sorted())
            only UIKit:  \(uiKit.subtracting(appKit).sorted())
            """)
    }

    /// Search lives in the toolbar, at the leading end — not inside the sidebar.
    ///
    /// CLAUDE.md: "no command may live inside it (a hidden command is an
    /// unreachable command). Commands go in the toolbar: search leading."
    /// `shell-chrome.md` D9 marks `.searchable` ❌ with two measured reasons —
    /// it collapses to a glyph at 860pt, the width where search matters most,
    /// and claims the trailing end of the band.
    ///
    /// Unifying the two shells' search briefly reached for
    /// `.searchable(placement: .sidebar)` because it is one native call on both
    /// platforms. It is — and it put search inside the collapsible column and
    /// reversed a documented decision. Parity is not a licence to overrule the
    /// chrome contract; one hand-built field placed leading satisfies both.
    @Test("Search is a toolbar item at the leading end, on both platforms")
    func searchIsInTheToolbarLeading() throws {
        let source = try Self.source("ContentView.swift")
        let sidebar = try #require(Self.propertyBody(named: "collectionTree", in: source),
                                   "collectionTree is not a `some View` property any more")
        // Scoped to the sidebar. The *compact* shell's Search tab uses
        // `.searchable` and should: there the search screen is the place, and
        // D9's objections are about the band in the column shell.
        #expect(!sidebar.contains(".searchable("),
                "the sidebar uses `.searchable`, which D9 rejects and which puts search inside the collapsible column")
        // **Not on the sidebar's own toolbar either.** That bar is inside the
        // collapsible column, and at 335pt it cannot hold a field beside the
        // toggle — iPadOS moved it into the `•••` overflow and the field
        // disappeared, which is D9's failure reproduced by hand. It belongs on
        // the editor column's toolbar, where it also survives a collapse.
        #expect(!sidebar.contains("searchField"),
                "the search field is on the sidebar's own toolbar, which is inside the collapsible column")
        #expect(source.ranges(of: "ToolbarItem(placement: .barLeading) { searchField }").count == 2,
                "the search field is not a leading item on both of the editor column's toolbars")
    }

    /// A platform placement means the edge it is named after.
    ///
    /// `barTrailing` mapped to `.primaryAction`, which Apple documents as the
    /// *leading* edge on macOS — so an inspector toggle asking for the trailing
    /// end landed on the wrong side of the window. The Mac's own measured
    /// chrome uses an unplaced `ToolbarItemGroup`, which is `.automatic`.
    @Test("barTrailing is not macOS's leading placement")
    func trailingPlacementIsActuallyTrailing() throws {
        let source = try String(contentsOf: URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "HelloNotes/UI/Shell/ToolbarPlacement.swift"), encoding: .utf8)
        let trailing = source.components(separatedBy: "static var barTrailing")[1]
            .components(separatedBy: "}")[0]
        #expect(!trailing.contains(".primaryAction"),
                "barTrailing maps to `.primaryAction`, which is macOS's leading edge")
    }

    /// A collection row says the same five things on both platforms.
    ///
    /// `NoteRowContent` fixed this one level down and the collection row never
    /// got the same treatment: the AppKit cell drew an orange warning icon and
    /// a dimmed title for an unreadable folder, a tooltip explaining why, a
    /// spinner during a scan, a Git dot coloured by the working tree, and
    /// semibold for the focused collection. The SwiftUI row drew
    /// `Text(collection.name).font(.headline)`.
    ///
    /// The warning is the one that matters: an unreadable collection keeps its
    /// notes listed, because they are the last true picture of the folder — so
    /// without it the row is indistinguishable from a healthy one and stale
    /// contents read as current.
    @Test("Neither sidebar decides for itself what a collection row says")
    func collectionRowsShareTheirContent() throws {
        let source = try String(contentsOf: URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "HelloNotes/UI/NoteOutlineList.swift"), encoding: .utf8)
        // Once per renderer, plus the `.help` on the SwiftUI row.
        #expect(source.ranges(of: "CollectionRowContent.make(").count >= 2,
                "one of the two sidebars still derives a collection row itself")
        for derived in ["case .unavailable(let reason) = collection.state",
                        "collection.showsScanProgress",
                        "collection.git.status.isRepository",
                        "collection.id == focusedCollectionID"] {
            #expect(!source.contains(derived),
                    "a sidebar re-derives `\(derived)` instead of reading CollectionRowContent")
        }
    }
}
