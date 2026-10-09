//
//  FindReplaceBar.swift
//  HelloNotes
//
//  Cross-platform. It was `#if os(macOS)` and contains no AppKit — pure SwiftUI
//  over bindings — so the gate was the only thing making find-and-**replace** a
//  Mac feature. iOS has UIKit's find navigator, which finds and replaces in the
//  live editor; it does not exist in Markdown mode or Preview, and it is not
//  reachable at all without a hardware keyboard.
//
//  Created by Chris Tham on 11/7/2026.
//

import MarkdownCore
import SwiftUI

/// A find/replace bar shown above the editor. It drives the editor's find
/// highlighting and replace handlers entirely through the notification bus
/// (`hnEditorFindQuery` / `hnEditorReplace*`), so it holds no reference to the
/// text view — it just posts queries and reflects the match count the engine
/// posts back.
///
/// The `.*` button makes the find a regular expression (`FindPattern`): the
/// replacement is then a template — `$1` the first group, `\n` a new line —
/// and a pattern the editor cannot read, or one too slow to finish, is said
/// where the count goes.
struct FindReplaceBar: View {
    @Binding var findText: String
    @Binding var replaceText: String
    /// 0-based index of the focused match; -1 when there are none.
    @Binding var currentIndex: Int
    /// Whether the find is a regular expression rather than a phrase.
    @Binding var isRegularExpression: Bool
    let matchCount: Int
    /// Why the editor has no count to give, or nil.
    var problem: FindPattern.Problem?
    var accent: Color = .accentColor
    var onFindChanged: () -> Void
    var onNext: () -> Void
    var onPrevious: () -> Void
    var onReplace: () -> Void
    var onReplaceAll: () -> Void
    var onClose: () -> Void

    @FocusState private var findFocused: Bool

    private var countLabel: String {
        if findText.isEmpty { return "" }
        switch problem {
        case .invalid: return "Invalid pattern"
        case .tooSlow: return "Too slow"
        case nil: break
        }
        if matchCount == 0 { return "No results" }
        return "\(currentIndex + 1) of \(matchCount)"
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                TextField("", text: $findText)
                    .textFieldStyle(.plain)
                    .focusEffectDisabled()
                    .focused($findFocused)
                    .onSubmit(onNext)
                    .onChange(of: findText) { _, _ in onFindChanged() }
                    .chromePlaceholder(isRegularExpression ? "Find (regular expression)" : "Find",
                                       showing: findText.isEmpty)
                    .accessibilityLabel("Find")
                    .chromeFieldBox()

                RegularExpressionToggle(isOn: $isRegularExpression, accent: accent) {
                    onFindChanged()
                }

                Text(countLabel)
                    .font(Chrome.Style.caption.monospacedDigit())
                    .foregroundStyle(problem == nil ? Chrome.Colour.secondaryLabel : Chrome.Colour.red)
                    .frame(minWidth: 64, alignment: .trailing)
                    .help(problem == .tooSlow
                          ? "The pattern took longer than half a second, so the search stopped. Patterns that nest repeats, like (a*)*, can take that long."
                          : "")

                Button(action: onPrevious) {
                    Image(systemName: "chevron.up")
                }
                // No shortcut of its own to name: Shift-Return is the field's
                // submit, which is Next, and ⇧⌘G — the usual Find Previous —
                // is Graph View here (toolbars.md §14, item 12).
                .help("Previous match")
                .disabled(matchCount == 0)

                Button(action: onNext) {
                    Image(systemName: "chevron.down")
                }
                .help("Next match (Return)")
                .disabled(matchCount == 0)

                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 6) {
                Image(systemName: "arrow.2.squarepath")
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                TextField("", text: $replaceText)
                    .textFieldStyle(.plain)
                    .focusEffectDisabled()
                    .chromePlaceholder(isRegularExpression ? "Replace ($1 for a group)" : "Replace",
                                       showing: replaceText.isEmpty)
                    .accessibilityLabel("Replace")
                    .chromeFieldBox()

                Button("Replace", action: onReplace)
                    .disabled(matchCount == 0)
                Button("Replace All", action: onReplaceAll)
                    .disabled(matchCount == 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // The chrome grey, not `.bar`, which is each platform's own material.
        .background(Chrome.Colour.chrome)
        .overlay(alignment: .bottom) { ChromeDivider() }
        .onAppear { findFocused = true }
    }
}

/// The find bar's `.*`: whether the find is a regular expression. Drawn as the
/// bar's glyph buttons are (`ChromeGlyph`) — the accent on its selection fill
/// while on — with the two characters editors use for it, since no SF Symbol
/// says "regular expression".
private struct RegularExpressionToggle: View {
    @Binding var isOn: Bool
    var accent: Color
    var onChange: () -> Void

    @State private var hovering = false

    var body: some View {
        Button {
            isOn.toggle()
            onChange()
        } label: {
            Text(".*")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(isOn ? accent : Chrome.Colour.secondaryLabel)
                .frame(width: Chrome.Metric.control, height: Chrome.Metric.control)
                .background(
                    RoundedRectangle(cornerRadius: Chrome.Metric.radius)
                        .fill(isOn ? Chrome.selection(accent)
                                   : hovering ? Chrome.Colour.hover : Color.clear))
                .contentShape(.rect.inset(by: -(Chrome.Metric.touchTarget - Chrome.Metric.control) / 2))
        }
        .buttonStyle(ChromePlainStyle())
        .onHover { hovering = $0 }
        .help("Regular expression — in the replacement, $1 is the first group and \\n a new line")
        .accessibilityLabel("Regular expression")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
