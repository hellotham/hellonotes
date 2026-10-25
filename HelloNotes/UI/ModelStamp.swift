//
//  ModelStamp.swift
//  HelloNotes
//
//  Where a result was made — on this device, or on Apple's Private Cloud
//  Compute.
//
//  **Recorded by the work, shown with the result.** Every AI feature runs on
//  the model chosen for it — the Settings default, or an Assistant
//  conversation's own — with one fallback, towards the device: Cloud (Apple)
//  with today's allowance spent runs on Local (Apple)
//  (`LanguageModels.serving`), and a request it refuses for the limit is
//  asked again there (`fallback(after:on:)`). So the stamp is the model that
//  made the result, as the work itself recorded it: `IntelligenceService.stamped`
//  for the writing tools, `DeepResearch.onModel` for Research, and the turn's
//  own for an Assistant reply. Not the model chosen now — the person can
//  switch while a result is on screen, and a conversation outlives a switch.
//  The report beside the result names the same model (`ResponseReport`).
//
//  Where a model is *chosen* for an operation: the Settings default for the
//  writing tools, and the Assistant's menu for its conversation
//  (`AssistantModel.conversationChoice`) — the person's decision, 2026-10-18.
//

import SwiftUI

/// The model a result came from, as it was when the work began.
nonisolated struct ModelStamp: Codable, Hashable, Sendable {
    /// Which kind of model made the result.
    let choice: ModelChoice
    /// The model's name — "Local (Apple)", "Cloud (Apple)", "Local (<MLX
    /// model>)" (`LanguageModels.title(of:)`), which says where it runs.
    let name: String
    /// The model asked first, when it refused and this one answered instead —
    /// Cloud (Apple) at its daily limit. What was sent to it had gone by then,
    /// so the result must not say nothing was. Optional, so a conversation
    /// kept before this decodes.
    let after: ModelChoice?

    init(choice: ModelChoice, name: String, after: ModelChoice? = nil) {
        self.choice = choice
        self.name = name
        self.after = after
    }

    var runsOnDevice: Bool { choice.runsOnDevice }

    /// What a result says about where it was made: the model's name, which
    /// leads with where it runs.
    var caption: String { name }

    var systemImage: String { runsOnDevice && after == nil ? "lock" : "lock.icloud" }

    /// The privacy line for the model, as the AI settings print it — or, after
    /// a refusal, what went where.
    var detail: String {
        guard after == .privateCloud else { return LanguageModels.privacySummary(of: choice) }
        return "Answered by \(name) after Cloud (Apple) reached today's limit. What had been sent to Apple's Private Cloud Compute isn't stored, and isn't accessible to Apple."
    }
}

/// "Cloud (Apple)" or "Local (Apple)", with a lock — under a result.
struct ModelStampLabel: View {
    let stamp: ModelStamp

    var body: some View {
        Label(stamp.caption, systemImage: stamp.systemImage)
            .font(Chrome.Style.caption2)
            .foregroundStyle(Chrome.Colour.secondaryLabel)
            .lineLimit(1)
            .help(stamp.detail)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stamp.after == .privateCloud
                                ? "Ran on \(stamp.name), after Cloud (Apple) reached its limit"
                                : "Ran on \(stamp.name)")
            .accessibilityIdentifier("ai.modelStamp")
    }
}
