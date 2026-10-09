//
//  EditorTabBar.swift
//  HelloNotes
//
//  The strip of open notes, and of the collection's tools open beside them —
//  one view, both platforms.
//
//  There were two: this file, gated to macOS, and `tabStrip` written inline in
//  `iOSContentView`. Same job, and they had drifted in three ways.
//
//  The close button carries an accessibility label on iPad and carried none on
//  the Mac, so VoiceOver there announced a row of unlabelled buttons.
//
//  Neither read `ShellContext.tabBarHeight`. The contract defines it —
//  `prefersTouch ? 44 : 32`, "tab bars are never removed; they only change
//  height (HIG: 44pt touch)" — and the Mac hard-coded 30 while iPad used
//  padding, so the one number the contract states about this view was consulted
//  by nothing. That is the same shape as `sortOrder`: a value with a rule and no
//  reader.
//
//  And the selection tint: `selectedContentBackgroundColor` on one side,
//  `.selection` on the other — and `.selection` is not the same colour on
//  both, it only has the same name. Everything here is `Chrome` now: fixed
//  sizes and colours, 28pt tabs whatever is doing the tapping (a tab's target
//  is its own frame), and no material or scroll view
//  of its own — it lives in the shell's bar, which decides what scrolls.
//

import SwiftUI

struct EditorTabBar: View {
    let notes: [Note]
    let activeID: Note.ID?
    let onSelect: (Note.ID) -> Void
    /// Closing goes through the caller so a *background* tab closing cannot
    /// move the selection off the note being read.
    let onClose: (Note.ID) -> Void
    /// The collection's tools open beside the notes (`ToolTabs`), after them.
    /// While one is showing, no note's tab is the active one.
    var tools: [CollectionTool] = []
    var activeTool: CollectionTool? = nil
    var onSelectTool: (CollectionTool) -> Void = { _ in }
    var onCloseTool: (CollectionTool) -> Void = { _ in }
    var accent: Color = .accentColor

    var body: some View {
        HStack(spacing: Chrome.Metric.barSpacing) {
            ForEach(notes) { note in
                tab(note.title, systemImage: nil, isActive: activeTool == nil && note.id == activeID,
                    select: { onSelect(note.id) }, close: { onClose(note.id) })
            }
            ForEach(tools) { tool in
                tab(tool.title, systemImage: tool.systemImage, isActive: tool == activeTool,
                    select: { onSelectTool(tool) }, close: { onCloseTool(tool) })
            }
        }
        .frame(height: Chrome.Metric.control)
    }

    /// One tab — a note's, or a tool's with its symbol before the title.
    private func tab(_ title: String, systemImage: String?, isActive: Bool,
                     select: @escaping () -> Void, close: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isActive ? Chrome.Colour.label : Chrome.Colour.secondaryLabel)
            }
            ChromeLine(title, size: 13, weight: isActive ? .semibold : .regular,
                       colour: isActive ? Chrome.Colour.label : Chrome.Colour.secondaryLabel)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Chrome.Colour.tertiaryLabel)
                    .frame(width: 16, height: 16)
                    .contentShape(.rect.inset(by: -6))
            }
            .buttonStyle(ChromePlainStyle())
            .accessibilityLabel("Close \(title)")
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: Chrome.Metric.tabMaxWidth)
        .frame(height: Chrome.Metric.control)
        .background(isActive ? Chrome.selection(accent) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Chrome.Metric.radius))
        // The whole tab selects, padding and vertical slack included. Wrapping
        // only the `Text` in a `Button` shrank the target to the title's glyph
        // box — about 17pt tall inside a 44pt touch bar — and left this
        // `contentShape` with no gesture attached to it, so tapping beside a
        // title or anywhere in the margin did nothing.
        //
        // Wrapping the *whole tab* is not the answer either: the close control
        // is a `Button` inside this HStack, and nesting one button in another
        // makes which of them a tap belongs to a matter of luck. So the gesture
        // stays, and what it was missing is added explicitly — a bare tap
        // recogniser carries no button trait and offers VoiceOver nothing to
        // activate, so the tab could be read aloud but never selected.
        .contentShape(.rect)
        .onTapGesture(perform: select)
        // `.combine` first, and that is the load-bearing line: this HStack holds
        // a Text and the close `Button`, so without it there is no element whose
        // frame is the tab — the trait and the action below would either be
        // dropped for want of one, or pushed down onto both children, putting
        // the tab's activate action on the close button and shrinking the
        // focus rect to the title's ~17pt glyph box. That is the same target
        // shrinkage the comment above says this design exists to avoid, arriving
        // through the accessibility tree instead of the layout.
        //
        // `WelcomeView:120` uses the same modifier but not for the same reason:
        // its row is an image plus two `Text`s and nothing interactive, so
        // `.combine` there only merges two static labels into one utterance.
        // This is the harder case, and it has a real cost — see the close
        // action below.
        .accessibilityElement(children: .combine)
        // Combining merges the children's labels, so name it explicitly or it
        // announces "«Title» Close «Title»".
        .accessibilityLabel(title)
        // Which note is open was carried only by weight, tint and a `.selection`
        // fill — three visual signals, none of which reaches VoiceOver. The app's
        // other tab strip already says it: `InspectorOverlay:126`, which adds
        // `.isSelected` alone because its row already *is* a `Button`. (The
        // accent swatches in `AppearanceSettingsSections` write the same
        // `[.isButton, .isSelected]` pair, but they are a colour picker, not a
        // tab strip, and being buttons already they do not need the `.isButton`
        // half either. This HStack is not a button, so here it is load-bearing.)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
        // Re-exposed by hand, and named with the title because the merged
        // element's label is the bare tab name: the close control's own
        // `.accessibilityLabel("Close \(title)")` above is absorbed by
        // `.combine` and no longer reaches anyone.
        //
        // **This is a trade, not a free fix.** `.combine` stops the close
        // `Button` being an accessibility *element*, so it leaves the rotor's
        // Actions menu as the only route to it: VoiceOver can no longer swipe
        // to it, Voice Control can no longer be told "Tap Close Meeting Notes",
        // and Switch Control / Full Keyboard Access cannot step onto it at all.
        // Verify with VoiceOver before shipping — if `.combine` turns out to
        // promote the merged child's own action as well, this line is a second,
        // duplicate "Close" in the same rotor and should go.
        .accessibilityAction(named: "Close \(title)", close)
    }
}
