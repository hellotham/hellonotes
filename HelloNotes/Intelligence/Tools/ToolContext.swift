//
//  ToolContext.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Everything the Assistant can do to a collection, as plain async methods.
//
//  The Foundation Models `Tool` types in `NoteTools.swift` are thin: they decode
//  their `@Generable` arguments, hop here, and hand back a string. The work
//  lives in one main-actor class because it touches the collection's observable
//  state — and a class, not the struct it used to be, because a tool must be
//  `Sendable` and a main-actor class is; a struct holding main-actor services
//  is not.
//
//  **The person approves each change, shown as a diff** — that is the
//  `PermissionBroker`'s job, and it is the one rule "Allow all this session"
//  relaxes: once chosen, later changes in that conversation are made without a
//  card, except deleting a note, which always asks. Everything below is kept by
//  this class itself, so it holds under "Allow all" too:
//
//  1. **Containment before reading.** A note whose file is a symlink out of the
//     vault is refused before its contents are read, so they never appear in
//     an approval diff.
//  2. **A note that can't be read is not an empty note.** One that hasn't
//     downloaded is downloaded first; one that still can't be read is refused,
//     never shown as blank (`readContents`).
//  3. **A save is a save.** Changes go through `Collection.noteDidSave`, the
//     same path the editor uses — which patches the indexes, tells the file
//     watcher the write was ours, and uploads it on a direct cloud collection.
//     The previous tools wrote the file and re-scanned, which never uploaded:
//     an Assistant edit in a Dropbox collection was overwritten by the next
//     sync. Because the watcher is told the write was ours, the open editors
//     are told directly (`noteChangedOutsideEditor`), or a tab showing the note
//     would save its stale text back over the approved change.
//  4. **What was approved is what gets replaced.** The write happens only if
//     the file still holds the text the diff was made from, checked inside the
//     coordinated write (`FileIO.replace`). Otherwise typing the person saved
//     while deciding would be overwritten by a diff that never showed it.
//  5. **A note open in an editor is read and changed there** (`openEditor`):
//     what is on screen, typing not yet saved included, is what the diff is
//     made from and what the change is made to — through the editor's own
//     write (`EditorModel.applyEdit`), and only if the screen still says
//     what was read. Read from the file and written to it, the change met
//     the typing in the editor as a change made elsewhere, and the person
//     had to choose between the two (implemented.md §51.36).
//
//  Failures the model can recover from — a note that isn't there, an edit that
//  doesn't match — are thrown as `ToolError` and turned into a sentence for the
//  model by the tool, rather than aborting the whole response.
//

import Foundation

/// How much of the window an Assistant turn has left, in tokens, for a note
/// tool shaping its result. Querying notes is what the Assistant is for, so a
/// result takes **all of the room there is**: older turns make way
/// (`HistoryWindow.fit` keeps the newest whole turns and summarises the rest),
/// and what stays is the instructions, the reply's reserve — both outside
/// `budget` — the message, and what the turn's tools have already returned.
///
/// **Results asked for together share it.** The model may ask for several
/// tools in one step; the framework runs them at once and adds their results
/// to the transcript when all are done, so a result measured against the
/// transcript alone cannot see its siblings, and two searches would each take
/// all of it — and fail the request together. Each takes its part here as it
/// is shaped, measured and taken on the main actor with nothing in between:
/// a call on its own gets everything left, and of several, each gets an even
/// part of what the ones before it left. When the step's results land in the
/// transcript, or another turn begins, the count starts again from it.
@MainActor final class TurnRoom {
    /// What the turn's transcript holds now, how many tools its latest step
    /// asked for, and where the turn began. The start is what tells two turns
    /// of one shape apart: a room lives as long as its session, and the next
    /// question the same size as the last inherited its spent room — "No room
    /// is left" before anything had been read.
    struct Held: Equatable {
        var tokens: Int
        var calls: Int
        var turnStart: Int
    }

    /// The history's share of the window (`AssistantModel.historyBudget`).
    var budget: Int
    private let held: () -> Held
    private var seen: Held?
    private var pending = 0
    private var answered = 0

