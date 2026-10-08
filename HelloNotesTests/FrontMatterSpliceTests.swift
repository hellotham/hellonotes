//
//  FrontMatterSpliceTests.swift
//  HelloNotesTests
//
//  A property changed in the Properties panel — added, removed, edited —
//  rewrites that key's lines and no others. The block was rendered again whole
//  in the panel's style, so every key nobody touched changed shape whenever
//  any key changed: `tags: [tour]` became a block list, hand-written quoting
//  and blank lines went, and a comment went with them (docs/implemented.md
//  §51.26; seen on the HN-iPad simulator in Intelligence.md, §51.20).
//
//  The control for each: the panel's own rendering of the same properties is
//  not the text as written, so "byte-identical" asks something of the splice.
//

import Foundation
import Testing
@testable import HelloNotes

struct FrontMatterSpliceTests {

    /// Front matter written by hand: a comment, a quoted value, a flow list, a
    /// block list, a blank line, single quotes — and a key order of its own.
    private static let handWritten = """
        ---
        # Written by hand, and kept.
        title: "Intelligence: a tour"
        tags: [tour, demo]
        aliases:
          - AI
        priority: 2

        summary: 'Single-quoted, by hand.'
        ---
        # Intelligence

        The body.
        """

    /// `handWritten` with `line` in place of `old`, or with `line` added
    /// before the closing fence when `old` is nil.
    private static func handWritten(replacing old: String?, with line: String?) -> String {
        var lines = handWritten.components(separatedBy: "\n")
        if let old, let index = lines.firstIndex(of: old) {
            if let line { lines[index] = line } else { lines.remove(at: index) }
        } else if let line, let closing = lines.dropFirst().firstIndex(of: "---") {
            lines.insert(line, at: closing)
        }
        return lines.joined(separator: "\n")
    }

    /// The properties with `edit` made to them, written back as the panel
    /// writes them (`EditorModel.setProperties`).
    private func written(_ text: String, _ edit: (inout [Property]) -> Void) throws -> String {
        var properties = FrontMatter.properties(in: text)
        edit(&properties)
        return try #require(FrontMatter.applyingChanges(properties, to: text), "the edit changed nothing")
    }

    private func value(_ key: String, in text: String) -> Property? {
        FrontMatter.properties(in: text).first { $0.key == key }
    }

    // MARK: - The control

    /// Rendered whole in the panel's style, the hand-written block is not what
    /// was written — so every expectation below of lines left as they were is
    /// one the old splice could not meet.
    @Test func thePanelsOwnRenderingIsNotTheBlockAsWritten() {
        let properties = FrontMatter.properties(in: Self.handWritten)
        #expect(FrontMatter.render(properties) + FrontMatter.body(of: Self.handWritten) != Self.handWritten)
    }

    // MARK: - One key, and only its lines

