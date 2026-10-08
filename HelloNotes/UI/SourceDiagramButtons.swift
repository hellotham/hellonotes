//
//  SourceDiagramButtons.swift
//  HelloNotes
//
//  A View diagram button on every diagram in Markdown and Split mode.
//
//  In Edit and Preview a diagram is a picture with the button in its corner,
//  and the button says which diagram it means. In the source editor a diagram
//  is a fence of text, and the only ways in were the bar and the menu, which
//  opened on the first diagram in the note: the source editor's caret is
//  nobody's to read, and a command cannot say which diagram it means anyway.
//  So every diagram's fence gets the same button on its opening line, at the
//  right, and pressing it opens that diagram.
//
//  Only the diagrams in TextKit's viewport get a button — positions outside it
//  are estimates, and nothing there is on screen — so the buttons are placed
//  again whenever the view lays out or scrolls. The diagrams are found off the
//  main actor after an edit (a whole-document parse); until the new list lands
//  the old places stand, and a press on a button whose diagram has since moved
//  still opens it by its source (`DiagramZoomRequest.make`).
//

import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import MarkdownCore
import MarkdownEditor

@MainActor
final class SourceDiagramButtons {
    #if canImport(AppKit)
    typealias TextView = NSTextView
    #else
    typealias TextView = UITextView
    #endif

    private weak var textView: TextView?
    /// What a press opens. Re-seated by the representable's update, as its
    /// binding is: the view outlives the note it is showing.
    var onPress: ((DiagramZoom) -> Void)?
    /// The diagrams last found.
    private(set) var diagrams: [MermaidDiagram] = []
    /// Every button made so far; the ones in use are the visible ones.
    private(set) var buttons: [DiagramButtonView] = []
    private var search: Task<Void, Never>?
    /// The text changed again while a search was running.
    private var searchIsStale = false
    /// Whatever takes a press on the buttons, kept alive — see `pressHandler`.
    private var press: AnyObject?

    init(textView: TextView) {
        self.textView = textView
        press = Self.pressHandler(on: textView) { [weak self] in self?.buttons ?? [] }
    }

    /// Who takes a press. On the Mac, the button: a click goes to the view
    /// under the pointer, so the text view never sees it. On iPad, a
    /// recogniser on the text view, which has to claim the touch before
    /// UIKit's caret tap moves the selection (`DiagramButtonPress`).
    private static func pressHandler(on textView: TextView,
                                     buttons: @escaping () -> [DiagramButtonView]) -> AnyObject? {
        #if canImport(AppKit)
        return nil
        #else
        return DiagramButtonPress(on: textView, buttons: buttons)
        #endif
    }

    /// The text changed, or arrived: find its diagrams again, off the main
    /// actor.
    ///
    /// One search at a time. This is called per keystroke, and each search
    /// copies the note and parses all of it; cancelling the one in flight does
    /// not stop its parse, so typing quickly used to leave one running per
    /// character. A change made while one runs marks it stale, and the search
    /// that follows it takes the text as it is by then.
    func textDidChange() {
        guard search == nil else {
            searchIsStale = true
            return
        }
        guard let textView else { return }
        let text = Self.text(of: textView)
        searchIsStale = false
        search = Task { [weak self] in
            let found = await offMain { MarkdownParsing.mermaidDiagrams(in: text) }
            guard let self else { return }
            self.search = nil
            guard !self.searchIsStale else { return self.textDidChange() }
            self.diagrams = found
            self.place()
        }
    }

    /// Put a button on the opening line of each diagram in the viewport, and
    /// hide the rest.
    func place() {
        var used = 0
        defer { for spare in buttons.dropFirst(used) { spare.isHidden = true } }
        guard let textView, !diagrams.isEmpty,
              let layoutManager = textView.textLayoutManager,
              let content = layoutManager.textContentManager else { return }
        let top = content.documentRange.location
        let length = content.offset(from: top, to: content.documentRange.endLocation)
        var low = 0, high = length
        if let viewport = layoutManager.textViewportLayoutController.viewportRange {
            low = content.offset(from: top, to: viewport.location)
            high = content.offset(from: top, to: viewport.endLocation)
        }
        let origin = Self.containerOrigin(of: textView)
        let side = DiagramZoomMetrics.side
        let x = textView.bounds.width - Self.trailingInset(of: textView) - side
        for diagram in diagrams {
            let at = diagram.range.location
            guard at >= low, at <= high, at < length,
                  let location = content.location(top, offsetBy: at),
                  let fragment = layoutManager.textLayoutFragment(for: location),
                  fragment.state == .layoutAvailable else { continue }
            let frame = fragment.layoutFragmentFrame
            let line = fragment.textLineFragments.first?.typographicBounds
                ?? CGRect(origin: .zero, size: frame.size)
            let button = button(at: used)
            button.frame = CGRect(x: x, y: origin.y + frame.minY + line.minY + (line.height - side) / 2,
                                  width: side, height: side)
            button.isHidden = false
            let zoom = DiagramZoom(source: diagram.source, location: at)
            button.onPress = { [weak self] in self?.onPress?(zoom) }
            used += 1
        }
    }

    private func button(at index: Int) -> DiagramButtonView {
        if index < buttons.count { return buttons[index] }
        let button = DiagramButtonView(label: String(localized: "View diagram"))
        textView?.addSubview(button)
        buttons.append(button)
        return button
    }

    #if canImport(AppKit)
    private static func text(of textView: NSTextView) -> String { textView.string }
    private static func containerOrigin(of textView: NSTextView) -> CGPoint { textView.textContainerOrigin }
    private static func trailingInset(of textView: NSTextView) -> CGFloat { textView.textContainerInset.width + 4 }
    #else
    private static func text(of textView: UITextView) -> String { textView.text ?? "" }
    private static func containerOrigin(of textView: UITextView) -> CGPoint {
        CGPoint(x: textView.textContainerInset.left, y: textView.textContainerInset.top)
    }
    private static func trailingInset(of textView: UITextView) -> CGFloat { textView.textContainerInset.right + 4 }
    #endif
}
