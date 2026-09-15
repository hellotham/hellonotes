//
//  MLXBridge.swift
//  HelloNotes
//
//  Created by Chris Tham on 15/9/2026.
//
//  The two adapters `MLXLanguageModel` needs to fetch and read a model: a
//  Hugging Face downloader, and a tokenizer from swift-transformers.
//
//  mlx-swift-lm ships these as macros (`#hubDownloader`, `#huggingFaceTokenizerLoader`,
//  `#huggingFaceLanguageModel`). They are written out by hand here instead, and
//  the reason is the build, not the code: a package macro is a compiler plugin,
//  and Xcode will not run one until someone has clicked "Trust & Enable" — which
//  a CI runner and a release archive cannot do. They would need
//  `-skipMacroValidation` on every `xcodebuild` in the repository, forever, and
//  the first script to forget it would fail in a way that looks nothing like the
//  cause. Forty lines of bridge cost less than that, and they mirror the macro
//  expansions in `MLXHuggingFaceMacros` exactly so they can be diffed against
//  upstream when the package moves.
//

import Foundation
import HuggingFace
import MLXLMCommon
import Tokenizers

/// Downloads a model snapshot from the Hugging Face Hub into the shared cache.
nonisolated struct HubModelDownloader: MLXLMCommon.Downloader {
    let client: HubClient
    /// Never touch the network: the model is already on disk. Loading a
    /// downloaded model must work on a plane — and in a region where the Hub
    /// is unreachable — so the caller sets this whenever the snapshot exists.
    var localFilesOnly = false

    init(client: HubClient = HubClient(), localFilesOnly: Bool = false) {
        self.client = client
        self.localFilesOnly = localFilesOnly
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repo = Repo.ID(rawValue: id) else {
            throw MLXModelError.invalidRepository(id)
        }
        return try await client.downloadSnapshot(
            of: repo,
            revision: revision ?? "main",
            matching: patterns,
            localFilesOnly: localFilesOnly,
            progressHandler: { @MainActor progress in progressHandler(progress) })
    }
}

/// Loads a model's tokenizer with swift-transformers.
nonisolated struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return TransformersTokenizer(upstream)
    }
}

/// swift-transformers' tokenizer, spoken in MLXLMCommon's vocabulary.
nonisolated struct TransformersTokenizer: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers names this `decode(tokens:)`.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

nonisolated enum MLXModelError: LocalizedError {
    case invalidRepository(String)
    case notDownloaded(String)
    case folderUnreadable(String)
    case noModelChosen

    var errorDescription: String? {
        switch self {
        case .invalidRepository(let id):
            "“\(id)” isn't a Hugging Face model name. Use the form organisation/model, for example mlx-community/Qwen3-4B-4bit."
        case .notDownloaded(let name):
            "\(name) hasn't been downloaded yet. Download it in AI settings."
        case .folderUnreadable(let name):
            "HelloNotes can no longer read the model folder “\(name)”. Choose it again in AI settings."
        case .noModelChosen:
            "Choose an MLX model in AI settings."
        }
    }
}
