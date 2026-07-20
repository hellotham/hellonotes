# HelloNotes — Cloud-native roadmap

*Research + plan: open cloud-hosted notes natively, on-demand, without pre-downloading
a whole vault to a local folder. Covers Box, Dropbox, OneDrive (personal + business),
Google Drive, and iCloud Drive.*

Status: **planning / backlog** (nothing here is implemented yet). Written 2026-07-20.

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
- **But we are not cloud-safe today.** The app uses `NSFileCoordinator` **nowhere**; every
  read is `String(contentsOf:)` and every write is `.write(to:.atomic)`. Reading a
  *dataless* File-Provider file without coordination fails with **`EDEADLK` (errno 35)** —
  the documented failure mode. And the search index + backlink graph read **every** note
  body eagerly, which would **force-download the entire vault** on first open.
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

### Phase 0 — Coordinated I/O foundation *(mandatory; also fixes iCloud)*
Single most important change. Route **all** note content reads and writes through
`NSFileCoordinator`, and treat dataless files as first-class.

- Add a small `FileAccess` helper:
  - `read(_ url) -> String` via `NSFileCoordinator.coordinate(readingItemAt:options:[])`
    (the coordinated read materializes on demand; fixes `EDEADLK`).
  - `write(_ text, to url)` via `coordinate(writingItemAt:options:.forReplacing)` (keeps the
    atomic-rename semantics we rely on, but coordinated so uploads are triggered correctly).
  - `isDataless(_ url) -> Bool` and `downloadingStatus(_ url)` from `URLResourceValues`
    (`.ubiquitousItemDownloadingStatusKey`, `.isUbiquitousItemKey`).
- Replace the raw calls (grep found ~30): `EditorModel` open/save
  (`State/EditorModel.swift:89,117,193`), `Collection` reads/writes
  (`State/Collection.swift:230,471,478,513,526,528`), rename rewrite
  (`MacContentView.swift:1132`), template expand, `LinkGraph`, `CollectionSearchModel`,
  `LibraryChatView`, `AgentTool`/`CollectionTools`, `FileViewerView`,
  `CollectionEmbedProvider`, `GFMPage`.
- Interaction with `EditorModel`'s existing serialized-write chain and conflict banner: keep
  them; the coordinator wraps the actual disk touch. Coordinated writes also make our
  file-watcher "own-write" suppression more reliable.

### Phase 1 — Dataless-aware indexing & open *(don't download the whole vault)*
Today `CollectionSearchModel.refresh` and `LinkGraph.rebuild` read **every** note body →
on a cloud vault that means "download everything." Make indexing on-demand-friendly:

- **Enumerate metadata only** (name/size/date/`isDirectory`/download-status resource keys) —
  never read content just to list notes. The note list, titles, folder tree already work
  from filenames; keep it that way.
- **Index only what's local.** When building the tag/alias/heading index and backlink graph,
  **skip non-materialized files** and rely on the persisted `CollectionIndexCache` for the
  rest; index a file's body the first time it's materialized (on open), then cache it. Never
  bulk-materialize to build an index.
- **Content search** (`spotlight` wave + `contentResults`) inherently needs bodies. On a
  cloud vault, restrict full-text search to **downloaded** files by default and offer an
  explicit "search online files (downloads them)" action — with a clear count of what would
  download. Title/alias/tag search stays instant (metadata only).
- **Materialize on open, with progress.** Opening a dataless note shows a small "Downloading
  from <provider>…" state (reuse the save-error/conflict banner pattern) driven by the
  coordinator's `Progress`.

### Phase 2 — First-class "Open cloud folder" UX
- **macOS:** the existing folder picker already reaches `~/Library/CloudStorage/…`; add a
  **launcher affordance** ("Open Cloud Folder") that starts the open panel there and a
  provider label/icon derived from the path (Dropbox / Google Drive / OneDrive / Box / iCloud).
- **iOS:** the `.fileImporter(...,.folder)` path already surfaces Files providers; label the
  opened collection with its provider and note the "provider app required" dependency.
- **Per-note download state in the UI:** a cloud badge on online-only notes; context-menu
  **Download**, **Keep Offline**, **Remove Download** (coordinated read to materialize;
  eviction via the provider is best-effort — see §5). Surface a collection-level "N of M
  downloaded" indicator.
- **Onboarding:** extend `WelcomeView`/launcher copy to mention "Open a Dropbox / Google
  Drive / OneDrive / Box / iCloud folder."

### Phase 3 — Git-on-cloud guardrails
`SwiftGitX`/libgit2 needs real local object files; a git repo whose `.git` objects are
online-only would thrash (libgit2 reads many objects, forcing downloads, and coordinated
access isn't wired through libgit2). **Detect** when a collection under
`~/Library/CloudStorage` is also a git repo and either (a) require it to be "always available
offline," or (b) disable auto-commit/live-git for cloud collections with a clear explanation.
Plain (non-git) cloud collections are the happy path.

### Phase 4 — *(optional, selective)* Direct API for one provider
Only if "requires the provider's client" is a real blocker. Scope to **one** provider first
(Dropbox via **SwiftyDropbox** is the least-friction OAuth + simplest API). Design a
`RemoteStore` protocol (list / read / write / watch) behind the current `Collection` so the
editor/index don't care whether a note is a local URL or a remote id; add OAuth (ASWebAuth +
Keychain), delta-cursor change detection, and upload-on-save. Explicitly a large, isolated
workstream — do not start it before Phases 0–2 prove the File-Provider path.

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
