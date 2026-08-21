//
//  InlineCompletionModel.swift
//  HelloNotes
//
//  Created by Chris Tham on 16/8/2026.
//
//  The half of ghost text that is allowed to be slow, wrong, or absent.
//
//  The editor package knows only where the caret is and how to paint a string
//  next to it; everything about *which* string — the debounce, the provider,
//  the cancellation, the decision not to bother — lives here. That split is
//  what makes the feature cuttable: delete this file and the editor still
//  compiles, still runs its tests, and simply never has a suggestion to draw.
//
//  On-device only, and not as a preference. A cloud round trip cannot feel like
//  ghost text — by the time it lands the user has typed past the sentence it
//  was completing, and the suggestion is refused as stale anyway. So this asks
//  `IntelligenceNeeds.inlineCompletion`, whose `onDevice` flag exists for
//  exactly this feature and no other, and stays silent when the answer is no.
//  Silent rather than complaining: an editor that nags about a provider every
//  time you stop typing is worse than one that never completes.
//

//  Cross-platform. It was macOS-only until the iOS editor grew somewhere to
//  draw a ghost (`ChromeOverlayView`) and — the part that actually needed
//  deciding — an acceptance gesture that works without a keyboard: you tap the
//  ghost. ⌥⇥ and Esc are still there when a keyboard is attached. Nothing in
//  this file changed to make that true, which is the point of the split.

import Foundation
import MarkdownEditor

@MainActor
@Observable
final class InlineCompletionModel {

    /// Off by default. Ghost text is the most opinionated thing in the app —
    /// text appearing next to your cursor that you did not write — and a
    /// notebook is not an IDE, where the convention has already been accepted.
    ///
    /// Read straight from `UserDefaults` on every request rather than cached,
    /// so it agrees with the Settings toggle (`@AppStorage`, same key) without
    /// either side observing the other. Caching it meant turning ghost text off
    /// left every already-open editor still completing.
    static let enabledKey = "inlineCompletionEnabled"
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// How long the typing has to stop before asking.
    ///
    /// Long enough that ordinary typing never triggers a request, short enough
    /// to land inside a natural pause. Every keystroke cancels the pending one,
    /// so a paragraph typed straight through costs exactly zero requests.
    private static let debounce = Duration.milliseconds(450)

    /// Below this there is nothing to continue, and the model invents a topic.
    private static let minimumPrefix = 12

    private var task: Task<Void, Never>?

    /// Why ghost text cannot run, or `nil` when it can — so the settings row
    /// explains itself rather than appearing to do nothing.
    static func unavailableReason(_ intelligence: IntelligenceService) -> String? {
        if case .unavailable(let why) = intelligence.availability { return why }
        guard !intelligence.can(.inlineCompletion) else { return nil }
        return "\(intelligence.providerName) runs in the cloud. Completions have to be on-device to appear as you type."
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Debounce, ask, and offer the result — if it is still wanted by then.
    func request(_ context: InlineCompletionContext,
                 intelligence: IntelligenceService?,
                 proxy: EditorProxy) {
        task?.cancel()
        guard isEnabled,
              context.prefix.count >= Self.minimumPrefix,
              let intelligence, intelligence.can(.inlineCompletion) else {
            proxy.clearInlineSuggestion()
            return
        }

        task = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.debounce)
                let reply = try await intelligence.completeInline(
                    prefix: context.prefix, suffix: context.suffix)
                try Task.checkCancellation()
                guard self != nil else { return }
                // The view rejects anything that no longer matches the caret,
                // so a reply that lost the race is dropped rather than shown at
                // the wrong place — this only has to hand it over.
                proxy.showInlineSuggestion(InlineSuggestion.sanitise(reply), at: context.location)
            } catch {
                // Deliberately silent. A failed completion is a completion that
                // does not appear, which is the same thing the user sees when
                // the model had nothing to say — and an error banner every time
                // typing pauses would make the editor unusable.
                proxy.clearInlineSuggestion()
            }
        }
    }
}
