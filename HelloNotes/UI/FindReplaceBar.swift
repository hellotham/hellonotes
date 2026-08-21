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

import SwiftUI

/// A find/replace bar shown above the editor. It drives the editor's find
/// highlighting and replace handlers entirely through the notification bus
/// (`hnEditorFindQuery` / `hnEditorReplace*`), so it holds no reference to the
/// text view — it just posts queries and reflects the match count the engine
/// posts back.
struct FindReplaceBar: View {
    @Binding var findText: String
    @Binding var replaceText: String
    /// 0-based index of the focused match; -1 when there are none.
    @Binding var currentIndex: Int
    let matchCount: Int
    var onFindChanged: () -> Void
    var onNext: () -> Void
    var onPrevious: () -> Void
    var onReplace: () -> Void
    var onReplaceAll: () -> Void
    var onClose: () -> Void

    @FocusState private var findFocused: Bool

    private var countLabel: String {
        if findText.isEmpty { return "" }
        if matchCount == 0 { return "No results" }
        return "\(currentIndex + 1) of \(matchCount)"
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find", text: $findText)
                    .textFieldStyle(.roundedBorder)
                    .focused($findFocused)
                    .onSubmit(onNext)
                    .onChange(of: findText) { _, _ in onFindChanged() }

                Text(countLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .trailing)

                Button(action: onPrevious) {
                    Image(systemName: "chevron.up")
                }
                .help("Previous match (Shift-Return)")
                .disabled(matchCount == 0)

                Button(action: onNext) {
                    Image(systemName: "chevron.down")
                }
                .help("Next match (return)")
                .disabled(matchCount == 0)

                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 6) {
                Image(systemName: "arrow.2.squarepath")
                    .foregroundStyle(.secondary)
                TextField("Replace", text: $replaceText)
                    .textFieldStyle(.roundedBorder)

                Button("Replace", action: onReplace)
                    .disabled(matchCount == 0)
                Button("Replace All", action: onReplaceAll)
                    .disabled(matchCount == 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { findFocused = true }
    }
}
