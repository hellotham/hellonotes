//
//  IntelligenceAvailability.swift
//  HelloNotes
//
//  Created by Chris Tham on 15/9/2026.
//
//  Whether a model can run, and — when it cannot — a sentence that tells the
//  person what to do about it.
//

import Foundation
import FoundationModels

nonisolated enum IntelligenceAvailability: Equatable, Sendable {
    case available
    case unavailable(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// The explanation, or `nil` when there is nothing to explain.
    var reason: String? {
        if case .unavailable(let why) = self { return why }
        return nil
    }
}

extension IntelligenceAvailability {
    /// Where the person turns Apple Intelligence on, named the way their
    /// platform names it. Telling an iPad user to open System Settings sends
    /// them looking for an app they do not have.
    private static var settingsName: String {
        #if os(macOS)
        "System Settings"
        #else
        "Settings"
        #endif
    }

    init(_ availability: SystemLanguageModel.Availability) {
        switch availability {
        case .available:
            self = .available
        case .unavailable(.deviceNotEligible):
            self = .unavailable("This device doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            self = .unavailable("Turn on Apple Intelligence in \(Self.settingsName) to use this.")
        case .unavailable(.modelNotReady):
            self = .unavailable("Apple Intelligence is still getting its model ready. Try again shortly.")
        case .unavailable:
            self = .unavailable("The on-device model is unavailable right now.")
        }
    }

    init(_ availability: PrivateCloudComputeLanguageModel.Availability) {
        switch availability {
        case .available:
            self = .available
        case .unavailable(.deviceNotEligible):
            self = .unavailable("Private Cloud Compute isn't available on this device.")
        case .unavailable(.systemNotReady):
            self = .unavailable("Private Cloud Compute isn't ready yet. Check that Apple Intelligence is on in \(Self.settingsName), then try again.")
        case .unavailable:
            self = .unavailable("Private Cloud Compute is unavailable right now.")
        }
    }
}
