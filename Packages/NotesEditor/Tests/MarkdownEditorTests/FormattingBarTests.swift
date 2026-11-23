//
//  FormattingBarTests.swift
//  MarkdownEditorTests
//
//  The keyboard's formatting bar, as built — not as its source spells it.
//  `EditorToolbarContractTests` reads `EditorCommands.swift` for each label,
//  and every label was there while six rows of the bar drew as bare glyphs:
//  a bar that runs out of room folds what does not fit into a ⋯ menu and
//  titles each row from the item's **title**, which no item had — an
//  accessibility label is not read there. On an iPhone, Heading 1–3, the two
//  lists and Blockquote were nameless in that menu from the day the bar was
//  made; they were found under 1.3.7's Insert Image, the first item given a
//  title.
//

#if canImport(UIKit) && !canImport(AppKit)
import UIKit
import Testing
import MarkdownCore
@testable import MarkdownEditor

@MainActor
@Suite struct FormattingBarTests {

    /// Every item of the bar, as the text view the app makes carries it: the
    /// shortcuts bar's groups and their stand-ins on an iPad, the accessory's
    /// items on a phone.
    private func items() -> [UIBarButtonItem] {
        let view = MarkdownUITextView.make(document: EditorDocument(text: "A note.\n"))
        let groups = view.inputAssistantItem.leadingBarButtonGroups
            + view.inputAssistantItem.trailingBarButtonGroups
        let grouped = groups.flatMap { $0.barButtonItems + [$0.representativeItem].compactMap { $0 } }
        let accessory = (view.inputAccessoryView as? UIToolbar)?.items ?? []
        return grouped + accessory
    }

    @Test func everyItemInTheBarHasATitleForItsRowInTheOverflow() {
        let all = items()
        #expect(all.count >= 12, "the bar has \(all.count) items, so nothing below is about it")
        let untitled = all.filter { ($0.title ?? "").isEmpty }.map { $0.accessibilityLabel ?? "an unnamed item" }
        #expect(untitled.isEmpty, "no title, so a bare glyph in the overflow menu: \(untitled)")
        // And the title is the name VoiceOver reads, not a second wording of it.
        let differing = all.filter { $0.title != nil && $0.accessibilityLabel != nil && $0.title != $0.accessibilityLabel }
            .map { "\($0.title ?? "") / \($0.accessibilityLabel ?? "")" }
        #expect(differing.isEmpty, "named two ways: \(differing)")
    }

    /// The source editor installs this bar too, in Markdown and Split, and
    /// cannot put a picture in: Insert Image is not offered there, rather
    /// than offered and dead.
    @Test func aTextViewThatCannotPutAPictureInOffersNone() {
        let view = SourceShaped()
        view.installFormattingAssistant()
        let groups = view.inputAssistantItem.leadingBarButtonGroups + view.inputAssistantItem.trailingBarButtonGroups
        let all = groups.flatMap(\.barButtonItems) + ((view.inputAccessoryView as? UIToolbar)?.items ?? [])
        #expect(all.count >= 11, "the bar has \(all.count) items, so nothing below is about it")
        #expect(!all.contains { $0.title == "Insert Image" }, "Insert Image offered where nothing answers it")
    }

    /// The source editor's shape (`SourceTextView`, in the app): it formats,
    /// and it is not `PictureRequesting`.
    private final class SourceShaped: UITextView, MarkdownFormatting {
        var formattingBlocks: [Block]? { nil }
        var formattingText: String { text ?? "" }
        func formattingSelection() -> NSRange { selectedRange }
        func setFormattingSelection(_ range: NSRange) { selectedRange = range }
        func performEdit(replacing range: NSRange, with text: String) -> Bool { false }
    }

    @Test func insertImageOffersEachSourceThisDeviceHas() throws {
        let picture = try #require(items().first { $0.title == "Insert Image" }, "no Insert Image in the bar")
        let titles = picture.menu?.children.map(\.title) ?? []
        #expect(titles.contains("Choose from Collection…"))
        #expect(titles.contains("Choose from Photos…"))
        #expect(titles.contains("Take Photo…") == UIImagePickerController.isSourceTypeAvailable(.camera),
                "Take Photo… is offered \(titles.contains("Take Photo…") ? "without" : "despite") a camera")
    }
}
#endif
