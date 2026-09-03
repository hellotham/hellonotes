//
//  CollectionStatusStrips.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  The two thin bars that say when the app cannot answer truthfully.
//
//  Both were `private` inside `MacContentView`, so the iPad had neither. A
//  collection that went unavailable said nothing there — the note simply
//  stopped saving — and a search over a half-built index came back short with
//  no indication that it had.
//
//  The second is the one that matters most, and the reason is in its own
//  comment on the Mac: **a false negative is the most damaging thing a
//  knowledge tool can produce, because it is invisible by construction.** You
//  cannot notice the note that did not come back. Someone searching a vault
//  whose index is behind has to be told at the point they are about to conclude
//  the note does not exist — and on iPad they never were.
//

import SwiftUI

/// One status row: a symbol, a sentence, and something to do about it.
struct ConditionStrip<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let message: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                trailing()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4))
            Divider()
        }
    }
}

/// Why the collection you are reading cannot be trusted right now: it is
/// unavailable, it is being scanned, or its index is behind the folder.
struct CollectionConditionBar: View {
    let collection: Collection?
    /// Only shown while a note is open — the bar explains the note's own
    /// condition, and above an empty editor it would be explaining nothing.
    let hasSelection: Bool
    let onRetry: (Collection) -> Void
    /// Re-grant access via a fresh folder pick — the recovery for a bookmark
    /// that no longer resolves at all, which "Try Again" cannot fix because it
    /// only ever re-tries the same dead grant.
    let onLocate: (Collection) -> Void

    var body: some View {
        if let collection {
            // **A scan is the collection's condition, not the note's.**
            //
            // Everything here used to require `hasSelection`, on the reasoning
            // that the bar explains the open note. That is true of the stale and
            // unavailable cases and exactly wrong for a scan: you open a
            // collection, no note is selected yet, and the one moment the app
            // most needs to say "this is going to take a while" was the one
            // moment the strip was suppressed. On a large cloud vault that ran
            // for minutes with nothing on screen but a spinner in the sidebar.
            if collection.showsScanProgress, let scan = collection.scanProgress {
                ScanProgressStrip(collection: collection, scan: scan)
            } else if let summary = collection.lastScanSummary {
                ConditionStrip(symbol: summary.wasCancelled ? "stop.circle" : "checkmark.circle",
                               tint: .secondary,
                               message: summary.wasCancelled
                                   ? "Stopped scanning \(collection.name) — \(summary.notes.formatted()) notes found so far."
                                   : "Scanned \(collection.name) — \(summary.notes.formatted()) notes in \(summary.folders.formatted()) folders.") {
                    EmptyView()
                }
            }
        }
        if let collection, hasSelection {
            if case .unavailable(let reason) = collection.state {
                ConditionStrip(symbol: "exclamationmark.triangle.fill", tint: .orange,
                               message: "\(collection.name) is unavailable — \(reason.explanation)") {
                    Button("Try Again") { onRetry(collection) }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    Button("Locate…") { onLocate(collection) }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            } else if let reason = collection.staleReason, !collection.showsScanProgress {
                // The wording is the reason's, not this view's. Three surfaces
                // used to phrase this independently and all three said a scan
                // was running — which for an unreadable folder is simply untrue,
                // and left a banner nothing could clear.
                ConditionStrip(symbol: reason.symbol,
                               tint: reason.isPermanent ? .orange : .secondary,
                               message: "\(collection.name): \(reason.explanation)") {
                    if reason.isPermanent {
                        Button("Rescan") { collection.rescan() }
                            .font(.caption)
                            .buttonStyle(.borderless)
                    } else {
                        EmptyView()
                    }
                }
            }
        }
    }
}

/// Say when search results are incomplete, at the point they are read.
///
/// Marking the collection row alone would not do: see the note at the top of
/// this file about false negatives.
struct SearchCompletenessNotice: View {
    let collections: [Collection]
    let isSearching: Bool

    /// Collections that cannot answer a search truthfully right now: the index
    /// is behind the folder, or the folder cannot be read at all.
    private var partial: [Collection] {
        collections.filter { !$0.isAvailable || $0.hasIncompleteIndex }
    }

    /// Collections holding items whose content a search cannot read because
    /// they have not been downloaded.
    private var unreadable: [Collection] {
        collections.filter { $0.notLocalCount > 0 }
    }

    var body: some View {
        if isSearching {
            if !partial.isEmpty {
                let names = partial.map(\.name).joined(separator: ", ")
                ConditionStrip(
                    symbol: "exclamationmark.circle.fill", tint: .orange,
                    message: "These results may be incomplete — \(names) "
                           + "\(partial.count == 1 ? "is" : "are") not fully indexed."
                ) { EmptyView() }
            }
            // Content search deliberately skips files that are not downloaded,
            // so a query never quietly pulls a whole account local. That
            // default is right — but a default is not the same as the only
            // option, and without a way past it the omission is a wall rather
            // than a choice.
            if !unreadable.isEmpty {
                let total = unreadable.reduce(0) { $0 + $1.notLocalCount }
                ConditionStrip(
                    symbol: "icloud.and.arrow.down", tint: .secondary,
                    message: "\(total) item\(total == 1 ? " isn't" : "s aren't") downloaded, "
                           + "so their contents aren't searched."
                ) {
                    Button("Download and Search") {
                        let targets = unreadable
                        Task { for collection in targets { await collection.downloadAllForSearch() } }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

/// What a scan is doing, while it does it.
///
/// **A spinner is the wrong instrument for minutes.** A large cloud vault can
/// walk for several of them, and an indeterminate spinner says only "something
/// is happening" — it cannot distinguish progress from a hang, which is the one
/// question someone waiting actually has. This shows the work itself: a bar, the
/// counts, and the folder currently being read.
///
/// The bar is **determinate when it can honestly be**. `WalkProgress.fraction`
/// is non-nil only when a previous complete run measured this tree, so a first
/// scan cannot know its own size and does not pretend to — it shows an
/// indeterminate bar with rising counts, which is a true statement about an
/// unknown total. Claiming a percentage we cannot compute would be worse than
/// the spinner it replaces.
struct ScanProgressStrip: View {
    let collection: Collection
    let scan: WalkProgress

    /// "1,240 notes in 86 folders", and the folders left when we know them.
    private var counts: String {
        var parts = ["\(scan.itemsSeen.formatted()) items"]
        if scan.directoriesVisited > 0 {
            parts.append("\(scan.directoriesVisited.formatted()) folders read")
        }
        if scan.directoriesRemaining > 0 {
            parts.append("\(scan.directoriesRemaining.formatted()) to go")
        }
        return parts.joined(separator: " · ")
    }

    /// The tail of the path being read — the whole path is too long for a strip
    /// and the leading components are the same for every row anyway.
    private var where_: String? {
        let tail = scan.currentPath.split(separator: "/").suffix(2).joined(separator: "/")
        return tail.isEmpty ? nil : tail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Scanning \(collection.name)")
                        .font(.caption.weight(.medium))
                    Text(counts)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let fraction = scan.fraction {
                    ProgressView(value: min(max(fraction, 0), 1))
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                if let where_ {
                    Text(where_)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Button("Stop") { collection.cancelScan() }
                .font(.caption)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scanning \(collection.name). \(counts).")
    }
}
