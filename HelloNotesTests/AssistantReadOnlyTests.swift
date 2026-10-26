//
//  AssistantReadOnlyTests.swift
//  HelloNotesTests
//
//  The Assistant in 1.3.5, as the person settled it on 18 October 2026: it
//  reads and answers and changes no note; it can reach a fact anywhere in a
//  long note; a conversation that outgrows the window keeps its thread in a
//  summary; each reply says where it was made; the models are named by where
//  they run; and its menu chooses for the conversation, never the default
//  (docs/implemented.md §51.55).
//

import Foundation
import FoundationModels
import Testing
@testable import HelloNotes

@MainActor
struct AssistantReadOnlyTests {

    private func makeContext() throws -> (ToolContext, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssistantReadOnly-\(UUID().uuidString)", isDirectory: true)
        let sample = RepoFile.url("SampleVault")
        try FileManager.default.copyItem(at: sample, to: base)
        let collection = Collection(rootURL: base)
        collection.scan()
        let git = GitService(); git.rootURL = base
        let permissions = PermissionBroker()
        // Setting up a note goes through the context's own create; nothing the
        // Assistant is offered can.
        permissions.respond(approved: true, allowAll: true)
        return (ToolContext(collection: collection, search: collection.search, git: git,
                            permissions: permissions), base)
    }

    private func prompt(_ text: String) -> Transcript.Entry {
        .prompt(Transcript.Prompt(metadata: [:], segments: [.text(.init(content: text))]))
    }
    private func response(_ text: String) -> Transcript.Entry {
        .response(Transcript.Response(metadata: [:], segments: [.text(.init(content: text))]))
    }

    // MARK: Reads, and changes nothing

    /// **No tool the Assistant is offered changes a note**, on the on-device
    /// window or Cloud's; exact-text search is on both; and its instructions
    /// say it cannot make changes rather than invite it to try.
    @Test func theAssistantIsOfferedNothingThatChangesANote() throws {
        let (ctx, vault) = try makeContext()
        defer { try? FileManager.default.removeItem(at: vault) }
        for window in [8_192, 32_768] {
            let names = Set(NoteTools.tools(for: ctx, contextTokens: window).map(\.name))
            for changing in ["create_note", "edit_note", "write_note", "delete_note"] {
                #expect(!names.contains(changing), "at \(window) tokens the Assistant is offered \(changing)")
            }
            #expect(names.contains("grep_collection"), "at \(window) tokens there is no exact-text search")
            let instructions = AssistantInstructions.text(toolNames: names, collectionName: nil, noteCount: 0)
            #expect(instructions.contains("can't create, change or delete notes"))
            #expect(!instructions.contains("edit_note"))
            #expect(instructions.contains("cite the notes you used"))
        }
    }

    // MARK: A long note, to its end

    private static let longNote = "# Long\n\n## Start\n" + String(repeating: "filler ", count: 900)
        + "\n\n## Middle\n" + String(repeating: "more ", count: 900)
        + "\n\n```\n# a comment in code, not a heading\n```\n\n## End\nThe launch code is 4242.\n"

    /// **The end of a long note can be read.** A cut says which sections lie
    /// past it, and a section can be read from; a section that isn't there is
    /// answered with the ones that are.
    @Test func aLongNoteIsReadableToItsEnd() async throws {
        let (ctx, vault) = try makeContext()
        defer { try? FileManager.default.removeItem(at: vault) }
        _ = try await ctx.createNote(title: "Long", content: Self.longNote, folder: nil)

        let top = try await ctx.readNote("Long", tokens: 1_000)
        #expect(top.contains("filler filler"), "the read stopped before the first long paragraph: \(top.prefix(200))")
        #expect(top.contains("truncated"))
        #expect(top.contains("Later sections: Middle; End"), "the cut does not name what lies past it: \(top.suffix(200))")
        #expect(!top.contains("4242"))

        let end = try await ctx.readNote("Long", tokens: 1_000, section: "End")
        #expect(end.contains("The launch code is 4242."))
        #expect(end.contains("from “End”"))

        // As the tool answers it: a failure the model can act on, in words.
        let missing = try await ToolOutcome.run {
            try await ctx.readNote("Long", tokens: 1_000, section: "Appendix")
        }
        #expect(missing.contains("no section “Appendix”") && missing.contains("Start; Middle; End"))
    }