    /// The symptom: adding a property and removing it again gives the note
    /// back as it was. It turned `tags: [tour]` into a block list.
    @Test func addingAPropertyAndRemovingItLeavesTheNoteAsItWas() throws {
        let note = "---\ntitle: Intelligence\ntags: [tour]\n---\n# Intelligence\n\nBody.\n"
        let added = try written(note) { $0.append(Property(key: "status", kind: .text, text: "", bool: false, items: [])) }
        #expect(added == "---\ntitle: Intelligence\ntags: [tour]\nstatus: \"\"\n---\n# Intelligence\n\nBody.\n",
                "adding one property changed other lines: \(added.debugDescription)")
        let removed = try written(added) { $0.removeAll { $0.key == "status" } }
        #expect(removed == note, "adding a property and removing it did not give the note back: \(removed.debugDescription)")
    }

    @Test func addingAPropertyTouchesNoOtherLine() throws {
        let added = try written(Self.handWritten) {
            $0.append(Property(key: "status", kind: .text, text: "draft", bool: false, items: []))
        }
        #expect(added == Self.handWritten(replacing: nil, with: "status: draft"), "got \(added.debugDescription)")
        #expect(value("status", in: added)?.text == "draft")
    }

    @Test func removingAPropertyTouchesNoOtherLine() throws {
        let removed = try written(Self.handWritten) { $0.removeAll { $0.key == "priority" } }
        #expect(removed == Self.handWritten(replacing: "priority: 2", with: nil), "got \(removed.debugDescription)")
        #expect(value("priority", in: removed) == nil)
    }

    @Test func changingAPropertyTouchesNoOtherLine() throws {
        let changed = try written(Self.handWritten) {
            if let i = $0.firstIndex(where: { $0.key == "priority" }) { $0[i].text = "3" }
        }
        #expect(changed == Self.handWritten(replacing: "priority: 2", with: "priority: 3"), "got \(changed.debugDescription)")
        #expect(value("priority", in: changed)?.text == "3")
    }

    /// A changed value is written with the panel's quoting — the rule that a
    /// value YAML would read as something else is quoted — in its own line.
    @Test func aChangedValueIsQuotedAsTheRulesSayAndNothingElseIs() throws {
        let changed = try written(Self.handWritten) {
            if let i = $0.firstIndex(where: { $0.key == "summary" }) { $0[i].text = "[[Linked]] from here" }
        }
        #expect(changed == Self.handWritten(replacing: "summary: 'Single-quoted, by hand.'",
                                            with: "summary: \"[[Linked]] from here\""), "got \(changed.debugDescription)")
        #expect(value("summary", in: changed)?.text == "[[Linked]] from here", "the value did not survive its round trip")
        #expect(value("title", in: changed)?.text == "Intelligence: a tour")
    }

    /// An edited list is written again as a whole — in the style it was
    /// written in, flow or block, and at its indentation — and no other key is.
    @Test func anEditedListKeepsItsStyle() throws {
        let flow = try written(Self.handWritten) {
            if let i = $0.firstIndex(where: { $0.key == "tags" }) { $0[i].items.append("new one") }
        }
        #expect(flow == Self.handWritten(replacing: "tags: [tour, demo]", with: "tags: [tour, demo, new one]"),
                "got \(flow.debugDescription)")
        #expect(value("tags", in: flow)?.items == ["tour", "demo", "new one"])

        let block = try written(Self.handWritten) {
            if let i = $0.firstIndex(where: { $0.key == "aliases" }) { $0[i].items.append("Artificial") }
        }
        #expect(block == Self.handWritten(replacing: "  - AI", with: "  - AI\n  - Artificial"), "got \(block.debugDescription)")
        #expect(value("aliases", in: block)?.items == ["AI", "Artificial"])
    }

    /// A flow list whose items a comma would split is written as a block list
    /// — the flow form could not read it back.
    @Test func aFlowListThatCannotHoldAnItemBecomesABlockList() throws {
        let changed = try written(Self.handWritten) {
            if let i = $0.firstIndex(where: { $0.key == "tags" }) { $0[i].items.append("one, two") }
        }
        #expect(value("tags", in: changed)?.items == ["tour", "demo", "one, two"], "got \(changed.debugDescription)")
        #expect(value("title", in: changed)?.text == "Intelligence: a tour")
        #expect(changed.contains("# Written by hand, and kept.") && changed.contains("summary: 'Single-quoted, by hand.'"))
    }

    /// A renamed key is its row renamed, in its place.
    @Test func aRenamedKeyStaysWhereItWas() throws {
        let renamed = try written(Self.handWritten) {
            if let i = $0.firstIndex(where: { $0.key == "priority" }) { $0[i].key = "rank" }
        }
        #expect(renamed == Self.handWritten(replacing: "priority: 2", with: "rank: 2"), "got \(renamed.debugDescription)")
    }

    // MARK: - What the block holds besides its keys

    /// A comment is not a property, whatever it says — one with a colon in it
    /// was read as a key named `# …`, and offered in the panel as one.
    @Test func aCommentIsNotAProperty() {
        let note = "---\n# Kept: by hand\ntitle: A\n---\nBody."
        #expect(FrontMatter.properties(in: note).map(\.key) == ["title"])
    }

    /// Line endings are the file's: a CRLF block keeps them on the lines it
    /// did not change, and a changed line gets the same.
    @Test func aCRLFBlockKeepsItsLineEndings() throws {
        let note = "---\r\ntitle: A\r\npriority: 2\r\n---\r\nBody.\r\n"
        let changed = try written(note) {
            if let i = $0.firstIndex(where: { $0.key == "priority" }) { $0[i].text = "3" }
        }
        #expect(changed == "---\r\ntitle: A\r\npriority: 3\r\n---\r\nBody.\r\n", "got \(changed.debugDescription)")
    }

    // MARK: - A value over several lines

    /// A `>` block: its text is the value — a `key: …` line in it is not a
    /// key — and a change or a removal takes every line of it. Counted as the
    /// key's own line, the rest stayed behind as lines of nothing, which YAML
    /// reads into the key above them.
    private static let folded = """
        ---
        title: A
        summary: >
          Folded over
          two lines: with a colon.
        priority: 2
        ---
        Body.
        """

    @Test func aBlockValueIsOneValueAndGoesWithItsKey() throws {
        #expect(FrontMatter.properties(in: Self.folded).map(\.key) == ["title", "summary", "priority"])
        #expect(value("summary", in: Self.folded)?.text == "Folded over two lines: with a colon.")

        let changed = try written(Self.folded) {
            if let i = $0.firstIndex(where: { $0.key == "summary" }) { $0[i].text = "New." }
        }
        #expect(changed == "---\ntitle: A\nsummary: New.\npriority: 2\n---\nBody.", "got \(changed.debugDescription)")

        let removed = try written(Self.folded) { $0.removeAll { $0.key == "summary" } }
        #expect(removed == "---\ntitle: A\npriority: 2\n---\nBody.", "got \(removed.debugDescription)")

        let other = try written(Self.folded) {
            if let i = $0.firstIndex(where: { $0.key == "priority" }) { $0[i].text = "3" }
        }
        #expect(other == Self.folded.replacingOccurrences(of: "priority: 2", with: "priority: 3"),
                "a change to another key touched the block: \(other.debugDescription)")
    }

    /// A value wrapped onto a deeper line is one value, as YAML folds it, and
    /// removing its key removes both lines.
    @Test func aWrappedValueIsOneValueAndGoesWithItsKey() throws {
        let note = "---\ndescription: A long value\n  wrapped onto the next line.\ntags: [a]\n---\n"
        #expect(value("description", in: note)?.text == "A long value wrapped onto the next line.")
        let removed = try written(note) { $0.removeAll { $0.key == "description" } }
        #expect(removed == "---\ntags: [a]\n---\n", "got \(removed.debugDescription)")
    }

    /// A block list goes on past a blank line or a comment between its items,
    /// as YAML reads it — and all of it is the key's.
    @Test func aBlockListGoesOnPastACommentBetweenItsItems() throws {
        let note = "---\naliases:\n  - One\n  # between\n\n  - Two\ntitle: T\n---\n"
        #expect(value("aliases", in: note)?.items == ["One", "Two"])
        let removed = try written(note) { $0.removeAll { $0.key == "aliases" } }
        #expect(removed == "---\ntitle: T\n---\n", "got \(removed.debugDescription)")
    }

    /// A key under another (`author:` then `  name: …`) is read flat, as it
    /// was, and a change to it is written at its own depth — so the mapping
    /// it sits in is still one.
    @Test func aNestedKeyIsWrittenAtItsOwnDepth() throws {
        let note = "---\nauthor:\n  name: Chris\n  email: c@example.com\ntitle: T\n---\n"
        #expect(FrontMatter.properties(in: note).map(\.key) == ["author", "name", "email", "title"])
        let changed = try written(note) {
            if let i = $0.firstIndex(where: { $0.key == "name" }) { $0[i].text = "Christine" }
        }
        #expect(changed == "---\nauthor:\n  name: Christine\n  email: c@example.com\ntitle: T\n---\n",
                "got \(changed.debugDescription)")
    }

    /// Every key removed is no front matter at all — the block goes, and the
    /// body is left as it was.
    @Test func removingEveryPropertyRemovesTheBlock() throws {
        let removed = try written(Self.handWritten) { $0.removeAll() }
        #expect(removed == FrontMatter.body(of: Self.handWritten))
    }

    // MARK: - The notes the app ships

    /// Every note the app ships with front matter, as the panel meets it — the
    /// real documents, not ones written for the test: a property added and
    /// removed again gives the note back byte for byte, and a change to each
    /// key in turn reads back as that change, leaves every other key as it was
    /// and moves no line of the body. Every one of them writes `tags:` as a
    /// flow list, which the first property added turned into a block list.
    @Test func everyShippedNoteKeepsItsFrontMatterAsWritten() throws {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "DefaultCollection")
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "md" }
        var checked = 0
        for file in files {
            let note = try String(contentsOf: file, encoding: .utf8)
            let properties = FrontMatter.properties(in: note)
            guard !properties.isEmpty, !properties.contains(where: { $0.key == "status" }) else { continue }
            checked += 1
            let name = file.lastPathComponent

            let added = properties + [Property(key: "status", kind: .text, text: "", bool: false, items: [])]
            let withStatus = try #require(FrontMatter.applyingChanges(added, to: note), "\(name)")
            #expect(FrontMatter.properties(in: withStatus) == added, "\(name): the added property did not read back")
            #expect(FrontMatter.applyingChanges(properties, to: withStatus) == note,
                    "\(name): adding a property and removing it changed the note")

            for index in properties.indices {
                var changed = properties
                switch changed[index].kind {
                case .text: changed[index].text += " (changed)"
                case .number: changed[index].text = "42"
                case .date: changed[index].text = "2026-01-01"
                case .checkbox: changed[index].bool.toggle()
                case .list: changed[index].items.append("changed")
                }
                let written = try #require(FrontMatter.applyingChanges(changed, to: note), "\(name)")
                #expect(FrontMatter.properties(in: written) == changed,
                        "\(name): changing \(properties[index].key) did not read back as that change alone")
                #expect(FrontMatter.body(of: written) == FrontMatter.body(of: note),
                        "\(name): changing \(properties[index].key) moved the body")
                let before = note.components(separatedBy: "\n"), after = written.components(separatedBy: "\n")
                let untouched = before.filter { !$0.hasPrefix(properties[index].key + ":") }
                #expect(untouched.allSatisfy(after.contains),
                        "\(name): changing \(properties[index].key) rewrote another line: \(written.debugDescription)")
            }
        }
        #expect(checked >= 10, "only \(checked) shipped notes with front matter were found — did the collection move?")
    }

    // MARK: - The suggestions

    /// A tag accepted from a suggestion goes the same way: into its own key,
    /// in the style that key was written in, and nothing else moves.
    @Test func aSuggestedTagTouchesOnlyTheTags() {
        let tagged = NoteEdits.addingTag("focus", to: Self.handWritten)
        #expect(tagged == Self.handWritten(replacing: "tags: [tour, demo]", with: "tags: [tour, demo, focus]"),
                "got \(tagged.debugDescription)")
    }

    /// A summary is set in its own line, folded to one, and quoted as YAML
    /// needs — the rules the suggestions keep.
    @Test func aSuggestedSummaryTouchesOnlyTheSummary() {
        let summarised = NoteEdits.setting("One line.\nAnd another: here.", property: "summary", of: Self.handWritten)
        #expect(summarised == Self.handWritten(replacing: "summary: 'Single-quoted, by hand.'",
                                               with: "summary: \"One line. And another: here.\""),
                "got \(summarised.debugDescription)")
    }
}
