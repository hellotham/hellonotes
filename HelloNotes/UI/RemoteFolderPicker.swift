//
//  RemoteFolderPicker.swift
//  HelloNotes
//
//  Created by Chris Tham on 25/8/2026.
//
//  Choose a folder from a signed-in cloud account, in the shape of a file
//  picker rather than a bespoke browser.
//
//  `RemoteBrowserView` — which still exists, and is still the right thing for
//  *reading and editing* a note straight off a provider — was doing double
//  duty as the way you added a collection, and it made a poor picker. It has a
//  sign-out button in the same row as the action, it opens notes into an
//  editor when you tap them, it can only add the folder you are currently
//  *inside* rather than one you can see, and it says "Add as Collection" where
//  every other folder-choosing surface in the app says "Open". Picking a
//  folder from Dropbox therefore looked and behaved like nothing else in the
//  app, including the panel you get for a folder on disk two menu items away.
//
//  So this borrows the *shape* of that panel — a path bar you can walk back
//  up, a list where folders are navigable and files are visible but inert, and
//  Cancel/Open in the bottom-right — without pretending to be a pixel copy of
//  it. Where it deliberately departs is the click: a single click descends,
//  as it does in the Files picker, rather than selecting a row for a second
//  click to open. See `targetName` for why — the faithful version had the
//  row's double-click recogniser eating the list's single click, which made
//  every folder look dead.
//

import SwiftUI

struct RemoteFolderPicker: View {
    @Bindable var model: RemoteBrowserModel
    /// Called once a collection has been added, so the host can dismiss.
    var onFinished: () -> Void
    /// Called the first time this store reports itself signed in, so a
    /// provisional account can be recorded only once it is real.
    var onAuthenticated: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    /// What Open would take: the folder currently being shown.
    ///
    /// There is deliberately **no row selection**. The first version of this
    /// mirrored the open panel — click to select, double-click to descend,
    /// Open takes the selection — and the row's double-click recogniser
    /// swallowed the `List`'s single click, so nothing highlighted and nothing
    /// happened: the folders read as dead. Navigating on a single click is
    /// what the Files picker does, needs no selection state at all, and leaves
    /// one unambiguous answer to "what does Open open".
    private var targetName: String { model.collectionName }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            content
            Divider()
            actionBar
        }
        .panelFrame(width: 560, height: 520)
        // Signing in is part of opening, not a separate screen to find.
        //
        // This used to be `loadRootIfNeeded()` alone, whose first line is
        // `guard isAuthenticated` — so arriving here without a token did
        // nothing at all and drew an empty folder. Someone who had just
        // chosen "Dropbox ▸ Sign in" got a blank list and no way forward,
        // which reads exactly like a provider with no files in it.
        .task {
            if model.isAuthenticated {
                await model.loadRootIfNeeded()
            } else {
                await model.connect()
            }
        }
        // Reported from `onChange`, **not** from the end of the `.task` above.
        //
        // A `.task` is cancelled when its view goes away, and the sheet goes
        // away as soon as a collection is added — so a line placed after the
        // `await` never ran, and an account that had genuinely signed in was
        // never recorded. The token was written (the store does that itself),
        // leaving credentials in the Keychain that no listed account owned:
        // the manager then offered "Sign in" for a provider already signed in.
        // A state change is not cancellable, so this fires either way.
        .onChange(of: model.isAuthenticated, initial: true) { _, isAuthenticated in
            if isAuthenticated { onAuthenticated() }
        }
    }

    // MARK: - Path bar

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.goUp() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoUp)
            .help("Back")

            Image(systemName: CloudProvider.symbol).foregroundStyle(.secondary)
            Text(model.providerName).fontWeight(.medium)
            Text(model.displayPath)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            if model.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Listing

    @ViewBuilder
    private var content: some View {
        // Not signed in, and not currently trying: the sign-in window was
        // dismissed or failed. Say so and offer it again, rather than showing
        // an empty folder listing that blames the provider.
        if !model.isAuthenticated && !model.isLoading {
            VStack(spacing: 14) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("Sign in to \(model.providerName)")
                    .font(.title3.bold())
                Text("HelloNotes needs permission to list your folders. Nothing is downloaded until you choose one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                Button("Sign In") { Task { await model.connect() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                if let error = model.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 360)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.error, model.entries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if model.needsReauthentication {
                    Button("Sign In Again") { Task { await model.reconnect() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.entries, id: \.path) { entry in
                row(entry)
            }
            .listStyle(.inset)
            // Files are *shown*, not hidden. A folder that looks empty because
            // the picker filtered its notes out is a folder you cannot tell
            // apart from an actually empty one — and knowing the notes are
            // there is the whole reason you are about to choose it.
            .overlay {
                if model.entries.isEmpty && !model.isLoading {
                    ContentUnavailableView("Empty Folder",
                                           systemImage: "folder",
                                           description: Text("Nothing here to choose."))
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: RemoteEntry) -> some View {
        if entry.isDirectory {
            Button { Task { await model.open(entry) } } label: { rowBody(entry) }
                .buttonStyle(.plain)
        } else {
            rowBody(entry)
        }
    }

    private func rowBody(_ entry: RemoteEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                .foregroundStyle(entry.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(width: 18)
            Text(entry.name)
                .foregroundStyle(entry.isDirectory ? .primary : .secondary)
            Spacer(minLength: 0)
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: 10) {
            if case .adding(let progress) = model.addState {
                ProgressView().controlSize(.small)
                Text(summary(progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                Button("Stop") { model.cancelAdd() }
            } else if case .failed(let message) = model.addState {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                Button("Try Again") { model.addAsCollection() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Text("Open “\(targetName)” as a collection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // "Open", not "Add as Collection": this is the same act as
                // choosing a folder on disk, and calling it something else in
                // one of the two places is what made them feel unrelated.
                Button("Open") { model.addAsCollection() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canAddAsCollection)
            }
        }
        .padding(12)
        .onChange(of: model.addState) { _, state in
            if case .added = state { onFinished(); dismiss() }
        }
    }

    private func summary(_ progress: RemoteSyncProgress) -> String {
        let files = progress.filesMirrored
        return files > 0
            ? "Adding \(files) file\(files == 1 ? "" : "s")…"
            : "Reading \(progress.foldersListed) folder\(progress.foldersListed == 1 ? "" : "s")…"
    }
}
