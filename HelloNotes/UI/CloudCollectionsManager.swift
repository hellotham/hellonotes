//
//  CloudFolderManager.swift
//  HelloNotes
//
//  Created by Chris Tham on 25/8/2026.
//
//  "Manage Cloud Collections" — everything about cloud storage in one place:
//  the collections you already have from it, the accounts they came from, and
//  the ways to add another.
//
//  Named for *collections*, not folders, because that is what the app manages.
//  A folder is what a collection is stored in; calling the screen after the
//  storage rather than the thing described the file system instead of the
//  library.
//
//  It began as a *picker* called "Connect a Cloud Account", which was
//  misleading twice over. It offered only one verb — connect — so a person who
//  had already connected everything they owned still met a screen asking them
//  to sign in, with their existing accounts nowhere on it. And "account" named
//  the wrong subject: what someone wants to manage is their cloud *folders*,
//  of which the account is only the route.
//
//  So it lists what exists before it offers to add more, and the adding is a
//  section rather than the whole screen. Two things it deliberately keeps
//  together, because they are the same question asked at different times:
//  folders already synced to this device (no sign-in) and folders that live on
//  a provider's servers (sign-in). Which one applies depends on facts about
//  *this* device — on macOS, `installedClients()` can state them — and that is
//  exactly why the fork belongs on a surface with room to explain rather than
//  in a menu item that can only ask.
//

import SwiftUI

struct CloudCollectionsManager: View {
    var accounts: CloudAccountsStore
    /// Cloud-backed collections currently open, newest first.
    var collections: [Collection]
    /// Builds the browser model for a chosen account, so this view never has to
    /// know how a store is made or what an `AddRemoteCollection` is.
    var makeModel: (CloudAccount) -> RemoteBrowserModel
    /// Open the system picker over folders the provider's own app already
    /// syncs to this device — the no-sign-in path.
    var onChooseSyncedFolder: () -> Void
    /// Take a collection out of the sidebar. **Not** a file deletion.
    var onRemoveCollection: (Collection) -> Void

    @Environment(\.dismiss) private var dismiss
    /// The account being browsed, and the model built for it.
    ///
    /// Keyed by the account rather than presented from the model directly, so
    /// the sheet has a stable `Identifiable` id — and so re-picking the same
    /// account presents the same identity rather than a second sheet.
    @State private var picking: BrowsingAccount?
    @State private var search = ""
    /// The account being renamed, and the text being typed.
    ///
    /// The generated name ("OneDrive 2") only has to be *unambiguous*; it is
    /// the user who knows that one of them is Jane's and the other is work's,
    /// and a list of accounts nobody can tell apart is the thing this screen
    /// exists to avoid.
    @State private var renaming: CloudAccount?
    @State private var draftLabel = ""
    /// The collection about to be removed, held for confirmation.
    @State private var removing: Collection?

    /// One account, listed as a *source* to add a collection from.
    ///
    /// Distinct identities matter: the same account appears twice in this one
    /// `List` — once here and once under Cloud Accounts — and two rows sharing
    /// an id makes SwiftUI reuse one's content for the other, so the managed
    /// account row rendered as its "From …" twin and no amount of relaunching
    /// changed it. Prefixing the id keeps every row in the list unique.
    private struct SourceRow: Identifiable {
        let account: CloudAccount
        var id: String { "source:" + account.id }
    }

    /// The same account, listed for renaming and signing out.
    private struct ManagedRow: Identifiable {
        let account: CloudAccount
        var id: String { "manage:" + account.id }
    }

    private struct BrowsingAccount: Identifiable {
        let account: CloudAccount
        let model: RemoteBrowserModel
        /// Whether this account still has to prove itself by signing in.
        var isNew = false
        var id: String { account.id }
    }

