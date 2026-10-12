//
//  DictationController.swift
//  HelloNotes
//
//  Drives on-device voice capture (`VoiceCapture`) from the UI: toggle to start/
//  stop dictation; the live transcript is exposed for display, and on stop it's
//  appended to today's daily note via `NavigationRouter`. A no-op on a platform
//  without the Speech framework.
//

import Foundation
import Observation

@MainActor
@Observable
final class DictationController {
    static let shared = DictationController()

    private(set) var isRecording = false
    private(set) var transcript = ""

    /// Why the last `start()` failed, or `nil` if it didn't.
    ///
    /// The `catch` below used to discard the error, which on iOS made a denied
    /// microphone — or an audio session that could not be activated —
    /// indistinguishable from a dead button: the command ran, nothing happened,
    /// and there was nothing to read. `VoiceCapture` now raises real, actionable
    /// errors, so they are kept for a caller to show.
    private(set) var lastError: String?

    #if canImport(Speech)
    private var capture: VoiceCapture?
    #endif

    /// Whether this platform has the Speech framework at all. It was an OS
    /// check as well, from when the app's floor was below the engine's (26).
    var isSupported: Bool {
        #if canImport(Speech)
        true
        #else
        false
        #endif
    }

    func toggle() {
        Task { isRecording ? await stop() : await start() }
    }

    func start() async {
        #if canImport(Speech)
        guard !isRecording else { return }
        transcript = ""
        lastError = nil
        let vc = VoiceCapture()
        capture = vc
        do {
            // The task takes its own weak reference: `[weak self]` makes the
            // handler's `self` a variable, and a task reading another closure's
            // variable is concurrently running code sharing it.
            try await vc.start { [weak self] text in
                Task { @MainActor [weak self] in self?.transcript = text }
            }
            isRecording = true
        } catch {
            capture = nil
            lastError = error.localizedDescription
        }
        #endif
    }

    func stop() async {
        #if canImport(Speech)
        guard let vc = capture else { return }
        await vc.stop()
        capture = nil
        isRecording = false
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // What was said is kept in `transcript` until the next recording
        // starts, and a note it could not be added to is said: the result was
        // ignored, so a transcript that reached no note was simply gone.
        switch await NavigationRouter.shared?.dailyNote(appending: text) {
        case .done: break
        case .noCollection, nil: lastError = "Open a collection to keep what was dictated."
        case .failed(let why): lastError = why
        }
        #endif
    }
}
