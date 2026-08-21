//
//  OpenAISettingsButton.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  "Set up AI to get started" — and, on iPad, no way to.
//
//  The Assistant's empty state explains that a provider needs an API key and
//  then offered `SettingsLink` inside `#if os(macOS)`, because `SettingsLink`
//  opens the `Settings` scene and iOS has no such scene. So the iPad drew the
//  explanation and no button: a screen whose entire purpose is to send you
//  somewhere, that sent nobody anywhere.
//
//  `SettingsLink` is a *View*, not an action, which is why this is a view and
//  not a `SettingsRoute.open()`. iOS presents AI settings as a sheet the shell
//  owns, so the other branch asks the shell for it.
//

import SwiftUI

struct OpenAISettingsButton: View {
    var title = "Open AI Settings…"

    var body: some View {
        #if os(macOS)
        SettingsLink { Text(title) }
            .buttonStyle(.borderedProminent)
        #else
        Button(title) {
            NotificationCenter.default.post(name: .hnOpenAISettings, object: nil)
        }
        .buttonStyle(.borderedProminent)
        #endif
    }
}

extension Notification.Name {
    /// Ask the iOS shell to present AI settings. It owns the sheet because the
    /// sheet belongs to its scene.
    static let hnOpenAISettings = Notification.Name("hn.settings.ai")
}