    /// Exact-text search says the section a line is in — what `read_note` can
    /// be asked to read from.
    @Test func exactTextSearchSaysWhichSection() async throws {
        let (ctx, vault) = try makeContext()
        defer { try? FileManager.default.removeItem(at: vault) }
        _ = try await ctx.createNote(title: "Long", content: Self.longNote, folder: nil)
        let found = await ctx.grep("launch code", tokens: 100_000)
        #expect(found.contains("Long › End:"), "no section in \(found)")
    }

    /// A `#` inside fenced code is not a heading.
    @Test func headingsInCodeAreNotSections() {
        #expect(NoteSections.titles(in: Self.longNote) == ["Long", "Start", "Middle", "End"])
        #expect(NoteSections.title(ofHeadingLine: "#hashtag") == nil)
        #expect(NoteSections.title(ofHeadingLine: "### Notes ###") == "Notes")
    }

    /// **A note saved on Windows has lines.** "\r\n" is one Character, never
    /// "\n", so exact-text search returned the whole note as its first line —
    /// past the turn's room — and no section in it could be found. And
    /// "## C#" is about C#, not C.
    @Test func windowsLineEndingsAndClosingHashes() async throws {
        let crlf = "# Long\r\n\r\n## Start\r\nalpha\r\n\r\n## End\r\nThe launch code is 4242.\r\n"
        #expect(NoteSections.titles(in: crlf) == ["Long", "Start", "End"])
        #expect(NoteSections.start(of: "End", in: crlf).map { crlf[$0...].hasPrefix("## End") } == true)
        #expect(NoteSections.title(ofHeadingLine: "## C#") == "C#")
        #expect(NoteSections.title(ofHeadingLine: "## Notes #") == "Notes")

        let (ctx, vault) = try makeContext()
        defer { try? FileManager.default.removeItem(at: vault) }
        _ = try await ctx.createNote(title: "Windows", content: crlf, folder: nil)
        let found = await ctx.grep("launch code", tokens: 100_000)
        #expect(found.contains("Windows › End:7: The launch code is 4242."), "\(found)")
        #expect(!found.contains("alpha"), "the whole note came back as one line: \(found)")

        let paragraph = String(repeating: "word ", count: 300) + "the launch code" + String(repeating: " word", count: 300)
        let shown = ToolContext.excerpt(Substring(paragraph), around: "launch code")
        #expect(shown.contains("the launch code") && shown.count <= 402, "\(shown.count) characters")
    }

    // MARK: A long conversation keeps its thread

    /// What falls out of the window is what gets summarised: the count is
    /// `fit`'s own, so the two cannot disagree about which turns went.
    @Test func whatFallsOutOfTheWindowIsCountedAsFitDropsIt() {
        let turns: [Transcript.Entry] = (0..<12).flatMap { i in
            [prompt("question \(i)"), response(String(repeating: "answer \(i) ", count: 60))]
        }
        let budget = 600
        let kept = HistoryWindow.fit(turns, tokens: budget).count
        #expect(HistoryWindow.droppedCount(turns, tokens: budget) == turns.count - kept)
        #expect(HistoryWindow.droppedCount(turns, tokens: 1_000_000) == 0)
        #expect(HistoryWindow.droppedCount(turns, tokens: budget) > 0)
    }

