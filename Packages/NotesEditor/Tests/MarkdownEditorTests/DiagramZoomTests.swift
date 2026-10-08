//
//  DiagramZoomTests.swift
//  MarkdownEditorTests
//
//  The enlarge button on a rendered diagram: drawn where it is offered and
//  nowhere else, hit where it is drawn, naming the diagram it sits on — and a
//  press on it leaves the caret alone, so the diagram stays a picture.
//
//  Cross-platform: the fragment draws the button for both, and each text view
//  has its own way of catching the press — an intercepted `mouseDown` on the
//  Mac, a refused recogniser on the iPad.
//

import CoreGraphics
import Foundation
import Testing
@testable import MarkdownCore
@testable import MarkdownEditor

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
@Suite struct DiagramZoomTests {

    /// Every diagram, one transparent picture: anything painted inside it is
    /// the button's, not the diagram's.
    private struct ClearPictureRenderer: BlockRenderer {
        func render(_ kind: BlockEmbedKind, maxWidth: CGFloat, darkMode: Bool) async -> PlatformImage? {
            guard case .mermaid = kind else { return nil }
            return DiagramZoomTests.clearImage(CGSize(width: 240, height: 140))
        }
    }

    /// `nonisolated`, because the renderer above has to be.
    ///
    /// A real bitmap, not `NSImage(size:)`: an image with no representation
    /// has no `CGImage`, and the fragment draws nothing for it — not even the
    /// button.
    private nonisolated static func clearImage(_ size: CGSize) -> PlatformImage {
        #if canImport(AppKit)
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return NSImage(cgImage: context.makeImage()!, size: size)
        #else
        return UIGraphicsImageRenderer(size: size).image { _ in }
        #endif
    }

    nonisolated static let source = "graph TD\n  A --> B"
    nonisolated static let fence = "```mermaid\n\(source)\n```"

    /// A document whose diagrams have been collapsed to their pictures.
    private func collapsed(_ text: String, offered: Bool) async throws -> EditorDocument {
        let document = EditorDocument(
            text: text,
            services: EditorServices(blockRenderer: ClearPictureRenderer(),
                                     offersDiagramZoom: offered))
        // The caret in the opening paragraph, outside every diagram, so none is
        // revealed. Not at the end: a note can end in a diagram, and the end of
        // the note is then inside it.
        document.selectionDidChange(NSRange(location: 0, length: 0))
        document.styleEverythingNow()
        let ns = text as NSString
        let wanted = BlockParser.fullParse(ns).mermaidDiagrams(in: ns).count
        for _ in 0..<100 {
            var pictures = 0
            document.storage.enumerateAttribute(
                blockImageAttribute, in: NSRange(location: 0, length: document.storage.length),
                options: []) { value, _, _ in if value != nil { pictures += 1 } }
            if pictures == wanted { return document }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the diagrams never collapsed to their pictures")
        return document
    }

    /// The note laid out offscreen in the editor's own fragments, at the
    /// editor's own padding.
    @MainActor private final class Layout {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        private let fragments = RenderedBlockLayoutDelegate()

        init(_ document: EditorDocument) {
            layoutManager.delegate = fragments
            let container = NSTextContainer(size: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
            container.lineFragmentPadding = EditorMetrics.lineFragmentPadding
            layoutManager.textContainer = container
            contentStorage.addTextLayoutManager(layoutManager)
            contentStorage.textStorage?.setAttributedString(document.storage)
            layoutManager.ensureLayout(for: layoutManager.documentRange)
        }

        var storage: NSTextStorage { contentStorage.textStorage! }

        /// Every fragment that draws a picture, top to bottom.
        var painters: [RenderedBlockFragment] {
            var found: [RenderedBlockFragment] = []
            layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location,
                                                       options: [.ensuresLayout]) { fragment in
                if let painter = fragment as? RenderedBlockFragment {
                    let offset = contentStorage.offset(from: contentStorage.documentRange.location,
                                                       to: fragment.rangeInElement.location)
                    if offset < storage.length,
                       storage.attribute(blockImageAttribute, at: offset, effectiveRange: nil) != nil {
                        found.append(painter)
                    }
                }
                return true
            }
            return found
        }

        /// Where the picture a painter draws sits, in container coordinates —
        /// its button's frame taken back to the picture's corner.
        func picture(of painter: RenderedBlockFragment) -> CGRect? {
            guard let button = painter.diagramZoomButtonFrame() else { return nil }
            let m = DiagramZoomMetrics.self
            return CGRect(x: button.maxX + m.inset - 240, y: button.minY - m.inset,
                          width: 240, height: 140)
        }

        /// The alpha of the pixel at `point`, with every fragment's chrome drawn
        /// the way the iOS overlay draws it.
        func alpha(at point: CGPoint) -> UInt8 {
            let size = CGSize(width: 600, height: max(1, layoutManager.usageBoundsForTextContainer.height))
            // The context owns its memory: a `&array` pointer lives only for the
            // initialiser's call, and drawing afterwards would write through it.
            let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                    bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            // y-down, as a text view's drawing is.
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location,
                                                       options: [.ensuresLayout]) { fragment in
                (fragment as? RenderedBlockFragment)?.drawChromeOnly(at: fragment.layoutFragmentFrame.origin,
                                                                     in: context)
                return true
            }
            // Memory row 0 is the top row, so a y-down point reads straight off.
            let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
            guard x >= 0, y >= 0, x < Int(size.width), y < Int(size.height),
                  let data = context.data else { return 0 }
            return data.load(fromByteOffset: y * context.bytesPerRow + x * 4 + 3, as: UInt8.self)
        }
    }

