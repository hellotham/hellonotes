//
//  VisionAlt.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  On-device "vision intelligence" for a picture's alt text — a pasted one,
//  or one put in with Insert Image: classifies the image (and reads any
//  prominent text) with the Vision framework to produce a short, descriptive
//  alt string. No network, no API key.
//

// **Cross-platform.** Vision ships on iOS, and every function here already
// worked in `CGImage` — the `AppKit` import was unused. The gate was the only
// thing keeping automatic alt text off the iPad.

import Foundation
import Vision
import CoreGraphics
import ImageIO

nonisolated enum VisionAlt {
    /// A short alt-text description of the image at `url`, or `nil` if nothing
    /// confident could be derived.
    ///
    /// `@concurrent`, and the enum `nonisolated`: by the target's default this
    /// was main-actor, so a pasted screenshot was decoded on the main thread
    /// before Vision was ever asked — tens of milliseconds for a large one, just
    /// as the editor wants to show the paste. Read through `FileIO`, because the
    /// picture is in the vault, and an uncoordinated read of a vault file is
    /// the one thing `FileIO` exists to prevent.
    @concurrent
    static func describe(_ url: URL) async -> String? {
        guard let data = await FileIO.onScanLane(for: url, { try? FileIO.readData(at: url) }),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              // Turned the way it is meant to be seen, and no larger than
              // Vision needs. A camera keeps a photo's orientation as a tag,
              // and decoded as stored a page photographed upright was read
              // on its side — no words, so no description from them; and a
              // 48-megapixel photo decoded whole is some 190 MB.
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4096,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }

        let labels = await classify(cgImage)
        // Readable text first, when there is some — a screenshot, a diagram,
        // a page photographed — and called a screenshot only when the
        // classifier says it is one: a photographed page is its words.
        if let text = await recognizedText(cgImage), text.count >= 8 {
            let excerpt = markdownSafe(String(text.prefix(80)))
            let isScreenshot = labels?.components(separatedBy: ", ").contains("screenshot") ?? false
            return isScreenshot ? "Screenshot: \(excerpt)" : excerpt
        }
        // Otherwise, what the classifier saw.
        return labels.map(markdownSafe)
    }

    /// `text` as a Markdown image's description can hold it — the alt text
    /// is written into `![…](…)` as it comes. A bracket ends the description
    /// early or leaves it open, and a backslash escapes the `]` after it:
    /// either way the note shows the Markdown, not the picture. And a pipe
    /// went from punctuation to a size when Obsidian's were read
    /// (`PictureNames.sizeSuffix`): a photographed sign reading
    /// "Platform | 12" drew its picture twelve points wide.
    static func markdownSafe(_ text: String) -> String {
        String(text.map { character -> Character in
            switch character {
            case "[": "("
            case "]": ")"
            case "\\", "|": "/"
            case _ where character.isNewline: " "
            default: character
            }
        })
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
            // `.accurate`, never `.fast`, which reads "text" into a photo: five
            // of the simulator's seven sample photos of flowers and water came
            // back as lines like `411 4fk• éji`, at the same confidence (0.3–0.5)
            // as a real screenshot's, and became their alt text. `.accurate`
            // read nothing in any of the seven and every line of the
            // screenshots at 1.0, in 50–190 ms each once its model is loaded
            // (measured on a Mac, 2026-11-22; the first request in a process
            // that has never used it waits for the model).
            request.recognitionLevel = .accurate
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
        // Handed over, not shared: the caller makes and configures the
        // request and never touches it again, and only this block runs it.
        nonisolated(unsafe) let request = request
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
///
/// `nonisolated`: it is resumed from Vision's completion handlers, on whatever
/// queue Vision chose, and the lock is what makes that safe — main-actor by the
/// target's default, every `resume` was a cross-isolation call.
nonisolated private final class OnceResumer: @unchecked Sendable {
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
