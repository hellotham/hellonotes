# HelloNotes — Cloud-native roadmap

*Research + plan: open cloud-hosted notes natively, on-demand, without pre-downloading
a whole vault to a local folder. Covers Box, Dropbox, OneDrive (personal + business),
Google Drive, and iCloud Drive.*

Status: **Phases 0–3 shipped**, **Phase 4 foundation shipped** (2026-07-20/21). The
File-Provider path (0–3) is complete and covers Box, Dropbox, OneDrive, Google Drive & iCloud;
Phase 4 (direct Dropbox API) has a tested client, gated on a user Dropbox-app registration +
collection wiring. Written 2026-07-20.

---

## 0. TL;DR

- On Apple platforms there are **two** ways to be "cloud native":
  1. **Adopt the OS File Provider layer** — open the provider's mounted folder
     (`~/Library/CloudStorage/<Provider>` on macOS, the **Files** app on iOS). Files are
     *dataless* (metadata local, content in the cloud) and **materialize on demand** when
     read. This covers **all five providers with one code path** and no per-provider SDK.
  2. **Talk to each provider's REST API directly** (OAuth) — no desktop/mobile client
     needed, but a large per-provider engineering + maintenance cost and a virtual
     filesystem that replaces "a URL is a file."
- **Our architecture already fits option 1.** "The local file system directory is the
  absolute source of truth" (CLAUDE.md) is *exactly* what File Provider gives us —
  `~/Library/CloudStorage/…` is a real local path. No CoreData rethink needed.
- **Phase 0 (coordinated I/O) is now done.** Previously the app used `NSFileCoordinator`
  **nowhere** — every read was `String(contentsOf:)`, every write `.write(to:.atomic)` —
  so reading a *dataless* File-Provider file would fail with **`EDEADLK` (errno 35)**. All
  vault reads/writes now go through `Core/FileIO.swift` (coordinated), verified live on a
  real iCloud/File-Provider vault.
- **Phase 1 (dataless-aware indexing) is also done.** The eager indexers used to read
  **every** note body, which would force-download the whole vault on first open; they now
  skip online-only files via `FileIO.isMaterialized` (indexing them lazily once opened).
  What's left is **UX** — Phase 2's cloud badges, download/keep-offline controls, and
  materialize-on-open progress.
- **Recommendation:** ship option 1 in phases (it also hardens iCloud Drive, which
  is already File-Provider-backed). Treat option 2 as a later, *selective* add — at most one
  provider (e.g. Dropbox) — only if "requires the provider's app installed" proves too
  limiting.

---

## 1. How cloud files actually work on Apple platforms

Since macOS 12.3 Apple deprecated cloud kernel extensions and required providers to adopt
the **File Provider** framework. Today Box, Dropbox, OneDrive, Google Drive, and iCloud all
present their storage as a **virtual filesystem** of *dataless* (a.k.a. dehydrated) files:

- The **directory entry + metadata** (name, size, dates, folder structure) are cached
  locally and are cheap to enumerate.
- The **content** lives on the provider's servers and is downloaded ("**materialized**")
  on demand the first time a process reads the file. `stat` shows `Blocks: 0` for a
  dataless file even though it reports a normal size.
- Reading a dataless file **requires coordinated access**. A plain `open()/read()` (or
  `String(contentsOf:)`) can fail with `EDEADLK` because the kernel pauses the read to call
  the provider's extension, and an uncoordinated/locked read deadlocks. The fix is
  `NSFileCoordinator` coordinated reads, which tell the system "materialize this now" before
  the accessor block runs. (See Apple **TN3150 "Getting ready for dataless files"** and
  WWDC21 "Sync files to the cloud with FileProvider on macOS".)

### macOS mount locations (`~/Library/CloudStorage/…`)
| Provider | Path (typical) |
|---|---|
| Dropbox | `~/Library/CloudStorage/Dropbox` |
| Google Drive | `~/Library/CloudStorage/GoogleDrive-<account>` |
| OneDrive personal | `~/Library/CloudStorage/OneDrive-Personal` |
| OneDrive business | `~/Library/CloudStorage/OneDrive-<TenantName>` |
| Box | `~/Library/CloudStorage/Box-Box` |
| iCloud Drive | `~/Library/Mobile Documents/com~apple~CloudDocs` (separate, older path) |

The location "is controlled by macOS" and can't be moved (offline cache can go on an
external drive for some providers, but the sync root stays on the home volume).

