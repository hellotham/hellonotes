//
//  MLXModelFolder.swift
//  HelloNotes
//
//  Created by Chris Tham on 16/9/2026.
//
//  Reading the models folder: which MLX models are in it, and what each one is.
//
//  The folder is normally a Hugging Face cache — `~/.cache/huggingface/hub` on a
//  Mac, where `mlx_lm` and every Hub client keep models. Each model there is a
//  `models--organisation--model` folder holding its files once in `blobs/`, each
//  revision as a folder of links in `snapshots/<revision>/`, and `refs/main`
//  naming the current one. A plain model folder dropped in beside them —
//  `config.json`, weights and tokenizer — counts too.
//
//  The grant is on the whole folder, not on one model's snapshot, because the
//  sandbox does not follow a link out of the folder it was given (measured with
//  `sandbox-exec`: "Operation not permitted" on a snapshot, readable from the
//  folder above).
//
//  A models folder is not vault content, and the model loader reads these files
//  with plain reads, so plain reads are used here too.
//

import Foundation

/// An MLX model in the models folder — the only kind the app offers. Everything
/// here is read from the model's own files.
nonisolated struct MLXLocalModel: Identifiable, Hashable, Sendable {
    /// Where the loader reads the model: a snapshot, or a plain model folder.
    let directory: URL
    let name: String
    let bytes: Int64
    let modelType: String?
    let rendersTools: Bool?
    /// The model's own folder in the models folder — what removing it deletes.
    let folder: URL
    /// `organisation/model` for a model in cache layout: how a download finds
    /// the copy already there, and how a 1.3.2 MLX choice is recognised.
    let repository: String?

    var id: String { directory.standardizedFileURL.path }
}

nonisolated enum MLXModelFolder {

    /// Every whole model in `folder`, by name.
    static func models(in folder: URL) -> [MLXLocalModel] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return children
            .compactMap { child -> MLXLocalModel? in
                let name = child.lastPathComponent
                guard name.hasPrefix("models--") else {
                    return model(at: child, name: name, folder: child, repository: nil)
                }
                guard let snapshot = currentSnapshot(of: child) else { return nil }
                return model(at: snapshot, name: displayName(ofRepositoryFolder: name),
                             folder: child, repository: repositoryID(ofRepositoryFolder: name))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The revision `refs/main` names, or — without one — the newest snapshot
    /// that is a whole model.
    static func currentSnapshot(of repositoryFolder: URL) -> URL? {
        let snapshots = repositoryFolder.appending(path: "snapshots", directoryHint: .isDirectory)
        var candidates: [URL] = []
        if let main = try? String(contentsOf: repositoryFolder.appending(path: "refs/main"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !main.isEmpty, !main.contains("/") {
            candidates.append(snapshots.appending(path: main, directoryHint: .isDirectory))
        }
        let others = (try? FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        candidates += others.sorted { modified($0) > modified($1) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appending(path: "config.json").path) }
    }

    /// The model in `directory`, if it is a whole one: a configuration and
    /// weights. A download that never finished has neither.
    static func model(at directory: URL, name: String, folder: URL, repository: String?) -> MLXLocalModel? {
        let bytes = weightsBytes(in: directory)
        guard bytes > 0,
              FileManager.default.fileExists(atPath: directory.appending(path: "config.json").path)
        else { return nil }
        return MLXLocalModel(directory: directory, name: name, bytes: bytes,
                             modelType: modelType(in: directory),
                             rendersTools: MLXChatTemplate.rendersTools(in: directory),
                             folder: folder, repository: repository)
    }

    /// What a model's weights weigh. Safetensors only: the tokenizer and
    /// configuration are noise beside them.
    ///
    /// Sizes follow a cache's links. Every file in a snapshot is a symlink into
    /// `blobs/`, and a link's own size is a few dozen bytes — so a 17 GB model
    /// read without resolving them was listed at 81 bytes, and still counted as
    /// "has weights". The blob is inside the models folder, so resolving stays
    /// inside the grant.
    static func weightsBytes(in directory: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.pathExtension == "safetensors" }
            .reduce(into: Int64(0)) { total, file in
                let target = file.resolvingSymlinksInPath()
                total += Int64((try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
    }

    /// `model_type` from the model's configuration — what the loader looks an
    /// architecture up by.
    static func modelType(in directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appending(path: "config.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["model_type"] as? String
    }

    /// `models--mlx-community--Qwen3-4B-4bit` → `mlx-community/Qwen3-4B-4bit`.
    static func repositoryID(ofRepositoryFolder name: String) -> String {
        let parts = name.components(separatedBy: "--")
        guard parts.count >= 3, parts[0] == "models" else { return name }
        return parts[1] + "/" + parts.dropFirst(2).joined(separator: "--")
    }

    /// `models--mlx-community--gemma-3-27b-it-bf16` → `gemma-3-27b-it-bf16`.
    static func displayName(ofRepositoryFolder name: String) -> String {
        let parts = name.components(separatedBy: "--")
        guard parts.count >= 3, parts[0] == "models" else { return name }
        return parts.dropFirst(2).joined(separator: "--")
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}

/// Whether a model's chat template can show it tools.
///
/// The template is how a model learns which tools exist and how to call them:
/// the adapter hands it the definitions, and a template that never refers to
/// `tools` drops them without a word. Gemma 3's is one. Measured with Gemma 3
/// 27B and the Assistant's eleven tools: the model saw only the tool *names*
/// the instructions mention, wrote `read_note("Welcome")` in a code block of
/// its own invention, and that text reached the screen as the answer — nothing
/// ran. Its template also accepts no turn but user and assistant, so a tool's
/// result would have broken the conversation anyway. Such a model gets no
/// tools, and the app says so, rather than pretend.
nonisolated enum MLXChatTemplate {

    /// `true` or `false` when there is a template to read; `nil` when the
    /// folder has none, which is not evidence either way.
    static func rendersTools(in directory: URL) -> Bool? {
        let found = templates(in: directory)
        guard !found.isEmpty else { return nil }
        return found.contains { $0.contains("tools") }
    }

    /// Every chat template the folder declares, where swift-transformers looks
    /// for one: `chat_template.jinja`, `chat_template.json`, and
    /// `tokenizer_config.json`'s `chat_template` — a string, or a list of named
    /// templates (a "default" and a "tool_use", say).
    static func templates(in directory: URL) -> [String] {
        var found: [String] = []
        if let jinja = try? String(contentsOf: directory.appending(path: "chat_template.jinja"), encoding: .utf8) {
            found.append(jinja)
        }
        for file in ["chat_template.json", "tokenizer_config.json"] {
            guard let data = try? Data(contentsOf: directory.appending(path: file)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            switch object["chat_template"] {
            case let template as String:
                found.append(template)
            case let named as [[String: Any]]:
                found += named.compactMap { $0["template"] as? String }
            default:
                break
            }
        }
        return found
    }
}

