# Productionising HelloNotes & shipping to the Mac App Store

A complete, do-this-in-order runbook to take HelloNotes from a working dev build
to an approved Mac App Store release. Copy‑paste values are given for every field.

> **Scope:** this targets the **Mac App Store** (the shippable target — the editor
> engine is macOS‑only). iOS/visionOS are declared in the project but not
> production‑ready; ship macOS first.

## At‑a‑glance facts

| Thing | Value |
|---|---|
| App name | **HelloNotes** |
| Bundle ID | `com.hellotham.HelloNotes` |
| Apple team | **Hello Tham Pty. Ltd.** — `RPL5R637DS` (Organization; Account Holder Chris Tham; signs as `Apple Development / Apple Distribution`) |
| Category | Productivity (`public.app-category.productivity`) |
| Version / build | `MARKETING_VERSION = 1.0`, `CURRENT_PROJECT_VERSION = 1` |
| Sandbox / Hardened Runtime | Enabled (required for the store) |
| Entitlements | App Sandbox · User-selected files (r/w) · Network client (Git sync) |
| Min OS | **macOS 15.0** |
| Website | <https://hellotham.github.io/hellonotes/> (Privacy · Support live) |

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

> **✅ Already done in this repo:** §1a (min OS → **macOS 15.0**), §1b (Git remote
> sync entitlement), §1c (Info.plist cleaned), §1d (`ITSAppUsesNonExemptEncryption`),
> plus the app icon and screenshots. **Left for you:** §1e–§1h (confirm signing,
> version policy, optional dependency pin, and the final build).

Work through each; several are genuine blockers or reviewer red flags.

### 1a. ✅ Minimum macOS version — done
Lowered to **`MACOSX_DEPLOYMENT_TARGET = 15.0`** so the app installs on macOS 15+
(Release build verified clean). On‑device Apple Intelligence stays guarded with
`#available(macOS 26.0, *)`, so it degrades gracefully on older systems. Raise or
lower further via Xcode ▸ target ▸ **General** ▸ *Minimum Deployments* if you wish.