    /// Providers a person may actually choose — never the debug mock.
    private var providers: [CloudBrowser] {
        let all = CloudBrowser.selectable
        guard !search.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                if !collections.isEmpty {
                    Section("Cloud Collections") {
                        ForEach(collections) { collection in
                            collectionRow(collection)
                        }
                    }
                }

                // Where a new collection can come *from*. One account can
                // supply several collections, so these are sources rather than
                // a one-shot setup step.
                Section("Add a Collection") {
                    syncedFolderRow
                    ForEach(accounts.accounts.map(SourceRow.init)) { row in
                        addFromAccountRow(row.account)
                    }
                }

                // Managing the accounts themselves — renaming, signing out,
                // signing in to another. Separate from the section above
                // because using an account and administering one are different
                // errands, and merging them is what made a screen full of
                // "Sign in" rows the only thing an already-connected user saw.
                Section("Cloud Accounts") {
                    ForEach(accounts.accounts.map(ManagedRow.init)) { row in
                        connectedRow(row.account)
                    }
                    ForEach(providers) { provider in
                        providerRow(provider)
                    }
                    if providers.isEmpty && accounts.accounts.isEmpty {
                        Text("No provider matches “\(search)”.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // A search field so the list stays usable however many providers
            // exist — the reason this is a modal and not a menu.
            .searchable(text: $search, prompt: "Search providers")
        }
        .panelFrame(width: 520, height: 580)
        .sheet(item: $picking) { browsing in
            RemoteFolderPicker(model: browsing.model) {
                dismiss()
            } onAuthenticated: {
                // Now it is real: a token exists for this id, so the account
                // is worth remembering. Doing this here rather than at the
                // click is what keeps cancelled sign-ins out of the list.
                if browsing.isNew {
                    accounts.adopt(browsing.account)
                }
            }
        }
        .alert("Rename Account",
               isPresented: Binding(get: { renaming != nil },
                                    set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draftLabel)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let account = renaming {
                    let trimmed = draftLabel.trimmingCharacters(in: .whitespaces)
                    // An empty name would leave a row labelled by nothing;
                    // falling back to the provider is the same rule the
                    // generated name follows.
                    accounts.rename(account, to: trimmed.isEmpty ? account.provider.displayName : trimmed)
                }
                renaming = nil
            }
        } message: {
            Text("What would you like to call this account? For example, “Jane’s OneDrive” or “Work”.")
        }
        // Removing is confirmed because the word people fear here is
        // "delete" — and the answer to that fear has to be stated, not
        // implied by a verb.
        .alert("Remove Collection",
               isPresented: Binding(get: { removing != nil },
                                    set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) {
                if let collection = removing { onRemoveCollection(collection) }
                removing = nil
            }
        } message: {
            Text(removing.map {
                "“\($0.name)” is removed from HelloNotes. Your files are not deleted — "
                + "the folder stays exactly where it is, and you can open it again later."
            } ?? "")
        }
    }

    private var header: some View {
        HStack {
            Label("Manage Cloud Collections", systemImage: "cloud")
                .font(.headline)
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    // MARK: - Collections you already have

    /// A cloud-backed collection, and the way to let it go.
    ///
    /// Listed first because this screen is named for these: someone opening
    /// "Manage Cloud Folders" most often wants to see what they already have,
    /// and a management screen that shows only what you could *add* is a
    /// signup form wearing the wrong title.
    private func collectionRow(_ collection: Collection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: collection.isRemote ? "cloud" : "externaldrive.badge.icloud")
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(collection.name).fontWeight(.medium)
                Text(describe(collection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button(role: .destructive) { removing = collection } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove “\(collection.name)” from HelloNotes (your files stay)")
            .accessibilityLabel("Remove \(collection.name)")
        }
    }

    /// Where a collection's files actually are, in one line.
    private func describe(_ collection: Collection) -> String {
        if let remote = collection.remote {
            // The *provider*, not `remote.displayName` — which is the
            // collection's own name, so the subtitle repeated the title back.
            return "\(remote.store.providerName) · online"
        }
        if let provider = CloudProvider.name(for: collection.rootURL) {
            return "\(provider) · synced to this device"
        }
        return collection.rootURL.path
    }

    // MARK: - Adding

    /// Choose a folder the provider's own app already syncs here.
    ///
    /// The subtitle **names what was found**, and that is the point of putting
    /// this in a modal rather than the menu: a menu item can only ask "is one
    /// of your services synced here?", where this can answer it. Someone who
    /// had forgotten Box is set up on their Mac reads it here and stops before
    /// signing in to something they already have.
    private var syncedFolderRow: some View {
        Button {
            dismiss()
            onChooseSyncedFolder()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.icloud")
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("From a Synced Cloud Folder…").fontWeight(.medium)
                    Text(syncedSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// What the app can honestly say about this device.
    ///
    /// macOS can name the installed clients — a LaunchServices lookup, which
    /// the sandbox permits. iOS cannot: `installedClients()` returns `[]` there
    /// **by design**, because a provider's app being installed says nothing
    /// about whether its File Provider extension is enabled, and only the Files
    /// picker knows. So iOS says the true, vaguer thing rather than a confident
    /// wrong one — and the picker itself shows what is really there.
    private var syncedSubtitle: String {
        let installed = CloudProvider.installedClients().map(\.name)
        guard !installed.isEmpty else {
            return "Folders from cloud apps set up on this device — no sign-in needed."
        }
        return "\(installed.formatted(.list(type: .and))) set up here — no sign-in needed."
    }

    /// Take a collection from an account already signed in.
    ///
    /// One row per account rather than per provider, because two accounts on
    /// one service are two different sets of folders — and the whole reason
    /// accounts have identities is that "Dropbox" no longer answers "whose?".
    private func addFromAccountRow(_ account: CloudAccount) -> some View {
        Button {
            picking = BrowsingAccount(account: account, model: makeModel(account))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: CloudProvider.symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("From \(account.displayName)…").fontWeight(.medium)
                    Text(account.provider.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// An account already signed in: go straight to browsing it.
    ///
    /// Browsing rather than a single add-and-done, because one account
    /// routinely holds more than one folder worth keeping as a collection, and
    /// re-signing in to reach the second would be absurd.
    private func connectedRow(_ account: CloudAccount) -> some View {
        // The rename control sits *beside* the row's button rather than inside
        // its label: a button nested in another button's label is not reliably
        // hittable, and the row itself has to stay one tap target.
        HStack(spacing: 6) {
            Button {
                picking = BrowsingAccount(account: account, model: makeModel(account))
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: CloudProvider.symbol)
                        .foregroundStyle(.tint)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.displayName).fontWeight(.medium)
                        // Its *state*, which is what this section is for —
                        // saying only the provider left a connected account
                        // looking much like the "sign in" row beneath it. The
                        // service is named too, but only when the account has
                        // been renamed away from it: "Dropbox / Dropbox ·
                        // Signed in" is a stutter, "Jane's / Dropbox · Signed
                        // in" is the one case where you still need telling.
                        Text(status(for: account))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            // Visible, not only in the context menu: renaming is the thing a
            // person wants the moment they connect a second account, and a
            // command they have to guess at by right-clicking is one most
            // people never find.
            Button { beginRename(account) } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Rename this account")
            .accessibilityLabel("Rename \(account.displayName)")

            Button(role: .destructive) { accounts.disconnect(account) } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Sign out of \(account.displayName)")
            .accessibilityLabel("Sign out of \(account.displayName)")
        }
        .contextMenu {
            Button { beginRename(account) } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Button(role: .destructive) { accounts.disconnect(account) } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    /// What a connected account's second line says.
    private func status(for account: CloudAccount) -> String {
        account.displayName == account.provider.displayName
            ? "Signed in"
            : "\(account.provider.displayName) · Signed in"
    }

    /// A provider to sign in to. Signing in again adds a *second* account
    /// rather than replacing the first.
    private func providerRow(_ provider: CloudBrowser) -> some View {
        Button {
            // The account is **provisional** until the sign-in succeeds.
            //
            // It used to be recorded the instant this was clicked, so every
            // cancelled or failed sign-in left a row claiming to be a connected
            // account with no token behind it — and clicking a provider twice
            // produced two. Recording it only on success means "Connected
            // Accounts" lists accounts that are actually connected, which is
            // the only thing that heading can honestly mean.
            let account = CloudAccount(provider: provider,
                                       label: nextLabel(for: provider))
            picking = BrowsingAccount(account: account, model: makeModel(account),
                                      isNew: true)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                // "New Dropbox", not "Dropbox". Sitting directly under an
                // account already signed in, a bare provider name read as a
                // second, contradictory claim about the same thing — where
                // what it actually offers is an *additional* account on that
                // service, which is the case this whole screen exists for.
                Text("New \(provider.displayName)")
                Spacer(minLength: 0)
                Text("Sign in")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func beginRename(_ account: CloudAccount) {
        draftLabel = account.label
        renaming = account
    }

    /// A provisional name for a second or third account on one service.
    ///
    /// The provider's own profile name would be better and is what should
    /// replace this once each store can report it; until then "OneDrive 2" at
    /// least distinguishes two rows, where sharing one name would leave the
    /// list unreadable exactly when it matters.
    private func nextLabel(for provider: CloudBrowser) -> String {
        let existing = accounts.accounts(for: provider).count
        return existing == 0 ? provider.displayName : "\(provider.displayName) \(existing + 1)"
    }
}
