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

    /// Value-only preference keys to mirror (no secrets, no note content, no
    /// device-specific bookmarks).
    private let keys = [
        "iosEditorViewMode", "dailyNoteFolder", "dailyDateFormat",
        "templatesFolder", "attachmentFolder", "editorFontSize",
        "appAppearance", "appAccentColor", "newEditorEnabled",
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

    @objc private func localChanged() {
        guard !isApplyingRemote else { return }   // don't echo a cloud→local apply back
        push()
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
        pullFromCloud()
    }

    private func pullFromCloud() {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        for key in keys {
            if let value = store.object(forKey: key) { defaults.set(value, forKey: key) }
        }
    }
}