    /// Offered: the button is drawn in the diagram's top-right corner and
    /// nothing else is — the picture is clear, so its middle stays unpainted.
    /// Not offered: the same corner stays clear, which is what shows the paint
    /// above was the button's.
    @Test func theButtonIsDrawnOnlyWhereTheZoomIsOffered() async throws {
        let text = "Intro\n\n\(Self.fence)\n\nAfter"
        let offered = Layout(try await collapsed(text, offered: true))
        let painter = try #require(offered.painters.first)
        let button = try #require(painter.diagramZoomButtonFrame())
        let picture = try #require(offered.picture(of: painter))
        #expect(button.width == DiagramZoomMetrics.side && button.height == DiagramZoomMetrics.side)
        #expect(picture.contains(button), "the button sits on the diagram")
        #expect(offered.alpha(at: CGPoint(x: button.midX, y: button.minY + 2)) > 100,
                "no button was drawn where the fragment says it is")
        #expect(offered.alpha(at: CGPoint(x: picture.midX, y: picture.midY)) == 0,
                "something other than the button was drawn on the diagram")

        let plain = Layout(try await collapsed(text, offered: false))
        let plainPainter = try #require(plain.painters.first)
        #expect(plainPainter.diagramZoomButtonFrame() == nil)
        #expect(plain.alpha(at: CGPoint(x: button.midX, y: button.minY + 2)) == 0,
                "a button was drawn although no zoom is offered")
    }

    /// A press on the button names its diagram and where it is written; a
    /// press anywhere else on the diagram is not the button's. At the end of
    /// the note too, where the picture is drawn by the fence's *last* line.
    @Test(arguments: ["Intro\n\n\(fence)\n\nAfter", "Intro\n\n\(fence)"])
    func aPressOnTheButtonNamesItsDiagram(text: String) async throws {
        let layout = Layout(try await collapsed(text, offered: true))
        let painter = try #require(layout.painters.first)
        let button = try #require(painter.diagramZoomButtonFrame())
        let picture = try #require(layout.picture(of: painter))
        let fenceAt = (text as NSString).range(of: "```mermaid").location

        let zoom = layout.layoutManager.diagramZoom(at: CGPoint(x: button.midX, y: button.midY),
                                                    in: layout.storage)
        #expect(zoom == DiagramZoom(source: Self.source, location: fenceAt))
        #expect(layout.layoutManager.diagramZoom(at: CGPoint(x: picture.midX, y: picture.midY),
                                                 in: layout.storage) == nil,
                "the diagram itself is for editing, not zooming")
        // Just outside the button: nothing for a pointer, the button for a finger.
        let beside = CGPoint(x: button.minX - 4, y: button.midY)
        #expect(layout.layoutManager.diagramZoom(at: beside, in: layout.storage) == nil)
        #expect(layout.layoutManager.diagramZoom(at: beside, in: layout.storage,
                                                 slop: DiagramZoomButton.touchSlop) != nil)
    }

    /// Nothing offered, nothing to press — at exactly the point that was the
    /// button when it was.
    @Test func withoutTheZoomThereIsNothingToPress() async throws {
        let text = "Intro\n\n\(Self.fence)\n\nAfter"
        let offered = Layout(try await collapsed(text, offered: true))
        let button = try #require(offered.painters.first?.diagramZoomButtonFrame())
        let plain = Layout(try await collapsed(text, offered: false))
        #expect(plain.layoutManager.diagramZoom(at: CGPoint(x: button.midX, y: button.midY),
                                                in: plain.storage) == nil)
    }

    /// Two identical diagrams, one straight under the other, are two buttons.
    /// Attribute runs with equal values merge, so had the mark been the source
    /// string the two would be one run, and the second button would have
    /// answered with the first diagram's place.
    @Test func identicalNeighboursAreTwoButtons() async throws {
        let text = "Intro\n\n\(Self.fence)\n\(Self.fence)\n\nAfter"
        let layout = Layout(try await collapsed(text, offered: true))
        let painters = layout.painters
        try #require(painters.count == 2)
        let ns = text as NSString
        let second = ns.range(of: "```mermaid", options: .backwards).location
        let button = try #require(painters[1].diagramZoomButtonFrame())
        let zoom = layout.layoutManager.diagramZoom(at: CGPoint(x: button.midX, y: button.midY),
                                                    in: layout.storage)
        #expect(zoom?.location == second, "the second button answered for another diagram")
    }


    /// The enlarge button a live text view's editor draws, in container
    /// coordinates — waited for, and if it never comes, why not.
    private func liveButton(in layoutManager: NSTextLayoutManager,
                            storage: NSTextStorage) async throws -> CGRect? {
        var seen = ""
        for _ in 0..<150 {
            layoutManager.ensureLayout(for: layoutManager.documentRange)
            var button: CGRect?
            var kinds: [String: Int] = [:]
            layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location,
                                                       options: [.ensuresLayout]) { fragment in
                kinds[String(describing: type(of: fragment)), default: 0] += 1
                button = (fragment as? RenderedBlockFragment)?.diagramZoomButtonFrame()
                return button == nil
            }
            if let button { return button }
            var marks = 0, pictures = 0
            let all = NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(diagramZoomAttribute, in: all) { v, _, _ in if v != nil { marks += 1 } }
            storage.enumerateAttribute(blockImageAttribute, in: all) { v, _, _ in if v != nil { pictures += 1 } }
            seen = "fragments \(kinds), zoom marks \(marks), pictures \(pictures)"
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the editor drew no button — \(seen)")
        return nil
    }

    #if canImport(AppKit)
    /// The whole Mac path: a click on the button reaches the host and the caret
    /// does not move. Intercepted before `NSTextView` sees the click — which is
    /// also why only the button is clicked here: anything else goes on to
    /// `super.mouseDown`, whose tracking loop waits for a mouse-up that a test
    /// never sends.
    @Test func aClickOnTheButtonZoomsAndLeavesTheCaret() async throws {
        let text = "Intro\n\n\(Self.fence)\n\nAfter"
        let document = try await collapsed(text, offered: true)
        let (scrollView, textView) = MarkdownTextView.scrollableEditor(document: document)
        scrollView.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(scrollView)
        defer { window.contentView = nil }
        let end = NSRange(location: (text as NSString).length, length: 0)
        textView.setSelectedRange(end)
        var asked: [DiagramZoom] = []
        textView.onDiagramZoom = { asked.append($0) }

        let layoutManager = try #require(textView.textLayoutManager)
        let frame = try #require(try await liveButton(in: layoutManager, storage: document.storage))
        let origin = textView.textContainerOrigin
        let inView = CGPoint(x: frame.midX + origin.x, y: frame.midY + origin.y)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: textView.convert(inView, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        textView.mouseDown(with: event)

        #expect(asked == [DiagramZoom(source: Self.source,
                                      location: (text as NSString).range(of: "```mermaid").location)])
        #expect(textView.selectedRange() == end, "the click moved the caret into the diagram")
    }
    #else
    /// The iPad path, as far as a test can drive it. A touch that begins on
    /// the button is taken at touch-down by a recogniser that shares it with
    /// nothing — which is what keeps UIKit's caret tap off the button — and a
    /// release over the button hands the host its diagram.
    ///
    /// What this cannot show is UIKit's side of the arbitration; that was
    /// checked live on the iPad simulator, where the first version — refusing
    /// UIKit's recognisers in `gestureRecognizerShouldBegin` — passed its test
    /// here and did nothing there: UIKit never asked. A finger tap moved the
    /// caret into the diagram and the button was gone before anything looked.
    @Test func aPressOnTheButtonIsTakenAtTouchDownAndZooms() async throws {
        let text = "Intro\n\n\(Self.fence)\n\nAfter"
        let document = try await collapsed(text, offered: true)
        let textView = MarkdownUITextView.make(document: document)
        textView.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        let window = UIWindow(frame: textView.frame)
        window.addSubview(textView)
        window.isHidden = false
        defer { textView.removeFromSuperview(); window.isHidden = true }
        textView.layoutIfNeeded()
        var asked: [DiagramZoom] = []
        let layoutManager = try #require(textView.textLayoutManager)
        let frame = try #require(try await liveButton(in: layoutManager, storage: document.storage))
        let inset = textView.textContainerInset
        let onButton = CGPoint(x: frame.midX + inset.left, y: frame.midY + inset.top)
        let inText = CGPoint(x: inset.left + 12, y: inset.top + 8)

        // No host listening: no button to take a touch for.
        #expect(!textView.takesDiagramZoomTouch(at: onButton))
        textView.onDiagramZoom = { asked.append($0) }

        // The arbitration: attached, begins at once, shares with nothing.
        let press = try #require(textView.diagramZoomRecognizer)
        #expect(press.view === textView && press.minimumPressDuration == 0)
        #expect(press.delegate !== textView, "the view is UIKit's delegate for its own recognisers")
        let link = try #require(textView.linkTapRecognizer)
        #expect(press.delegate?.gestureRecognizer?(press, shouldRecognizeSimultaneouslyWith: link) != true,
                "sharing the touch would let UIKit's caret tap act on the button too")

        // Touch-down decides: the button, yes; the text, no.
        #expect(textView.takesDiagramZoomTouch(at: inText) == false)
        #expect(textView.takesDiagramZoomTouch(at: onButton))
        // Released off the button: nothing, like any button dragged off.
        textView.handleDiagramZoomPress(PlacedPress(at: inText, state: .ended))
        #expect(asked.isEmpty)
        // Released on it: the diagram, with where it is written.
        #expect(textView.takesDiagramZoomTouch(at: onButton))
        textView.handleDiagramZoomPress(PlacedPress(at: onButton, state: .ended))
        #expect(asked == [DiagramZoom(source: Self.source,
                                      location: (text as NSString).range(of: "```mermaid").location)])
        #expect(textView.pendingDiagramZoom == nil)
    }

    /// A press that says it is wherever, and in whatever state, the test puts it.
    private final class PlacedPress: UILongPressGestureRecognizer {
        let point: CGPoint
        let placedState: UIGestureRecognizer.State
        init(at point: CGPoint, state: UIGestureRecognizer.State) {
            self.point = point
            self.placedState = state
            super.init(target: nil, action: nil)
        }
        override func location(in view: UIView?) -> CGPoint { point }
        override var state: UIGestureRecognizer.State {
            get { placedState }
            set {}
        }
    }
    #endif

    /// The document lists its diagrams from the parse it keeps, which is
    /// updated edit by edit rather than rebuilt — so after an edit its list has
    /// to be the one a fresh parse of the same text gives, in the same order and
    /// at the same places.
    @Test func theDocumentListsItsDiagramsFromItsOwnParse() {
        let text = "Intro\n\n```mermaid\ngraph TD\n  A --> B\n```\n\nEnd"
        let document = EditorDocument(text: text)
        func fresh() -> [MermaidDiagram] {
            let ns = document.storage.string as NSString
            return BlockParser.fullParse(ns).mermaidDiagrams(in: ns)
        }
        #expect(document.mermaidDiagrams.map(\.source) == ["graph TD\n  A --> B"])
        #expect(document.mermaidDiagrams == fresh())

        document.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "```mermaid\npie\n```\n\n")
        #expect(document.mermaidDiagrams.map(\.source) == ["pie", "graph TD\n  A --> B"])
        #expect(document.mermaidDiagrams == fresh(), "after an edit the document's list and a fresh parse's disagree")
    }
}