### iOS / iPadOS
There is no `~/Library/CloudStorage`. Instead each provider ships a **File Provider
extension** surfaced in the **Files** app. An app reaches those files by presenting
`UIDocumentPickerViewController` (folder mode) → the user picks a provider folder →
the app persists a **security-scoped bookmark**. Same dataless mechanics; coordinated reads
materialize on demand. An app **cannot** enumerate another app's File-Provider domains via
`NSFileProviderManager` (that's only for domains you own), so the document picker is the
entry point, and the **provider's app must be installed**.

---

## 2. Provider matrix

| Provider | macOS File Provider | iOS (Files) | Direct API / OAuth (option 2) |
|---|---|---|---|
| **Dropbox** | ✅ `~/Library/CloudStorage/Dropbox` (needs Dropbox app) | ✅ Files | Dropbox API v2 — **SwiftyDropbox** (official Swift SDK) |
| **Google Drive** | ✅ `GoogleDrive-<acct>` (needs Drive for desktop, macOS 13+) | ✅ Files | Drive API v3 — REST/GTLR, or a thin client (no Google SDK needed) |
| **OneDrive personal** | ✅ `OneDrive-Personal` | ✅ Files | Microsoft **Graph** API via **MSAL** |
| **OneDrive business / SharePoint** | ✅ `OneDrive-<Tenant>` | ✅ Files | Microsoft **Graph** (work/school; may need tenant admin consent) |
| **Box** | ✅ `Box-Box` (Box Drive) | ✅ Files | Box Platform API + Box iOS SDK |
| **iCloud Drive** | ✅ (already; File-Provider-backed) | ✅ | n/a (use the OS layer) |

Takeaway: **option 1 is a single implementation for the whole column**; option 2 is a
separate OAuth + SDK + sync engine per provider.

---

## 3. Two strategies, weighed

### Strategy A — Adopt File Provider (recommended, primary)
Open the provider's mounted folder as a normal collection; let the OS materialize on demand.

- **Pros:** one code path for all providers; zero OAuth/token/SDK maintenance; keeps our
  "filesystem is truth" model intact; also hardens iCloud Drive support; Finder/Files stay
  the source of truth so users trust it.
- **Cons:** requires the provider's **desktop/mobile client installed**; the sync root lives
  on the home volume; we must become **dataless-aware** (coordinate I/O, avoid whole-vault
  downloads, surface download state). Git collections on a cloud folder are problematic
  (see §5).

### Strategy B — Direct REST API per provider (selective, later)
The app authenticates to the provider and streams file content over HTTP; no client needed.

- **Pros:** works with no desktop/mobile client; full control over caching and what's
  fetched; can run headless (e.g. server/CI).
- **Cons:** **large** and **ongoing** per provider — OAuth + refresh tokens (Keychain),
  redirect URL schemes, a **virtual filesystem** abstraction to replace `URL`-is-a-file
  across the editor/index/watcher/git, **upload-on-save**, **remote change** detection
  (polling/webhooks/delta cursors), conflict handling, and rate-limit/throttling. Breaks the
  "filesystem is truth" invariant and duplicates what the OS already does well.

**Verdict:** do A now; consider B for *one* provider only if the "client-installed"
requirement is a real adoption blocker.

---

## 4. Phased plan for this codebase (Strategy A)

### Phase 0 — Coordinated I/O foundation ✅ **shipped** *(commit: coordinated I/O for vault reads/writes)*
The single most important change. All **vault** note reads/writes now route through
`NSFileCoordinator`, so dataless files materialize on read instead of failing with `EDEADLK`;
for local files it's a no-op.

- Added `Core/FileIO.swift`: `readData` / `readString` (coordinated read, materializes on
  demand), `write` (coordinated atomic replace), `create` (coordinated `withoutOverwriting`).
- Migrated every vault read/write: `EditorModel` open/reconcile/save, `Collection`
  (index refresh, create, rename-link rewrite, daily-note create, append),
  `CollectionSearchModel` + `LinkGraph` (indexing), `MacContentView` (mentions, link-mention,
  template insert), `LibraryChatView`, `FileViewerView`, `CollectionEmbedProvider`,
  `AuxiliaryWindows`, `AgentTool`, `CollectionTools`, `ImagePaste`, `EditorExport`.
  App-private files (index cache, chat transcripts, widget snapshot) intentionally keep
  direct writes — they never live in a cloud folder. (`GFMPage` reads a *bundle* resource,
  also left as-is.)
- Hardening: `writeWidgetSnapshot()`'s file write moved off the main actor — a synchronous
  main-thread write hangs the whole UI when a volume stalls (the exact cloud failure mode).
- **Verified live on a real iCloud/File-Provider vault** (2,019 notes): open + read a note
  (body + backlinks/mentions), create a note, autosave (bytes confirmed on disk), delete —
  no hangs, no `EDEADLK`.
- *Not yet done here (moved to Phase 1):* `isDataless` / download-status helpers on
  `URLResourceValues`. Phase 0 makes I/O *correct*; Phase 1 makes indexing *download-aware*.

### Phase 1 — Dataless-aware indexing ✅ **core shipped** *(commit: dataless-aware indexing)*
The eager indexers used to read **every** note body → on a cloud vault that downloads the
whole thing on first open. Fixed:

- ✅ **`FileIO.isMaterialized(at:)`** — true for local + already-downloaded files, false only
  for explicitly online-only (`.notDownloaded`) items; conservative (true) on unknown status.
  Cheap metadata read, no download.
- ✅ **Index only what's local.** `Collection.refreshDerived` (the primary offender — its
  cold-cache scan read every uncached body), `CollectionSearchModel.refresh` (iOS path) and
  `LinkGraph.rebuild` now **skip online-only, uncached notes**. They still appear in the list
  (title from filename) and are indexed once materialized (opened) or on the next refresh
  after download. The persisted `CollectionIndexCache` covers previously-indexed notes even
  after eviction.
