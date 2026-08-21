//
//  LinkReviewFlow.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  Review Links — one implementation, both shells.
//
//  Written twice, with the same shape and one difference that matters: the Mac
//  gathered proposals from `focused`, the iPad from the open note's *own*
//  collection. The iPad's was right, and its comment said why — the proposals
//  are character offsets into that note's text and are looked up in that
//  collection's index. With two collections open, the Mac reviewed a note from
//  one against the index of the other, and then reported the failure onto the
//  wrong collection's error banner.
//
//  That is the argument for extraction in miniature: the two copies did not
//  disagree because anyone decided they should. One of them was simply fixed and
//  the other was not, and nothing in the codebase could notice.
//
//  The re-derivation guard is the load-bearing part. A proposal is a range, and
//  a range only describes the text it was computed from. If the note changed
//  while the sheet was open, re-deriving would silently link *different words* —
//  so it refuses and says so. Repeating a review is cheap; a wrong link is a
//  wrong link in someone's notes.
//

import Foundation

@MainActor
enum LinkReviewFlow {

    /// A review in progress: what was proposed, and the text it was proposed
    /// against. One type, where there were two — `LinkReview` on the Mac and
    /// `LinkReviewRequest` on iOS, identical field for field.
    struct Request: Identifiable {
        let id = UUID()
        let proposals: [LinkProposal]
        /// The note's text at the moment the proposals were computed. The
        /// ranges are only valid against exactly this.
        let noteText: String
    }

    /// Gather link proposals for `text`.
    ///
    /// - Parameter collection: the note's **own** collection, never the focused
    ///   one. See the file comment.
    static func begin(text: String,
                      noteURL: URL?,
                      in collection: Collection?) async -> Request? {
        guard let collection else { return nil }
        let found = await collection.linkProposals(in: text, for: noteURL)
        return Request(proposals: found, noteText: text)
    }

    /// What applying the accepted links should do.
    enum Outcome: Equatable {
        /// Replace the note's text with this.
        case apply(String)
        /// Nothing to do — nothing was accepted.
        case nothing
        /// The note moved under the review; the ranges no longer describe it.
        case stale(message: String)
    }

    static let staleMessage =
        "The note changed while you were reviewing, so no links were added. Run Review Links again."

    /// Decide what accepting `accepted` means for `currentText`.
    ///
    /// Pure: the caller owns the buffer and the error banner, which is all that
    /// differed between the two shells once this moved out of them.
    static func apply(_ accepted: [LinkProposal],
                      reviewedText: String,
                      currentText: String) -> Outcome {
        guard !accepted.isEmpty else { return .nothing }
        guard currentText == reviewedText else { return .stale(message: staleMessage) }
        return .apply(LinkProposals.apply(accepted, to: currentText))
    }
}
