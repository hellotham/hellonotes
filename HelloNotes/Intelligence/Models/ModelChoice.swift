//
//  ModelChoice.swift
//  HelloNotes
//
//  Created by Chris Tham on 15/9/2026.
//
//  Which language model does a job.
//
//  Three kinds, and only three, because that is everything Foundation Models can
//  reach from an app: Apple's on-device model, Apple's Private Cloud Compute
//  model, and an open model running in-process through MLX. HelloNotes used to
//  carry sixteen bespoke provider integrations — API keys, model discovery,
//  per-provider context tables — and every one of them is gone. What replaced
//  them is one `LanguageModelSession` API over three models, which is also what
//  lets the app ship in regions where third-party AI services cannot.
//
//  Deliberately *not* a list of model names. The on-device model is whichever
//  AFM 3 variant this hardware runs (Core, or Core Advanced on the most capable
//  Apple silicon), and the SDK decides that — `SystemLanguageModel.variant` is
//  read-only and no initializer takes one. Private Cloud Compute is one model
//  from an app's point of view. Naming a model the app cannot select would be a
//  setting that does nothing — so the on-device model is shown as "System", the
//  name Apple's `fm` tool gives it.
//

import Foundation

nonisolated enum ModelChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Apple's on-device model. Nothing leaves the device.
    case onDevice
    /// Apple's server model, reached through Private Cloud Compute.
    case privateCloud
    /// An open model downloaded to this device and run with MLX.
    case mlx

    var id: String { rawValue }

    /// Whether the text a request carries stays on this device.
    ///
    /// The one question the Human Interface Guidelines say a person must always
    /// be able to answer about an AI feature: where does my data go?
    var runsOnDevice: Bool {
        switch self {
        case .onDevice, .mlx: true
        case .privateCloud: false
        }
    }

    /// A stored value, read leniently. An unrecognised string — a future
    /// build's choice, or a hand-edited preference — falls back rather than
    /// failing, because a settings read that throws is a settings reset.
    init(stored: String?, fallback: ModelChoice) {
        self = stored.flatMap(ModelChoice.init(rawValue:)) ?? fallback
    }
}

/// How hard a reasoning model thinks before it answers.
///
/// Only Private Cloud Compute and some MLX models reason; the on-device model
/// does not, and asking it to is an error rather than a no-op — so the setting
/// is carried here and applied only where the model declares the capability.
nonisolated enum ReasoningChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, light, moderate, deep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .light: "Light"
        case .moderate: "Moderate"
        case .deep: "Deep"
        }
    }
}

/// How the model picks the next token — `GenerationOptions.SamplingMode`, as
/// the framework offers it and no further.
///
/// Automatic is the framework's own default (`nil`): it decides. Greedy always
/// takes the likeliest token, which is the same answer every time. Top-k and
/// top-p narrow the pool the model samples from, by count or by probability
/// mass, each with an optional seed that makes a run repeatable.
nonisolated enum SamplingChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, greedy, topK, topP

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .greedy: "Greedy"
        case .topK: "Top-k"
        case .topP: "Top-p"
        }
    }

    /// What it means, in the one line a settings row can carry.
    var caption: String {
        switch self {
        case .automatic: "The model decides how to sample."
        case .greedy: "Always the likeliest next word — the same answer every time."
        case .topK: "Sample from the k likeliest words."
        case .topP: "Sample from the likeliest words that add up to this probability."
        }
    }
}

/// One entry in a model picker. Apple's models are entries by where they run;
/// MLX models are entries by which model, because more than one can be on the
/// device — identified by `MLXLocalModel.id`.
nonisolated enum ModelOption: String, Hashable, Identifiable, CaseIterable, Sendable {
    case onDevice
    case privateCloud
    /// The MLX model in use. **One**, not one per role: only one MLX model is
    /// loaded at a time, so a role picker offering a different MLX model for
    /// the Assistant and the writing tools would be offering something the app
    /// cannot do — pick one and the other silently followed. Which model that
    /// is belongs to the MLX section, where the models are.
    case mlx

    var id: String { rawValue }

    var choice: ModelChoice {
        switch self {
        case .onDevice: .onDevice
        case .privateCloud: .privateCloud
        case .mlx: .mlx
        }
    }
}
