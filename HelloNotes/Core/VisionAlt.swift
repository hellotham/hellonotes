//
//  VisionAlt.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  On-device "vision intelligence" for pasted-image alt text: classifies the
//  image (and OCRs any prominent text) with the Vision framework to produce a
//  short, descriptive alt string. No network, no API key.
//

// **Cross-platform.** Vision ships on iOS, and every function here already
// worked in `CGImage` — the `AppKit` import was unused. The gate was the only
// thing keeping automatic alt text off the iPad.

import Foundation
import Vision
import CoreGraphics
import ImageIO

enum VisionAlt {
    /// A short alt-text description of the image at `url`, or `nil` if nothing
    /// confident could be derived.
    static func describe(_ url: URL) async -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        // Prefer readable text (screenshots, diagrams) when present.
        if let text = await recognizedText(cgImage), text.count >= 8 {
            return "Screenshot: \(String(text.prefix(80)))"
        }
        // Otherwise, top classification labels.
        if let labels = await classify(cgImage), !labels.isEmpty {
            return labels
        }
        return nil
    }

    /// The top classification labels, already joined (so this and
    /// `recognizedText` share one non-generic `OnceResumer` — see its note).
    private static func classify(_ image: CGImage) async -> String? {
        await withCheckedContinuation { continuation in
            let once = OnceResumer(continuation)
            let request = VNClassifyImageRequest { request, _ in
                let labels = (request.results as? [VNClassificationObservation] ?? [])
                    .filter { $0.confidence > 0.3 }
                    .sorted { $0.confidence > $1.confidence }
                    .prefix(3)
                    .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
                once.resume(labels.isEmpty ? nil : labels.joined(separator: ", "))
            }
            perform(request, on: image) { once.resume(nil) }
        }
    }

    private static func recognizedText(_ image: CGImage) async -> String? {
        await withCheckedContinuation { continuation in
            let once = OnceResumer(continuation)
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                let joined = lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                once.resume(joined.isEmpty ? nil : joined)
            }
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = true
            perform(request, on: image) { once.resume(nil) }
        }
    }

    /// Run a Vision request off the main thread, invoking `onFailure` if it
    /// throws. `handler.perform` invokes the request's completion handler (which
    /// also resumes) even on failure, so both paths funnel through `OnceResumer`
    /// — resuming a `CheckedContinuation` twice is a runtime crash.
    ///
    /// Deliberately **non-generic** (the caller closes over its own `OnceResumer`
    /// instead of passing it in): as a generic taking `OnceResumer<T>`, this
    /// crashed the Swift 6.2 SIL performance inliner in `-O` builds
    /// (`isCallerAndCalleeLayoutConstraintsCompatible` → null generic
    /// signature), so Release archives segfaulted while Debug built fine.
    private static func perform(_ request: VNRequest, on image: CGImage,
                                onFailure: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do { try handler.perform([request]) }
            catch { onFailure() }
        }
    }
}

/// Resumes a `CheckedContinuation` at most once (Vision's completion handler and
/// a thrown `perform` can otherwise both resume it).
///
/// Deliberately **non-generic**. As `OnceResumer<T>`, its compiler-generated
/// `__deallocating_deinit` crashed the Swift 6.3 SIL `EarlyPerfInliner` in `-O`
/// builds — `isCallerAndCalleeLayoutConstraintsCompatible` walked a null generic
/// signature and segfaulted, so *every* Release archive died (Debug was fine,
/// which is why it went unnoticed). Both callers funnel through `String?`, so
/// the generic bought nothing. Keep it concrete.
private final class OnceResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<String?, Never>
    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
    func resume(_ value: String?) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation.resume(returning: value)
    }
}