    init(budget: Int, held: @escaping () -> Held) {
        self.budget = budget
        self.held = held
    }

    /// A result's part of what is left now.
    func share() -> Int {
        let now = held()
        if now != seen {
            seen = now
            pending = 0
            answered = 0
        }
        let left = budget - now.tokens - pending - max(200, budget / 25)
        return max(0, left) / max(1, now.calls - answered)
    }

    /// Count a result of `tokens` as taken.
    func take(_ tokens: Int) {
        pending += tokens
        answered += 1
    }
}

@MainActor
final class ToolContext {
    let collection: Collection
    let search: CollectionSearchModel
    let git: GitService
    let permissions: PermissionBroker
    /// For tools that start sessions of their own (deep research).
    var settings: IntelligenceSettings?
    /// The model the conversation using these tools runs on, which a tool that
    /// starts sessions of its own runs on too. Set by the Assistant as it
    /// builds each session; `nil` is the Settings default.
    var modelChoice: ModelOption?
    /// The collection's `SKILL.md` files (`load_skill`).
    var skills: SkillStore?

    init(collection: Collection, search: CollectionSearchModel, git: GitService,
         permissions: PermissionBroker, settings: IntelligenceSettings? = nil,
         skills: SkillStore? = nil) {
        self.collection = collection
        self.search = search
        self.git = git
        self.permissions = permissions
        self.settings = settings
        self.skills = skills
    }

    var rootURL: URL? { collection.rootURL }
    var notes: [Note] { collection.notes }

    // MARK: - Lookup

