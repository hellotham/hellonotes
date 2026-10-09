//
//  AssistantHost.swift
//  HelloNotes
//
//  Created by Chris Tham on 16/8/2026.
//
//  The assistant, with its model, permission broker and skill store, pointed at
//  whichever collection is focused.
//
//  Extracted from `AuxiliaryWindows` when the assistant came to iOS, where it
//  lived in a `Window` scene on the Mac and a sheet on iOS. It was one of the
//  right panel's views for a while; it is one of the collection's tools now,
//  opened from the sidebar as a tab beside the notes (`CollectionTool`), and
//  the ownership stays here.
//

import SwiftUI

struct AssistantHost: View {
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

    @State private var model: AssistantModel?
    @State private var permissions = PermissionBroker()
    @State private var skills = SkillStore()

    var body: some View {
        presentingSettings(Group {
            if let model {
                AssistantView(model: model) { openAISettings() }
            } else {
                ProgressView()
            }
        })
        .task {
            if model == nil {
                model = AssistantModel(settings: intelligenceSettings)
            }
            syncFocusedServices()
        }
        .onChange(of: library.focusedID) { _, _ in syncFocusedServices() }
        .onChange(of: library.allNotes) { _, _ in
            if let c = library.focused { skills.refresh(from: c.notes) }
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
    /// Presented from here, not the shell: the Assistant, a view of the panel,
    /// has no route to the shell's own Settings sheet — the old "Open AI
    /// Settings…" button here did nothing on iPad for want of one.
    private func presentingSettings(_ content: some View) -> some View {
        content.sheet(isPresented: $showSettings) {
            AppSettingsView(intelligenceSettings: intelligenceSettings, appearance: appearance,
                            git: library.focused?.git, accounts: gitAccounts, store: store,
                            page: .ai)
        }
    }
    #endif

    /// Point the assistant's tools and conversation at the focused collection.
    private func syncFocusedServices() {
        guard let model, let c = library.focused else { return }
        skills.refresh(from: c.notes)
        model.toolContext = ToolContext(
            collection: c, search: c.search, git: c.git, permissions: permissions,
            settings: intelligenceSettings, skills: skills)
        model.sessionStore = ChatSessionStore(collectionURL: c.rootURL)
    }
}