- ✅ **Content search restricted to downloaded files** — full-text search skips online-only
  files so a query never silently downloads the vault; title/tag/alias (metadata) search
  still covers everything.
- ✅ **Enumerate metadata only** — already the case (note list / titles / tree come from
  filenames), preserved.
- ✅ **Tests** (`FileIOTests`): coordinated round-trip, create-refuses-overwrite,
  write-replaces, and `localFileIsAlwaysMaterialized()` (the no-skip-local invariant). 4/4.
- ✅ **Verified:** no regression on the real vault (2,019 notes / 1,140 tags index fully);
  `isMaterialized` reads real iCloud status correctly (`.current` → true) on a live file.

**Deferred to Phase 2 (UX):** the explicit *"search online files (downloads them)"* action;
materialize-on-open **progress UI** (the download itself already works via Phase 0's
coordinated read — only the progress indicator is missing).

### Phase 2 — Cloud-state UX ✅ **shipped** *(commit: online-only state in the UI)*
- ✅ **`Note.isOnlineOnly`**, captured for free during the scan (added the ubiquitous /
  download-status resource keys to the enumerate pass).
- ✅ **Cloud badge** (`icloud.and.arrow.down`) on online-only notes — macOS outline row and
  the iOS list row.
- ✅ **Download / Remove Download** actions (`FileIO.download` / `FileIO.evict`) — macOS note
  context menu (cloud items only) and an iOS leading swipe action.
- ✅ **Collection-level "N online-only"** status-bar indicator with an explanatory tooltip.
- ✅ **Provider label** — `CloudProvider.name(for:)` maps a path to Dropbox / Google Drive /
  OneDrive / Box / iCloud Drive; shown under the collection name in the macOS sidebar.
- ✅ **Onboarding** copy mentions cloud folders.
- ✅ **Materialize-on-open progress** — `EditorModel.isDownloading` drives a "Downloading from
  the cloud…" editor banner.
