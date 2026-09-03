# Productionising HelloNotes & shipping to the App Store

A complete, do-this-in-order runbook to take HelloNotes from a working dev build
to an approved App Store release. Copy‑paste values are given for every field.

> **Scope:** HelloNotes ships on **both macOS and iOS**, from a single App Store
> Connect app record (App ID `6803259848`) — both platforms are live and in
> TestFlight. The two platforms share one app record, one bundle ID, and one
> set of metadata (§3–§7); they differ only in the build/export step (§9) and
> the screenshot sizes (§8). visionOS is still listed in the project's
> `SUPPORTED_PLATFORMS` (`xros`) purely because `SDKROOT = auto` pulls it in
> automatically for a multiplatform target — there is no visionOS-specific
> target, entitlement, or submission, and nothing below should be read as
> visionOS being production-ready.

## At‑a‑glance facts

| Thing | Value |
|---|---|
| App name | **HelloNotes** |
| Platforms | **macOS + iOS**, one App Store Connect app record — both live, both in TestFlight |
| App Store Connect App ID | `6803259848` |
| Bundle ID | `com.hellotham.HelloNotes` |
| SKU | `HELLONOTES-001` |
| Apple team | **Hello Tham Pty. Ltd.** — `RPL5R637DS` (Organization; Account Holder Chris Tham; signs as `Apple Development / Apple Distribution`) |
| Category | Productivity (`public.app-category.productivity`) |
| Version / build | `MARKETING_VERSION = 1.3.2`, `CURRENT_PROJECT_VERSION = 8` — **verify fresh**: these bump every release, so read them from `HelloNotes.xcodeproj/project.pbxproj` rather than trusting this table |
| Sandbox / Hardened Runtime | Enabled (required for the store) |
| Entitlements | App Sandbox · User-selected files (r/w) · Network client (Git sync) · App Group · iCloud KV store · Audio input — see §1b for the full current list and what each is for |
| Min OS | **macOS 26.5 / iOS 26.5** |
| Website | <https://hellotham.com/hellonotes/> (Privacy · Support live) |

---

## 0 · Prerequisites (one‑time)

1. **Apple Developer Program** membership — **paid, active** ($99/yr). The free
   account can only run locally; it cannot upload to the store. Enrol at
   <https://developer.apple.com/programs/> using the **Hello Tham** Apple ID.
