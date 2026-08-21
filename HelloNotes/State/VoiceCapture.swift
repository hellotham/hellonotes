//
//  VoiceCapture.swift
//  HelloNotes
//
//  On-device voice capture via the new Speech engine (macOS/iOS 26):
//  `SpeechAnalyzer` + `SpeechTranscriber` stream a live transcript from the
//  microphone, which the caller writes into a note. Models install on demand via
//  `AssetInventory`. Availability- and `canImport`-gated so the app still builds
//  on the macOS 15 floor.
//

import Foundation

#if canImport(Speech) && canImport(AVFoundation)
import Speech
import AVFoundation

/// Why capture couldn't start, for the cases the Speech framework has no error
/// of its own for.
enum VoiceCaptureError: LocalizedError {
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "HelloNotes can't use the microphone. Turn it on in Settings › Privacy & Security › Microphone."
        }
    }
}

@available(macOS 26.0, iOS 26.0, *)
actor VoiceCapture {
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    /// Whether on-device transcription is supported at all.
    static func isSupported() async -> Bool { !(await SpeechTranscriber.supportedLocales).isEmpty }

    /// Start transcribing. `onTranscript` receives the running transcript (final
    /// text + the current volatile tail) as it grows.
    func start(onTranscript: @escaping @Sendable (String) -> Void) async throws {
        #if os(iOS)
        // Asked first, before the model download below, so the permission alert
        // lands on the tap that asked for dictation rather than some seconds
        // after it. Already-answered requests return immediately.
        guard await AVAudioApplication.requestRecordPermission() else {
            throw VoiceCaptureError.microphoneDenied
        }
        #endif

        let transcriber = SpeechTranscriber(
            locale: Locale.current,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [])
        self.transcriber = transcriber

        // Install the on-device model if needed.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        resultsTask = Task {
            var finalized = ""
            do {
                for try await result in transcriber.results {
                    let piece = String(result.text.characters)
                    if result.isFinal {
                        finalized += piece
                        onTranscript(finalized)
                    } else {
                        onTranscript(finalized + piece)
                    }
                }
            } catch { }
        }

        try await analyzer.start(inputSequence: stream)

        #if os(iOS)
        // iOS hands out no microphone until an audio session asks for one: the
        // default `.soloAmbient` category has no input route at all, so the tap
        // install and `engine.start()` below both fail before a single sample
        // arrives — and `DictationController` swallows the throw, which is how
        // dictation on iPad managed to produce no prompt, no transcript and no
        // error. macOS has no `AVAudioSession` (the input device is simply
        // there), hence the gate rather than a shared path.
        //
        // This must run *before* `engine.inputNode` is first read: the node
        // latches the hardware format on that first access, and the format the
        // session has yet to grant is not the one we want to tap.
        do {
            try activateAudioSession()
        } catch {
            unwindFailedStart()
            throw error
        }
        #endif

        // Feed microphone audio, converted to the analyzer's preferred format.
        let inputNode = engine.inputNode
        let sourceFormat = inputNode.outputFormat(forBus: 0)
        let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? sourceFormat
        let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: sourceFormat) { buffer, _ in
            let output = converter.flatMap { conv -> AVAudioPCMBuffer? in
                guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                 frameCapacity: buffer.frameCapacity) else { return nil }
                var consumed = false
                var error: NSError?
                conv.convert(to: out, error: &error) { _, status in
                    if consumed { status.pointee = .noDataNow; return nil }
                    consumed = true; status.pointee = .haveData; return buffer
                }
                return error == nil ? out : nil
            } ?? buffer
            continuation.yield(AnalyzerInput(buffer: output))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            unwindFailedStart()
            throw error
        }
    }

    /// Undo a half-built capture.
    ///
    /// `DictationController` drops the `VoiceCapture` when `start()` throws and
    /// never calls `stop()`, so anything already running has to be unwound here:
    /// the results task is waiting on a stream that would otherwise never
    /// finish, and on iOS the audio session would go on ducking other audio for
    /// a dictation that isn't happening.
    private func unwindFailedStart() {
        #if os(iOS)
        deactivateAudioSession()
        #endif
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
    }

    func stop() async {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        inputContinuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        #if os(iOS)
        deactivateAudioSession()
        #endif
    }

    #if os(iOS)
    /// Put the session into a category that has an input route.
    ///
    /// `.measurement` turns off the system's own signal processing, which is
    /// what a recogniser wants to hear rather than an AGC'd version of it, and
    /// has the side effect of allowing a Bluetooth HFP mic. `.duckOthers` lowers
    /// whatever is playing instead of stopping it.
    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)
    }

    /// Hand the audio route back. `.notifyOthersOnDeactivation` is what lets a
    /// ducked podcast come back up instead of staying quiet after dictation.
    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
    #endif
}
#endif
