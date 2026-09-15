//
//  MLXModelStore.swift
//  HelloNotes
//
//  Created by Chris Tham on 15/9/2026.
//
//  The open models HelloNotes can run with MLX: which one is chosen, whether it
//  is on disk, and fetching or removing it.
//
//  Two ways in, because one of them does not work everywhere the app now ships:
//
//  * **Download** from the Hugging Face Hub, into the Hub's own cache under
//    Library/Caches — not backed up, and reclaimable by the system, which is
//    the right home for several gigabytes that can always be fetched again.
//  * **A model folder** the person already has. The Hub is unreachable from
//    mainland China, and a Mac on a plane or behind a proxy is in the same
//    position. Any MLX-format folder works (config.json, weights, tokenizer),
//    wherever it came from — ModelScope, a colleague, a USB stick — held by a
//    security-scoped bookmark like a collection is.
//
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

/// A downloadable model the app suggests.
///
/// Sizes, licences and tool-calling support were read from each repository's
/// Hub listing and chat template on 15 September 2026 — every one of these
/// templates accepts tools, which is what lets the Assistant edit notes on them.
nonisolated struct MLXCatalogModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let bytes: Int64
    /// Emits a reasoning trace before answering (Qwen3's thinking mode).
    let reasons: Bool
    let summary: String
}

nonisolated enum MLXCatalog {
    static let models: [MLXCatalogModel] = [
        MLXCatalogModel(id: "mlx-community/Qwen3-1.7B-4bit", name: "Qwen3 1.7B",
                        bytes: 980_000_000, reasons: true,
                        summary: "Small and quick. Fine for tags, summaries and short answers."),
        MLXCatalogModel(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", name: "Llama 3.2 3B",
                        bytes: 1_820_000_000, reasons: false,
                        summary: "Answers directly, without a thinking step."),
        MLXCatalogModel(id: "mlx-community/Qwen3-4B-4bit", name: "Qwen3 4B",
                        bytes: 2_280_000_000, reasons: true,
                        summary: "A good balance of quality and speed."),
        MLXCatalogModel(id: "mlx-community/Qwen3-8B-4bit", name: "Qwen3 8B",
                        bytes: 4_620_000_000, reasons: true,
                        summary: "The strongest here, and the slowest."),
    ]

    static func model(id: String) -> MLXCatalogModel? {
        models.first { $0.id == id }
    }

    /// Whether this device has the memory to run `model` comfortably.
    ///
    /// Weights are only part of it — the KV cache for a long note, the app, and
    /// everything else the person has open all share the same memory. iOS is
    /// stricter because the system ends a foreground app that grows too large,
    /// and it does so without asking.
    static func fits(_ model: MLXCatalogModel,
                     physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        #if os(macOS)
        let share = 0.40
        #else
        let share = 0.25
        #endif
        return Double(model.bytes) <= Double(physicalMemory) * share
    }

    /// How many tokens of context an MLX model is planned against.
    ///
    /// The models themselves accept far more (Qwen3 40,960; Llama 3.2 131,072),
    /// but the KV cache costs memory per token — about 144 KB a token for Qwen3
    /// 4B — so the window the app *uses* is set by the device, not the model.
    static var contextTokens: Int {
        #if os(macOS)
        16_384
        #else
        8_192
        #endif
    }
}

@MainActor
@Observable
final class MLXModelStore {

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
        case .hub(let id): MLXCatalog.model(id: id)?.name ?? Self.shortName(ofRepository: id)
        case .folder(let url): folderModel?.name ?? url.lastPathComponent
        case nil: "MLX"
        }
    }

    /// Whether the chosen model reasons, where the app knows. A custom model
    /// is assumed not to: declaring `.reasoning` on a model without a thinking
    /// template makes every request fail, while not declaring it on one that
    /// has one only hides the trace.
    var reasons: Bool {
        if case .hub(let id) = source { return MLXCatalog.model(id: id)?.reasons ?? false }
        return false
    }

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
        await refreshToolSupport()
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

    /// Read the chosen model's chat template, if it is on disk, to learn
    /// whether it can use tools.
    private func refreshToolSupport() async {
        let directory: URL?
        switch source {
        case .folder: directory = folderModel?.directory
        case .hub(let id): directory = downloaded.contains(id) ? Self.snapshotDirectory(forRepository: id) : nil
        case nil: directory = nil
        }
        guard let directory else {
            toolsSupported = true
            return
        }
        let chosen = source
        let renders = await offMain { MLXChatTemplate.rendersTools(in: directory) }
        guard source == chosen else { return }   // chosen again meanwhile
        toolsSupported = renders ?? true
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

    /// Recompute which catalog models and the chosen one are complete on disk.
    func refreshDownloaded() {
        var ids = Set(MLXCatalog.models.map(\.id))
        if case .hub(let id) = source { ids.insert(id) }
        downloaded = Set(ids.filter { id in
            FileManager.default.fileExists(
                atPath: Self.snapshotDirectory(forRepository: id).appending(path: "config.json").path)
        })
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
