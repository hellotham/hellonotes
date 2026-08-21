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

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Quick Capture", systemImage: "square.and.pencil")
                .font(.headline)
            Text("Appends to today's daily note.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.body)
#if os(macOS)
                .frame(width: 300, height: 96)
#else
                // A popover has a width to declare; a sheet is given one.
                .frame(minHeight: 120)
#endif
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .focused($focused)

            HStack {
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
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
