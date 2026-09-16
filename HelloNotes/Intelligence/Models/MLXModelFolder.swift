//
//  MLXModelFolder.swift
//  HelloNotes
//
//  Created by Chris Tham on 16/9/2026.
//
//  What to load from a model folder the person chose.
//
//  Three layouts arrive at "Choose a Model Folder…":
//
//  * **An MLX model folder** — `config.json`, weights and tokenizer side by side,
//    however it was made.
//  * **A model's folder in a Hugging Face cache**, `models--org--name`. On a Mac
//    that is where `mlx_lm`, `huggingface-cli` and every Hub client keep models
//    (`~/.cache/huggingface/hub`), so it is where a person who already runs MLX
//    models has them. The files are stored once in `blobs/`; each revision is a
//    folder of links in `snapshots/<revision>/`, and `refs/main` names the
//    current one.
//  * **One snapshot inside such a cache** — the folder that visibly holds
//    `config.json`, so the natural one to pick. It cannot work in the app: every
//    file in it is a link into `../../blobs/`, and the sandbox grants the chosen
//    folder, not what its links point to. Measured with `sandbox-exec` against a
//    copy of that layout: a read grant on the snapshot refuses the linked
//    `config.json` ("Operation not permitted"), a grant on the model's folder
//    reads it. The Debug build cannot show this — Xcode gives Debug builds read
//    access to the whole disk — so it is decided here, by layout, and the person
//    is asked for the model's folder instead of meeting a permissions error from
//    inside the model loader.
//
//  A model folder is not vault content: nothing here is a note, and the model
//  loader reads these files with plain reads, so plain reads are used here too.
//

import Foundation

nonisolated enum MLXModelFolder {

    enum Resolution: Equatable {
        /// Load the model from `directory`, shown as `name`.
        case model(directory: URL, name: String)
        /// A snapshot inside a Hugging Face cache: the enclosing model folder,
        /// named here, is the one to choose.
        case chooseModelFolder(String)
        /// A whole Hugging Face cache: one model's folder inside it is the one
        /// to choose.
        case chooseOneModel
        /// Nothing here looks like a model.
        case notAModel
    }

    static func resolve(_ folder: URL) -> Resolution {
        let manager = FileManager.default
        let components = folder.standardizedFileURL.pathComponents

        // …/models--org--name/snapshots/<revision>
        if components.count >= 3, components[components.count - 2] == "snapshots",
           components[components.count - 3].hasPrefix("models--") {
            return .chooseModelFolder(components[components.count - 3])
        }

        // …/models--org--name
        let snapshots = folder.appending(path: "snapshots", directoryHint: .isDirectory)
        if folder.lastPathComponent.hasPrefix("models--") || manager.fileExists(atPath: snapshots.path) {
            var candidates: [URL] = []
            if let main = try? String(contentsOf: folder.appending(path: "refs/main"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !main.isEmpty, !main.contains("/") {
                candidates.append(snapshots.appending(path: main, directoryHint: .isDirectory))
            }
            // No `refs/main` — a cache written by a tool that pins revisions —
            // then the newest snapshot that is a whole model.
            let others = (try? manager.contentsOfDirectory(
                at: snapshots, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
            candidates += others.sorted { modified($0) > modified($1) }
            if let snapshot = candidates.first(where: { hasModel($0) }) {
                return .model(directory: snapshot, name: displayName(ofRepositoryFolder: folder.lastPathComponent))
            }
            return .notAModel
        }

        if hasModel(folder) {
            return .model(directory: folder, name: folder.lastPathComponent)
        }

        // …/huggingface/hub, holding many models--… folders.
        let children = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
        if children.contains(where: { $0.hasPrefix("models--") }) {
            return .chooseOneModel
        }
        return .notAModel
    }

    /// `models--mlx-community--gemma-3-27b-it-bf16` → `gemma-3-27b-it-bf16`.
    static func displayName(ofRepositoryFolder name: String) -> String {
        let parts = name.components(separatedBy: "--")
        guard parts.count >= 3, parts[0] == "models" else { return name }
        return parts.dropFirst(2).joined(separator: "--")
    }

    /// Why a chosen folder can't be used, in words for the settings screen.
    static func problem(with resolution: Resolution, folderName: String) -> String? {
        switch resolution {
        case .model:
            return nil
        case .chooseModelFolder(let repository):
            return "“\(folderName)” is one version inside a Hugging Face cache, and its files are links HelloNotes isn't allowed to follow from there. Choose the folder that holds it, “\(repository)”, instead."
        case .chooseOneModel:
            return "“\(folderName)” is a whole Hugging Face cache. Choose one model's folder inside it — one named like “models--mlx-community--…”."
        case .notAModel:
            return "“\(folderName)” doesn't hold an MLX model. A model folder contains config.json with the model's weights and tokenizer."
        }
    }

    /// What a model's weights weigh, for the caution about a model too large
    /// for the device. Safetensors only: the tokenizer and configuration are
    /// noise beside them, and a cache folder holds nothing else of size.
    static func weightsBytes(in directory: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.pathExtension == "safetensors" }
            .reduce(into: Int64(0)) { total, file in
                total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
    }

    private static func hasModel(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: "config.json").path)
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

