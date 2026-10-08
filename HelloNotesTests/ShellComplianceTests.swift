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

    /// An auxiliary surface is presented the same way on both platforms, and
    /// the app opens no window of its own for one.
    ///
    /// The Mac opened a `Window` for Graph, Ask Library, Assistant, the mind
    /// map and the cloud browsers; the iPad presented a sheet for each. Two
    /// lists, independently maintained, either of which could gain a surface
    /// the other never heard about — and it had already produced a behaviour
    /// difference, since the Mac's mind-map window read the note's file and
    /// showed the last saved version while the iPad's sheet was handed the live
    /// buffer. Unifying them on *width* replaced that with a subtler one: a
    /// scene the system places cannot be relied on to sit beside the notes, and
    /// on iPadOS closing one left the app.
    ///
    /// So there is one panel and one enum of what it can show (`SidePanel`),
    /// one piece of state for which of them it is showing, and one header
    /// inside the panel to choose and to close. The shell is collections on the
    /// left, the editor in the middle, anything else on the right — and an
    /// editor never blocks editing, so the panel is a column wherever one fits
    /// and only a canvas with no room for one carries it over the note.
    /// Neither shell holds presentation state of its own for these surfaces,
    /// and neither opens a scene for one: the only windows the app opens are
    /// the two someone asks for by name, New Window and Open in New Window,
    /// which are on both platforms.
    @Test("Neither shell decides how an auxiliary surface is presented")
    func auxiliarySurfacesArePresentedTheSameWay() throws {
        let file = "ContentView.swift"
        let source = try Self.source(file)
        #expect(source.contains("private func showPanel(_ choice: SidePanel)"),
                "\(file) does not route ancillary views through one panel")
        #expect(source.contains("inspector: { trailingPanel }"),
                "\(file) does not give the shell's trailing slot the panel")
        #expect(source.contains("SidePanelHeader("),
                "\(file) draws no header for the panel — nothing picks what it shows")
        // One state, not one per kind of thing the panel can hold.
        #expect(!source.contains("auxiliarySurface"),
                "\(file) keeps a second piece of panel state")
        for forbidden in ["showGraph", "showMindMap", "showAssistant", "showLibraryChat",
                         "cloudBrowser"] {
            #expect(!source.contains(forbidden),
                    "\(file) still owns presentation state for an auxiliary surface (\(forbidden))")
        }
        // The scenes are gone with the windows. `NoteRef` and "main" stay:
        // those are the windows someone asks for.
        let scenes = try Self.source("HelloNotesApp.swift")
        for gone in ["AuxiliaryRef", "MindMapRef"] {
            #expect(!scenes.contains(gone),
                    "HelloNotesApp still declares a scene for an auxiliary surface (\(gone))")
        }
    }

    /// The mind map shows what you are typing, not what was last saved.
    ///
    /// It read the note's file unconditionally, which was invisible while it
    /// was a sheet on iPad — a sheet lives in the editor's own scene and was
    /// handed the buffer directly. Once both platforms opened a window, that
    /// read became the only source, and unifying the two presentations would
    /// have settled the difference by taking the worse of them.
    @Test("An auxiliary surface prefers the live buffer to the file")
    func mindMapReadsTheLiveBuffer() throws {
        let source = try String(contentsOf: URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "HelloNotes/UI/SidePanel.swift"), encoding: .utf8)
        #expect(source.contains("liveBuffer.text(for: rootURL) ?? fileText"),
                "MindMapPanel no longer prefers the editor's buffer")
        #expect(source.contains("guard liveBuffer.text(for: rootURL) == nil else { return }"),
                "MindMapPanel reads the file even when the buffer has the note")
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
    /// that — but **every jump to a heading**, which was posted as
    /// `hn.editor.findQuery` then, so tapping an outline row, a mind-map
    /// section or a `[[link#heading]]` did nothing at all on one platform. A
    /// jump is the view's own to answer now (`HeadingJumpListener`, which shows
    /// it when the view is in a window), and both views must have one.
    @Test("Both editors listen on the same editor notifications")
    func bothEditorsAnswerTheCommandBus() throws {
        let package = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Packages/NotesEditor/Sources/MarkdownEditor")
        let source = try String(contentsOf: package.appending(path: "MarkdownEditorView.swift"),
                                encoding: .utf8)
        // Both halves are in one file now, so each name must appear twice —
        // once on each side of the gate. Counting is the point: a single
        // occurrence is exactly the state this test exists to catch. The names
        // are addressed to the editor now (`EditorBus`), so each is spelled as
        // the call that builds it for this editor's id.
        for name in ["EditorBus.findQuery(editor: editorID)", "EditorBus.replaceCurrent(editor: editorID)",
                     "EditorBus.replaceAll(editor: editorID)", "EditorBus.clearHighlights(editor: editorID)"] {
            #expect(source.ranges(of: name).count >= 2,
                    "\(name) is observed by one editor only")
        }
        #expect(source.ranges(of: "lazy var headingJumps = HeadingJumpListener(").count >= 2,
                "one editor cannot answer a heading jump")
        // `showMatch` lives with the rest of the `MarkdownFormatting`
        // conformance, whose two halves are also one gate now.
        let commands = try String(contentsOf: package.appending(path: "EditorCommands.swift"),
                                  encoding: .utf8)
        #expect(commands.ranges(of: "func showMatch(of query: String, index: Int) -> Int").count >= 2,
                "one editor cannot jump to a match, so no heading link can scroll to one there")
    }

    /// Every command on the editor's bus names the editor it is for.
    ///
    /// The find bar's four messages, the heading jump, the match count that
    /// answers a find, and ⌘F were posted with no address, and every editor in
    /// every window answered them: a find in one window moved the selection in
    /// another, and Replace All there rewrote the note open here. The Format bus
    /// had an address, but it was the note's path — which two windows on one
    /// note share. `EditorBusTests` holds the editors to the contract; this
    /// holds the app, which that test cannot see: no source here spells a bus
    /// name without an editor, and every view that joins the bus joins as its
    /// `EditorModel`, never as its note.
    ///
    /// The note's sheet commands too — Rewrite or Expand, Present as Slides and
    /// View Diagram. Posted to no one, one command opened its sheet in every
    /// window at once: reproduced with two windows, where a Rewrite chosen in
    /// one opened a rewrite sheet in both, each over its own note and wired to
    /// replace it.
    @Test("Every command on the editor's bus names its editor")
    func theEditorBusIsAddressed() throws {
        let app = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "HelloNotes")
        let files = (FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
        #expect(files.count > 150, "the scan read \(files.count) sources — it is not reading the app")
        let unaddressed = ["\"hn.editor.findQuery\"", "\"hn.editor.replaceCurrent\"",
                           "\"hn.editor.replaceAll\"", "\"hn.editor.clearHighlights\"",
                           "\"hn.editor.jumpToHeading\"", "\"hn.editor.findResults\"",
                           "\"hn.editor.toggleFind\"", "\"hnEditorFormat.", "\"hnEditorFind.",
                           "\"hnEditorUndo.", "\"hnEditorRedo.", "\"hnEditorEndEditing.",
                           "\"hn.editor.rewriteNote\"", "\"hn.editor.showSlides\"",
                           "\"hn.editor.showMermaid\"",
                           ".commandBus(documentId", "documentId: note."]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for name in unaddressed where source.contains(name) {
                Issue.record("\(file.lastPathComponent) spells an editor-bus name without its editor: \(name)")
            }
        }
        // Every view on the bus joins as its editor: the live editor, and in
        // the pane both the Markdown source and Preview.
        let host = try Self.source("UI/EditorHost.swift")
        #expect(host.contains(".commandBus(editorID: editor.editorID)"),
                "the live editor does not join the bus as its editor")
        let pane = try Self.source("UI/NoteEditorPane.swift")
        #expect(pane.contains("editorID: editor.editorID"),
                "the Markdown pane does not join the bus as its editor")
        let preview = try Self.source("UI/NotePreview.swift")
        #expect(preview.contains(".commandBus(editorID: editor.editorID)"),
                "Preview does not join the bus as its editor")
        // The control: the scan has to be able to see a post at all. The find
        // bar's Replace All is addressed, and it is found where it is posted.
        let bar = try Self.source("UI/NoteEditorView.swift")
        #expect(bar.contains("EditorBus.replaceAll(editor: editor.editorID)"),
                "the find bar's Replace All was not found — this test is not reading what posts")
        // And the sheets answer their own editor, in the same file.
        for sheet in [".hnRewriteNote(editor: editor.editorID)", ".hnShowSlides(editor: editor.editorID)",
                      ".hnShowMermaid(editor: editor.editorID)"] {
            #expect(bar.contains(sheet), "a note sheet does not listen on its own editor: \(sheet)")
        }
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
    ///
    /// The bar is the app's own now (`shellBar`, one builder for both
    /// platforms), so "leading on both" is one statement: the field is the
    /// bar's first item. And `.searchable` is nowhere in the shell — the
    /// compact Search place draws the same field, full width.
    @Test("Search is the bar's leading item, on both platforms")
    func searchIsInTheToolbarLeading() throws {
        let source = try Self.source("ContentView.swift")
        let sidebar = try #require(Self.propertyBody(named: "collectionTree", in: source),
                                   "collectionTree is not a `some View` property any more")
        // Code only: a comment may name what it replaced.
        let code = source.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }.joined(separator: "\n")
        #expect(!code.contains(".searchable("),
                "the shell uses `.searchable`, which D9 rejects and which each platform draws its own way")
        // **Not in the sidebar.** It is inside the collapsible column, and at
        // 335pt it cannot hold a field beside the toggle — iPadOS once moved
        // it into the `•••` overflow and the field disappeared, which is D9's
        // failure reproduced by hand. It belongs on the editor's bar, where it
        // also survives a collapse.
        #expect(!sidebar.contains("searchField"),
                "the search field is in the sidebar, which is inside the collapsible column")
        let bar = try #require(source.components(separatedBy: "private func shellBar(").dropFirst().first,
                               "shellBar is not a function any more")
        let stack = try #require(bar.components(separatedBy: "HStack(spacing: Chrome.Metric.barSpacing) {").dropFirst().first,
                                 "shellBar is not an HStack of bar items")
        let firstItem = stack.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("//") } ?? ""
        #expect(firstItem.contains("searchField()"),
                "the bar's first item is `\(firstItem)`, not the search field")
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
        // One renderer now — the AppKit outline and the SwiftUI list became one
        // drawn list (`ChromeRows`) — so one call, and nothing derived beside it.
        #expect(source.ranges(of: "CollectionRowContent.make(").count >= 1,
                "the sidebar no longer reads its collection rows from CollectionRowContent")
        for derived in ["case .unavailable(let reason) = collection.state",
                        "collection.showsScanProgress",
                        "collection.git.status.isRepository",
                        "collection.id == focusedCollectionID"] {
            #expect(!source.contains(derived),
                    "a sidebar re-derives `\(derived)` instead of reading CollectionRowContent")
        }
    }

    /// The inspector toggle reports what is actually on screen.
    ///
    /// `inspectorPresented` was `true` on the Mac and `false` on iOS — one
    /// `@SceneStorage` key, two answers. Picking the Mac's created a worse
    /// problem: below the column threshold there is no inspector *column*, so
    /// a stored `true` meant the window opened with a modal panel over the
    /// note. Suppressing that with a session-scoped "opened by hand" flag made
    /// the toolbar toggle draw as selected while nothing was visible — a
    /// control saying on with nothing shown, which is the defect rather than
    /// the fix.
    ///
    /// `false` is the only default with no inconsistency, and it lets the
    /// overlay follow `presented` directly.
    @Test("The inspector default cannot reintroduce a lying toggle")
    func inspectorDefaultIsOffAndTheOverlayHasNoHiddenGate() throws {
        let shell = try Self.source("ContentView.swift")
        #expect(shell.contains(#"@SceneStorage("inspectorPresented") private var inspectorPresented = false"#),
                "the inspector default is not `false`, so a fresh scene can show a toggle with nothing behind it")
        let overlay = try String(contentsOf: URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "HelloNotes/UI/InspectorOverlay.swift"), encoding: .utf8)
        #expect(!overlay.contains("openedByHand"),
                "the overlay has a second condition again, which the toolbar toggle cannot see")
    }

    /// New Note goes into the folder the shell is showing.
    ///
    /// `newNote()` called `createNote()` with no folder, so on the tall shell —
    /// where the band's left pane is a folder picker and its right pane lists
    /// that folder — a note made with a folder selected landed at the
    /// collection root, outside the only list on screen. Reproduced on an iPad
    /// simulator: Examples selected, New Note, and the file appeared in the
    /// collection root while the list showed nothing new.
    @Test("New Note is created in the container the band is showing")
    func newNoteGoesIntoTheSelectedContainer() throws {
        let source = try Self.source("ContentView.swift")
        let start = try #require(source.range(of: "private func newNote() {"),
                                 "newNote() is gone or renamed")
        var depth = 1
        var end = start.upperBound
        while end < source.endIndex, depth > 0 {
            if source[end] == "{" { depth += 1 } else if source[end] == "}" { depth -= 1 }
            end = source.index(after: end)
        }
        let body = source[start.upperBound..<end]
        #expect(body.contains("bandContainerID"),
                "New Note ignores the band's container again — notes land at the collection root")
    }

    /// The folder panel's configuration **wraps** the importer it configures.
    ///
    /// `fileDialogDefaultDirectory` sets a value the `fileImporter` reads from
    /// its own environment, and an environment flows inward — so a modifier
    /// applied *inside* the importer is invisible to it. Build 25 had exactly
    /// that: the directory on the `Form`, the importer attached outside, and
    /// **Access MLX Models…** opened wherever the app's last panel had been —
    /// on the Mac that found it, an Obsidian vault. A probe presenting both
    /// orderings off-screen read the panel's own `directoryURL`: inside gave
    /// `~/Documents`, outside gave `~/.cache/huggingface/hub`.
    /// **The chrome's orange is the app's, never the platform's.**
    /// `Color.orange` is a different orange on each platform, and
    /// `Chrome.Colour.orange` is AppKit's value on both (D12). Two collection
    /// rows and the collection status bar drew the platform's, beside the
    /// app's everywhere else (ui.md §12, item 3; implemented.md §51.36). The
    /// accent picker's `.orange` is a choice of accent, not a colour, and is
    /// not matched here.
    @Test("No view draws the platform's orange")
    func noViewDrawsThePlatformsOrange() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "HelloNotes")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 100, "the app's sources were not found, so this checks nothing")
        for file in files {
            // Code only: a comment may name what it does not use.
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for pattern in ["Color.orange", "? .orange :", "(.orange)", ": .orange)"] {
                #expect(!code.contains(pattern), "\(file.lastPathComponent) draws \(pattern)")
            }
        }
    }

    @Test("The models folder panel's configuration wraps its importer")
    func folderPanelConfigurationWrapsTheImporter() throws {
        let source = try Self.source("UI/Assistant/IntelligenceSettingsView.swift")
        // Everything the helper is handed: from its opening parenthesis to the
        // one that balances it.
        let opening = try #require(source.range(of: "startingInHuggingFaceCache(ChromeForm"),
                                   "the settings form no longer passes itself to the panel helper")
        var depth = 1
        var end = opening.upperBound
        while end < source.endIndex, depth > 0 {
            if source[end] == "(" { depth += 1 } else if source[end] == ")" { depth -= 1 }
            end = source.index(after: end)
        }
        let argument = source[opening.upperBound..<end]
        #expect(argument.contains(".fileImporter("),
                "the fileImporter is outside the helper again — the default directory cannot reach it")
        // And the helper really is where the directory is set.
        #expect(source.contains(".fileDialogDefaultDirectory(Self.huggingFaceCache)"))
    }

    /// A control in a bar carries a **title**, not just a picture.
    ///
    /// When the bar runs out of room the system folds its items into an
    /// overflow menu and titles each row from the item's *label*. An
    /// image-only label has no title, so the row draws as a bare glyph with a
    /// disclosure arrow and no name — which is what an iPad mini in portrait,
    /// with the collections band and the right panel both open, did to the
    /// note menu: an unnamed chevron sitting next to a row that read "Panel".
    /// `accessibilityLabel` does not rescue it; VoiceOver reads it and nobody
    /// sees it.
    ///
    /// An **allow-list**, and it is meant to stay one entry: the search
    /// field's clear button, which lives *inside* a text field, never folds
    /// into a bar, and would be wrong with a title beside it.
    @Test("Every control that can fold into a toolbar's overflow has a name")
    func barControlsAreLabelledNotJustDrawn() throws {
        let source = try Self.source("ContentView.swift")
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        /// The one image-only label that is not a bar control.
        let allowed = ["xmark.circle.fill"]

        var offenders: [String] = []
        for (index, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces) == "} label: {" {
            // The first thing the closure draws, skipping blanks and comments.
            var next = index + 1
            while next < lines.count {
                let text = lines[next].trimmingCharacters(in: .whitespaces)
                if text.isEmpty || text.hasPrefix("//") { next += 1; continue }
                break
            }
            guard next < lines.count else { continue }
            let body = lines[next].trimmingCharacters(in: .whitespaces)
            let closes = next + 1 < lines.count
                && lines[next + 1].trimmingCharacters(in: .whitespaces) == "}"
            guard body.hasPrefix("Image("), closes else { continue }
            guard !allowed.contains(where: body.contains) else { continue }
            offenders.append("ContentView.swift:\(next + 1)  \(body)")
        }
        #expect(offenders.isEmpty,
                """
                image-only label(s) — give each a `Label(title, systemImage:)` so the \
                toolbar overflow has a name to draw: \(offenders.joined(separator: ", "))
                """)
    }
}
