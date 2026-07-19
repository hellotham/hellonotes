//
//  ChatSessionStore.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Persists a chat as append-style JSONL (one message per line) under Application
//  Support, keyed by the collection path — so a conversation survives relaunches.
//  Simple and filesystem-based, matching the app's "files are the source of
//  truth" philosophy.
//

import Foundation
import CryptoKit

@MainActor
final class ChatSessionStore {
    private let fileURL: URL

    init(collectionURL: URL?) {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let key = collectionURL.map { Self.hash($0.standardizedFileURL.path) } ?? "no-collection"
        let dir = support.appendingPathComponent("HelloNotes/chats/\(key)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("current.jsonl")
    }

    func load() -> [LLMMessage] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(LLMMessage.self, from: d)
        }
    }

    /// The most recent messages kept on disk. Bounds the persisted transcript so
    /// a long-lived conversation (with verbatim tool outputs) can't grow the file
    /// without limit. The in-memory session keeps the full history for the run.
    private static let persistedTailLimit = 1000

    /// The most recent write, so each save chains after it instead of racing.
    private var writeTask: Task<Void, Never>?

    func save(_ messages: [LLMMessage]) {
        let capped = Array(messages.suffix(Self.persistedTailLimit))
        let url = fileURL
        let previous = writeTask
        // Encode + write off the main actor — the transcript is re-serialized
        // every turn, and tool outputs make it large. Chain on the previous write
        // so two saves in one turn (pre-turn + completion) can't land out of
        // order and persist a stale transcript.
        writeTask = Task.detached(priority: .utility) {
            await previous?.value
            let encoder = JSONEncoder()
            let lines = capped.compactMap { message -> String? in
                guard let d = try? encoder.encode(message) else { return nil }
                return String(data: d, encoding: .utf8)
            }
            try? lines.joined(separator: "\n").data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    func clear() {
        writeTask?.cancel()
        writeTask = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func hash(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
