//
//  AIPlaceList.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  The AI place — decision 7's fourth compact tab, on both platforms.
//
//  It was `aiPlace`, a `private var` on `iOSContentView`, which is why the Mac's
//  compact shell had nothing to put in this tab and therefore no compact shell
//  at all. Everything it draws comes from `AIActions` and a handful of optional
//  closures, both of which each shell already builds for the menu bar — so this
//  is the same furniture, not a second AI surface.
//
//  Every row is disabled rather than hidden when it cannot apply, with a footer
//  saying which of "no note" or "no provider" is the reason. A row that vanishes
//  teaches you nothing; a row that is present and does nothing teaches you the
//  wrong thing.
//

import SwiftUI

struct AIPlaceList: View {
    /// The note-scoped actions, or nil when there is no note open *or* no
    /// provider that can answer. Both are reasons to disable, and the footer
    /// distinguishes them.
    var ai: AIActions?
    /// Whether there are notes to ask about at all.
    var canAsk: Bool
    var askLibrary: () -> Void
    /// Nil when there is no note to review links in.
    var reviewLinks: (() -> Void)?
    /// Nil when there is no collection to write the new note into.
    var compose: (() -> Void)?
    var assistant: () -> Void
    /// Nil where the platform reaches AI settings another way — the Mac has a
    /// Preferences tab, so it does not need a row here.
    var aiSettings: (() -> Void)?

    /// Whether a note is open, for the footer's wording. Supplied separately
    /// because `ai` is nil for two different reasons.
    var hasOpenNote: Bool = true

    var body: some View {
        List {
            Section {
                Button {
                    askLibrary()
                } label: {
                    Label("Ask Your Library", systemImage: "sparkles.rectangle.stack")
                }
                .disabled(!canAsk)

                Button {
                    compose?()
                } label: {
                    Label("New Note from a Prompt…", systemImage: "sparkles.square.filled.on.square")
                }
                .disabled(compose == nil)
            } footer: {
                Text("Answers are drawn from the notes you have open, with links back to them.")
            }

            Section {
                Button { ai?.summarize() } label: {
                    Label("Summarize", systemImage: "text.append")
                }
                Button { ai?.suggestTags() } label: {
                    Label("Suggest Tags", systemImage: "number")
                }
                Button { ai?.suggestLinks() } label: {
                    Label("Suggest Links", systemImage: "link.badge.plus")
                }
                Button { ai?.rewriteNote() } label: {
                    Label("Rewrite Note…", systemImage: "wand.and.stars")
                }
                Button { reviewLinks?() } label: {
                    Label("Review Links…", systemImage: "checklist")
                }
                .disabled(reviewLinks == nil)
            } header: {
                Text("This note")
            } footer: {
                if !hasOpenNote {
                    Text("Open a note to use these.")
                } else if ai == nil {
                    Text("No AI provider is configured. Set one up in AI Settings.")
                }
            }
            .disabled(ai == nil)

            Section {
                Button { assistant() } label: {
                    Label("Assistant", systemImage: "sparkles")
                }
                if let aiSettings {
                    Button { aiSettings() } label: {
                        Label("AI Settings…", systemImage: "brain")
                    }
                }
            }
        }
        .navigationTitle("AI")
    }
}
