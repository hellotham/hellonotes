//
//  CloudPrefs.swift
//  HelloNotes
//
//  Mirrors a small set of UserDefaults *preference* keys through iCloud's
//  key-value store (`NSUbiquitousKeyValueStore`) so settings follow the user
//  across devices. Prefs only — never note content, never secrets (those stay
//  in the Keychain / the file system). The 1 MB / 1024-key limits are ample.
//
//  Requires the iCloud (Key-Value storage) capability + the
//  `com.apple.developer.ubiquity-kvstore-identifier` entitlement.
//
//  **What the person set, never what a launch was handed.** Only the app's own
//  domain is pushed and compared with (`ownValues`), and only a value of the
//  kind the app writes is pulled (`isSetting`). `object(forKey:)` reads the
//  launch's arguments first, and a capture session passes the settings it
//  draws with as arguments — so `window-parity.sh`'s `-textScale 1` went to
//  iCloud as the person's text size, and the next launch pulled it into their
//  own settings, on every device it reached (2026-11-22). A value that is not
//  a setting is put right from this device's own when it is pulled.
//

import Foundation
import os

@MainActor
final class CloudPrefs {
    static let shared = CloudPrefs()

    /// One line when a repair happens (`pullFromCloud`) — rare, and worth
    /// being able to see in `log show` afterwards.
    nonisolated private static let log = Logger(subsystem: "com.hellotham.HelloNotes", category: "CloudPrefs")

    private let store = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    /// Reentrancy guard so a cloud→local apply doesn't echo back as a push.
    private var isApplyingRemote = false

    /// Posted after a cloud→local pull actually changed something, naming the
    /// keys in `userInfo[changedKeysKey]`.
    ///
    /// It exists because a pull can arrive *after* the object that read the
    /// value: `AppearanceSettings` reads UserDefaults once, in `init()`, and is
    /// built at `HelloNotesApp.swift:19` — before `start()` is called at :39, and
    /// before any later `didChangeExternallyNotification`. Writing the defaults
    /// is therefore not enough to make a pulled setting *take effect*; whoever
    /// cached it has to be told to re-read.
    static let didPullFromCloud = Notification.Name("HelloNotesCloudPrefsDidPull")
    /// `userInfo` key on `didPullFromCloud`: `[String]` of the keys that changed.
    static let changedKeysKey = "changedKeys"

    /// Value-only preference keys to mirror (no secrets, no note content, no
    /// device-specific bookmarks).
    ///
    /// The list is the contract, so it has to name the keys the app *writes*.
    /// It previously carried four that exist nowhere in the codebase
    /// ("appAppearance", "appAccentColor", "editorFontSize" — which is a
    /// computed property, not a stored default — and "newEditorEnabled") while
    /// omitting every key `AppearanceSettings` actually persists, so the
    /// appearance settings this file promises to carry across devices were the
    /// one group it never carried.
    private let keys = [
        // Appearance (AppearanceSettings)
        "appearanceMode", "accentChoice", "customAccentHex",
        "textScale", "increaseContrast",
        "readingWidth", "editorWidth", "wrapGuide", "showInlineTitle",
        "noteSortOrder",
        // Folders (GeneralSettingsView / iOSSettingsView)
        "dailyNoteFolder", "dailyDateFormat", "templatesFolder", "attachmentFolder",
        // Editor view mode. One key: the two-key split was a defect, not a
        // policy — see the note in `HelloNotesCommands`. An iPad that had a
        // stored `iosEditorViewMode` reverts once to Edit, which is where a
        // fresh install starts anyway.
        "editorViewMode",
    ]

    private init() {}

