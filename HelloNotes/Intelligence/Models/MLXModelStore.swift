//
//  MLXModelStore.swift
//  HelloNotes
//
//  Created by Chris Tham on 15/9/2026.
//
//  The open models HelloNotes can run with MLX: which one is chosen, whether it
//  is on disk, and fetching or removing it.
//
//  **The app suggests nothing.** It used to carry four models with their sizes
//  and a sentence each, read from the Hub on one day in September 2026 — and
//  within a day they were a generation behind what a person actually had on
//  their disk (Qwen 3.8, Gemma 4), while not one of them had ever been run.
//  A remembered model list is stale the week after it is written, and a
//  suggestion carries a promise the app cannot keep. Choosing a model is the
//  advanced end of the app: bring one you know you want.
//
//  Two ways in, because one of them does not work everywhere the app now ships:
//  A model is *loaded* lazily by `MLXLanguageModel` on its first request and
//  cached process-wide there; this store never holds weights itself.
//

import Foundation
import FoundationModels
import HuggingFace
import MLXFoundationModels
import MLXLLM
import MLXLMCommon
import Observation

@MainActor
@Observable
final class MLXModelStore {

    /// How many tokens of context an MLX model is planned against.
    ///
    /// Models accept far more than this (32,768 and up is ordinary), but the
    /// KV cache costs memory per token — and a model the person chose may
    /// already be most of what the device has. So the window the app *uses* is
    /// set by the device, not by the model.
    nonisolated static var contextTokens: Int {
        #if os(macOS)
        16_384
        #else
        8_192
        #endif
    }

    /// The share of this device's memory a model may reasonably occupy before
    /// the app says so. iOS is stricter: the system ends a foreground app that
    /// grows too large, without asking.
    private static var memoryShare: Double {
        #if os(macOS)
        0.40
        #else
        0.25
        #endif
    }

    /// Where the chosen model comes from.
    enum Source: Equatable {
        case hub(String)
        case folder(URL)
    }

    static let shared = MLXModelStore()

    private let defaults: UserDefaults

    nonisolated enum Keys {
        /// A Hub repository id, or `folder:` followed by the folder's name.
        static let model = "aiMLXModel"
        static let folderBookmark = "aiMLXFolderBookmark"
    }

    /// The chosen model, if any.
    private(set) var source: Source?

    /// Whether the chosen model is ready, refreshed after anything that can
    /// change it. `MLXLanguageModel.availability` is async, and a settings
    /// screen needs an answer it can draw synchronously.
    private(set) var availability: IntelligenceAvailability =
        .unavailable(MLXModelError.noModelChosen.localizedDescription)

    /// Repository ids with a complete snapshot on disk.
    private(set) var downloaded: Set<String> = []

    /// The download in progress, if any, so it can be cancelled.
    private var downloadTask: Task<Void, Never>?
    private(set) var downloadingID: String?
    private(set) var lastError: String?

    /// The folder whose security scope is open, so it can be closed when the
    /// person chooses something else.
    private var scopedFolder: URL?

    /// Where the chosen folder's model actually is — the folder itself, or the
    /// current snapshot inside a Hugging Face cache's model folder — found by
    /// `refreshAvailability()`, which reads the disk to decide.
    private(set) var folderModel: FolderModel?

    /// Whether the chosen model's chat template can show it tools — decided by
    /// `MLXChatTemplate` once the model is on disk. Until then, and for a model
    /// with no template to read, assumed: refusing tools on a guess would take
    /// the Assistant's work away from models that can do it.
    private(set) var toolsSupported = true

    /// Said once the model is on disk, when its weights are large for this
    /// device. Not a refusal: the person chose this model, and only they know
    /// what else they are running.
    private(set) var sizeCaution: String?

    struct FolderModel: Equatable {
        let directory: URL
        let name: String
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restore()
        refreshDownloaded()
    }

    // MARK: - Choosing

