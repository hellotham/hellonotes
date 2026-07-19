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
        try engine.start()
    }

    func stop() async {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        inputContinuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
    }
}
#endif
