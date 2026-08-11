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

    /// Reports a persistence failure to the host, which shows it on the
    /// assistant's error line. Losing the transcript is recoverable — the
    /// conversation stays in memory for the run and `load()` tolerates a
    /// truncated file — so this warns rather than throws. It was previously
    /// `try?`: a full disk or a revoked container silently stopped saving and
    /// the loss only showed up at the next launch, as an empty conversation.
    var onPersistenceError: (@Sendable @MainActor (String) -> Void)?

    func save(_ messages: [LLMMessage]) {
        let capped = Array(messages.suffix(Self.persistedTailLimit))
        let url = fileURL
        let previous = writeTask
        // Encode + write off the main actor — the transcript is re-serialized
        // every turn, and tool outputs make it large. Chain on the previous write
        // so two saves in one turn (pre-turn + completion) can't land out of
        // order and persist a stale transcript.
        let report = onPersistenceError
        writeTask = Task.detached(priority: .utility) {
            await previous?.value
            let encoder = JSONEncoder()
            let lines = capped.compactMap { message -> String? in
                guard let d = try? encoder.encode(message) else { return nil }
                return String(data: d, encoding: .utf8)
            }
            do {
                try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
            } catch {
                await MainActor.run {
                    report?("Couldn't save the chat transcript: \(error.localizedDescription)")
                }
            }
        }
    }

    func clear() {
        writeTask?.cancel()
        writeTask = nil
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            // Nothing persisted yet — clearing an empty conversation is a no-op.
        } catch {
            onPersistenceError?("Couldn't clear the saved chat: \(error.localizedDescription)")
        }
    }

    private static func hash(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
