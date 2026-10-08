//
//  EditorBus.swift
//  MarkdownEditor
//
//  The editor's command bus, and the one place its names are spelled.
//
//  **Every name on it is addressed to one editor.** The Format commands always
//  were — `hnEditorFormat.<kind>.<id>` — but the find bar's four
//  (`hn.editor.findQuery`, `replaceCurrent`, `replaceAll`, `clearHighlights`),
//  the heading jump, and the match count that answers a find were posted with
//  no address at all, and every editor in every window answered them. The only
//  guard was `window != nil`, which every open editor passes. Two windows on
//  the same note showed it: a mind-map section tapped in one selected the
//  heading in both. Read from the code, it was worse than a stray selection —
//  Replace replaced whatever the other editor had selected, and Replace All
//  rewrote every match in the note open there, saved to disk with nothing on
//  screen to say so.
//
//  **The address is the editor, not the note.** It was the note's path, and
//  that was the Format bus's defect too: two editors can show one note — two
//  windows, or Open in New Window, each with a buffer of its own — so a Bold
//  meant for one bolded the other's selection as well. The host gives each
//  editor an id of its own and joins it with `commandBus(editorID:)`;
//  everything posted under that id reaches that editor and nothing else, and a
//  post with no address reaches nothing. Split's two panes are one editor, so
//  both answer a jump addressed to it, which is what Split wants.
//

import Foundation

/// `nonisolated` because this target defaults to the main actor, and spelling a
/// name is a pure function: anything may post, from anywhere.
public nonisolated enum EditorBus {
    /// A Format command — `kind` is `bold`, `italic`, `strikethrough`,
    /// `highlight`, `inlineCode`, `blockquote`, `unorderedList`,
    /// `orderedList` or `heading` (with `userInfo["level"]`).
    public static func format(_ kind: String, editor: String) -> Notification.Name {
        Notification.Name("hnEditorFormat.\(kind).\(editor)")
    }

    /// Put the n-th heading at the top: `userInfo["ordinal"]`, with
    /// `userInfo["title"]`.
    ///
    /// **Not a find, and not an offset either.** It began as a find — the
    /// heading's own text, posted as a search query — so "go to Maths" meant
    /// "select the first occurrence of the word Maths", which is the front
    /// matter's `title:` line as often as not. A source offset is worse than it
    /// looks: it is only valid for the text it was measured against, so it goes
    /// stale the moment anything above the heading is typed, and keeping it
    /// fresh means re-parsing on the editor's actor. So what travels is an
    /// **ordinal**, the heading's index in document order, which the outline
    /// already knows because it drew that row. Each surface resolves it against
    /// something it already maintains — the editor against
    /// `EditorDocument.blocks`, Preview against the n-th `<h1>`…`<h6>` in the
    /// DOM. The title rides along only to notice when the two disagree, and
    /// the fallback is still a heading, never prose.
    public static func jumpToHeading(editor: String) -> Notification.Name {
        Notification.Name("hn.editor.jumpToHeading.\(editor)")
    }

    /// Select a find match: `userInfo["query"]`, and `userInfo["currentIndex"]`
    /// for Next and Previous.
    public static func findQuery(editor: String) -> Notification.Name {
        Notification.Name("hn.editor.findQuery.\(editor)")
    }

    /// The editor's answer to `findQuery`: `userInfo["count"]` matches. Addressed
    /// on the way back as well — one editor's count is not another find bar's.
    public static func findResults(editor: String) -> Notification.Name {
        Notification.Name("hn.editor.findResults.\(editor)")
    }

    /// Replace the current match with `userInfo["replacement"]`.
    public static func replaceCurrent(editor: String) -> Notification.Name {
        Notification.Name("hn.editor.replaceCurrent.\(editor)")
    }

    /// Replace every match of the last query with `userInfo["replacement"]`.
    public static func replaceAll(editor: String) -> Notification.Name {
        Notification.Name("hn.editor.replaceAll.\(editor)")
    }

    /// Drop the find query and collapse the selection to the caret.
    public static func clearHighlights(editor: String) -> Notification.Name {
        Notification.Name("hn.editor.clearHighlights.\(editor)")
    }

    /// iOS: present the text view's own find navigator.
    public static func find(editor: String) -> Notification.Name {
        Notification.Name("hnEditorFind.\(editor)")
    }

    /// iOS: undo and redo on the document's own stack, which a button outside
    /// the editor cannot reach through the responder chain.
    public static func undo(editor: String) -> Notification.Name {
        Notification.Name("hnEditorUndo.\(editor)")
    }

    public static func redo(editor: String) -> Notification.Name {
        Notification.Name("hnEditorRedo.\(editor)")
    }

    /// iOS: put the keyboard away.
    public static func endEditing(editor: String) -> Notification.Name {
        Notification.Name("hnEditorEndEditing.\(editor)")
    }
}

