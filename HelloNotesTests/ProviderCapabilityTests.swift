//
//  ProviderCapabilityTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 16/8/2026.
//

import Testing
import Foundation
@testable import HelloNotes

/// The routing seam (`docs`: 1.3 §6). These pin the *shape* of the rule, not
/// any particular provider's numbers — the numbers are expected to move, and a
/// test that froze them would have to be edited every time a model improved,
/// which is exactly the maintenance burden this design exists to remove.
struct ProviderCapabilityTests {

    @Test func aFeatureNeedingNothingRunsAnywhere() {
        for kind in ProviderKind.allCases {
            #expect(IntelligenceNeeds().satisfied(by: kind.capabilities),
                    "\(kind) should satisfy an empty requirement")
        }
    }

    /// The one requirement no cloud provider can ever meet, however good it is.
    @Test func inlineCompletionRoutesOnlyToOnDeviceProviders() {
        for kind in ProviderKind.allCases {
            let satisfied = IntelligenceNeeds.inlineCompletion.satisfied(by: kind.capabilities)
            #expect(satisfied == kind.capabilities.onDevice,
                    "\(kind): on-device is \(kind.capabilities.onDevice) but routing said \(satisfied)")
        }
    }

    /// Tool use is not optional for deep research — it *is* deep research.
    @Test func deepResearchRequiresToolUse() {
        let noTools = ProviderCapabilities(inputBudget: .max, structuredOutput: true,
                                           toolUse: false, onDevice: false, isFree: false)
        #expect(!IntelligenceNeeds.deepResearch.satisfied(by: noTools))
    }

    /// A bigger context must never make a provider *less* eligible.
    @Test func raisingTheBudgetOnlyEverAddsCapability() {
        let small = ProviderCapabilities(inputBudget: 4_000, structuredOutput: true,
                                         toolUse: true, onDevice: true, isFree: true)
        var large = small
        large.inputBudget = 128_000
        let features: [IntelligenceNeeds] = [.summarise, .rewrite, .suggestTags,
                                             .suggestLinks, .askLibrary,
                                             .deepResearch, .inlineCompletion]
        for feature in features where feature.satisfied(by: small) {
            #expect(feature.satisfied(by: large))
        }
    }

    /// The property that makes the seam worth having: raising the on-device
    /// model's declared window is *all* it takes for a bigger feature to route
    /// there. If this ever fails, some call site has grown its own cap again.
    @Test func aBiggerOnDeviceWindowUnlocksAskLibraryWithNoOtherChange() {
        var caps = ProviderCapabilities.appleOnDevice
        #expect(!IntelligenceNeeds.askLibrary.satisfied(by: caps),
                "today's on-device window is expected to be below Ask Library's need")
        caps.inputBudget = IntelligenceNeeds.askLibrary.inputBudget
        #expect(IntelligenceNeeds.askLibrary.satisfied(by: caps))
    }

    /// On-device and free are separate axes: a local Ollama is both, a hosted
    /// model is neither, and nothing should assume they move together.
    @Test func onDeviceAndFreeAreIndependent() {
        #expect(ProviderKind.ollama.capabilities.onDevice)
        #expect(ProviderKind.ollama.capabilities.isFree)
        #expect(!ProviderKind.anthropic.capabilities.onDevice)
        #expect(!ProviderKind.anthropic.capabilities.isFree)
    }

    /// Every provider must declare a usable budget — a zero would silently
    /// truncate every prompt to nothing and look like a broken model.
    @Test func everyProviderDeclaresAWorkableBudget() {
        for kind in ProviderKind.allCases {
            #expect(kind.capabilities.inputBudget >= 2_000, "\(kind) budget too small")
        }
    }
}