    /// A note matched by exact title, filename, or relative path (case-insensitive).
    func note(matching query: String) -> Note? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nil }
        if let n = notes.first(where: { $0.title.lowercased() == q }) { return n }
        if let n = notes.first(where: { $0.fileURL.lastPathComponent.lowercased() == q }) { return n }
        return notes.first(where: {
            let rel = relativePath($0).lowercased()
            return rel == q || rel.hasSuffix("/" + q)
        })
    }

    func relativePath(_ note: Note) -> String {
        guard let base = rootURL?.standardizedFileURL.path else { return note.fileURL.lastPathComponent }
        let path = note.fileURL.standardizedFileURL.path
        guard path.hasPrefix(base) else { return note.fileURL.lastPathComponent }
        return String(path.dropFirst(base.count).drop(while: { $0 == "/" }))
    }

    /// True when `url`, after resolving symlinks, stays inside the collection
    /// root. Defends the mutating tools against a note whose file is a symlink
    /// pointing out of the vault (the directory enumerator follows symlinks).
    ///
    /// Resolved off the main actor: resolving symlinks is a file system lookup
    /// per path component, and in a File Provider folder each one waits for the
    /// provider.
    func isWithinRoot(_ url: URL) async -> Bool {
        guard let root = rootURL else { return true }   // no scoped root: nothing to enforce
        return await offMain { Self.contains(root: root, url) }
    }

    nonisolated static func contains(root: URL, _ url: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        return target == base || target.hasPrefix(base + "/")
    }

    /// A note's text, downloaded first if it isn't on this device, and read off
    /// the main actor — a coordinated read of a cloud file blocks for as long as
    /// its provider takes.
    ///
    /// **Throws rather than returning `""`.** An unreadable note used to read as
    /// an empty one, which the editor learned is not a failure but a claim
    /// (`EditorModel`'s load). Here it was worse than a blank tab: the empty
    /// text became the "before" of an approval diff, so deleting or rewriting a
    /// note that simply hadn't downloaded looked like deleting or rewriting
    /// nothing — and `read_note` told the model the note was empty.
    func readContents(of note: Note) async throws -> String {
        let url = note.fileURL
        // Open in an editor: what is on screen.
        if let editor = openEditor(for: url) {
            editor.carryLiveEdits()
            return editor.text
        }
        // A direct cloud collection keeps a zero-byte placeholder until asked.
        await collection.hydrateIfNeeded(url)
        if (notes.first { $0.fileURL == url } ?? note).isOnlineOnly {
            throw ToolError.failed(notOnDevice(note))
        }
        // An iCloud Drive or File Provider file the system holds online-only.
        // `materialise` answers at once for a file that is already here, and
        // runs off the main actor either way.
        guard await FileIO.materialise(at: url) else { throw ToolError.failed(notOnDevice(note)) }
        collection.noteBecameAvailable(url)
        do {
            return try await offMain { try FileIO.readString(at: url) }
        } catch {
            throw ToolError.failed("Couldn't read “\(note.title)”: \(error.localizedDescription)")
        }
    }

    /// The editor holding the note at `url` with the note in it and nothing
    /// to choose — loaded, and no conflict open — which the Assistant reads
    /// and changes the note through. With a conflict open the file is read:
    /// which side is the note is the person's to say, and a change made to the
    /// file is theirs moving on, under the same banner.
    private func openEditor(for url: URL) -> EditorModel? {
        EditorModel.editors(holding: url).first { $0.isLoaded && !$0.hasConflict }
    }

    private func notOnDevice(_ note: Note) -> String {
        "“\(note.title)” hasn't downloaded to this device yet, so it can't be read or changed right now."
    }

    private func require(_ query: String) throws -> Note {
        guard let note = note(matching: query) else {
            throw ToolError.notFound("No note matching “\(query)”. Search for it first to get its exact title.")
        }
        return note
    }

    // MARK: - Reading

    /// Every note's title and path — as many as fit (`share(of:room:)`).
    func listNotes(tokens: Int, room: TurnRoom? = nil) -> String {
        let all = notes
        guard !all.isEmpty else { return "The collection is empty." }
        let lines = all.map { "- \($0.title)  (\(relativePath($0)))" }
        guard let tokens = Self.share(of: tokens, room: room) else { return Self.noRoom }
        let shown = Self.fitting(lines, tokens: tokens)
        var text = lines.prefix(shown).joined(separator: "\n")
        if shown < lines.count {
            text += "\n… and \(lines.count - shown) more. Use search_notes to find a specific note."
        }
        room?.take(TokenBudget.estimate(text))
        return text
    }

    /// A note's Markdown — from the top, or from one of its sections.
    ///
    /// **A long note was half-blind.** This read the note's opening, up to the
    /// window's share, and said only how much more there was: nothing could
    /// read past it, so a fact near the end of a long note was one the model
    /// truthfully could not find. Now a cut says which sections lie past it,
    /// and `section` reads from any of them.
    func readNote(_ query: String, tokens: Int, section: String? = nil, room: TurnRoom? = nil) async throws -> String {
        let note = try require(query)
        // Taken before the read, not after: a sibling shaped while this one
        // reads sees what is left without it.
        guard let tokens = Self.share(of: tokens, room: room) else { return Self.noRoom }
        room?.take(tokens)
        let body = try await readContents(of: note)
        let wanted = section?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = note.title
        let shown = try await offMain { () throws -> String in
            var start = body.startIndex
            if !wanted.isEmpty {
                guard let found = NoteSections.start(of: wanted, in: body) else {
                    let names = NoteSections.titles(in: body).prefix(40)
                    throw ToolError.failed("“\(title)” has no section “\(wanted)”. Its sections: "
                        + (names.isEmpty ? "none." : names.joined(separator: "; ") + "."))
                }
                start = found
            }
            let rest = String(body[start...])
            // Cut as a model counts: three characters a token is a Chinese
            // note read three times over its share.
            let (kept, cut) = TokenBudget.prefix(rest, tokens: max(100, tokens - 80))
            guard cut else { return rest }
            let later = NoteSections.titles(in: String(rest.dropFirst(kept.count))).prefix(30)
            return kept + "\n… (truncated: \(rest.count - kept.count) more characters"
                + (later.isEmpty ? ")" : ". Later sections: \(later.joined(separator: "; ")) — read one by passing its name as `section`)")
        }
        let from = wanted.isEmpty ? "" : ", from “\(wanted)”"
        return "# \(title)  (\(relativePath(note))\(from))\n\n\(shown)"
    }

    /// Every note that matches `query`, best first — as many as fit in
    /// `tokens`, measured as a model counts them (`TokenBudget`), and the
    /// count of the rest, so a model given part of the list never takes it
    /// for the whole.
    func searchNotes(_ query: String, tokens: Int, room: TurnRoom? = nil) async -> String {
        var found = await search.fullTextResults(query: query)
        // Titles from the collection's own list as well. The index holds only
        // the notes it has read — none until the rebuild that opening a
        // collection starts has landed, and never one that hasn't downloaded —
        // so a note `list_notes` shows was "not matched" by its own name, and
        // the model told the person it did not exist.
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let seen = Set(found.map(\.id))
            let all = notes
            let byTitle = await offMain {
                all.filter { !seen.contains($0.fileURL) && $0.title.localizedStandardContains(q) }
            }
            found += byTitle.map { SearchHit(note: $0, snippet: "") }
        }
        guard !found.isEmpty else { return "No notes matched “\(query)”." }
        let lines = found.map { hit in
            let snippet = hit.snippet.replacingOccurrences(of: "\n", with: " ")
            return "- \(hit.note.title)  (\(relativePath(hit.note)))\n  \(snippet)"
        }
        // Measured, packed and taken with nothing in between, so results
        // asked for together share the room rather than each take all of it.
        guard let tokens = Self.share(of: tokens, room: room) else { return Self.noRoom }
        let shown = Self.fitting(lines, tokens: tokens)
        var text = lines.prefix(shown).joined(separator: "\n")
        if shown < lines.count {
            text += "\n… and \(lines.count - shown) more notes matched that don't fit here. Search with more words to narrow it."
        }
        room?.take(TokenBudget.estimate(text))
        return text
    }

    /// What a result may take: its part of the turn's room in a conversation
    /// (`TurnRoom.share`), or `tokens`, the window's share, outside one —
    /// `nil` when a conversation has no room left, which is said rather than
    /// sent past the window, where the whole request would fail.
    static func share(of tokens: Int, room: TurnRoom?) -> Int? {
        guard let room else { return tokens }
        let share = room.share()
        guard share >= 120 else {
            room.take(40)
            return nil
        }
        return share
    }

    static let noRoom = "No room is left in this conversation for more results this turn. Answer from what you have read, and say what is left to look at."

    /// A matching line as a result shows it: whole, or — past 400 characters,
    /// a long paragraph's worth — the stretch around the match. A line is
    /// where `read_note` can be asked to read from, not the reading, and one
    /// line longer than the turn's room was sent whole (`fitting` keeps one).
    nonisolated static func excerpt(_ line: Substring, around needle: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 400 else { return trimmed }
        let lower = trimmed.lowercased()
        let offset = lower.range(of: needle).map { lower.distance(from: lower.startIndex, to: $0.lowerBound) } ?? 0
        let start = max(0, min(offset - 150, trimmed.count - 400))
        let from = trimmed.index(trimmed.startIndex, offsetBy: start)
        let to = trimmed.index(from, offsetBy: 400)
        return (start > 0 ? "…" : "") + trimmed[from..<to] + (to < trimmed.endIndex ? "…" : "")
    }

    /// How many of `lines`, from the first, fit in `tokens` — at least one.
    nonisolated static func fitting(_ lines: [String], tokens: Int) -> Int {
        var used = 0
        for (index, line) in lines.enumerated() {
            used += TokenBudget.estimate(line) + 1
            if used > tokens { return max(1, index) }
        }
        return lines.count
    }

    /// Lines containing `pattern`, across every note. The reads happen off the
    /// main actor in one pass; the list of notes is taken here, where it lives.
    ///
    /// Only notes already on this device are searched, as `search_notes` does:
    /// reading an online-only note downloads it, so one call — and the model
    /// makes several at once — would pull a whole cloud vault local. The result
    /// says how many were left out, so the model doesn't take "no matches" as
    /// the whole answer.
    func grep(_ pattern: String, tokens: Int, room: TurnRoom? = nil) async -> String {
        let needle = pattern.lowercased()
        let targets = notes
        let notOnDevice = targets.filter(\.isOnlineOnly).count
        // A turn with no room left is told so before a scan, not after one.
        if let room, room.share() < 120 { return Self.noRoom }
        // A bound on the scan, not on the result: past it, the line count is
        // only a floor, and says so. More lines than this never fit a window.
        let limit = 2_000
        let found = await offMain { () -> [String] in
            var out: [String] = []
            for target in targets {
                guard FileIO.hasContentAvailable(target),
                      let text = try? FileIO.readString(at: target.fileURL),
                      // A note without the text is passed over whole, not
                      // lowered a line at a time.
                      text.lowercased().contains(needle) else { continue }
                // Where each match is, as well as what: the section a line is
                // under is what `read_note` can be asked to read from.
                var heading: String?
                var inFence = false
                // At any line break — a note saved on Windows ends its lines
                // with "\r\n", which is one Character, never "\n", so the
                // whole note was one line.
                for (i, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
                    if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle() }
                    if !inFence, let title = NoteSections.title(ofHeadingLine: line) { heading = title }
                    guard line.lowercased().contains(needle) else { continue }
                    let place = heading.map { "\(target.title) › \($0)" } ?? target.title
                    out.append("\(place):\(i + 1): \(ToolContext.excerpt(line, around: needle))")
                    if out.count > limit { return out }
                }
            }
            return out
        }
        let skipped = notOnDevice > 0
            ? "\n(\(notOnDevice) notes that haven't downloaded to this device weren't searched.)"
            : ""
        guard !found.isEmpty else { return "No matches for “\(pattern)”." + skipped }
        guard let tokens = Self.share(of: tokens, room: room) else { return Self.noRoom }
        let lines = Array(found.prefix(limit))
        let shown = Self.fitting(lines, tokens: tokens)
        var text = lines.prefix(shown).joined(separator: "\n")
        if shown < found.count {
            let more = found.count > limit ? "\(found.count - shown - 1) or more" : "\(found.count - shown)"
            text += "\n… and \(more) more matching lines that don't fit here. Look for something more exact to narrow it."
        }
        text += skipped
        room?.take(TokenBudget.estimate(text))
        return text
    }

    func loadSkill(_ name: String) throws -> String {
        guard let store = skills, !store.skills.isEmpty else {
            return "This collection has no skills."
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let skill = store.skill(named: trimmed) else {
            // The list is served here, as tool output, rather than written into
            // the instructions. Skill descriptions come from files in the vault,
            // and anything a file can say must never be in the instructions,
            // where the model treats it as coming from the app.
            let list = store.discoveryList
            return trimmed.isEmpty
                ? "Skills in this collection:\n\(list)"
                : "No skill named “\(trimmed)”. Skills in this collection:\n\(list)"
        }
        return "# Skill: \(skill.name)\n\n\(skill.body)"
    }

    // MARK: - Changing (approved, then committed)

    func createNote(title: String, content: String, folder: String?) async throws -> String {
        guard let root = rootURL else { throw ToolError.failed("No collection is open.") }
        let safe = title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        guard !safe.isEmpty else { throw ToolError.badArguments("The note needs a title.") }
        var directory = root
        if let folder = folder?.trimmingCharacters(in: .whitespaces), !folder.isEmpty {
            directory = root.appendingPathComponent(folder)
        }
        // Containment — enforced independently of the permission broker, so it
        // holds under "Allow all". `appendingPathComponent` does not resolve
        // `..`, and a lexical check would miss a symlinked folder, so this
        // resolves symlinks. Both checks touch the file system, so both run off
        // the main actor, together.
        let url = directory.appendingPathComponent(safe + ".md")
        let (inside, exists) = await offMain { [directory] in
            (Self.contains(root: root, directory), FileManager.default.fileExists(atPath: url.path))
        }
        guard inside else {
            throw ToolError.failed("Notes can only be created inside the collection.")
        }
        guard !exists else {
            throw ToolError.failed("A note named “\(safe)” already exists there. Use edit_note to change it.")
        }
        let rootBase = root.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        let rel = target.hasPrefix(rootBase + "/") ? String(target.dropFirst(rootBase.count + 1)) : safe + ".md"

        guard await permissions.confirm(
            title: "Create note",
            detail: "Create “\(rel)”",
            diff: EditDiff(path: rel, before: "", after: content, isCreation: true))
        else { throw ToolError.declined }

        let folder = directory
        do {
            try await offMain { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        } catch {
            throw ToolError.failed("Couldn't create the folder: \(error.localizedDescription)")
        }
        guard let note = await collection.createNote(title: safe, in: directory) else {
            throw ToolError.failed(collection.lastError ?? "Couldn't create the note.")
        }
        do {
            let data = Data(content.utf8)
            let noteURL = note.fileURL
            try await offMain { try FileIO.write(data, to: noteURL) }
        } catch {
            throw ToolError.failed("Couldn't write the note: \(error.localizedDescription)")
        }
        // A new folder arrives with the note (`Collection.adopt(createdAt:)`);
        // this used to wait for a walk of the whole collection to find it, and
        // the walk then rebuilt the sidebar under whoever was typing.
        collection.noteDidSave(note.fileURL, text: content)
        commit("assistant: create \(rel)", of: note.fileURL)
        return "Created “\(relativePath(note))”."
    }

    func editNote(_ query: String, oldString: String, newString: String, replaceAll: Bool) async throws -> String {
        let note = try require(query)
        guard await isWithinRoot(note.fileURL) else {
            throw ToolError.failed("That note resolves outside the collection.")
        }
        guard !oldString.isEmpty else { throw ToolError.badArguments("`old_string` can't be empty.") }
        let before = try await readContents(of: note)

        let occurrences = before.components(separatedBy: oldString).count - 1
        guard occurrences > 0 else {
            throw ToolError.failed("`old_string` wasn't found in “\(note.title)”. Read the note first and copy the text exactly.")
        }
        if occurrences > 1 && !replaceAll {
            throw ToolError.failed("`old_string` appears \(occurrences) times in “\(note.title)”. Include more surrounding text so it is unique, or set replace_all.")
        }
        let after = occurrences == 1
            ? EditReplacement.once(oldString, with: newString, in: before)
            : before.replacingOccurrences(of: oldString, with: newString)
        let rel = relativePath(note)

        guard await permissions.confirm(
            title: "Edit note",
            detail: "Apply an edit to “\(rel)”",
            diff: EditDiff(path: rel, before: before, after: after))
        else { throw ToolError.declined }

        try await save(after, to: note, replacing: before)
        commit("assistant: edit \(rel)", of: note.fileURL)
        return "Edited “\(rel)” (\(replaceAll ? "\(occurrences) replacements" : "1 replacement"))."
    }

    func writeNote(_ query: String, content: String) async throws -> String {
        let note = try require(query)
        guard await isWithinRoot(note.fileURL) else {
            throw ToolError.failed("That note resolves outside the collection.")
        }
        let before = try await readContents(of: note)
        let rel = relativePath(note)

        guard await permissions.confirm(
            title: "Rewrite note",
            detail: "Overwrite “\(rel)”",
            diff: EditDiff(path: rel, before: before, after: content))
        else { throw ToolError.declined }

        try await save(content, to: note, replacing: before)
        commit("assistant: rewrite \(rel)", of: note.fileURL)
        return "Rewrote “\(rel)”."
    }

    func deleteNote(_ query: String) async throws -> String {
        let note = try require(query)
        guard await isWithinRoot(note.fileURL) else {
            throw ToolError.failed("That note resolves outside the collection.")
        }
        let rel = relativePath(note)
        let before = try await readContents(of: note)

        guard await permissions.confirm(
            title: "Delete note",
            detail: "Move “\(rel)” to the Trash",
            diff: EditDiff(path: rel, before: before, after: "", isDeletion: true))
        else { throw ToolError.declined }

        await collection.deleteNote(note)
        // `deleteNote` reports a failure and returns, leaving the note where
        // it was — and this went on to commit and to answer "Moved to the
        // Trash". A note still in the collection was not deleted.
        guard !collection.notes.contains(where: { $0.fileURL == note.fileURL }) else {
            throw ToolError.failed(collection.lastError ?? "Couldn't move “\(rel)” to the Trash.")
        }
        commit("assistant: delete \(rel)", of: note.fileURL)
        return "Moved “\(rel)” to the Trash."
    }

    /// Replace the text the person approved a change to — and only that text.
    private func save(_ text: String, to note: Note, replacing before: String) async throws {
        let url = note.fileURL
        if let editor = openEditor(for: url) {
            return try await save(text, in: editor, of: note, replacing: before)
        }
        let replaced: Bool
        do {
            replaced = try await offMain { try FileIO.replace(text, at: url, ifContentsEqual: before) }
        } catch {
            throw ToolError.failed("Couldn't write “\(note.title)”: \(error.localizedDescription)")
        }
        guard replaced else {
            throw ToolError.failed("“\(note.title)” changed after it was read — probably edited while the change was waiting for approval — so the change wasn't made. Read the note again before changing it.")
        }
        collection.noteDidSave(url, text: text)
        collection.noteChangedOutsideEditor()
    }

    /// The change made in the editor showing the note — to what is on screen,
    /// if it still says what the change was made from — and written by it,
    /// so its rules hold: a save it cannot make (a folder gone) keeps the
    /// change on screen and says why. Any other editor on the note is told,
    /// as of a change made outside it.
    private func save(_ text: String, in editor: EditorModel, of note: Note,
                      replacing before: String) async throws {
        editor.carryLiveEdits()
        let shown = editor.text
        let generation = editor.textGeneration
        let unchanged = await offMain { EditorModel.sameBytes(shown, before) }
        guard unchanged, editor.textGeneration == generation, openEditor(for: note.fileURL) === editor else {
            throw ToolError.failed("“\(note.title)” changed after it was read — probably edited while the change was waiting for approval — so the change wasn't made. Read the note again before changing it.")
        }
        editor.applyEdit { _ in text }
        await editor.save()
        collection.noteChangedOutsideEditor()
        if editor.isDirty, let reason = editor.saveError {
            throw ToolError.failed("The change was made to “\(note.title)”, which is open, but it couldn't be saved yet: \(reason)")
        }
    }

    /// Commit the change — that file, and nothing else — if the collection is
    /// a Git repository the app may commit into unasked. Every Assistant edit
    /// is its own commit, so each one can be undone on its own.
    ///
    /// It was `commitAll`: the commit took every pending change in the
    /// collection with it, and was made in a cloud folder and in a sub-folder
    /// of a larger repository, where Auto-commit is refused. It is made under
    /// Auto-commit's rule now (`GitService.allowsUnattendedCommits`), though
    /// not under its switch: the person approved this change, and a commit of
    /// its own is how it is taken back (implemented.md §51.44).
    ///
    /// **Not awaited.** Git runs one operation at a time, so a commit waits
    /// behind whatever is in flight — a push to a slow remote can take minutes —
    /// and the tool's result, and with it the Assistant's reply, waited too. The
    /// change is already saved; the commit follows it in order. The commit
    /// refreshes the status in its own queue slot, so nothing else is needed.
    func commit(_ message: String, of file: URL) {
        lastCommit = nil
        guard git.status.isRepository,
              git.allowsUnattendedCommits(isCloudBacked: CloudProvider.name(for: collection.rootURL) != nil)
        else { return }
        lastCommit = Task { [git] in await git.commit([file], message: message) }
    }

    /// The commit of the last change made, while it runs and after — `nil`
    /// when that change was not committed. For a test to wait on.
    private(set) var lastCommit: Task<Void, Never>?
}

/// Why a tool could not do what it was asked.
nonisolated enum ToolError: LocalizedError {
    case badArguments(String)
    case notFound(String)
    case declined
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .badArguments(let m): "Invalid arguments: \(m)"
        case .notFound(let m): m
        case .declined: "The person declined this change. Don't try it again unless they ask."
        case .failed(let m): m
        }
    }
}

