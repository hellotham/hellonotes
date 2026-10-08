//
//  QuickCaptureView.swift
//  HelloNotes
//
//  Quick capture: type a line and append it to today's daily note in the focused
//  collection. Runs in-process (no sandbox/bookmark issues) via the shared
//  NavigationRouter.
//
//  On the Mac it lives in a `MenuBarExtra`, so it is reachable without switching
//  to the app. iOS has no such chrome — the nearest equivalents are a Control
//  Center control or a widget, both of which can only *launch* the app — so
//  there it is a sheet, reached from the Library actions, the `+` menu and the
//  command palette. The capture itself is the same view and the same code path.
//

import SwiftUI

struct QuickCaptureView: View {
    let router: NavigationRouter
    @State private var text = ""
    @State private var status: String?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Quick Capture", systemImage: "square.and.pencil")
                .font(Chrome.Style.headline)
            Text("Appends to today's daily note.")
                .font(Chrome.Style.caption)
                .foregroundStyle(Chrome.Colour.secondaryLabel)

            TextEditor(text: $text)
                .font(Chrome.Style.body)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .chromeFieldBox(multiline: true)
                // The menu-bar window has only its content to size itself by,
                // so the editor states an ideal size for it; a sheet — the same
                // on the Mac and the iPad — gives the editor its room, and it
                // fills it.
                .frame(minWidth: 300, idealWidth: 300, minHeight: 96, idealHeight: 96)

            HStack {
                if let status {
                    Text(status).font(Chrome.Style.caption).foregroundStyle(Chrome.Colour.secondaryLabel)
                }
                Spacer()
                // A way out that Escape reaches: as a sheet it had none but a
                // swipe (toolbars.md §14, item 10; implemented.md §51.36).
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Append") { append() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private func append() {
        let capture = trimmed
        guard !capture.isEmpty else { return }
        text = ""
        Task {
            let ok = await router.openDailyNote(appending: capture)
            status = ok ? "Added to today's note." : "Open a collection first."
        }
    }
}
