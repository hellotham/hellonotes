//
//  FoundationModelsProvider.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Apple's on-device model (macOS 26+) as a provider. Reuses the availability
//  logic from NoteIntelligence. Streams text via `streamResponse`, which yields
//  cumulative snapshots — we diff to emit deltas. Chat only (Foundation Models'
//  native tools need compile-time types, not our dynamic tool registry).
//

#if os(macOS)
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct FoundationModelsProvider: LLMProvider {
    func stream(_ context: LLMContext, model: String, options: LLMRequestOptions) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                #if canImport(FoundationModels)
                if #available(macOS 26.0, *) {
                    do {
                        let instructions = context.systemPrompt
                            ?? "You are the HelloNotes assistant. Be concise and helpful."
                        let session = LanguageModelSession(instructions: instructions)
                        let prompt = PromptRendering.transcript(context.messages)
                        var previous = ""
                        for try await snapshot in session.streamResponse(to: prompt) {
                            let full = snapshot.content
                            // streamResponse yields CUMULATIVE snapshots that can
                            // revise earlier text, not just append. Diff from the
                            // common prefix so a same-length revision still emits
                            // (and a shrink can't slice at an out-of-range offset).
                            let common = full.commonPrefix(with: previous)
                            if full.count > common.count {
                                let delta = String(full[full.index(full.startIndex, offsetBy: common.count)...])
                                continuation.yield(.textDelta(delta))
                            }
                            previous = full
                        }
                        continuation.yield(.done(.stop))
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        continuation.yield(.done(.cancelled)); continuation.finish(); return
                    } catch {
                        continuation.finish(throwing: error); return
                    }
                }
                #endif
                continuation.finish(throwing: LLMError.unsupported(
                    "Apple Intelligence requires macOS 26 on a supported Mac."))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
