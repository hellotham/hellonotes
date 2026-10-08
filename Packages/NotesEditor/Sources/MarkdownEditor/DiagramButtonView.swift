//
//  DiagramButtonView.swift
//  MarkdownEditor
//
//  The diagram button as a view, for the one place a diagram has no picture to
//  draw it on: the Markdown source, where a diagram is a fence of text.
//
//  In Edit the editor draws the button in a diagram's corner, and in Preview
//  the page does; in the source a host puts one of these on each diagram's
//  opening line. It draws what the editor draws (`DiagramZoomButton`), so the
//  button is one picture in every mode, and it is a button to accessibility,
//  named by the host ("View diagram").
//
//  On iPad it takes no touches itself. A control laid on a `UITextView` loses
//  its tap to UIKit's caret tap, which is what the editor's own button found
//  (`DiagramZoom.swift`): the selection moved first and the press came second.
//  So the host installs a `DiagramButtonPress`, which claims a touch that
//  starts on a button at touch-down, the same way.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import MarkdownCore

#if canImport(AppKit)
public final class DiagramButtonView: NSView {
    /// What a press does.
    public var onPress: (() -> Void)?

    public init(label: String) {
        let side = DiagramZoomMetrics.side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        toolTip = label
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("not built from a coder") }

    /// y-down, as the text it sits on and as the fragment it copies draws.
    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        DiagramZoomButton.draw(in: bounds, context: context)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The first click is the button's, even in a window that is not key; the
    /// text view under it never sees it.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A press is a mouse-up over the button, as any button's is.
    public override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        var over = true
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            over = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp { break }
        }
        if over { onPress?() }
    }

    /// An arrow over the button, not the text view's I-beam.
    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    public override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }
}
#else
public final class DiagramButtonView: UIView {
    /// What a press does.
    public var onPress: (() -> Void)?

    public init(label: String) {
        let side = DiagramZoomMetrics.side
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        backgroundColor = .clear
        isOpaque = false
        // Touches go through to the text view, whose `DiagramButtonPress`
        // takes the ones that start here — see the file header.
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = label
        accessibilityTraits = .button
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: DiagramButtonView, _) in
            view.setNeedsDisplay()
        }
    }

    required init?(coder: NSCoder) { fatalError("not built from a coder") }

    public override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        DiagramZoomButton.draw(in: bounds, context: context)
    }

    /// Whether a touch at `point`, in this view's coordinates, is on the
    /// button — with a fingertip's slop, as the editor's drawn button has.
    public func takes(touchAt point: CGPoint) -> Bool {
        !isHidden && superview != nil
            && bounds.insetBy(dx: -DiagramZoomButton.touchSlop, dy: -DiagramZoomButton.touchSlop).contains(point)
    }

    public override func accessibilityActivate() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }
}

/// Presses on the `DiagramButtonView`s laid on a text view, claimed at
/// touch-down and made on release over the same button — a press of no
/// duration that recognises alongside nothing, so for a touch on a button it
/// excludes UIKit's caret tap, loupe and drags, and a touch anywhere else never
/// reaches it. The editor's own button works the same way
/// (`MarkdownUITextView.handleDiagramZoomPress`).
public final class DiagramButtonPress: NSObject, UIGestureRecognizerDelegate {
    public let recognizer: UILongPressGestureRecognizer
    private weak var host: UIView?
    private let buttons: () -> [DiagramButtonView]
    private(set) var pending: DiagramButtonView?

    /// Install on `host`, pressing whichever of `buttons()` a touch starts on.
    public init(on host: UIView, buttons: @escaping () -> [DiagramButtonView]) {
        self.host = host
        self.buttons = buttons
        recognizer = UILongPressGestureRecognizer()
        super.init()
        recognizer.minimumPressDuration = 0
        recognizer.addTarget(self, action: #selector(handle(_:)))
        recognizer.delegate = self
        host.addGestureRecognizer(recognizer)
    }

    /// The button a touch at `point` (in the host's coordinates) is on, if any.
    func button(at point: CGPoint) -> DiagramButtonView? {
        guard let host else { return nil }
        return buttons().first { $0.takes(touchAt: $0.convert(point, from: host)) }
    }

    /// Decided at touch-down, while the button is on screen: a touch that
    /// starts on one is the button's.
    func takes(touchAt point: CGPoint) -> Bool {
        pending = button(at: point)
        return pending != nil
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldReceive touch: UITouch) -> Bool {
        guard let host else { return false }
        return takes(touchAt: touch.location(in: host))
    }

    @objc func handle(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .ended:
            defer { pending = nil }
            guard let pending, let host,
                  button(at: press.location(in: host)) === pending else { return }
            pending.onPress?()
        case .cancelled, .failed:
            pending = nil
        default:
            break
        }
    }
}
#endif