    /// Begin syncing: pull once, then keep local ⇄ cloud in step.
    func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudChangedExternally(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store)
        NotificationCenter.default.addObserver(
            self, selector: #selector(localChanged),
            name: UserDefaults.didChangeNotification, object: defaults)
        store.synchronize()
        pullFromCloud()
    }

    // NOTE: `@objc` selectors are invoked by the ObjC runtime on the *poster's*
    // thread — actor isolation isn't enforced across that boundary, and
    // `didChangeExternallyNotification` is documented as arriving on a
    // system-chosen background queue. Both handlers therefore hop onto the main
    // actor before touching `isApplyingRemote` / UserDefaults, so the reentrancy
    // guard actually holds (and Swift 6 strict concurrency won't trap).
    @objc private func localChanged() {
        Task { @MainActor [self] in
            guard !isApplyingRemote else { return }   // don't echo a cloud→local apply back
            push()
        }
    }

    /// Push the current local prefs to the cloud (call on background / quit) —
    /// what the person set, and nothing a launch was handed (`ownValues`).
    func push() {
        for (key, value) in Self.pushable(ownValues(), keys: keys) {
            store.set(value, forKey: key)
        }
        store.synchronize()
    }

    /// What the person set: the app's own domain, never the search list.
    /// `object(forKey:)` answers from the launch's arguments first, so a
    /// capture session's `-textScale 1` was pushed to iCloud as the person's
    /// text size, and the next launch pulled it into their own settings — and
    /// so did every device the store reached (2026-11-22). A launch argument
    /// is that launch's alone.
    private func ownValues() -> [String: Any] {
        guard let name = Bundle.main.bundleIdentifier else { return [:] }
        return defaults.persistentDomain(forName: name) ?? [:]
    }

    /// The keys written as numbers and as switches; every other is a string.
    private static let numeric: Set<String> = ["textScale", "wrapGuide", "increaseContrast", "showInlineTitle"]

    /// Whether `value` is what the app writes for `key`: a number (a switch is
    /// one) where it writes one, a string where it writes a string. A launch
    /// argument is always a string — `-textScale 1` is `"1"`, `-increaseContrast
    /// NO` is `"NO"` — so a string under a number's key came from a launch, not
    /// from a person. Read back, it is not even the same setting:
    /// `showInlineTitle` is read `as? Bool ?? true`, and `"NO"` turned the
    /// title on.
    nonisolated static func isSetting(_ value: Any, for key: String) -> Bool {
        numeric.contains(key) ? value is NSNumber : value is String
    }

    /// The values `own` holds for `keys` that are settings (`isSetting`).
    nonisolated static func pushable(_ own: [String: Any], keys: [String]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in keys { if let value = own[key], isSetting(value, for: key) { out[key] = value } }
        return out
    }

    @objc private func cloudChangedExternally(_ note: Notification) {
        // Only apply the keys that actually changed (or all, on initial sync).
        Task { @MainActor [self] in pullFromCloud() }
    }

    private func pullFromCloud() {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        let own = ownValues()
        var changed: [String] = []
        var repaired: [String] = []
        for key in keys {
            guard let value = store.object(forKey: key) else { continue }
            // Not a setting: a launch's argument an earlier build pushed as
            // the person's. The person's own goes back over it — which is
            // what puts it right on their other devices too — or, with none
            // here, it is taken away.
            guard Self.isSetting(value, for: key) else {
                if let mine = Self.pushable(own, keys: [key])[key] {
                    store.set(mine, forKey: key)
                } else {
                    store.removeObject(forKey: key)
                }
                repaired.append(key)
                continue
            }
            // Write only what differs from what the person set. Setting an
            // identical value still posts `UserDefaults.didChangeNotification`,
            // and `localChanged` hops to the main actor *after* the `defer`
            // above has cleared the guard — so an unconditional write echoes
            // straight back out as a push.
            if let current = own[key] as? NSObject,
               let incoming = value as? NSObject,
               current.isEqual(incoming) { continue }
            defaults.set(value, forKey: key)
            changed.append(key)
        }
        if !repaired.isEmpty {
            store.synchronize()
            // Key names only — the values are the person's.
            Self.log.notice("Put the person's own back over \(repaired.count) synced key(s) holding a launch argument: \(repaired.joined(separator: ", "), privacy: .public)")
        }
        guard !changed.isEmpty else { return }
        NotificationCenter.default.post(name: Self.didPullFromCloud, object: self,
                                        userInfo: [Self.changedKeysKey: changed])
    }
}
