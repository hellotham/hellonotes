//
//  AssistantHost.swift
//  HelloNotes
//
//  Created by Chris Tham on 16/8/2026.
//
//  The assistant, with its model, permission broker and skill store, pointed at
//  whichever collection is focused.
//
//  Extracted from `AuxiliaryWindows` when the assistant came to iOS. That file
//  is macOS-only for a good reason — it is about *windows*, which iOS does not
//  have — but the thing inside the window was never Mac-specific. So the
//  ownership lives here and each platform supplies its own container: a `Window`
//  scene on the Mac, a sheet on iOS.
//

import SwiftUI

struct AssistantHost: View {
    @Environment(Library.self) private var library
    @Environment(IntelligenceSettings.self) private var intelligenceSettings

    @State private var model: AssistantModel?
    @State private var permissions = PermissionBroker()
    @State private var skills = SkillStore()
    @State private var showSettings = false

    var body: some View {
        Group {
            if let model {
                AssistantView(model: model) { showSettings = true }
            } else {
                ProgressView()
            }
        }
        .sheet(isPresented: $showSettings) {
            IntelligenceSettingsView(settings: intelligenceSettings)
        }
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
