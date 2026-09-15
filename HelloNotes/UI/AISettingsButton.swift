//
//  AISettingsButton.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  "AI isn't available" — and, on iPad, no way to do anything about it.
//
//  The Assistant's empty state explains why its model can't run (Apple
//  Intelligence switched off, a model still downloading) and offers a way to
//  choose another. It used to offer `SettingsLink` inside `#if os(macOS)`,
//  because `SettingsLink` opens the `Settings` scene and iOS has no such scene.
//  So the iPad drew the explanation and no button: a screen whose entire purpose
//  is to send you somewhere, that sent nobody anywhere.
//
//  `SettingsLink` is a *View*, not an action, which is why this is a view and
//  not a `SettingsRoute.open()`. iOS presents AI settings as a sheet the shell
//  owns, so the other branch asks the shell for it.
//
//  Named `AISettingsButton`, not `OpenAISettingsButton`: a Swift type name is
//  compiled into the binary's metadata, and "OpenAI" is a string a reviewer's
//  scan for third-party AI services would find in an app that has none.
//

import SwiftUI

struct AISettingsButton: View {
    var title = "Open AI Settings…"

    var body: some View {
        #if os(macOS)
        SettingsLink { Text(title) }
            .buttonStyle(.borderedProminent)
        #else
        Button(title) {
            NotificationCenter.default.post(name: .hnShowAISettings, object: nil)
        }
        .buttonStyle(.borderedProminent)
        #endif
    }
}

extension Notification.Name {
    /// Ask the iOS shell to present AI settings. It owns the sheet because the
    /// sheet belongs to its scene.
    static let hnShowAISettings = Notification.Name("hn.settings.ai")
}
