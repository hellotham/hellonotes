//
//  QuickCaptureView.swift
//  HelloNotes
//
//  The menu-bar quick-capture popover: type a line and append it to today's
//  daily note in the focused collection, without switching to the app. Runs
//  in-process (no sandbox/bookmark issues) via the shared NavigationRouter.
//

#if os(macOS)
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
                .frame(width: 300, height: 96)
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
#endif