    /// **The summary is a turn, never instructions**: it is the model's
    /// account of replies that quote notes and web pages, so it goes in as an
    /// answer — after the instructions, before the turns shown — and only
    /// while a turn it covers is not shown, or is no longer there at all.
    @Test func theSummaryIsCarriedAsATurnNotAsInstructions() {
        let instructions = Transcript.Entry.instructions(
            Transcript.Instructions(segments: [.text(.init(content: "Use the tools."))], toolDefinitions: []))
        let turns: [Transcript.Entry] = (0..<12).flatMap { i in
            [prompt("question \(i)"), response(String(repeating: "answer \(i) ", count: 60))]
        }
        let summary = EarlierSummary.Value(text: "They asked about the launch code; it is 4242.", through: turns[3].id)
        let fitted = HistoryWindow.fit([instructions] + turns, tokens: 600, earlier: summary)
        guard fitted.count > 3, case .instructions = fitted[0], case .prompt = fitted[1], case .response = fitted[2],
              case .prompt = fitted[3] else {
            Issue.record("the summary is not a turn after the instructions"); return
        }
        #expect(AssistantModel.conversationLine(fitted[2])?.hasSuffix(summary.text) == true)
        #expect(fitted.count - 3 < turns.count, "nothing fell out, so the summary repeats what is shown")
        #expect(HistoryWindow.cost(of: Array(fitted.dropFirst())) <= 600, "the summary was not given room")
        // Everything fits: no summary, which would only repeat what is shown.
        #expect(HistoryWindow.fit([instructions] + turns, tokens: 1_000_000, earlier: summary).count == turns.count + 1)
        // What it covers has gone from the history altogether: it is the
        // only account there is.
        let gone = EarlierSummary.Value(text: summary.text, through: "no-longer-here")
        #expect(HistoryWindow.fit([instructions] + turns, tokens: 1_000_000, earlier: gone).count == turns.count + 3)
        #expect(!AssistantInstructions.text(toolNames: ["search_notes", "read_note"], collectionName: "Work",
                                            noteCount: 3).contains("summary"))
    }

    /// **A summary covers exactly what it read.** Its parts are the person's
    /// words and the replies, never the tools' bulk; each says how far it
    /// reaches; and an entry longer than a part is read in several, never cut
    /// to its opening — the old fold read half a window of what fell out and
    /// marked all of it covered.
    @Test func theSummaryIsMadeOfEverythingThatFellOut() {
        let output = Transcript.Entry.toolOutput(Transcript.ToolOutput(
            id: "t", toolName: "read_note", segments: [.text(.init(content: "BULK"))]))
        let asked = prompt("What is the code?")
        let answered = response("It is 4242.")
        let parts = AssistantModel.summaryParts([asked, output, answered][...], tokens: 1_000)
        #expect(parts.count == 1)
        #expect(parts.first?.text == "Person: What is the code?\n\nAssistant: It is 4242.")
        #expect(parts.first?.through == answered.id)

        let text = String(repeating: "The launch code is 4242. ", count: 400)
        let long = response(text)
        let split = AssistantModel.summaryParts([asked, long][...], tokens: 300)
        #expect(split.count > 3, "a long reply was read as \(split.count) parts")
        #expect(split.first?.through == asked.id)
        #expect(split.last?.through == long.id)
        #expect(split.dropLast().allSatisfy { $0.through != long.id }, "a part claimed the reply before all of it was read")
        #expect(split.dropFirst().map(\.text).joined() == "Assistant: " + text, "the reply was not read whole")
    }

    // MARK: Where each reply was made

    /// A turn stamps the replies it added — never one from before it, which
    /// says nothing rather than guess, and never one stamped already.
    @Test func eachReplyIsStampedWithItsTurnsModel() {
        let old = response("from before")
        let earlier = ChatSessionStore.replyIDs(in: [prompt("q0"), old])
        let mine = response("this turn's")
        let entries = [prompt("q0"), old, prompt("q1"), mine]
        let cloud = ModelStamp(choice: .privateCloud, name: "Cloud (Apple)")
        let stamps = AssistantModel.stamping([:], newRepliesIn: entries, notIn: earlier, with: cloud)
        #expect(stamps.count == 1)
        if case .response(let reply) = mine { #expect(stamps[reply.id] == cloud) }

        let local = ModelStamp(choice: .onDevice, name: "Local (Apple)")
        let again = AssistantModel.stamping(stamps, newRepliesIn: entries, notIn: [], with: local)
        if case .response(let reply) = mine { #expect(again[reply.id] == cloud, "a reply's stamp was rewritten") }
    }

    /// The stamps are kept with the conversation they belong to, and go with it.
    @Test func stampsAreKeptWithTheConversation() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("Stamps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let collection = URL(fileURLWithPath: "/tmp/SomeVault")
        let store = ChatSessionStore(collectionURL: collection, baseDirectory: base)
        let reply = response("It is 4242.")
        guard case .response(let r) = reply else { return }
        let stamp = ModelStamp(choice: .privateCloud, name: "Cloud (Apple)")
        store.save([prompt("q"), reply], stamps: [r.id: stamp, "not-kept": stamp])

        var patience = Waits.Patience(.seconds(10), every: .milliseconds(50))
        var loaded: [String: ModelStamp] = [:]
        while patience.lasts {
            loaded = ChatSessionStore(collectionURL: collection, baseDirectory: base).loadStamps()
            if !loaded.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(loaded == [r.id: stamp], "only a kept reply's stamp is saved")

        await store.clear().value
        #expect(ChatSessionStore(collectionURL: collection, baseDirectory: base).loadStamps().isEmpty)
    }

    /// What a result says: the model's name, with the cloud's symbol for one
    /// off the device.
    @Test func aStampSaysWhereItRan() {
        let cloud = ModelStamp(choice: .privateCloud, name: "Cloud (Apple)")
        #expect(cloud.caption == "Cloud (Apple)" && cloud.systemImage == "lock.icloud")
        let local = ModelStamp(choice: .onDevice, name: "Local (Apple)")
        #expect(local.caption == "Local (Apple)" && local.systemImage == "lock")
        #expect(cloud.detail.contains("Private Cloud Compute"))
    }

    // MARK: Cloud (Apple)'s daily limit

    /// **A spent Cloud (Apple) allowance falls back to Local (Apple) — and
    /// that is the only fallback there is.** Before a request, `serving` sends
    /// it to this device; the request that finds the allowance spent first is
    /// asked again here (`fallback`). Never away from the device, never for
    /// another failure, never when Local (Apple) can't run — then the limit is
    /// the answer, in words.
    @Test func theCloudLimitFallsBackToThisDevice() {
        // Before a request.
        #expect(LanguageModels.serving(.privateCloud, limitReached: true, localAvailable: true) == .onDevice)
        #expect(LanguageModels.serving(.privateCloud, limitReached: false, localAvailable: true) == .privateCloud)
        #expect(LanguageModels.serving(.privateCloud, limitReached: true, localAvailable: false) == .privateCloud)
        for choice in [ModelChoice.onDevice, .mlx] {
            #expect(LanguageModels.serving(choice, limitReached: true, localAvailable: true) == choice)
        }

        // The request that finds it spent.
        let soon = Date(timeIntervalSinceNow: 3_600)
        let refused = PrivateCloudComputeLanguageModel.Error.quotaLimitReached(
            .init(resetDate: soon, debugDescription: "limit"))
        #expect(LanguageModels.fallback(after: refused, on: .privateCloud, localAvailable: true) == .onDevice)
        #expect(LanguageModels.fallback(after: refused, on: .privateCloud, localAvailable: false) == nil)
        #expect(LanguageModels.fallback(after: refused, on: .onDevice, localAvailable: true) == nil,
                "a request that ran here is never asked again")
        // Negative control: Cloud (Apple) failing for any other reason is not
        // something another model mends, and is reported as it is.
        let offline = PrivateCloudComputeLanguageModel.Error.networkFailure(.init(debugDescription: "offline"))
        #expect(LanguageModels.fallback(after: offline, on: .privateCloud, localAvailable: true) == nil)
        #expect(LanguageModels.fallback(after: CancellationError(), on: .privateCloud, localAvailable: true) == nil)

        // What it says: that Local (Apple) is standing in, and when Cloud is back.
        #expect(LanguageModels.limitReached(resets: soon, fallingBack: true)
            .hasPrefix("You've reached today's limit for Cloud (Apple), so Local (Apple) is being used instead. It resets "))
        #expect(LanguageModels.limitReached(resets: nil, fallingBack: false) == "You've reached today's limit for Cloud (Apple).")
        #expect(IntelligenceError.describe(refused, modelName: "Cloud (Apple)")
            .hasPrefix("You've reached today's limit for Cloud (Apple). It resets "))
    }

    // MARK: Names, and the conversation's own model

    /// Named by where they run, then whose they are — in a menu and a
    /// sentence alike.
    @Test(.scratchDefaults) func theModelsAreNamedByWhereTheyRun() {
        let models = LanguageModels(mlx: MLXModelStore(defaults: ScratchDefaults.suite()))
        #expect(models.name(of: .onDevice) == "Local (Apple)")
        #expect(models.name(of: .privateCloud) == "Cloud (Apple)")
        #expect(models.name(of: .mlx) == "Local (\(models.mlx.modelName))")
        for choice in ModelChoice.allCases {
            #expect(models.title(of: choice) == models.name(of: choice))
        }
    }

    /// **The Assistant's menu chooses for its conversation, never the
    /// default**, and New Conversation goes back to the default.
    @Test(.scratchDefaults) func theMenuChoosesForTheConversationOnly() {
        let defaults = ScratchDefaults.suite()
        defaults.set(true, forKey: IntelligenceMigration.doneKey)
        let settings = IntelligenceSettings(defaults: defaults)
        settings.model = .onDevice
        let assistant = AssistantModel(settings: settings)
        #expect(assistant.menuOptions.first == .onDevice)
        #expect(assistant.menuOptions.contains(.privateCloud) == LanguageModels.privateCloudComputeEnabled)

        assistant.conversationChoice = .privateCloud
        #expect(assistant.chosenModel == .privateCloud)
        #expect(settings.model == .onDevice, "choosing for a conversation changed the default")

        assistant.clear()
        #expect(assistant.conversationChoice == nil && assistant.chosenModel == .onDevice)
    }

    /// **A conversation keeps its own model, and only its own.** Chosen in the
    /// Assistant's menu, it is kept beside the conversation — so a relaunch does
    /// not put a conversation kept on this device back on a Cloud (Apple)
    /// default with everything it read — and another collection's conversation
    /// starts on its own (it carried the last one's).
    @Test(.scratchDefaults) func aConversationKeepsItsOwnModel() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "conversation-choice-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let defaults = ScratchDefaults.suite()
        defaults.set(true, forKey: IntelligenceMigration.doneKey)
        let settings = IntelligenceSettings(defaults: defaults)
        settings.model = .privateCloud
        let here = ChatSessionStore(collectionURL: URL(filePath: "/notes/here"), baseDirectory: base)
        let there = ChatSessionStore(collectionURL: URL(filePath: "/notes/there"), baseDirectory: base)
        let assistant = AssistantModel(settings: settings)
        assistant.sessionStore = here
        assistant.conversationChoice = .onDevice

        var patience = Waits.Patience(.seconds(5))
        while here.loadConversation().model != ModelOption.onDevice.id, patience.lasts {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(here.loadConversation().model == ModelOption.onDevice.id, "the conversation's model was not kept with it")

        assistant.sessionStore = there
        #expect(assistant.conversationChoice == nil, "a choice made for one conversation carried into another's")
        #expect(assistant.chosenModel == .privateCloud)

        // As after a relaunch: a new model, the same conversation.
        let relaunched = AssistantModel(settings: settings)
        relaunched.sessionStore = ChatSessionStore(collectionURL: URL(filePath: "/notes/here"), baseDirectory: base)
        #expect(relaunched.conversationChoice == .onDevice)
        #expect(relaunched.chosenModel == .onDevice)
    }

    /// **Use my notes is kept with the conversation.** Turning it off is how
    /// a conversation on a model off the device keeps the notes away from it,
    /// and it came back on whenever the Assistant was made again — a note
    /// shown in its tab's place was enough — while the conversation's Cloud
    /// (Apple) choice came back from disk. New Conversation keeps it as well.
    @Test(.scratchDefaults) func useMyNotesIsKeptWithTheConversation() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "use-my-notes-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let defaults = ScratchDefaults.suite()
        defaults.set(true, forKey: IntelligenceMigration.doneKey)
        let settings = IntelligenceSettings(defaults: defaults)
        let here = ChatSessionStore(collectionURL: URL(filePath: "/notes/here"), baseDirectory: base)
        let assistant = AssistantModel(settings: settings)
        assistant.sessionStore = here
        assistant.agentMode = false

        var patience = Waits.Patience(.seconds(5))
        while here.loadConversation().useNotes != false, patience.lasts { try await Task.sleep(for: .milliseconds(10)) }
        let again = AssistantModel(settings: settings)
        again.sessionStore = ChatSessionStore(collectionURL: URL(filePath: "/notes/here"), baseDirectory: base)
        #expect(again.agentMode == false, "Use my notes came back on")
        again.clear()
        #expect(again.agentMode == false, "New Conversation turned Use my notes back on")
    }

    /// **A conversation whose model the folder no longer has stays on it**,
    /// says so in the menu, and sends nothing. It fell to the Settings
    /// default — which may be Cloud (Apple) — with everything it had read.
    @Test(.scratchDefaults) func aConversationsMissingModelIsNotSwappedForTheDefault() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "missing-model-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let defaults = ScratchDefaults.suite()
        defaults.set(true, forKey: IntelligenceMigration.doneKey)
        let settings = IntelligenceSettings(
            defaults: defaults, models: LanguageModels(mlx: MLXModelStore(defaults: defaults)))
        settings.model = .privateCloud
        let gone = ModelOption.mlx("/models/models--org--gone/snapshots/abc")
        let store = ChatSessionStore(collectionURL: URL(filePath: "/notes/kept"), baseDirectory: base)
        let first = AssistantModel(settings: settings)
        first.sessionStore = store
        first.choose(gone)

        var patience = Waits.Patience(.seconds(5))
        while store.loadConversation().model != gone.id, patience.lasts { try await Task.sleep(for: .milliseconds(10)) }
        let again = AssistantModel(settings: settings)
        again.sessionStore = ChatSessionStore(collectionURL: URL(filePath: "/notes/kept"), baseDirectory: base)
        #expect(again.chosenOption == gone, "the conversation moved to \(again.chosenOption)")
        #expect(!again.availability.isAvailable)
        #expect(again.menuOptions.contains(gone), "the menu doesn't say what the conversation is on")
    }

    /// **Research runs on the model it is handed** — the Assistant hands it the
    /// conversation's — never on the Settings default behind it. It ran on the
    /// default, so a conversation kept on this device researched on Cloud
    /// (Apple) under a Local stamp. Asked of an MLX store with no model, the
    /// answer is that store's, whatever the default says.
    @Test(.scratchDefaults) func researchRunsOnTheModelItIsHanded() {
        let defaults = ScratchDefaults.suite()
        defaults.set(true, forKey: IntelligenceMigration.doneKey)
        let settings = IntelligenceSettings(
            defaults: defaults, models: LanguageModels(mlx: MLXModelStore(defaults: defaults)))
        settings.model = .onDevice
        let absent = ModelOption.mlx("/no/such/model")
        let mlxReason = settings.models.availability(ofOption: absent).reason
        #expect(mlxReason != nil, "an MLX model that isn't in the folder should say why it can't run")
        #expect(DeepResearch.unavailableReason(settings: settings, requested: absent) == mlxReason)
        #expect(DeepResearch.unavailableReason(settings: settings)
                == DeepResearch.unavailableReason(settings: settings, requested: .onDevice))
    }

    /// **The Assistant's menu lists every MLX model, and a conversation runs
    /// the one it chose beside the default's.** It listed one, because one MLX
    /// model loads at a time — but the person has the memory for more ("You are
    /// assuming the user does not have space to load multiple models
    /// simultaneously. This is incorrect", 2026-10-18). Choosing one here
    /// leaves the default's model alone.
    @Test(.scratchDefaults) func aConversationRunsTheMLXModelItChose() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "mlx-menu-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["alpha", "beta"] {
            let repository = folder.appending(path: "models--org--\(name)", directoryHint: .isDirectory)
            let snapshot = repository.appending(path: "snapshots/abc", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: repository.appending(path: "refs"), withIntermediateDirectories: true)
            try "abc".write(to: repository.appending(path: "refs/main"), atomically: true, encoding: .utf8)
            try #"{"model_type": "qwen2"}"#.write(to: snapshot.appending(path: "config.json"), atomically: true, encoding: .utf8)
            try Data(repeating: 1, count: 64).write(to: snapshot.appending(path: "model.safetensors"))
        }
        let defaults = ScratchDefaults.suite()
        defaults.set(true, forKey: IntelligenceMigration.doneKey)
        let store = MLXModelStore(defaults: defaults)
        let settings = IntelligenceSettings(defaults: defaults, models: LanguageModels(mlx: store))
        store.chooseFolder(folder)
        await store.refresh()
        let beta = try #require(store.models.first { $0.name == "beta" })

        let assistant = AssistantModel(settings: settings)
        #expect(assistant.menuOptions.compactMap(\.mlxModelID).count == 2,
                "the menu lists \(assistant.menuOptions.compactMap(\.mlxModelID).count) MLX models of two")
        assistant.choose(.mlx(beta.id))
        #expect(assistant.servingOption == .mlx(beta.id))
        #expect(assistant.modelName == "Local (beta)")
        #expect(assistant.menuOptions.filter(assistant.isChosen) == [.mlx(beta.id)])
        #expect(settings.model == .onDevice && store.chosenID == nil,
                "choosing a model for a conversation changed the default's")
    }

    /// A single model's own folder, chosen in the panel where the folder of
    /// models was meant, is that one model — not a models folder with nothing
    /// in it (the person's check of build 34: the panel looked like a request
    /// to open a model).
    @Test func oneModelsOwnFolderIsThatModel() throws {
        let repository = FileManager.default.temporaryDirectory
            .appending(path: "mlx-one-\(UUID().uuidString)/models--org--gamma", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: repository.deletingLastPathComponent()) }
        let snapshot = repository.appending(path: "snapshots/abc", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository.appending(path: "refs"), withIntermediateDirectories: true)
        try "abc".write(to: repository.appending(path: "refs/main"), atomically: true, encoding: .utf8)
        try #"{"model_type": "qwen2"}"#.write(to: snapshot.appending(path: "config.json"), atomically: true, encoding: .utf8)
        try Data(repeating: 1, count: 64).write(to: snapshot.appending(path: "model.safetensors"))
        #expect(MLXModelFolder.models(in: repository).map(\.name) == ["gamma"])
        #expect(MLXModelFolder.models(in: repository.deletingLastPathComponent()).map(\.name) == ["gamma"])
    }
}
