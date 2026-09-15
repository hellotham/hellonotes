//
//  ChatSessionStore.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Keeps a collection's Assistant conversation across launches, under
//  Application Support and keyed by the collection's path.
//
//  The conversation is stored as a Foundation Models `Transcript` — prompts,
//  responses, tool calls and their results — which is `Codable` and is exactly
//  what a new session is seeded with. A JSON round trip preserves every entry's
//  text, identity and metadata.
//
//  A 1.3.2 conversation (`current.jsonl`, one message per line in the old
//  provider-agnostic format) is converted on first load: its text turns carry
//  over, and tool calls — made against tools and formats that no longer exist —
//  do not.
//

import Foundation
import CryptoKit
import FoundationModels

@MainActor
final class ChatSessionStore {
    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("transcript.json") }
    private var legacyURL: URL { directory.appendingPathComponent("current.jsonl") }

    /// The most recent entries kept on disk, so a long-lived conversation with
    /// verbatim tool output cannot grow the file without limit.
    static let persistedTailLimit = 400

    /// The most recent write, so each save chains after it instead of racing.
    private var writeTask: Task<Void, Never>?

    /// Reports a persistence failure to the host, which shows it on the
    /// Assistant's error line. Losing the transcript is recoverable — the
    /// conversation stays in memory for the run — so this warns rather than throws.
    var onPersistenceError: (@Sendable @MainActor (String) -> Void)?

    init(collectionURL: URL?, baseDirectory: URL? = nil) {
        let support = baseDirectory
            ?? (try? FileManager.default.url(for: .applicationSupportDirectory,
                                             in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let key = collectionURL.map { Self.hash($0.standardizedFileURL.path) } ?? "no-collection"
        directory = support.appendingPathComponent("HelloNotes/chats/\(key)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The conversation's history — every entry but the instructions.
    func load() -> [Transcript.Entry] {
        if let data = try? Data(contentsOf: fileURL) {
            do {
                return Self.history(of: try JSONDecoder().decode(Transcript.self, from: data))
            } catch {
                // Kept, not overwritten: a transcript this build cannot read may
                // be one a later build wrote.
                let aside = directory.appendingPathComponent("transcript-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: fileURL, to: aside)
                onPersistenceError?("Couldn't read the saved conversation, so a new one was started.")
                return []
            }
        }
        guard let data = try? Data(contentsOf: legacyURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let migrated = LegacyChatTranscript.entries(fromJSONL: text)
        save(migrated)
        try? FileManager.default.removeItem(at: legacyURL)
        return migrated
    }

    func save(_ entries: [Transcript.Entry]) {
        let transcript = Transcript(entries: entries.suffix(Self.persistedTailLimit))
        let url = fileURL
        let previous = writeTask
        let report = onPersistenceError
        writeTask = Task.detached(priority: .utility) {
            await previous?.value
            // Cancelled by `clear()` before it started: the conversation this
            // would have written has been deleted.
            guard !Task.isCancelled else { return }
            do {
                let data = try JSONEncoder().encode(transcript)
                try data.write(to: url, options: .atomic)
            } catch {
                await MainActor.run {
                    report?("Couldn't save the conversation: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Delete the saved conversation.
    ///
    /// **In the write queue, after anything already in it.** This used to cancel
    /// the pending save and delete the file at once — but cancelling a task does
    /// not stop one that has already started writing, so a save still under way
    /// landed after the delete and brought back the conversation the person had
    /// just cleared. The delete now runs last, and a save it cancels before it
    /// starts writes nothing. Returns the delete, for a caller that needs to
    /// wait for it.
    @discardableResult
    func clear() -> Task<Void, Never> {
        writeTask?.cancel()
        let previous = writeTask
        let urls = [fileURL, legacyURL]
        let report = onPersistenceError
        let removal = Task.detached(priority: .utility) {
            await previous?.value
            for url in urls {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch CocoaError.fileNoSuchFile {
                    // Nothing saved yet.
                } catch {
                    await MainActor.run {
                        report?("Couldn't clear the saved conversation: \(error.localizedDescription)")
                    }
                }
            }
        }
        writeTask = removal
        return removal
    }

    nonisolated static func history(of transcript: some Sequence<Transcript.Entry>) -> [Transcript.Entry] {
        transcript.filter {
            if case .instructions = $0 { return false }
            return true
        }
    }

    private static func hash(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Reading a 1.3.2 conversation.
///
/// Each line was an `LLMMessage`: `{"role": "user", "parts": [{"text": {"_0": "…"}}], …}`
/// — Swift's synthesised coding for an enum with an associated value. Only the
/// text parts of user and assistant messages are read.
nonisolated enum LegacyChatTranscript {
    static func entries(fromJSONL text: String) -> [Transcript.Entry] {
        let entries = text.split(separator: "\n").compactMap { line -> Transcript.Entry? in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let role = object["role"] as? String,
                  let parts = object["parts"] as? [[String: Any]]
            else { return nil }
            let content = parts
                .compactMap { ($0["text"] as? [String: Any])?["_0"] as? String }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            let segments = [Transcript.Segment.text(Transcript.TextSegment(content: content))]
            switch role {
            case "user": return .prompt(Transcript.Prompt(metadata: [:], segments: segments))
            case "assistant": return .response(Transcript.Response(metadata: [:], segments: segments))
            default: return nil
            }
        }
        // A conversation starts with something the person said.
        return Array(entries.drop { if case .prompt = $0 { return false }; return true })
    }
}