    /// The chosen model's display name.
    var modelName: String {
        switch source {
        case .hub(let id): Self.shortName(ofRepository: id)
        case .folder(let url): folderModel?.name ?? url.lastPathComponent
        case nil: "MLX"
        }
    }

    /// Whether the chosen model is asked to reason. **It never is.**
    ///
    /// Reasoning has to be declared before the weights are loaded, and nothing
    /// the app can read beforehand says truthfully whether a model reasons —
    /// declaring it on a model that does not makes every request fail, which is
    /// a worse trade than a model that answers without showing its thinking.
    /// The suggested-model list used to carry this as a remembered flag per
    /// model; it went with the list.
    var reasons: Bool { false }

    func choose(repository id: String) {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        closeFolderScope()
        folderModel = nil
        source = .hub(id)
        defaults.set(id, forKey: Keys.model)
        defaults.removeObject(forKey: Keys.folderBookmark)
        lastError = nil
        Task { await refreshAvailability() }
    }

    /// Use an MLX model folder the person picked.
    func choose(folder url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        guard let bookmark = Bookmark.data(for: url) else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            lastError = MLXModelError.folderUnreadable(url.lastPathComponent).localizedDescription
            return
        }
        closeFolderScope()
        if scoped { scopedFolder = url }
        defaults.set("folder:\(url.lastPathComponent)", forKey: Keys.model)
        defaults.set(bookmark, forKey: Keys.folderBookmark)
        use(folder: url)
    }

    /// Use a model folder this process can already read, without keeping a
    /// bookmark to it. `choose(folder:)` does this after minting the bookmark;
    /// the evaluation harness calls it directly, because the test host reads
    /// the folder without the security scope a bookmark carries.
    func use(folder url: URL) {
        folderModel = nil
        source = .folder(url)
        // Not available until the folder has been read: until then the model
        // would load from the chosen folder itself, which for a cache's model
        // folder is not where the model is.
        availability = .unavailable("Checking “\(url.lastPathComponent)”…")
        lastError = nil
        Task { await refreshAvailability() }
    }

    private func restore() {
        guard let stored = defaults.string(forKey: Keys.model), !stored.isEmpty else { return }
        if stored.hasPrefix("folder:") {
            guard let data = defaults.data(forKey: Keys.folderBookmark),
                  let resolved = Bookmark.resolveRefreshing(data) else {
                lastError = MLXModelError.folderUnreadable(String(stored.dropFirst("folder:".count))).localizedDescription
                return
            }
            if let refreshed = resolved.refreshed { defaults.set(refreshed, forKey: Keys.folderBookmark) }
            if resolved.url.startAccessingSecurityScopedResource() { scopedFolder = resolved.url }
            source = .folder(resolved.url)
        } else {
            source = .hub(stored)
        }
        Task { await refreshAvailability() }
    }

    private func closeFolderScope() {
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = nil
    }

    // MARK: - The model

    /// The chosen model as a Foundation Models `LanguageModel`.
    func languageModel() throws -> MLXLanguageModel {
        guard let source else { throw MLXModelError.noModelChosen }
        var capabilities: [LanguageModelCapabilities.Capability] = [.guidedGeneration]
        if toolsSupported { capabilities.append(.toolCalling) }
        if reasons { capabilities.append(.reasoning) }

        switch source {
        case .hub(let id):
            guard Repo.ID(rawValue: id) != nil else { throw MLXModelError.invalidRepository(id) }
            let onDisk = downloaded.contains(id)
            return MLXLanguageModel(
                configuration: ModelConfiguration(id: id),
                capabilities: capabilities,
                weightsLocation: { id in Self.snapshotDirectory(forRepository: id) },
                load: { configuration, progress in
                    try await loadModelContainer(
                        from: HubModelDownloader(localFilesOnly: onDisk),
                        using: TransformersTokenizerLoader(),
                        configuration: configuration,
                        progressHandler: progress)
                })

        case .folder(let url):
            let directory = folderModel?.directory ?? url
            return MLXLanguageModel(
                configuration: ModelConfiguration(directory: directory),
                capabilities: capabilities,
                weightsLocation: { _ in directory },
                load: { configuration, progress in
                    try await loadModelContainer(
                        from: HubModelDownloader(localFilesOnly: true),
                        using: TransformersTokenizerLoader(),
                        configuration: configuration,
                        progressHandler: progress)
                })
        }
    }

    // MARK: - Availability

    func refreshAvailability() async {
        #if targetEnvironment(simulator)
        // MLX needs a real Metal GPU; the simulator's cannot run its kernels.
        availability = .unavailable("MLX models run on a Mac, iPhone or iPad — not in the simulator.")
        return
        #else
        guard source != nil else {
            availability = .unavailable(MLXModelError.noModelChosen.localizedDescription)
            return
        }
        if case .folder(let folder) = source {
            let resolution = await offMain { MLXModelFolder.resolve(folder) }
            guard source == .folder(folder) else { return }   // chosen again meanwhile
            guard case .model(let directory, let name) = resolution else {
                let problem = MLXModelFolder.problem(with: resolution, folderName: folder.lastPathComponent)
                    ?? MLXModelError.folderUnreadable(folder.lastPathComponent).localizedDescription
                folderModel = nil
                lastError = problem
                availability = .unavailable(problem)
                return
            }
            folderModel = FolderModel(directory: directory, name: name)
            if let missing = await offMain({ MLXModelStore.firstFileNotOnDevice(in: directory) }) {
                availability = .unavailable("“\(missing)” in \(folder.lastPathComponent) hasn't downloaded to this device yet. Download the folder, then choose the model again.")
                return
            }
        }
        refreshDownloaded()
        await refreshFromModelFiles()
        do {
            let model = try languageModel()
            switch await model.availability {
            case .available:
                availability = .available
            case .downloading:
                availability = .unavailable("\(modelName) is downloading.")
            case .unavailable(.deviceNotCapable):
                availability = .unavailable("This device can't run MLX models.")
            case .unavailable(.modelNotDownloaded):
                availability = .unavailable(MLXModelError.notDownloaded(modelName).localizedDescription)
            case .unavailable(.downloadFailed):
                availability = .unavailable("\(modelName) didn't finish downloading. Try downloading it again in AI settings.")
            @unknown default:
                availability = .unavailable("\(modelName) is unavailable right now.")
            }
        } catch {
            availability = .unavailable(error.localizedDescription)
        }
        #endif
    }

    /// Read what the chosen model's own files say about it, once it is on
    /// disk: whether its chat template can show it tools, and whether its
    /// weights are more than this device should hold.
    private func refreshFromModelFiles() async {
        let directory: URL?
        switch source {
        case .folder: directory = folderModel?.directory
        case .hub(let id): directory = downloaded.contains(id) ? Self.snapshotDirectory(forRepository: id) : nil
        case nil: directory = nil
        }
        guard let directory else {
            toolsSupported = true
            sizeCaution = nil
            return
        }
        let chosen = source
        let share = Self.memoryShare
        let memory = ProcessInfo.processInfo.physicalMemory
        let read = await offMain { () -> (tools: Bool?, caution: String?) in
            let tools = MLXChatTemplate.rendersTools(in: directory)
            let bytes = MLXModelFolder.weightsBytes(in: directory)
            guard bytes > 0, Double(bytes) > Double(memory) * share else { return (tools, nil) }
            let size = bytes.formatted(.byteCount(style: .file))
            let total = Int64(memory).formatted(.byteCount(style: .file))
            return (tools, "This model's weights are \(size), on a device with \(total) of memory. It may fail to load, or be stopped while it runs.")
        }
        guard source == chosen else { return }   // chosen again meanwhile
        toolsSupported = read.tools ?? true
        sizeCaution = read.caution
    }

    /// The first file in a chosen model folder whose bytes are still in the cloud.
    ///
    /// A folder picked in iCloud Drive or another cloud folder can hold weights
    /// the system keeps online-only. The model loader reads them with plain file
    /// reads, which a dataless file can fail outright, so this says so before
    /// the first request instead of failing inside it. Metadata only — nothing
    /// is downloaded.
    nonisolated static func firstFileNotOnDevice(in folder: URL) -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey],
            options: [.skipsHiddenFiles])) ?? []
        return files.first { !FileIO.isMaterialized(at: $0) }?.lastPathComponent
    }

    // MARK: - Downloading

    var isDownloading: Bool { downloadingID != nil }

    /// Fetch the chosen Hub model. Progress is published by the adapter on
    /// `MLXDownloadProgress.shared`, which the settings screen observes.
    func downloadChosenModel() {
        guard case .hub(let id) = source, downloadTask == nil else { return }
        lastError = nil
        downloadingID = id
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                // A fresh value, so the loader is not told the files exist.
                let model = MLXLanguageModel(
                    configuration: ModelConfiguration(id: id),
                    weightsLocation: { id in Self.snapshotDirectory(forRepository: id) },
                    load: { configuration, progress in
                        try await loadModelContainer(
                            from: HubModelDownloader(),
                            using: TransformersTokenizerLoader(),
                            configuration: configuration,
                            progressHandler: progress)
                    })
                try await model.preload()
            } catch is CancellationError {
                // Stopped by the person; nothing to report.
            } catch {
                self.lastError = Self.describeDownloadError(error, modelName: self.modelName)
            }
            self.downloadTask = nil
            self.downloadingID = nil
            await self.refreshAvailability()
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Delete a downloaded model's files and release its memory.
    func removeDownload(repository id: String) async {
        guard let repo = Repo.ID(rawValue: id) else { return }
        if case .hub(let chosen) = source, chosen == id {
            if let model = try? languageModel() { await model.evict() }
        }
        let directory = HubCache.default.repoDirectory(repo: repo, kind: .model)
        do {
            // Library/Caches, not the vault: `FileIO`'s coordination rule is
            // about note content and does not apply to a model cache.
            try await offMain { try FileManager.default.removeItem(at: directory) }
        } catch CocoaError.fileNoSuchFile {
            // Already gone.
        } catch {
            lastError = "Couldn't remove \(Self.shortName(ofRepository: id)): \(error.localizedDescription)"
        }
        await refreshAvailability()
    }

    // MARK: - Helpers

    /// Whether the chosen Hub model is complete on disk.
    func refreshDownloaded() {
        guard case .hub(let id) = source else {
            downloaded = []
            return
        }
        let complete = FileManager.default.fileExists(
            atPath: Self.snapshotDirectory(forRepository: id).appending(path: "config.json").path)
        downloaded = complete ? [id] : []
    }

    /// The directory a Hub model's files live in once downloaded — the same
    /// resolution the adapter uses to decide whether a model is on disk.
    nonisolated static func snapshotDirectory(forRepository id: String) -> URL {
        let cache = HubCache.default
        guard let repo = Repo.ID(rawValue: id) else { return cache.cacheDirectory }
        if let commit = cache.resolveRevision(repo: repo, kind: .model, ref: "main"),
           let snapshot = try? cache.snapshotPath(repo: repo, kind: .model, commitHash: commit) {
            return snapshot
        }
        return cache.repoDirectory(repo: repo, kind: .model)
    }

    nonisolated static func shortName(ofRepository id: String) -> String {
        String(id.split(separator: "/").last ?? Substring(id))
    }

    /// A download failure in words that say what to do. A person in a region
    /// where the Hub is blocked sees a timeout, and a timeout alone does not
    /// tell them a model folder is the way round it.
    private static func describeDownloadError(_ error: Error, modelName: String) -> String {
        if let urlError = error as? URLError,
           [.notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost,
            .networkConnectionLost, .dnsLookupFailed].contains(urlError.code) {
            return "Couldn't reach Hugging Face to download \(modelName). If it is blocked where you are, download the model another way and choose its folder instead."
        }
        return "Couldn't download \(modelName): \(error.localizedDescription)"
    }
}