2. You are **Account Holder / Admin / App Manager** on the team in both
   [App Store Connect](https://appstoreconnect.apple.com) and the
   [Developer portal](https://developer.apple.com/account).
3. **Xcode 26** signed in: Xcode ▸ Settings ▸ Accounts ▸ add the Hello Tham Apple
   ID ▸ select the team. Let it create a **“Apple Distribution”** certificate when
   prompted (or Manage Certificates ▸ **+** ▸ *Apple Distribution*).
4. **Agreements:** App Store Connect ▸ **Business** ▸ accept the *Paid Apps* /
   *Free Apps* agreement and complete tax & banking (even for a free app the
   agreement must be **Active**, or your app can’t be released).

---

## 1 · Project hardening (pre‑flight) — do these before archiving

> **✅ Already done in this repo:** §1a (min OS → **macOS 26.5**), §1b (Git remote
> sync entitlement), §1c (Info.plist cleaned), §1d (`ITSAppUsesNonExemptEncryption`),
> plus the app icon and screenshots. **Left for you:** §1e–§1h (confirm signing,
> version policy, optional dependency pin, and the final build).

Work through each; several are genuine blockers or reviewer red flags.

### 1a. ✅ Minimum macOS version — done
**`MACOSX_DEPLOYMENT_TARGET = 26.5`**, matching iOS.

It sat at 15.0 for 1.3.1, which was wrong in a way nothing caught: the Widgets,
Preview and Thumbnail extensions were already 26.5, so the app promised an OS its
own embedded extensions refused to run on. App Store validation is entitled to
reject that, and on a macOS 15 machine the extensions simply would not load.

Raised rather than lowered because the Intelligence features are built on
Foundation Models, which is 26-only. The `#available(macOS 26.0, *)` guards stay
— they cost nothing and they document the boundary — but they are no longer
load-bearing.

### 1b. ✅ Git remote sync — enabled
The app ships an explicit entitlements file
(`HelloNotes/HelloNotes.entitlements`, wired via `CODE_SIGN_ENTITLEMENTS`) granting
**Outgoing Connections (Client)** alongside the sandbox and user‑selected‑files
entitlements. **As of this session it carries seven keys** (confirmed by reading
the file directly — this list has grown since the four-key version this section
used to describe, so verify it again the same way rather than trusting either
copy):
```xml
<key>com.apple.security.app-sandbox</key>                        <true/>
<key>com.apple.security.application-groups</key>
<array><string>group.com.hellotham.HelloNotes</string></array>
<key>com.apple.developer.ubiquity-kvstore-identifier</key>
<string>$(TeamIdentifierPrefix)$(CFBundleIdentifier)</string>
<key>com.apple.security.files.bookmarks.app-scope</key>          <true/>
<key>com.apple.security.files.user-selected.read-write</key>     <true/>
<key>com.apple.security.network.client</key>                     <true/>
<key>com.apple.security.device.audio-input</key>                 <true/>
```
What each is for: `files.bookmarks.app-scope` is required for the security-scoped
bookmarks that remember collection folders across launches; `network.client` also
covers the optional cloud AI providers and the assistant's web search/fetch
tools; `application-groups` (`group.com.hellotham.HelloNotes`) shares the
widget's recent/daily-note snapshot with `HelloNotesWidgetsExtension` (see
`docs/xcode-targets-setup.md`); `ubiquity-kvstore-identifier` and
`device.audio-input` back the iCloud key-value preference sync and the
SpeechAnalyzer dictation feature respectively, both shipped per
`docs/native-roadmap.md`.
Verified present in the Release build. Git push/fetch to a remote can reach the
network. Note: SSH‑agent/keychain credential access from a sandbox is still
limited — **HTTPS remotes with a personal access token** are the reliable path
for end users.

### 1c. ✅ Info.plist document types — done
The placeholder `com.example.*` UTIs were replaced with a proper Markdown
declaration (now in `HelloNotes/Info.plist`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>net.daringfireball.markdown</string>
                <string>public.plain-text</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
```

### 1d. ✅ Export‑compliance key — done
`ITSAppUsesNonExemptEncryption` = `false` is set in `Info.plist` (the app uses only
exempt TLS/HTTPS), so App Store Connect won’t ask on each upload.

### 1e. Confirm distribution signing
Target ▸ **Signing & Capabilities** ▸ **Release**:
- **Automatically manage signing** ✔
- **Team:** Hello Tham Pty. Ltd. (`RPL5R637DS`)
- Signing Certificate resolves to **Apple Distribution** for the Release config.
Nothing else to do — Xcode makes the cert/profile on first archive.

### 1f. Version & build number policy
- First submission was `1.0` (build `1`); as of this doc pass the repo carries
  `1.3.2` (build `8`) — **do not trust that number**, read
  `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` fresh from
  `HelloNotes.xcodeproj/project.pbxproj` (every target repeats the same pair;
  any one occurrence is representative), since both move on every release and
  this line will be stale again the next time either bumps.
- **Every** upload needs a **unique, higher build number** — shared across
  *both* platforms, since one app record covers macOS and iOS. Bump
  `CURRENT_PROJECT_VERSION` (`1 → 2 → …`) for re‑uploads of the same version;
  bump `MARKETING_VERSION` (`1.0 → 1.1`) for a new public version.

### 1g. Editor dependency
The editor is the in-repo **`Packages/NotesEditor`** package (MarkdownCore +
MarkdownEditor + GFMRender); GFM rendering/parity is provided by Apple's
`swift-cmark` (`gfm` branch), pinned in `Package.resolved` for reproducible
release builds. The former `ChristineTham/swift-markdown-engine` fork was
removed at M4 and is no longer a dependency.

### 1h. Final local check
A shared scheme (`HelloNotes.xcodeproj/xcshareddata/xcschemes/HelloNotes.xcscheme`)
is committed, so these commands (and Appendix A / CI) work from a clean checkout: 
```bash
xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes \
  -destination 'platform=macOS' -only-testing:HelloNotesTests test   # green
xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes \
  -destination 'platform=macOS' -configuration Release build         # builds clean
# …and BOTH slices, exactly as the archive builds them:
xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes \
  -destination 'generic/platform=macOS' -configuration Release build
```
This is the macOS half only. For the iOS half, run the iOS test/build commands
in the repo-root `CLAUDE.md` (Commands section) — kept there rather than
duplicated here, so there is exactly one place these commands can drift from
reality instead of two.

> ### ⚠️ The Release build is not optional — Debug proves nothing about it
> **A green Debug build can hide a hard shipping blocker.** On 2026‑07‑25 every
> Release build was failing while Debug was perfectly clean: `swift-frontend`
> **segfaulted** in the SIL `EarlyPerfInliner` — an optimizer pass that only runs
> under `-O` — so no archive, and therefore no DMG or App Store build, could be
> produced at all. It went unnoticed through ~6,400 lines of work because every
> verification build had been Debug. (Cause: a generic class's compiler‑generated
> `deinit`; see [implemented.md §13](implemented.md).)
>
> Two habits that follow:
> - **Run the Release build after any substantial change**, not just before shipping.
> - **When a build fails with no `error:` line, suspect a compiler crash.** Check
>   `~/Library/Logs/DiagnosticReports/swift-frontend-*.ips`, and grep the *full*
>   `xcodebuild` output (not a filtered tail) for `While running pass` — that line
>   names the exact SIL function, which is the fastest route to the trigger:
>   ```bash
>   xcodebuild … 2>&1 > /tmp/rel.log; grep -aE "While running pass|Stack dump" /tmp/rel.log
>   ```
> - `SWIFT_COMPILATION_MODE=singlefile SWIFT_ENABLE_BATCH_MODE=NO` narrows a
>   whole‑module crash to a single file.

---

## 2 · Register the App ID (Developer portal)

<https://developer.apple.com/account> ▸ **Certificates, IDs & Profiles** ▸
**Identifiers** ▸ **＋**.

| Field | Value |
|---|---|
| Type | **App IDs → App** |
| Description | `HelloNotes` |
| Bundle ID | **Explicit** → `com.hellotham.HelloNotes` |
| Capabilities | None required (Sandbox & file access are entitlements, not capabilities). *Leave all off unless you added a network/App‑Group capability in §1b.* |

Click **Continue → Register**.
*(You can skip this — Xcode auto‑creates it on first upload — but registering
explicitly avoids surprises.)*

---

## 3 · Create the app record (App Store Connect)

> **This has already happened.** The app record exists (App ID `6803259848`)
> and now spans **both macOS and iOS**. What follows is the original
> first-creation recipe, kept because it's the right recipe for a *new* app —
> use it as written only if you're standing up a fresh app record from
> scratch. To add a platform to the **existing** record instead (which is what
> happened here: it started macOS-only and iOS was added later), go to
> **App Store Connect ▸ your app ▸ App Information ▸ Platforms ▸ ＋** and pick
> the new platform — do **not** use **＋ New App**, which creates a second,
> unrelated record with its own App ID.

<https://appstoreconnect.apple.com> ▸ **Apps** ▸ **＋** ▸ **New App**.

| Field | Value to paste |
|---|---|
| Platforms | ☑ **macOS** ☑ **iOS** *(check every platform you're shipping at creation — adding one later uses the Platforms flow above instead)* |
| Name | `HelloNotes` *(must be globally unique; if taken, try `HelloNotes – Markdown` or `HelloNotes Knowledge Base`)* |
| Primary language | `English (Australia)` (or your preference) |
| Bundle ID | select **com.hellotham.HelloNotes** |
| SKU | `HELLONOTES-001` |
| User access | **Full Access** |

**Create.**

---

## 4 · Version metadata (the `1.0` page → “Prepare for Submission”)

Paste these into the corresponding fields.

**Subtitle** (≤30 chars):
```
Local-first Markdown notes
```

**Promotional text** (≤170 chars, editable any time without review):
```
A fast, private Markdown knowledge base for Mac, iPhone and iPad. Wiki-links, backlinks, a graph, diagrams, maths and on-device AI — your notes stay plain files you own.
```

**Description** (≤4000 chars):
```
HelloNotes is a fast, private, local-first Markdown knowledge base for Mac, iPhone and iPad. Your notes are plain .md files in a folder you choose — no account, no lock-in, no cloud required.

WRITE IN LIVE MARKDOWN
• A native editor with live styling — headings, bold, lists, tables and syntax-highlighted code
• LaTeX math ($…$ and $$…$$) and Mermaid diagrams rendered inline
• Obsidian-style callouts, hidden comments, and a clean editor that tucks YAML front matter into an editable Properties panel

CONNECT YOUR IDEAS
• [[Wiki-links]] with autocomplete, including links straight to a heading
• Backlinks and unlinked mentions, with one-click linking
• #tags (nested) with autocomplete, searchable from the inspector
• Note transclusion — embed a whole note or a single section
• An interactive graph view of your whole vault

FIND ANYTHING
• Full-text search and “Open Quickly” across notes and headings
• Bookmarks, daily notes and templates

AI, ON YOUR TERMS
• Summarise a note, suggest tags and links — powered by Apple Intelligence, entirely on-device
• “Ask your library”: answers grounded in your own notes, with citations
• An agentic Assistant that can search, read, and (with your approval) edit notes
• Bring your own model: fully local (Apple, MLX, Ollama, LM Studio) or your own cloud API key (Anthropic, OpenAI-compatible, Gemini)
On-device models send nothing off your device. Cloud providers are optional, off by default, and use your own key — note content goes only to the provider you configure.

VERSION HISTORY WITH GIT
• Built-in Git: initialise a repo, browse a note’s history and restore earlier versions

EXPORT & MORE
• Export to HTML or PDF
• Multi-tab editing and open-in-new-window
• Full light and dark support, keyboard-first

SUPPORT THE APP
Every feature is included for everyone. Backing HelloNotes — a one-off Champion contribution or an annual commercial licence — adds one thing: you can send a support request from inside the app. Nothing else is gated.

Your files stay yours — readable in any editor, syncable with any tool. HelloNotes just makes them a joy to think in.

Terms of Use (EULA): https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
Privacy Policy: https://hellotham.com/hellonotes/privacy
```

> **The EULA link in the Description is not optional.** Guideline 3.1.2(c) has
> two halves and build 14 was rejected for missing both: the disclosures in the
> binary (which `SupportSettingsView` renders and `SupportContractTests` guards)
> **and**, when using Apple's standard EULA, a link to it in the App Description
> itself. The app can be perfect and still be rejected for the description.
> Both URLs above return 200 — and note the privacy one takes **no trailing
> slash**: `…/privacy` is 200, `…/privacy/` is 404. Check with `curl`, never by
> reading.

**Keywords** (≤100 chars, comma‑separated, no spaces):
```
markdown,knowledge base,wiki,backlinks,zettelkasten,pkm,notes,notetaking,git,graph,local,privacy
```

**Support URL** (required — replace with a real page you control):
```
https://hellotham.com/hellonotes/support
```

**Marketing URL** (optional):
```
https://hellotham.com/hellonotes/
```

**Copyright**:
```
© 2026 Hello Tham
```

**Version** / **What’s New in This Version** — for 1.3.2:
```
HelloNotes runs properly on iPad now. Typing keeps up on a large vault, formatting lives in the system bar above the keyboard, and in portrait the navigation band splits into folders and notes so about a quarter more fits on screen.

A note that has not finished downloading from iCloud no longer opens blank — the editor waits for the file, says which note it is waiting for, and will not save a buffer it never loaded.

Opening a collection now notices what changed while the app was closed, and a folder it cannot read says so instead of quietly going missing.

Also: wiki-links show their display text rather than their target, the graph resolves links written as a folder path, Ask Your Library formats its answers, and the spell checker stops underlining Markdown vocabulary.
```

*(For 1.0 this said "Initial release." — it is per-version text and needs
rewriting for each submission, which is easy to miss because the field keeps its
previous contents.)*

**App Review Information** (bottom of the page):
- **Sign-in required:** No.
- **Notes to reviewer** (paste):
  ```
  HelloNotes is a local-first Markdown editor. Nothing needs to be set up: a sample collection is bundled in the app and opens by itself on first launch, so the tour, the manual and every feature below are reachable immediately. To use your own notes instead, choose Open… and pick any folder of .md files.

  All notes stay on-device in plain files; no account and no network are required for any core feature. The optional Intelligence features default to Apple's on-device Foundation Models (shown only on Apple Intelligence hardware); a user may instead configure a cloud provider with their own API key, in which case note content goes to that provider under the user's own account.

  IN-APP PURCHASES. Settings ▸ Support ▸ Support HelloNotes shows both products: Champion (a repeatable one-off contribution) and Commercial (an annual auto-renewable subscription). That screen carries the subscription's title, length, price per period, and working links to the Terms of Use (EULA) and the privacy policy. Every feature of the app is included for everyone; the only thing backing it adds is the ability to send a support request from inside the app, and that screen says so.
  ```

  The path in that note is worth keeping accurate — it is how the reviewer finds
  the purchase screen. `assets/iap-review/` holds a screenshot of it and an
  82-second recording that walks the same path and follows both policy links
  into Safari, for the Resolution Center if 3.1.2(c) is raised.
- **Contact:** your name, phone, email.

---

## 5 · App Privacy

App Store Connect ▸ your app ▸ **App Privacy**.

- **Data collection:** choose **“No, we do not collect data from this app.”**
  This remains accurate under Apple's definition (data "collected" = transmitted
  off-device **to the developer or their partners**): HelloNotes has no backend,
  no analytics, and no developer-operated endpoint. Everything the app sends
  goes to **user-configured destinations under the user's own credentials** —
  a Git remote, a cloud LLM provider the user enabled with their own API key,
  or a web page the assistant fetches at the user's request. Disclose these
  user-directed flows plainly in the privacy policy (Appendix C) and the app
  description; do **not** claim "nothing is ever sent to a server."
- **Privacy Policy URL** (required even when nothing is collected). ✅ **Live** — the
  landing site is deployed at <https://hellotham.com/hellonotes/> with working
  Privacy and Support pages. Paste:
  ```
  https://hellotham.com/hellonotes/privacy
  ```

---

## 6 · Age rating

App Store Connect ▸ **Age Rating** ▸ **Edit** ▸ answer **None / No** to every
category (no violence, no mature content, no gambling, no unrestricted web, etc.).
Result: **4+**.

---

## 7 · Pricing & availability

- **Pricing:** **App Store Connect ▸ Pricing and Availability ▸** choose a price
  or **Free** (price tier **AUD 0.00**).
- **Availability:** all territories (default) unless you want to restrict.

---

## 8 · Screenshots (required)

Mac screenshots must be exactly one of: **1280×800, 1440×900, 2560×1600, 2880×1800**.
Provide **at least 1** (up to 10). Retina capture is easiest:

1. Run the Release app, open the bundled **SampleVault** so the window looks full.
2. Resize the window to a clean shape, then capture just the window:
   **⌘⇧4**, press **Space**, click the window → saves a Retina PNG to the Desktop.
3. If the PNG isn’t one of the accepted sizes, scale/pad it to **2560×1600**:
   ```bash
   sips -z 1600 2560 --padColor FFFFFF shot.png --out shot-2560x1600.png
   ```
**✅ A ready-made set of 5 frames at 2560×1600 is committed** — but not where an
earlier draft of this section said. They live in **`website/src/assets/screens/`**
as `light_01…05.png` and `dark_01…05.png`: the site's marketing shots, each the
brand gradient plus a caption plus the window, and already one of Apple's four
accepted Mac sizes. The five scenes are the sidebar and editor, maths and
diagrams inline, callouts and properties, the graph view, and Ask Library.

`dist/` is a build artefact and is **gitignored**, so `dist/screenshots/` does not
exist until something puts it there — an earlier version of this section promised
a folder that is never checked in. Assemble it:

```bash
mkdir -p dist/screenshots/dark
for i in 1 2 3 4 5; do
  cp website/src/assets/screens/light_0$i.png dist/screenshots/screenshot_0$i.png
  cp website/src/assets/screens/dark_0$i.png  dist/screenshots/dark/screenshot_0$i.png
done
```

Upload one appearance or the other — Apple allows up to 10, but a gallery that
switches halfway reads as inconsistent. To refresh them against a newer build,
capture the five scenes with the recipe above and composite with
`scripts/make-screenshots.py` (needs Pillow: `python3 -m venv venv &&
./venv/bin/pip install Pillow`); the raw capture is a manual step by design.

**iOS screenshots are required — the app record now includes iOS, not just
macOS.** Apple asks for one set per device *family* the app supports, and you
only need to supply the largest display in each family; App Store Connect
scales down to populate the rest (confirmed against Apple's published
screenshot spec this session — sizes are revised periodically, so re-check at
submission time):

- **iPhone — 6.9-inch, 1320×2868.** Required because the app's
  `TARGETED_DEVICE_FAMILY` includes iPhone (family `1`), not just iPad — this
  is a phone-capable app (see `docs/shell-chrome.md`'s "P5 Phone capturer"
  persona), so skipping iPhone shots is not an option the way it might be for
  an iPad-only app.
- **iPad — 13-inch, 2064×2752** (the M4/M5 iPad Pro class). The repo already
  has a device sized for this: **`HN-iPad13`** (an
  `iPad-Pro-13-inch-M5-12GB` simulator, distinct from the `HN-iPad` 11-inch
  one used for day-to-day testing in `CLAUDE.md`) — its native capture
  (`xcrun simctl io HN-iPad13 screenshot out.png`) lands exactly on
  2064×2752, no padding/scaling step needed the way the Mac shots below need
  one. The old **`HN-iPad`** (11-inch, 1668×2420) is still right for
  day-to-day iOS testing — just don't submit its captures to App Store
  Connect, which rejects that size for the 13-inch requirement.

Neither iPhone nor iPad has a marketing-shot pipeline yet (no equivalent of
`website/src/assets/screens/` or `scripts/make-screenshots.py` for iOS) — raw,
unbranded simulator captures satisfy App Store Connect's requirement, but
producing branded ones like the Mac set below is still open work.

---

## 9 · Build: archive & upload

Both platforms upload to the same app record, but each needs its own archive —
Options A and B below are **macOS**; Option C is the iOS equivalent.

### Option A — Xcode, macOS (simplest)
1. Toolbar destination → **Any Mac (Apple Silicon, Intel)**.
2. **Product ▸ Archive.**
3. **Organizer** opens → select the archive → **Distribute App** →
   **App Store Connect** → **Upload** → keep the defaults (Automatic signing) →
   **Upload**.
4. Wait for “processing” to finish in App Store Connect (minutes → ~1 hr); you’ll
   get an email when the build is ready.

For iOS in Xcode instead of the command line, the same four steps work with the
toolbar destination set to **Any iOS Device (arm64)**.

### Option B — Command line, macOS

> **The repo-root `ExportOptions.plist` is *not* this file.** It is
> `method = developer-id`, for the notarised DMG, and exporting an App Store
> build through it signs for the wrong distribution channel. The App Store
> plists are `ExportOptions-AppStore-macOS.plist` and
> `ExportOptions-AppStore-iOS.plist`; both carry `destination = upload`, so the
> export step *is* the upload. This section described `ExportOptions.plist` as
> though it were the app-store one, which it has never been.

`ExportOptions-AppStore-macOS.plist` holds:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>            <string>app-store-connect</string>
    <key>teamID</key>            <string>RPL5R637DS</string>
    <key>destination</key>       <string>upload</string>
    <key>signingStyle</key>      <string>automatic</string>
</dict>
</plist>
```
Then (see the full script in Appendix A):
```bash
xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath build/HelloNotes.xcarchive archive

xcodebuild -exportArchive -archivePath build/HelloNotes.xcarchive \
  -exportOptionsPlist ExportOptions-AppStore-macOS.plist -exportPath build/export \
  -allowProvisioningUpdates
```
The export step uploads directly. (For CI, authenticate `notarytool`/`altool`
with an **App Store Connect API key** instead of your Apple ID.)

### Option C — iOS, command line

`ExportOptions-AppStore-iOS.plist` is the upload plist
(`method = app-store-connect` — the same method TestFlight and an App Store
release both use — with `destination = upload`). The older
`ExportOptions-iOS.plist` is the same method but `destination = export`, so it
writes an `.ipa` locally and uploads nothing; keep it for producing an artefact
to inspect, and use the AppStore one to ship. Toolbar/GUI archiving works
too (destination **Any iOS Device (arm64)**), but headless is the same shape as
the macOS path above with the iOS destination and plist swapped in:
```bash
xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/HelloNotes-iOS.xcarchive archive

xcodebuild -exportArchive -archivePath build/HelloNotes-iOS.xcarchive \
  -exportOptionsPlist ExportOptions-AppStore-iOS.plist -exportPath build/export-ios \
  -allowProvisioningUpdates
```
Same App Store Connect App ID, same bundle ID, same build-number rule (§1f) —
this uploads as an iOS build attached to the *same* app record the macOS
archive uploads to, not a separate app.

---

## 10 · Attach the build & submit for review

Back in App Store Connect on the **1.0** page:
1. **Build** section → **＋** (or *Add Build*) → pick the processed build.
2. **Export Compliance:** if you added the `ITSAppUsesNonExemptEncryption=false`
   key (§1d) you won’t be asked; otherwise answer **“Uses standard encryption
   only / exempt.”**
3. **Version Release:** *Automatically release after approval* (or Manual).
4. Confirm §4–§7 are all complete (green), then **Add for Review → Submit to App
   Review**.

Review is typically **~1–3 days**. Status changes arrive by email.

---

## 11 · After submission — common rejection triggers to pre‑empt

- **Incomplete metadata / missing screenshots** → the #1 delay. Fill everything.
- **Placeholder content** (the `com.example.*` UTIs) → fixed in §1c.
- **Broken/parked Support or Privacy URLs** → they must resolve to real pages.
- **Crash on a clean machine** → test on a Mac without your dev tools, from a fresh
  vault, before submitting.
- **Feature only works with entitlements you didn’t ship** → if you advertise Git
  remote sync, ship §1b; otherwise don’t mention it.
- **Guideline 2.1 “what does this need?”** → the reviewer notes in §4 cover the
  vault‑folder step and on‑device AI.

---

## Appendix A · One‑command release script

Save as `scripts/release.sh`, `chmod +x`, run from the repo root:
```bash
#!/usr/bin/env bash
set -euo pipefail
SCHEME=HelloNotes
ARCHIVE=build/HelloNotes.xcarchive

rm -rf build && mkdir -p build
echo "▸ Archiving (Release)…"
xcodebuild -project HelloNotes.xcodeproj -scheme "$SCHEME" \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" clean archive

echo "▸ Exporting & uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export \
  -allowProvisioningUpdates

echo "✓ Uploaded. Watch App Store Connect for the processed build."
```

## Appendix A2 · Direct distribution — signed, notarized DMG

> The `/release` skill (`.claude/skills/release/`) packages this sequence plus
> the site-metadata sync — keep the two in step when this appendix changes.

The App Store path is above; this is the **outside‑the‑store** path (Developer ID),
which produces `dist/HelloNotes.dmg`. `scripts/package-dmg.sh` does everything from
an already‑notarized `.app` onward, so the only question is how you produce that app.

**One‑time:** a *Developer ID Application* cert (see [signing.md](signing.md) Part 6)
and a stored notary profile:
```bash
xcrun notarytool store-credentials "hellotham-notary" \
  --apple-id info@hellotham.com --team-id RPL5R637DS
```
**The stored profile has twice vanished mid-pipeline (2026-08-12).** Both times
`xcrun notarytool` went from working to `No Keychain password item found for
profile: hellotham-notary`, with the login keychain rewritten in between and
`security find-generic-password -s com.apple.gke.notary.tool` confirming the item
was genuinely gone (the keychain itself was unlocked, `no-timeout`). Once it
failed straight after archive+export; once it survived export, notarized the
*app* successfully, then was gone by the time the DMG was signed a minute later —
so **the culprit is not pinned down**, and it is not simply "Xcode ate it".

Two practical consequences:

- Budget for re-running `store-credentials` mid-release. Nothing else is lost —
  the archive, the export and the app's own notarization all survive; only the
  remaining `notarytool` calls fail.
- Consider storing the profile in a **dedicated keychain** that the build
  toolchain has no reason to touch, and passing it explicitly:

  ```bash
  security create-keychain -p "" notary.keychain-db
  security unlock-keychain -p "" notary.keychain-db
  xcrun notarytool store-credentials "hellotham-notary" \
    --apple-id info@hellotham.com --team-id RPL5R637DS \
    --keychain ~/Library/Keychains/notary.keychain-db
  # then add --keychain … to every notarytool call
  ```

The prompt wants an **app‑specific password** (account.apple.com → Sign‑In and
Security → App‑Specific Passwords), *not* the Apple Account password. Changing the
Apple Account password revokes it, and you'd re‑run this.

**Either** archive + export in Xcode (Organizer ▸ Distribute App ▸ Direct
Distribution), **or** headlessly — no Xcode UI needed:
```bash
# 1 · Archive (universal: arm64 + x86_64)
xcodebuild archive -project HelloNotes.xcodeproj -scheme HelloNotes \
  -destination 'generic/platform=macOS' \
  -archivePath build/HelloNotes.xcarchive -allowProvisioningUpdates

# 2 · Export with Developer ID  (ExportOptions.plist: method=developer-id,
#     teamID=RPL5R637DS, signingStyle=automatic)
xcodebuild -exportArchive -archivePath build/HelloNotes.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export \
  -allowProvisioningUpdates

# 3 · Notarize + staple the .app (package-dmg.sh requires this — it runs
#     `stapler validate` on its input and refuses an un-notarized app)
ditto -c -k --keepParent build/export/HelloNotes.app build/HelloNotes.zip
xcrun notarytool submit build/HelloNotes.zip --keychain-profile "hellotham-notary" --wait
xcrun stapler staple build/export/HelloNotes.app

# 4 · Build, sign, notarize and staple the DMG
scripts/package-dmg.sh build/export/HelloNotes.app
```

**Verify what you're shipping** (don't just trust the script's own output — mount it
and assess the app as a user's Mac would):
```bash
spctl --assess -t open --context context:primary-signature --verbose dist/HelloNotes.dmg
#   → accepted / source=Notarized Developer ID
hdiutil attach dist/HelloNotes.dmg -nobrowse -mountpoint /tmp/hn
lipo -info /tmp/hn/HelloNotes.app/Contents/MacOS/HelloNotes   # x86_64 arm64
spctl --assess --type execute --verbose /tmp/hn/HelloNotes.app
xcrun stapler validate /tmp/hn/HelloNotes.app                 # works offline
hdiutil detach /tmp/hn
```

> **Gotchas learned the hard way**
> - `package-dmg.sh` **overwrites `dist/HelloNotes.dmg` (`rm -f`)**. Move the previous
>   build aside first if you want to keep it.
> - The DMG bakes in whatever `Config/Secrets.xcconfig` held at build time. Building
>   on a machine without it ships with **empty cloud provider keys** — the app still
>   runs, those providers just report "not configured".
> - Do §1h's Release check *before* archiving: an archive is the slowest possible way
>   to discover a Release‑only compile failure.

## Appendix B · Pre‑submission checklist

- [ ] Paid Developer Program active; Paid/Free Apps agreement **Active**
- [ ] §1 hardening done (min OS decided, Git‑network decided, Info.plist cleaned,
      encryption key added, Release signs with Apple Distribution / Hello Tham)
- [ ] Version `1.0`, build number unique & higher than any prior upload
- [ ] App icon complete (already shipped) and app builds clean in **Release**
- [ ] App ID `com.hellotham.HelloNotes` registered
- [ ] App record created; name accepted
- [ ] Description, subtitle, promo, keywords, URLs, copyright pasted (§4)
- [ ] App Privacy = *Data Not Collected*; Privacy Policy URL live (§5)
- [ ] Age rating 4+ (§6); pricing set (§7)
- [ ] ≥1 screenshot at an accepted size (§8)
- [ ] Build archived, uploaded, processed, and attached (§9–10)
- [ ] Reviewer notes filled; **Submitted** ✅

## Appendix C · Privacy policy (host this text, then link it in §5)

> **HelloNotes — Privacy Policy**
>
> HelloNotes is a local‑first application. Your notes are stored as plain files on
> your own device, in a folder you select. **We do not collect, transmit, sell, or
> have access to your notes or any personal data.**
>
> - **No account** is required or created.
> - **No analytics or tracking** is performed.
> - **On‑device intelligence:** the default summarise / suggest / “ask your
>   library” features use Apple’s on‑device Foundation Models or local models
>   you run yourself (MLX, Ollama, LM Studio). Content processed this way never
>   leaves your device.
> - **Optional cloud AI:** you may connect a cloud model provider (such as
>   Anthropic, an OpenAI‑compatible service, or Google Gemini) using **your own
>   API key**. When you do, the notes and questions you submit to those features
>   are sent to that provider under your account and their privacy terms.
>   Cloud providers are off until you configure one, and your key is stored in
>   the Keychain. We never see, proxy, or store this traffic.
> - **Assistant web tools:** if you ask the assistant to search or fetch a web
>   page, the query/URL is sent to the search engine or site in question.
> - **Version control:** if you choose to use the built‑in Git features and
>   configure your own remote, your notes are sent only to the destination you
>   configure, under your control. HelloNotes is not that destination.
>
> Because we hold no user data, there is nothing for us to disclose, share, or
> delete on request. Questions: `info@hellotham.com`.
>
> _Last updated: 2026._