/// What `edit_note` writes for a match that occurs once: `oldText` replaced
/// by `newText` — except that whole lines `newText` restates on *both* sides
/// of the match are context, not text to add.
///
/// Asked to change one line of a list, Apple's on-device model sent that line
/// alone to replace and the lines around it, restated, as its replacement
/// (`- pears` → `- apples\n- plums\n- flour`) in four requests out of five;
/// taken as written, the note gained a second "- apples" and a second
/// "- flour". Restatement on one side only is left as written, because that is
/// also how an insertion looks — a line added before the match — and only
/// whole lines count, so a match inside a line is replaced where it stands.
/// Either way the person approves the change that results, shown as a diff.
nonisolated enum EditReplacement {
    static func once(_ oldText: String, with newText: String, in text: String) -> String {
        guard let match = text.range(of: oldText) else { return text }
        let region = restated(around: match, in: text, by: newText) ?? match
        return text.replacingCharacters(in: region, with: newText)
    }

    /// The match widened over the whole lines `newText` restates on each side
    /// of it — nil unless it restates at least one on both.
    private static func restated(around match: Range<String.Index>, in text: String,
                                 by newText: String) -> Range<String.Index>? {
        let lead = text[..<match.lowerBound]
        let trail = text[match.upperBound...]
        // Whole lines: the match begins one and ends one.
        guard lead.isEmpty || lead.last == "\n", trail.isEmpty || trail.first == "\n" else { return nil }

        // The most lines that both end the lead and begin `newText`.
        var start: String.Index?
        for i in newText.indices where newText[i] == "\n" {
            let lines = newText[...i]
            guard lead.hasSuffix(lines) else { continue }
            let from = lead.index(lead.endIndex, offsetBy: -lines.count)
            if from == lead.startIndex || lead[lead.index(before: from)] == "\n" { start = from }
        }
        // The most lines that both begin the trail and end `newText`.
        var end: String.Index?
        for i in newText.indices where newText[i] == "\n" {
            let lines = newText[i...]
            guard trail.hasPrefix(lines) else { continue }
            let to = trail.index(trail.startIndex, offsetBy: lines.count)
            if to == trail.endIndex || trail[to] == "\n" { end = to; break }
        }
        guard let start, let end else { return nil }
        return start..<end
    }
}

