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

import Foundation

@MainActor
final class CloudPrefs {
    static let shared = CloudPrefs()

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

    /// Push the current local prefs to the cloud (call on background / quit).
    func push() {
        for key in keys where defaults.object(forKey: key) != nil {
            store.set(defaults.object(forKey: key), forKey: key)
        }
        store.synchronize()
    }

    @objc private func cloudChangedExternally(_ note: Notification) {
        // Only apply the keys that actually changed (or all, on initial sync).
        Task { @MainActor [self] in pullFromCloud() }
    }

    private func pullFromCloud() {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        var changed: [String] = []
        for key in keys {
            guard let value = store.object(forKey: key) else { continue }
            // Write only what differs. Setting an identical value still posts
            // `UserDefaults.didChangeNotification`, and `localChanged` hops to
            // the main actor *after* the `defer` above has cleared the guard —
            // so an unconditional write echoes straight back out as a push.
            if let current = defaults.object(forKey: key) as? NSObject,
               let incoming = value as? NSObject,
               current.isEqual(incoming) { continue }
            defaults.set(value, forKey: key)
            changed.append(key)
        }
        guard !changed.isEmpty else { return }
        NotificationCenter.default.post(name: Self.didPullFromCloud, object: self,
                                        userInfo: [Self.changedKeysKey: changed])
    }
}
