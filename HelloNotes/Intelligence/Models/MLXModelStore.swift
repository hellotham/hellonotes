//
//  MLXModelStore.swift
//  HelloNotes
//
//  Created by Chris Tham on 15/9/2026.
//
//  The open models HelloNotes can run with MLX.
//
//  **There is one place for models: the models folder.** The picker lists the
//  models in it that the loader can run, downloads go into it, and Remove
//  deletes from it. On a Mac the person chooses it once — their Hugging Face
//  cache, `~/.cache/huggingface/hub`, so HelloNotes and `mlx_lm` share one copy
//  of each model; the sandbox lets the app read nothing it has not been given.
//  On iPhone and iPad, which have no shared cache, it is HelloNotes' own storage
//  unless the person chooses a folder in Files.
//
//  Nothing about a model is remembered: what it is, how big it is and whether
//  it can use tools are read from its files (`MLXModelFolder`), and whether it
//  can run is asked of the loader. One MLX model runs at a time, so the
//  Assistant and the writing tools share it.
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

    /// The models folder when the person has not chosen one.
    ///
    /// On a Mac that is the **Hugging Face cache**, `~/.cache/huggingface/hub`,
    /// where `mlx_lm` and every other MLX tool keeps its models — so a model
    /// already on the machine is simply there, and one downloaded here is the
    /// same copy those tools use. The app is sandboxed, so this is reachable
    /// only because the app asks for it by name
    /// (`com.apple.security.temporary-exception.files.home-relative-path.read-write`);
    /// a Debug build reads the whole disk and proves nothing about it.
    ///
    /// On iPhone and iPad there is no shared cache, so it is HelloNotes' own
    /// storage. Either way the folder is *already set*: nothing to choose
    /// before a model can be downloaded, and Change… for somewhere else.
    private static var ownStorage: URL? {
        #if os(macOS)
        // The person's real home. Inside the sandbox `NSHomeDirectory()` is the
        // container, which is not where any other tool puts models.
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home))
            .appending(path: ".cache/huggingface/hub", directoryHint: .isDirectory)
        #else
        return HubCache.default.cacheDirectory
        #endif
    }

    static let shared = MLXModelStore()

    nonisolated enum Keys {
        /// The model in use, by its directory (or, straight after a 1.3.2
        /// upgrade, by its Hugging Face repository name).
        static let model = "aiMLXModel"
        /// The models folder, as a security-scoped bookmark.
        static let folder = "aiMLXFolderBookmark"
    }

    /// The folder the person chose, if they have.
    private(set) var chosenFolder: URL?
    /// The models in the models folder that the loader can run, by name.
    private(set) var models: [MLXLocalModel] = []
    private(set) var chosenID: String?

    /// Whether the model in use is ready, refreshed after anything that can
    /// change it. `MLXLanguageModel.availability` is async, and a settings
    /// screen needs an answer it can draw synchronously.
    private(set) var availability: IntelligenceAvailability =
        .unavailable(MLXModelError.noModelChosen.localizedDescription)

    private(set) var downloadingID: String?
    private(set) var lastError: String?
    private var downloadTask: Task<Void, Never>?
    private var folderScopeOpen = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        chosenID = defaults.string(forKey: Keys.model)
        if let data = defaults.data(forKey: Keys.folder), let resolved = Bookmark.resolveRefreshing(data) {
            if let refreshed = resolved.refreshed { defaults.set(refreshed, forKey: Keys.folder) }
            folderScopeOpen = resolved.url.startAccessingSecurityScopedResource()
            chosenFolder = resolved.url
        }
        Task { await refresh() }
    }

    /// Where models are listed from, downloaded into and removed from.
    var modelsFolder: URL? { chosenFolder ?? Self.ownStorage }

    /// What to call the models folder in settings: the Hugging Face cache by
    /// name where that is what it is, the folder's own name where someone has
    /// chosen one, and HelloNotes' own storage on iPhone and iPad.
    var folderName: String {
        if let chosenFolder { return chosenFolder.lastPathComponent }
        #if os(macOS)
        return "Hugging Face cache"
        #else
        return "HelloNotes"
        #endif
    }

    /// The model in use, if it is in the models folder.
    var chosen: MLXLocalModel? { models.first { $0.id == chosenID } }

    var modelName: String { chosen?.name ?? "MLX" }

    /// Whether the model in use is asked to reason. **It never is.**
    ///
    /// Reasoning has to be declared before the weights are loaded, and nothing
    /// the app can read beforehand says truthfully whether a model reasons —
    /// declaring it on a model that does not makes every request fail, which is
    /// a worse trade than a model that answers without showing its thinking.
    var reasons: Bool { false }

    /// Whether the model in use can be shown tools. A model without a template
    /// to read is given the benefit of the doubt.
    var toolsSupported: Bool { chosen?.rendersTools ?? true }

    /// Said when the model in use weighs more than a share of this device's
    /// memory. Not a refusal: the person chose it, and only they know what else
    /// they are running.
    var sizeCaution: String? {
        guard let chosen else { return nil }
        let memory = ProcessInfo.processInfo.physicalMemory
        guard Double(chosen.bytes) > Double(memory) * Self.memoryShare else { return nil }
        let size = chosen.bytes.formatted(.byteCount(style: .file))
        let total = Int64(memory).formatted(.byteCount(style: .file))
        return "\(chosen.name)'s weights are \(size), on a device with \(total) of memory. It may fail to load, or be stopped while it runs."
    }

    var isDownloading: Bool { downloadingID != nil }

    // MARK: - Choosing

    /// Use `model` — for both roles that use MLX, since one runs at a time.
    func use(_ model: MLXLocalModel) {
        chosenID = model.id
        defaults.set(model.id, forKey: Keys.model)
        lastError = nil
        Task { await refreshAvailability() }
    }

    /// Make `url` the models folder, keeping access to it across launches.
    func chooseFolder(_ url: URL) {
        let opened = url.startAccessingSecurityScopedResource()
        guard let bookmark = Bookmark.data(for: url) else {
            if opened { url.stopAccessingSecurityScopedResource() }
            lastError = MLXModelError.folderUnreadable(url.lastPathComponent).localizedDescription
            return
        }
        if folderScopeOpen { chosenFolder?.stopAccessingSecurityScopedResource() }
        chosenFolder = url
        folderScopeOpen = opened
        defaults.set(bookmark, forKey: Keys.folder)
        lastError = nil
        Task { await refresh() }
    }

    /// Point at a folder this process can already read, without a bookmark, and
    /// use the model in `url`. The evaluation harness's way in: the test host
    /// reads the folder without the security scope a bookmark carries.
    func use(folder url: URL) async {
        chosenFolder = url.lastPathComponent.hasPrefix("models--") ? url.deletingLastPathComponent() : url
        await refresh()
        let wanted = url.standardizedFileURL
        if let model = models.first(where: { $0.folder.standardizedFileURL == wanted }) ?? models.first {
            use(model)
            await refreshAvailability()
        }
    }

    /// Read the models folder, and keep the models the loader can run.
    func refresh() async {
        guard let folder = modelsFolder else {
            models = []
            await refreshAvailability()
            return
        }
        let found = await offMain { MLXModelFolder.models(in: folder) }
        var runnable: [String: Bool] = [:]
        for type in Set(found.compactMap(\.modelType)) {
            runnable[type] = await LLMTypeRegistry.shared.contains(type)
        }
        models = found.filter { model in model.modelType.flatMap { runnable[$0] } ?? false }
        // Straight after a 1.3.2 upgrade the choice is a repository name.
        if chosen == nil, let stored = chosenID, let match = models.first(where: { $0.repository == stored }) {
            use(match)
        }
        await refreshAvailability()
    }

    // MARK: - The model

    /// The model in use as a Foundation Models `LanguageModel`.
    func languageModel() throws -> MLXLanguageModel {
        guard let chosen else {
            throw chosenID == nil ? MLXModelError.noModelChosen : MLXModelError.notOnDevice(modelName)
        }
        var capabilities: [LanguageModelCapabilities.Capability] = [.guidedGeneration]
        if chosen.rendersTools != false { capabilities.append(.toolCalling) }
        if reasons { capabilities.append(.reasoning) }
        let directory = chosen.directory
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

    func refreshAvailability() async {
        #if targetEnvironment(simulator)
        // MLX needs a real Metal GPU; the simulator's cannot run its kernels.
        availability = .unavailable("MLX models run on a Mac, iPhone or iPad — not in the simulator.")
        return
        #else
        guard let chosen else {
            availability = .unavailable(chosenID == nil
                ? MLXModelError.noModelChosen.localizedDescription
                : MLXModelError.notOnDevice(modelName).localizedDescription)
            return
        }
        let directory = chosen.directory
        if let missing = await offMain({ MLXModelStore.firstFileNotOnDevice(in: directory) }) {
            availability = .unavailable("“\(missing)” in \(chosen.name) hasn't downloaded to this device yet.")
            return
        }
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
                availability = .unavailable(MLXModelError.notOnDevice(modelName).localizedDescription)
            case .unavailable(.downloadFailed):
                availability = .unavailable("\(modelName) didn't finish downloading.")
            @unknown default:
                availability = .unavailable("\(modelName) is unavailable right now.")
            }
        } catch {
            availability = .unavailable(error.localizedDescription)
        }
        #endif
    }

    /// The first file in a model's folder whose bytes are still in the cloud —
    /// a models folder in iCloud Drive can hold weights the system keeps
    /// online-only, which the loader's plain reads can fail on. Metadata only.
    nonisolated static func firstFileNotOnDevice(in folder: URL) -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey],
            options: [.skipsHiddenFiles])) ?? []
        return files.first { !FileIO.isMaterialized(at: $0) }?.lastPathComponent
    }

    // MARK: - Downloading and removing

    /// Download a Hugging Face model into the models folder and use it — or use
    /// the copy already there. Progress is published by the adapter on
    /// `MLXDownloadProgress.shared`, which the settings screen observes.
    func download(repository name: String) {
        let id = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Repo.ID(rawValue: id) != nil else {
            lastError = MLXModelError.invalidRepository(id).localizedDescription
            return
        }
        if let existing = models.first(where: { $0.repository == id }) {
            use(existing)
            return
        }
        guard let folder = modelsFolder else {
            lastError = "Choose a models folder first."
            return
        }
        guard downloadTask == nil else { return }
        lastError = nil
        downloadingID = id
        let cache = HubCache(cacheDirectory: folder)
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let model = MLXLanguageModel(
                    configuration: ModelConfiguration(id: id),
                    weightsLocation: { id in Self.snapshotDirectory(forRepository: id, in: cache) },
                    load: { configuration, progress in
                        try await loadModelContainer(
                            from: HubModelDownloader(client: HubClient(cache: cache)),
                            using: TransformersTokenizerLoader(),
                            configuration: configuration,
                            progressHandler: progress)
                    })
                try await model.preload()
                await model.evict()
            } catch is CancellationError {
                // Stopped by the person; nothing to report.
            } catch {
                self.lastError = Self.describeDownloadError(error, modelName: Self.shortName(ofRepository: id))
            }
            self.downloadTask = nil
            self.downloadingID = nil
            await self.refresh()
            if let arrived = self.models.first(where: { $0.repository == id }) { self.use(arrived) }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Delete a model from the models folder, and release its memory.
    func remove(_ model: MLXLocalModel) async {
        if chosen?.id == model.id, let loaded = try? languageModel() { await loaded.evict() }
        let folder = model.folder
        do {
            // A models folder, not the vault: `FileIO`'s coordination rule is
            // about note content and does not apply here.
            try await offMain { try FileManager.default.removeItem(at: folder) }
        } catch {
            lastError = "Couldn't remove \(model.name): \(error.localizedDescription)"
        }
        if chosenID == model.id {
            chosenID = nil
            defaults.removeObject(forKey: Keys.model)
        }
        await refresh()
    }

    // MARK: - Helpers

    /// Where a repository's files are once downloaded into `cache`.
    nonisolated static func snapshotDirectory(forRepository id: String, in cache: HubCache) -> URL {
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
    /// tell them they can put a model in the models folder themselves.
    private static func describeDownloadError(_ error: Error, modelName: String) -> String {
        if let urlError = error as? URLError,
           [.notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost,
            .networkConnectionLost, .dnsLookupFailed].contains(urlError.code) {
            return "Couldn't reach Hugging Face to download \(modelName). If it is blocked where you are, get the model another way and put its folder in the models folder."
        }
        return "Couldn't download \(modelName): \(error.localizedDescription)"
    }
}
