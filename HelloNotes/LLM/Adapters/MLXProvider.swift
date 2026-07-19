//
//  MLXProvider.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  In-process local inference with Apple MLX. Models are downloaded from the
//  Hugging Face `mlx-community` org on first use and cached, then run on Metal —
//  no server, no subprocess (sandbox-friendly). Chat only; MLX has no native
//  tool calling.
//

#if os(macOS)
import Foundation
import MLXLLM
import MLXLMCommon

/// Loads and caches MLX model containers by id. First use of a model downloads
/// its weights (multi-GB) from Hugging Face; subsequent uses are instant.
actor MLXModelStore {
    static let shared = MLXModelStore()
    private var containers: [String: ModelContainer] = [:]
    private var loadTasks: [String: Task<ModelContainer, Error>] = [:]
    private(set) var loadingModel: String?
    private(set) var progress: Double = 0

    func container(for id: String) async throws -> ModelContainer {
        if let existing = containers[id] { return existing }
        // Share one in-flight load: two turns requesting the same not-yet-cached
        // model would otherwise both pass the nil check and each trigger a full
        // multi-GB download (and fight over loadingModel/progress).
        if let task = loadTasks[id] { return try await task.value }
        let task = Task { [weak self] () -> ModelContainer in
            try await loadModelContainer(id: id) { p in
                Task { await self?.setProgress(p.fractionCompleted) }
            }
        }
        loadTasks[id] = task
        loadingModel = id
        progress = 0
        defer { loadTasks[id] = nil; loadingModel = nil }
        let container = try await task.value
        containers[id] = container
        return container
    }

    private func setProgress(_ value: Double) { progress = value }
}

struct MLXProvider: LLMProvider {
    func stream(_ context: LLMContext, model: String, options: LLMRequestOptions) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let container = try await MLXModelStore.shared.container(for: model)
                    var params = GenerateParameters()
                    params.temperature = Float(options.temperature ?? 0.6)
                    if let maxTokens = options.maxTokens { params.maxTokens = maxTokens }

                    let session = ChatSession(
                        container,
                        instructions: context.systemPrompt,
                        generateParameters: params
                    )
                    let prompt = PromptRendering.transcript(context.messages)
                    for try await chunk in session.streamResponse(to: prompt) {
                        continuation.yield(.textDelta(chunk))
                    }
                    continuation.yield(.done(.stop))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.done(.cancelled)); continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
