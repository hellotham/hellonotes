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
//
//  Failures the model can recover from — a note that isn't there, an edit that
//  doesn't match — are thrown as `ToolError` and turned into a sentence for the
//  model by the tool, rather than aborting the whole response.
//

import Foundation

@MainActor
final class ToolContext {
    let collection: Collection
    let search: CollectionSearchModel
    let git: GitService
    let permissions: PermissionBroker
    /// For tools that start sessions of their own (deep research).
    var settings: IntelligenceSettings?
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

    func listNotes(limit: Int) -> String {
        let all = notes
        guard !all.isEmpty else { return "The collection is empty." }
        let shown = all.prefix(max(1, limit))
        var lines = shown.map { "- \($0.title)  (\(relativePath($0)))" }
        if all.count > shown.count {
            lines.append("… and \(all.count - shown.count) more. Use search_notes to find a specific note.")
        }
        return lines.joined(separator: "\n")
    }

    func readNote(_ query: String, maxCharacters: Int) async throws -> String {
        let note = try require(query)
        let body = try await readContents(of: note)
        let shown = body.count > maxCharacters
            ? String(body.prefix(maxCharacters)) + "\n… (truncated: \(body.count - maxCharacters) more characters)"
            : body
        return "# \(note.title)  (\(relativePath(note)))\n\n\(shown)"
    }

    func searchNotes(_ query: String, limit: Int) async -> String {
        let hits = await Array(search.fullTextResults(query: query).prefix(max(1, limit)))
        guard !hits.isEmpty else { return "No notes matched “\(query)”." }
        return hits.map { hit in
            let snippet = hit.snippet.replacingOccurrences(of: "\n", with: " ")
            return "- \(hit.note.title)  (\(relativePath(hit.note)))\n  \(snippet)"
        }.joined(separator: "\n")
    }

    /// Lines containing `pattern`, across every note. The reads happen off the
    /// main actor in one pass; the list of notes is taken here, where it lives.
    ///
    /// Only notes already on this device are searched, as `search_notes` does:
    /// reading an online-only note downloads it, so one call — and the model
    /// makes several at once — would pull a whole cloud vault local. The result
    /// says how many were left out, so the model doesn't take "no matches" as
    /// the whole answer.
    func grep(_ pattern: String, limit: Int) async -> String {
        let needle = pattern.lowercased()
        let targets = notes
        let notOnDevice = targets.filter(\.isOnlineOnly).count
        let limit = max(1, limit)
        let found = await offMain { () -> [String] in
            var out: [String] = []
            for target in targets {
                guard FileIO.hasContentAvailable(target),
                      let text = try? FileIO.readString(at: target.fileURL) else { continue }
                for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where line.lowercased().contains(needle) {
                    out.append("\(target.title):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
                    if out.count > limit { return out }
                }
            }
            return out
        }
        let skipped = notOnDevice > 0
            ? "\n(\(notOnDevice) notes that haven't downloaded to this device weren't searched.)"
            : ""
        guard !found.isEmpty else { return "No matches for “\(pattern)”." + skipped }
        if found.count > limit {
            return found.prefix(limit).joined(separator: "\n") + "\n… (stopped at \(limit) matches)" + skipped
        }
        return found.joined(separator: "\n") + skipped
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
        commit("assistant: create \(rel)")
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
        let after = replaceAll
            ? before.replacingOccurrences(of: oldString, with: newString)
            : before.replacingFirst(oldString, with: newString)
        let rel = relativePath(note)

        guard await permissions.confirm(
            title: "Edit note",
            detail: "Apply an edit to “\(rel)”",
            diff: EditDiff(path: rel, before: before, after: after))
        else { throw ToolError.declined }

        try await save(after, to: note, replacing: before)
        commit("assistant: edit \(rel)")
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
        commit("assistant: rewrite \(rel)")
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
        commit("assistant: delete \(rel)")
        return "Moved “\(rel)” to the Trash."
    }

    /// Replace the text the person approved a change to — and only that text.
    private func save(_ text: String, to note: Note, replacing before: String) async throws {
        let url = note.fileURL
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

    /// Commit the change if the collection is a Git repository — every
    /// Assistant edit is its own commit, so each one can be undone on its own.
    ///
    /// **Not awaited.** Git runs one operation at a time, so a commit waits
    /// behind whatever is in flight — a push to a slow remote can take minutes —
    /// and the tool's result, and with it the Assistant's reply, waited too. The
    /// change is already saved; the commit follows it in order. The commit
    /// refreshes the status in its own queue slot, so nothing else is needed.
    func commit(_ message: String) {
        guard git.status.isRepository else { return }
        Task { [git] in await git.commitAll(message: message) }
    }
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

private extension String {
    /// Replace the first occurrence of `target` with `replacement`.
    func replacingFirst(_ target: String, with replacement: String) -> String {
        guard let range = range(of: target) else { return self }
        return replacingCharacters(in: range, with: replacement)
    }
}