### 1b. ✅ Git remote sync — enabled
The app now ships an explicit entitlements file
(`HelloNotes/HelloNotes.entitlements`, wired via `CODE_SIGN_ENTITLEMENTS`) granting
**Outgoing Connections (Client)** alongside the sandbox and user‑selected‑files
entitlements:
```xml
<key>com.apple.security.app-sandbox</key>            <true/>
<key>com.apple.security.files.bookmarks.app-scope</key> <true/>
<key>com.apple.security.files.user-selected.read-write</key> <true/>
<key>com.apple.security.network.client</key>          <true/>
```
(`files.bookmarks.app-scope` is required for the security-scoped bookmarks that
remember collection folders across launches; `network.client` also covers the
optional cloud AI providers and the assistant's web search/fetch tools.)
Verified in the Release build (all three present, no conflicts). Git push/fetch to
a remote can now reach the network. Note: SSH‑agent/keychain credential access from
a sandbox is still limited — **HTTPS remotes with a personal access token** are the
reliable path for end users.

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
- First submission: `1.0` (build `1`) — already set.
- **Every** upload needs a **unique, higher build number**. Bump
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
```

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

<https://appstoreconnect.apple.com> ▸ **Apps** ▸ **＋** ▸ **New App**.

| Field | Value to paste |
|---|---|
| Platforms | ☑ **macOS** |
| Name | `HelloNotes` *(must be globally unique; if taken, try `HelloNotes – Markdown` or `HelloNotes Knowledge Base`)* |
| Primary language | `English (Australia)` (or your preference) |
| Bundle ID | select **com.hellotham.HelloNotes** |
| SKU | `HELLONOTES-MAC-001` |
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
A fast, private Markdown knowledge base for your Mac. Wiki-links, backlinks, a graph view, diagrams, math and on-device AI — your notes stay plain files you own.
```

**Description** (≤4000 chars):
```
HelloNotes is a fast, private, local-first Markdown knowledge base for your Mac. Your notes are plain .md files in a folder you choose — no account, no lock-in, no cloud required.

WRITE IN LIVE MARKDOWN
• A native editor with live styling — headings, bold, lists, tables and syntax-highlighted code
• LaTeX math ($…$ and $$…$$) and Mermaid diagrams rendered inline
• Obsidian-style callouts, hidden comments, and a clean editor that tucks YAML front matter into an editable Properties panel

CONNECT YOUR IDEAS
• [[Wiki-links]] with autocomplete, including links straight to a heading
• Backlinks and unlinked mentions, with one-click linking
• #tags (nested) with autocomplete and a tag sidebar
• Note transclusion — embed a whole note or a single section
• An interactive graph view of your whole vault

FIND ANYTHING
• Full-text search and “Open Quickly” across notes and headings
• Bookmarks, daily notes and templates

AI, ON YOUR TERMS
• Summarise a note, suggest tags and links — powered by Apple Intelligence, entirely on your Mac
• “Ask your library”: answers grounded in your own notes, with citations
• An agentic Assistant that can search, read, and (with your approval) edit notes
• Bring your own model: fully local (Apple, MLX, Ollama, LM Studio) or your own cloud API key (Anthropic, OpenAI-compatible, Gemini)
On-device models send nothing off your Mac. Cloud providers are optional, off by default, and use your own key — note content goes only to the provider you configure.

VERSION HISTORY WITH GIT
• Built-in Git: initialise a repo, browse a note’s history and restore earlier versions

EXPORT & MORE
• Export to HTML or PDF
• Multi-tab editing and open-in-new-window
• Full light and dark support, keyboard-first

Your files stay yours — readable in any editor, syncable with any tool. HelloNotes just makes them a joy to think in.
```

**Keywords** (≤100 chars, comma‑separated, no spaces):
```
markdown,knowledge base,wiki,backlinks,zettelkasten,pkm,notes,notetaking,git,graph,local,privacy
```

**Support URL** (required — replace with a real page you control):
```
https://hellotham.github.io/hellonotes/support.html
```

**Marketing URL** (optional):
```
https://hellotham.github.io/hellonotes/
```

**Copyright**:
```
© 2026 Hello Tham
```

**Version** / **What’s New in This Version** (for 1.0):
```
Initial release.
```

**App Review Information** (bottom of the page):
- **Sign-in required:** No.
- **Notes to reviewer** (paste):
  ```
  HelloNotes is a local-first Markdown editor. On first launch, click "Open…" and choose any folder of .md files (a demo "SampleVault" ships with the source repo). All notes stay on-device in plain files; no account or network is required for core functionality. The optional Intelligence features default to Apple's on-device Foundation Models (shown only on Apple Intelligence hardware); users may alternatively configure a cloud model provider with their own API key, in which case submitted content goes to that provider under the user's own account.
  ```
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
  landing site is deployed at <https://hellotham.github.io/hellonotes/> with working
  Privacy and Support pages. Paste:
  ```
  https://hellotham.github.io/hellonotes/privacy.html
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
**✅ A ready-made set of 5 screenshots at 2560×1600 is already generated** in
`dist/HelloNotes.dmg`’s sibling folder **`dist/screenshots/`** (`screenshot_01…05.png`
— note list, math+diagrams, callouts, graph, ask-vault, each on a branded gradient
with captions). Upload those directly, or capture your own with the recipe above.

---

## 9 · Build: archive & upload

### Option A — Xcode (simplest)
1. Toolbar destination → **Any Mac (Apple Silicon, Intel)**.
2. **Product ▸ Archive.**
3. **Organizer** opens → select the archive → **Distribute App** →
   **App Store Connect** → **Upload** → keep the defaults (Automatic signing) →
   **Upload**.
4. Wait for “processing” to finish in App Store Connect (minutes → ~1 hr); you’ll
   get an email when the build is ready.

### Option B — Command line
Create `ExportOptions.plist` in the repo root:
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
  -exportOptionsPlist ExportOptions.plist -exportPath build/export \
  -allowProvisioningUpdates
```
The export step uploads directly. (For CI, authenticate `notarytool`/`altool`
with an **App Store Connect API key** instead of your Apple ID.)

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
>   leaves your Mac.
> - **Optional cloud AI:** you may connect a cloud model provider (such as
>   Anthropic, an OpenAI‑compatible service, or Google Gemini) using **your own
>   API key**. When you do, the notes and questions you submit to those features
>   are sent to that provider under your account and their privacy terms.
>   Cloud providers are off until you configure one, and your key is stored in
>   the macOS Keychain. We never see, proxy, or store this traffic.
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
