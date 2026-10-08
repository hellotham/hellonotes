//
//  ReviewLinksView.swift
//  HelloNotes
//
//  Created by Chris Tham on 16/8/2026.
//
//  Walking a note's link proposals one at a time: **Link · Skip · Never**.
//
//  The spell-check metaphor, on purpose. Mac users have known it for thirty
//  years, it makes "how many are left" and "what have I decided" obvious without
//  explanation, and — the part that actually matters — it shows *context*. The
//  same phrase can deserve a link in one paragraph and not the next, so a
//  decision made against a bare list of words is a decision made blind. Both
//  sides are shown: the sentence the phrase sits in, and the opening of the note
//  it would point at.
//
//  Nothing is written until the review ends. Accepting a link mid-review would
//  shift every later proposal's range — so decisions accumulate, and the whole
//  set applies at once as a single undoable edit.
//

import SwiftUI

struct ReviewLinksView: View {
    let proposals: [LinkProposal]
    /// The note being reviewed, for showing each phrase in its sentence.
    let noteText: String
    /// The opening lines of a target note, for judging whether the link is apt.
    ///
    /// `async`, because it reads the file. As a synchronous closure it was
    /// called from inside `body` — a *coordinated read on the main actor, on
    /// every body evaluation*, which against a File Provider can block the
    /// window for as long as the provider takes, repeatedly.
    var preview: (URL) async -> String
    /// Accepted proposals, applied by the host as one edit.
    var onFinish: ([LinkProposal]) -> Void
    /// "Never propose this again", persisted per collection.
    var onDecline: (LinkProposal) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var position = 0
    @State private var accepted: [LinkProposal] = []
    /// Loaded previews, keyed by target. Read once per note, not once per draw.
    @State private var previews: [URL: String] = [:]

    private var current: LinkProposal? {
        position < proposals.count ? proposals[position] : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ChromeDivider()
            if let current {
                review(current)
            } else {
                summary
            }
        }
        // The Mac's size, on both: `chromeSheetFrame` fits the iPad's sheet
        // to it, where `panelFrame` left the iPad's to the device.
        .chromeSheetFrame(width: 520, height: 460)
    }

    private var header: some View {
        HStack {
            Label("Review Links", systemImage: "link.badge.plus")
                .font(Chrome.Style.headline)
            Spacer()
            if !proposals.isEmpty {
                Text("\(min(position + 1, proposals.count)) of \(proposals.count)")
                    .font(Chrome.Style.caption)
                    .monospacedDigit()
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
            }
            Button("Close") { finish() }
                .keyboardShortcut(.cancelAction)
        }
        // 16 is the Mac's `.padding()`, said rather than asked for: the
        // default amount is platform-specific.
        .padding(16)
    }

    // MARK: - One proposal

    private func review(_ proposal: LinkProposal) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("IN THIS NOTE")
                    .font(Chrome.Style.caption2.weight(.semibold))
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                sentence(around: proposal)
                    .font(Chrome.Style.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Chrome.Colour.quaternaryLabel.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("WOULD LINK TO")
                    .font(Chrome.Style.caption2.weight(.semibold))
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                Text(proposal.targetTitle).font(Chrome.Style.headline)
                Text(previews[proposal.targetURL] ?? "Loading…")
                    .font(Chrome.Style.callout)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .task(id: proposal.targetURL) {
                        guard previews[proposal.targetURL] == nil else { return }
                        previews[proposal.targetURL] = await preview(proposal.targetURL)
                    }
            }

            Spacer(minLength: 0)

            HStack {
                Button("Link") { accept(proposal) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(ChromePushStyle(prominent: true))
                Button("Skip") { advance() }
                // Destructive-ish, and the only decision here that persists past
                // this sheet, so it is last and unemphasised.
                Button("Never") {
                    onDecline(proposal)
                    advance()
                }
                Spacer()
            }
        }
        .padding(16)
    }

    /// The phrase in its sentence, with the phrase itself emphasised — the
    /// context that makes the decision answerable.
    private func sentence(around proposal: LinkProposal) -> Text {
        let ns = noteText as NSString
        guard NSMaxRange(proposal.range) <= ns.length else { return Text(proposal.phrase) }
        // A window rather than a real sentence split: sentence tokenisation on a
        // note full of abbreviations gets this wrong often enough to be worse
        // than a generous margin.
        let start = max(0, proposal.range.location - 120)
        let end = min(ns.length, NSMaxRange(proposal.range) + 120)
        let before = ns.substring(with: NSRange(location: start, length: proposal.range.location - start))
        let after = ns.substring(with: NSRange(location: NSMaxRange(proposal.range),
                                               length: end - NSMaxRange(proposal.range)))
        let phrase = Text(proposal.phrase).bold().foregroundStyle(.tint)
        return Text("\(start > 0 ? "…" : "")\(before)\(phrase)\(after)\(end < ns.length ? "…" : "")")
    }

    // MARK: - Finished

    private var summary: some View {
        VStack(spacing: 8) {
            Image(systemName: accepted.isEmpty ? "checkmark.circle" : "link.badge.plus")
                .font(Chrome.Style.largeTitle)
                .foregroundStyle(Chrome.Colour.tertiaryLabel)
            Text(proposals.isEmpty ? "No Links to Review" : "Review Complete")
                .font(Chrome.Style.headline)
            Text(summaryDetail)
                .font(Chrome.Style.callout)
                .foregroundStyle(Chrome.Colour.secondaryLabel)
                .multilineTextAlignment(.center)
            Button(accepted.isEmpty ? "Done" : "Add \(accepted.count) Link\(accepted.count == 1 ? "" : "s")") {
                finish()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(ChromePushStyle(prominent: true))
            .padding(.top, 4)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summaryDetail: String {
        if proposals.isEmpty {
            return "Nothing in this note names another note without already linking it."
        }
        return accepted.isEmpty
            ? "Nothing was accepted, so the note is unchanged."
            : "\(accepted.count) of \(proposals.count) will be added when you continue."
    }

    // MARK: - Actions

    private func accept(_ proposal: LinkProposal) {
        accepted.append(proposal)
        advance()
    }

    private func advance() { position += 1 }

    /// Hand the accepted set to the host and close. Called by Close as well as
    /// by the summary's button: closing part-way through should keep the
    /// decisions already made rather than silently discarding them.
    private func finish() {
        onFinish(accepted)
        dismiss()
    }
}
