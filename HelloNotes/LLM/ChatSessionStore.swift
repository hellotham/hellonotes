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

    func save(_ messages: [LLMMessage]) {
        let encoder = JSONEncoder()
        let lines = messages.compactMap { message -> String? in
            guard let d = try? encoder.encode(message) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        try? lines.joined(separator: "\n").data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func hash(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
