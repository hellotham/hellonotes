//
//  AssistantHost.swift
//  HelloNotes
//
//  Created by Chris Tham on 16/8/2026.
//
//  The Assistant's tab: the conversation of the collection the window's
//  sidebar has selected, and the Settings it opens.
//
//  Extracted from `AuxiliaryWindows` when the assistant came to iOS, where it
//  lived in a `Window` scene on the Mac and a sheet on iOS. It was one of the
//  right panel's views for a while; it is one of the collection's tools now,
//  opened from the sidebar as a tab beside the notes (`CollectionTool`). The
//  conversation is the library's (`Library.assistant(for:settings:)`), not
//  this view's: it owned the model, the approvals and the skills, and a note
//  shown in the tab's place took all three down with it.
//

import SwiftUI

struct AssistantHost: View {
    /// The collection the window's sidebar has selected, whose conversation
    /// this is — the sidebar's, as everything keyed on a collection is; it
    /// followed the library's focus, which every window shares.
    let collection: Collection?

    @Environment(Library.self) private var library
    @Environment(IntelligenceSettings.self) private var intelligenceSettings
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #else
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(GitAccountsStore.self) private var gitAccounts
    @Environment(StoreService.self) private var store
    @State private var showSettings = false
    #endif

    var body: some View {
        let model = library.assistantIfMade(for: collection)
        presentingSettings(Group {
            if let model {
                AssistantView(model: model) { openAISettings() }
            } else {
                ProgressView()
            }
        })
        // Made in a task, not while drawing: making one reads the kept
        // conversation from disk. The library's list is observed, so this
        // draws again when it has.
        .task(id: collection?.id) {
            _ = library.assistant(for: collection, settings: intelligenceSettings)
        }
        .onChange(of: collection?.notes) { _, notes in
            if let notes { model?.toolContext?.skills?.refresh(from: notes) }
        }
    }

    /// Settings, at its AI page: the Settings window on the Mac, the Settings
    /// sheet over the Assistant on iOS.
    private func openAISettings() {
        #if os(macOS)
        UserDefaults.standard.set(SettingsPage.ai.rawValue, forKey: SettingsPage.storageKey)
        openSettings()
        #else
        showSettings = true
        #endif
    }

    #if os(macOS)
    /// Nothing to present: the Mac opens its Settings window.
    private func presentingSettings(_ content: some View) -> some View { content }
    #else
    /// Presented from here, not the shell: the Assistant, a tab beside the
    /// notes, has no route to the shell's own Settings sheet — the old "Open
    /// AI Settings…" button here did nothing on iPad for want of one.
    private func presentingSettings(_ content: some View) -> some View {
        content.sheet(isPresented: $showSettings) {
            AppSettingsView(intelligenceSettings: intelligenceSettings, appearance: appearance,
                            git: collection?.git, accounts: gitAccounts, store: store,
                            page: .ai)
        }
    }
    #endif
}