/// A note's sections, by its Markdown headings — outside fenced code, where a
/// `#` is a comment, not a heading.
nonisolated enum NoteSections {
    /// "Plans" for a line "## Plans", nil for any other line.
    ///
    /// A closing run of `#`s is the heading's own only after a space, as in
    /// CommonMark: "## Notes ###" is "Notes", and "## C#" is about C# — every
    /// `#` at the end was trimmed, so it was "C", and `read_note` could not be
    /// asked for the section by the name it lists.
    static func title(ofHeadingLine line: Substring) -> String? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count), line.dropFirst(hashes.count).first == " " else { return nil }
        var title = line.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
        if let last = title.lastIndex(where: { $0 != "#" }) {
            if title[last].isWhitespace { title = title[..<last].trimmingCharacters(in: .whitespaces) }
        } else {
            title = ""
        }
        return title.isEmpty ? nil : title
    }

    /// Every heading's title, in order.
    static func titles(in text: String) -> [String] {
        var out: [String] = []
        var inFence = false
        // At any line break, "\r\n" among them (`ToolContext.grep`).
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
            if !inFence, let title = title(ofHeadingLine: line) { out.append(title) }
        }
        return out
    }

    /// Where the section named `name` begins: the heading that is `name`
    /// (ignoring case and its `#`s), or failing that the first that contains it.
    static func start(of name: String, in text: String) -> String.Index? {
        let wanted = name.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        guard !wanted.isEmpty else { return nil }
        var contains: String.Index?
        var inFence = false
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(where: \.isNewline) ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
            } else if !inFence, let title = title(ofHeadingLine: line)?.lowercased() {
                if title == wanted { return lineStart }
                if contains == nil, title.contains(wanted) { contains = lineStart }
            }
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }
        return contains
    }
}