// MARK: - Heading jumps that wait for their editor

/// A jump to the `ordinal`-th heading, with its `title` to notice when the two
/// disagree (`EditorBus.jumpToHeading`). `nonisolated`, like the bus: a post's
/// payload is read wherever the post arrives.
public nonisolated struct HeadingJump: Sendable, Equatable {
    public let ordinal: Int
    public let title: String

    public init(ordinal: Int, title: String) {
        self.ordinal = ordinal
        self.title = title
    }

    /// The jump a `jumpToHeading` post carries.
    init?(userInfo: [AnyHashable: Any]?) {
        guard let ordinal = userInfo?["ordinal"] as? Int else { return nil }
        self.init(ordinal: ordinal, title: userInfo?["title"] as? String ?? "")
    }
}

public extension EditorBus {

    /// Ask the editor `editor` to show a heading: at once, wherever a surface
    /// of it is showing, and otherwise as soon as one is.
    ///
    /// A jump used to be a post and nothing more, so it reached only the
    /// surfaces already up — and following `[[Note#Heading]]` opens the note
    /// and jumps in one go, before the new tab's text view is in a window or
    /// its page has loaded. The host waited a fixed 350ms and posted anyway; a
    /// tab that took longer scrolled nowhere. Now the jump is kept for its
    /// editor until a surface shows it (`HeadingJumpListener`). A newer jump
    /// replaces an older one.
    @MainActor static func requestHeadingJump(_ jump: HeadingJump, editor: String) {
        waitingJumps[editor] = jump
        NotificationCenter.default.post(name: jumpToHeading(editor: editor), object: nil,
                                        userInfo: ["ordinal": jump.ordinal, "title": jump.title])
    }

    /// The jump waiting for `editor`, taken: the surface that shows it is the
    /// one it was waiting for.
    @MainActor static func takePendingHeadingJump(editor: String) -> HeadingJump? {
        waitingJumps.removeValue(forKey: editor)
    }
}

/// Jumps nobody has shown yet, by editor.
@MainActor private var waitingJumps: [String: HeadingJump] = [:]

/// Answers heading jumps for one surface of an editor — the live editor, the
/// raw-source pane, Preview — the same way on each.
///
/// A post reaches a surface that is ready (`isReady`: in a window, its page
/// loaded) and is shown there at once; Split's two panes are one editor and
/// both answer it. A surface that is not ready leaves the jump waiting, and
/// shows it when it becomes ready (`surfaceBecameReady`), which the surface
/// says from wherever it learns it: arriving in a window, a page finishing.
@MainActor public final class HeadingJumpListener {
    /// The editor this surface answers for (`EditorBus`); nil answers nothing.
    public var editorID: String? {
        didSet { if editorID != oldValue { listen() } }
    }
    private let isReady: () -> Bool
    private let show: (HeadingJump) -> Void
    private let token = EditorBusObserver()

    /// `isReady` and `show` are the surface's: whether it can show a heading
    /// now, and how. Capture the surface weakly — it owns this.
    public init(isReady: @escaping () -> Bool, show: @escaping (HeadingJump) -> Void) {
        self.isReady = isReady
        self.show = show
    }

    /// The surface can show a heading now: show the one waiting for it, if any.
    public func surfaceBecameReady() {
        guard let editorID, isReady(),
              let jump = EditorBus.takePendingHeadingJump(editor: editorID) else { return }
        show(jump)
    }

    private func listen() {
        token.replace(with: nil)
        guard let editorID, !editorID.isEmpty else { return }
        token.replace(with: NotificationCenter.default.addObserver(
            forName: EditorBus.jumpToHeading(editor: editorID), object: nil, queue: .main
        ) { [weak self] note in
            guard let jump = HeadingJump(userInfo: note.userInfo) else { return }
            MainActor.assumeIsolated {
                // Not ready: it stays waiting, for this surface or another.
                guard let self, self.isReady() else { return }
                _ = EditorBus.takePendingHeadingJump(editor: editorID)
                self.show(jump)
            }
        })
        // Re-addressed while already up — a tab's view handed to another
        // editor — and a jump may be waiting for the new one.
        surfaceBecameReady()
    }
}

/// One observer registration, removed when replaced or when this goes — from
/// a `deinit` that is not on the main actor, so the token sits behind a lock.
nonisolated final class EditorBusObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NSObjectProtocol?

    /// Hold `token` in place of whatever was held, which is unregistered.
    func replace(with token: NSObjectProtocol?) {
        if let old = take() { NotificationCenter.default.removeObserver(old) }
        if let token { lock.withLock { stored = token } }
    }

    private func take() -> NSObjectProtocol? {
        lock.withLock { defer { stored = nil }; return stored }
    }

    deinit { if let token = take() { NotificationCenter.default.removeObserver(token) } }
}
