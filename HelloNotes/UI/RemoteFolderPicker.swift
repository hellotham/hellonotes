//
//  RemoteFolderPicker.swift
//  HelloNotes
//
//  Created by Chris Tham on 25/8/2026.
//
//  Choose a folder from a signed-in cloud account, in the shape of a file
//  picker rather than a bespoke browser.
//
//  `RemoteBrowserView` — a browser for *reading and editing* a note straight
//  off a provider, since removed — was doing double duty as the way you added
//  a collection, and it made a poor picker. It has a
//  sign-out button in the same row as the action, it opens notes into an
//  editor when you tap them, it can only add the folder you are currently
//  *inside* rather than one you can see, and it says "Add as Collection" where
//  every other folder-choosing surface in the app says "Open". Picking a
//  folder from Dropbox therefore looked and behaved like nothing else in the
//  app, including the panel you get for a folder on disk two menu items away.
//
//  So this borrows the *shape* of that panel — a path bar you can walk back
//  up, and a list where folders are navigable and files are visible but
//  inert — without pretending to be a pixel copy of it. Cancel and Open sit in
//  the sheet's own bar at the top, as they do in every sheet the app draws,
//  either side of the name of the folder Open would take. Where it
//  deliberately departs is the click: a single click descends, as it does in
//  the Files picker, rather than selecting a row for a second click to open.
//  See `targetName` for why — the faithful version had the row's double-click
//  recogniser eating the list's single click, which made every folder look
//  dead.
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
            ChromeSheetBar(targetName) {
                leadingAction
            } trailing: {
                trailingAction
            }
            pathBar
            ChromeDivider()
            content
            ChromeDivider()
            statusLine
        }
        .chromeSheetFrame(width: 560, height: 520)
        // Signing in is part of opening, not a separate screen to find.
        //
        // This used to be `loadRootIfNeeded()` alone, whose first line is
        // `guard isAuthenticated` — so arriving here without a token did
        // nothing at all and drew an empty folder. Someone who had just
        // chosen "Dropbox ▸ Sign in" got a blank list and no way forward,
        // which reads exactly like a provider with no files in it.
        .task { await model.start() }
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

            Image(systemName: CloudProvider.symbol).foregroundStyle(Chrome.Colour.secondaryLabel)
            Text(model.providerName).fontWeight(.medium)
            Text(model.displayPath)
                .foregroundStyle(Chrome.Colour.secondaryLabel)
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
                    .font(Chrome.Style.title3.bold())
                Text("HelloNotes needs permission to list your folders. Nothing is downloaded until you choose one.")
                    .font(Chrome.Style.callout)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                Button("Sign In") { Task { await model.connect() } }
                    .buttonStyle(ChromePushStyle(prominent: true))
                    .controlSize(.large)
                if let error = model.error {
                    Text(error)
                        .font(Chrome.Style.caption)
                        .foregroundStyle(Chrome.Colour.red)
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
                    .font(Chrome.Style.largeTitle)
                    .foregroundStyle(Chrome.Colour.orange)
                Text(error)
                    .font(Chrome.Style.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                    .textSelection(.enabled)
                if model.needsReauthentication {
                    Button("Sign In Again") { Task { await model.reconnect() } }
                        .buttonStyle(ChromePushStyle(prominent: true))
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.entries, id: \.path) { entry in
                        row(entry)
                    }
                }
                .padding(.vertical, 4)
            }
            .viewport()
            .background(Chrome.Colour.content)
            // Files are *shown*, not hidden. A folder that looks empty because
            // the picker filtered its notes out is a folder you cannot tell
            // apart from an actually empty one — and knowing the notes are
            // there is the whole reason you are about to choose it.
            .overlay {
                if model.entries.isEmpty && !model.isLoading {
                    ChromeEmptyState("Empty Folder",
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
                .buttonStyle(ChromePlainStyle())
        } else {
            rowBody(entry)
        }
    }

    private func rowBody(_ entry: RemoteEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                .foregroundStyle(entry.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(Chrome.Colour.tertiaryLabel))
                .frame(width: 18)
            Text(entry.name)
                .foregroundStyle(entry.isDirectory ? Chrome.Colour.label : Chrome.Colour.secondaryLabel)
            Spacer(minLength: 0)
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(Chrome.Style.caption)
                    .foregroundStyle(Chrome.Colour.tertiaryLabel)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(.rect)
    }

    // MARK: - Actions

    /// The way out. None while a folder is being added — Stop is the way out
    /// of that — and no Escape once adding has failed, as before.
    @ViewBuilder
    private var leadingAction: some View {
        switch model.addState {
        case .adding:
            EmptyView()
        case .failed:
            Button("Cancel") { dismiss() }
        case .idle, .added:
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    /// The way forward: Open, Try Again after a failure, Stop while adding.
    @ViewBuilder
    private var trailingAction: some View {
        switch model.addState {
        case .adding:
            Button("Stop") { model.cancelAdd() }
        case .failed:
            Button("Try Again") { model.addAsCollection() }
                .buttonStyle(ChromePushStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
        case .idle, .added:
            // "Open", not "Add as Collection": this is the same act as
            // choosing a folder on disk, and calling it something else in
            // one of the two places is what made them feel unrelated.
            Button("Open") { model.addAsCollection() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(ChromePushStyle(prominent: true))
                .disabled(!model.canAddAsCollection)
        }
    }

    /// What Open does, how the add is going, or why it failed — at the foot,
    /// under the folder it is about.
    private var statusLine: some View {
        HStack(spacing: 10) {
            if case .adding(let progress) = model.addState {
                ProgressView().controlSize(.small)
                Text(summary(progress))
                    .font(Chrome.Style.caption)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                    .monospacedDigit()
            } else if case .failed(let message) = model.addState {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Chrome.Colour.orange)
                Text(message)
                    .font(Chrome.Style.caption)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                    .lineLimit(2)
            } else {
                Text("Open “\(targetName)” as a collection.")
                    .font(Chrome.Style.caption)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
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
