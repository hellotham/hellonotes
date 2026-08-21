//
//  DictationController.swift
//  HelloNotes
//
//  Drives on-device voice capture (`VoiceCapture`) from the UI: toggle to start/
//  stop dictation; the live transcript is exposed for display, and on stop it's
//  appended to today's daily note via `NavigationRouter`. Availability-gated —
//  a no-op where the Speech engine isn't available.
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
    private var capture: Any?   // VoiceCapture (macOS/iOS 26-gated), held as Any
    #endif

    var isSupported: Bool {
        if #available(macOS 26.0, iOS 26.0, *) { return true }
        return false
    }

    func toggle() {
        Task { isRecording ? await stop() : await start() }
    }

    func start() async {
        #if canImport(Speech)
        guard #available(macOS 26.0, iOS 26.0, *), !isRecording else { return }
        transcript = ""
        lastError = nil
        let vc = VoiceCapture()
        capture = vc
        do {
            try await vc.start { [weak self] text in
                Task { @MainActor in self?.transcript = text }
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
        guard #available(macOS 26.0, iOS 26.0, *), let vc = capture as? VoiceCapture else { return }
        await vc.stop()
        capture = nil
        isRecording = false
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { await NavigationRouter.shared?.openDailyNote(appending: text) }
        #endif
    }
}