- ✅ **Verified live:** sidebar shows "iCloud Drive"; status bar shows the online-only count
  for an evicted note. (iCloud aggressively re-hydrates freshly-evicted files, so the row
  glyph itself couldn't be held on screen long — but it renders from the same verified flag.)
- *Not done:* an explicit "search online files (downloads them)" action (search skips
  online-only by default, which is the safe behaviour).

### Phase 3 — Git-on-cloud guardrails ✅ **shipped** *(commit: Git-on-cloud guardrails)*
- ✅ Orange **caution** in the sidebar Git section for a collection under a cloud provider
  ("In <provider>. Git works best when the folder is fully downloaded…"), in both the
  pre-Initialize and repo states.
- ✅ **Auto-commit disabled** (toggle greyed + explained) for cloud collections, AND guarded at
  the trigger so a pre-existing enabled flag never fires on a cloud folder. Manual Git actions
  stay available for users who keep the folder downloaded. Uses `CloudProvider.name(for:)`.

### Phase 4 — Direct-API pilot (Dropbox) ✅ **foundation shipped** *(commit: direct-API pilot)*
The optional, isolated pilot — reach a cloud account directly over REST, no client installed.
- ✅ **`RemoteStore`** protocol (list / read / write / delete + auth), `RemoteEntry`,
  `RemoteStoreError`, `RemoteTokenStore` (Keychain).
- ✅ **`DropboxStore`** over the Dropbox API v2 using plain **URLSession — no SwiftyDropbox
  dependency** (nothing added to the project graph; avoids the project-regen corruption risk).
  list_folder / download / upload / delete_v2, PKCE OAuth via `ASWebAuthenticationSession`,
  token exchange. Pure request builders + parsing are static and **unit-tested**
  (`DropboxStoreTests`, 8 tests).
- **Externally gated (the user's steps, not code):**
  1. Register a Dropbox app and put its **App key** in Info.plist (`DropboxAppKey`) + register
     the redirect `hellonotes://dropbox-auth`. (I can't create a Dropbox developer app.)
  2. Wire a `RemoteStore` into the filesystem-based `Collection` model — a larger, separate
     refactor. Until then `DropboxStore` is a tested, self-contained client ready to adopt.

---

## 5. Risks & constraints
- **`EDEADLK` on uncoordinated reads** — the whole reason Phase 0 is mandatory; without it,
  cloud collections silently fail to open.
- **Whole-vault download** from eager indexing/content-search — Phase 1 must gate this.
- **Git** on File-Provider folders — Phase 3 guardrails.
- **Eviction** (making a file online-only again) for a domain we don't own is **best-effort**:
  we can trigger downloads via coordinated reads, but forcing dehydration is the provider's
  job — expose "Remove Download" as a hint, not a guarantee.
- **Security-scoped bookmark staleness** — CloudStorage bookmarks can go stale across
  provider updates; keep the existing re-mint-on-persist behaviour and re-mint on `isStale`.
- **iOS provider dependency** — the provider's app must be installed for its Files location
  to appear; detect absence and message it.
- **Sandbox/entitlements** — user-selected read-write file access already covers
  `~/Library/CloudStorage` (macOS) and document-picker bookmarks (iOS). Direct API (Phase 4)
  would additionally need per-provider OAuth redirect schemes + outbound-network config.
- **External-drive cache** — providers vary; out of our control, just document it.

## 6. Verification
- Unit-test the `FileAccess` coordinator wrapper against a synthesized dataless URL where
  possible; otherwise integration-test on a real `~/Library/CloudStorage` folder with
  online-only files (toggle "Free Up Space" / "make online-only" in the provider).
- Live checks: open a Dropbox and a Google Drive folder containing online-only `.md` files;
  confirm the note list populates from metadata **without** downloading; open one note and
  confirm it materializes with progress; edit + save and confirm the change uploads; confirm
  full-text search doesn't silently download the vault.

## Sources
- Apple — [File Provider framework](https://developer.apple.com/documentation/fileprovider),
  [Synchronizing files using file provider extensions](https://developer.apple.com/documentation/FileProvider/synchronizing-files-using-file-provider-extensions),
  [TN3150: Getting ready for dataless files](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files),
  [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator),
  [WWDC21 — Sync files to the cloud with FileProvider on macOS](https://developer.apple.com/videos/play/wwdc2021/10182/),
  [UIDocumentPickerViewController](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller).
- Failure mode — [claude-code #40783: File read failure on macOS FileProvider paths (EDEADLK)](https://github.com/anthropics/claude-code/issues/40783).
- Providers — [Google Drive for desktop on macOS (File Provider)](https://support.google.com/drive/answer/12178485),
  [Dropbox for macOS on File Provider](https://help.dropbox.com/installs/dropbox-for-macos-support),
  [OneDrive Files On-Demand on macOS](https://techcommunity.microsoft.com/blog/onedriveblog/inside-the-new-files-on-demand-experience-on-macos/3058922),
  [Apple's File Provider forces Mac cloud storage changes (TidBITS)](https://tidbits.com/2023/03/10/apples-file-provider-forces-mac-cloud-storage-changes/).
- Direct-API SDKs — [SwiftyDropbox](https://github.com/dropbox/SwiftyDropbox),
  [MSAL for Apple (Microsoft Graph)](https://github.com/Azure-Samples/ms-identity-mobile-apple-swift-objc),
  [Google Drive Swift client](https://github.com/darrarski/swift-google-drive-client).
