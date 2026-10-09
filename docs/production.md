# Productionising HelloNotes & shipping to the App Store

A complete, do-this-in-order runbook to take HelloNotes from a working dev build
to an approved App Store release. Copy‑paste values are given for every field.

> **Scope:** HelloNotes ships on **both macOS and iOS**, from a single App Store
> Connect app record (App ID `6803259848`). **1.3.2 was approved and released on
> 2026-09-07** and both platforms read *Ready for Distribution*; the public
> listing is <https://apps.apple.com/app/id6803259848>.
>
> **1.3.3 is in preparation** on `release/1.3.3`: macOS 27 / iOS 27 floor, every
> AI feature rebuilt on Apple Foundation Models (on-device, MLX, and Private
> Cloud Compute once Apple grants the entitlement), the sixteen bespoke provider
> integrations removed, and China mainland to be re-enabled. Its App Store copy is
> in [`app-store-listing.md`](app-store-listing.md).
>
> They share one app record and one bundle ID. **They do not share metadata.**
> Promotional text, description, screenshots, What's New and the reviewer notes
> are *per platform* — live proof: the macOS description opens "…for your Mac"
> and the iOS one "…for iPhone and iPad". An earlier version of this line said
> the two shared one set, which is the kind of error that gets a fix applied to
> one platform and called done (§8 has a case where exactly that happened). They
> also differ in the build/export step (§9) and the screenshot sizes (§8).
>
> **One store page, though.** Apple serves both platforms as a single unified
> product page, and `?mt=12` — the legacy Mac-App-Store selector — is *dropped on
> redirect*. There is no separate Mac URL to link to. visionOS is still listed in the project's
> `SUPPORTED_PLATFORMS` (`xros`) purely because `SDKROOT = auto` pulls it in
> automatically for a multiplatform target — there is no visionOS-specific
> target, entitlement, or submission, and nothing below should be read as
> visionOS being production-ready.

## At‑a‑glance facts

| Thing | Value |
|---|---|
| App name | **HelloNotes** |
| Platforms | **macOS + iOS**, one App Store Connect app record — both **live on the App Store since 2026-09-07** |
| App Store Connect App ID | `6803259848` |
| Bundle ID | `com.hellotham.HelloNotes` |
| SKU | `HELLONOTES-001` |
| Apple team | **Hello Tham Pty. Ltd.** — `RPL5R637DS` (Organization; Account Holder Chris Tham; signs as `Apple Development / Apple Distribution`) |
| Category | Productivity (`public.app-category.productivity`) |
| Version / build | `MARKETING_VERSION = 1.3.3`, `CURRENT_PROJECT_VERSION = 28` — uploaded to TestFlight (both platforms) on 2026-10-09. **Mac builds 23 and 24 were rejected** (2.4.5(i), the Hugging Face temporary exception); 25 was the first without it and passed review, 26 makes its Access MLX Models panel open in the right folder, 27 carries everything since (§10f), and 28 the rearrangement asked for after testing 27 (§10g). 1.3.2 build 21 is what is live. **Verify fresh**: these bump every release, so read them from `HelloNotes.xcodeproj/project.pbxproj` rather than trusting this table (it has been stale here twice) |
| Store listing | <https://apps.apple.com/app/id6803259848> — one page for Mac, iPhone and iPad |
| Sandbox / Hardened Runtime | Enabled (required for the store) |
| Entitlements | App Sandbox · User-selected files (r/w) · Network client (Git sync, MLX model downloads, the Assistant's web tools) · App Group · iCloud KV store · Audio input — see §1b for the full current list, and §1b-PCC for the one still to come |
| Min OS | **macOS 26.5 / iOS 26.5** for 1.3.2 · **macOS 27 / iOS 27 from 1.3.3** |
| Website | <https://hellotham.com/hellonotes/> — Privacy, Support, and (since 2026-09-15) the App Store links and iPhone/iPad screenshots |

---

## 0 · Prerequisites (one‑time)

1. **Apple Developer Program** membership — **paid, active** ($99/yr). The free
   account can only run locally; it cannot upload to the store. Enrol at
   <https://developer.apple.com/programs/> using the **Hello Tham** Apple ID.
2. You are **Account Holder / Admin / App Manager** on the team in both
   [App Store Connect](https://appstoreconnect.apple.com) and the
   [Developer portal](https://developer.apple.com/account).
3. **Xcode 27** (1.3.3 builds against the 27 SDKs; 1.3.2 was Xcode 26) signed in: Xcode ▸ Settings ▸ Accounts ▸ add the Hello Tham Apple
   ID ▸ select the team. Let it create a **“Apple Distribution”** certificate when
   prompted (or Manage Certificates ▸ **+** ▸ *Apple Distribution*).
4. **Agreements:** App Store Connect ▸ **Business** ▸ accept the *Paid Apps* /
   *Free Apps* agreement and complete tax & banking (even for a free app the
   agreement must be **Active**, or your app can’t be released). ✅ Both
   agreements, the bank account and all three tax forms are Active.
   **Also check the Compliance table at the bottom of that page**, which is easy
   to scroll past: it carries per-regulation rows (Digital Services Act, and for
   an Australian entity the *Sharing Economy Reporting Regime*) that can sit at
   **Missing Info** while everything above them reads Active. Nothing blocks
   review, so the first symptom is a payout question much later.

---

## 1 · Project hardening (pre‑flight) — do these before archiving

> **✅ Already done in this repo:** §1a (min OS → **macOS 26.5**), §1b (Git remote
> sync entitlement), §1c (Info.plist cleaned), §1d (`ITSAppUsesNonExemptEncryption`),
> plus the app icon and screenshots. **Left for you:** §1e–§1h (confirm signing,
> version policy, optional dependency pin, and the final build).

Work through each; several are genuine blockers or reviewer red flags.

### 1a. ✅ Minimum macOS version — done
**`MACOSX_DEPLOYMENT_TARGET = 26.5`**, matching iOS — and **27.0 on both from 1.3.3**,
because the rebuilt AI layer uses what only the 27 SDKs have: the `LanguageModel`
protocol that lets an MLX model run in a `LanguageModelSession`, dynamic
profiles, and Private Cloud Compute.

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
bookmarks that remember collection folders across launches (and, from 1.3.3, a
chosen MLX model folder); `network.client` also covers MLX model downloads from
Hugging Face and the assistant's web search/fetch tools; `application-groups` (`group.com.hellotham.HelloNotes`) shares the
widget's recent/daily-note snapshot with `HelloNotesWidgetsExtension` (see
`docs/xcode-targets-setup.md`); `ubiquity-kvstore-identifier` and
`device.audio-input` back the iCloud key-value preference sync and the
SpeechAnalyzer dictation feature respectively, both shipped per
`docs/native-roadmap.md`.
Verified present in the Release build. Git push/fetch to a remote can reach the
network. Note: SSH‑agent/keychain credential access from a sandbox is still
limited — **HTTPS remotes with a personal access token** are the reliable path
for end users.

### 1b-PCC. ⏳ Private Cloud Compute — the entitlement Apple has not granted yet

`com.apple.developer.private-cloud-compute` is a **managed** entitlement: request
it at <https://developer.apple.com/contact/request/private-cloud-compute/>. The
form stays locked (*Access Unavailable*) until the App Store Small Business
Program enrolment is approved; the request was waiting on that as of 2026-09-15.
**Never add the key to `HelloNotes.entitlements` before Apple assigns it** — a
profile without it fails to sign.

**Without it, offering the model crashes the app.** Measured in the signed app:
`PrivateCloudComputeLanguageModel.availability` reports `.available`, and the
first request ends the process with `fatalError("Missing entitlement: …")` inside
Foundation Models. An unsandboxed command-line probe reports the same
availability and does *not* crash, which is exactly how it looks safe. So the app
offers Private Cloud Compute only when built with the `PRIVATE_CLOUD_COMPUTE`
compilation condition (`LanguageModels.privateCloudComputeEnabled`; on the Mac
the signed entitlement is checked at runtime as well).

When Apple grants it, in **one** change:
1. Add `<key>com.apple.developer.private-cloud-compute</key><true/>` to
   `HelloNotes/HelloNotes.entitlements`.
2. Add `PRIVATE_CLOUD_COMPUTE` to the app target's
   `SWIFT_ACTIVE_COMPILATION_CONDITIONS`, Debug **and** Release.
3. Run `PrivateCloudComputeEntitlementTests` (fails if 1 and 2 disagree), then
   `TEST_RUNNER_HN_PCC_PROBE=1 ./scripts/run-tests.sh -only-testing:HelloNotesTests/PrivateCloudComputeProbe`
   for one real request from inside the app.
4. Add Private Cloud Compute to the listing copy (`app-store-listing.md` says
   where) and to the privacy policy, and re-read Apple's current guidance on how
   Private Cloud Compute processing is declared in App Privacy (§5).

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
  `1.3.2` (build `21`) — **do not trust that number**, read
  `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` fresh from
  `HelloNotes.xcodeproj/project.pbxproj` (every target repeats the same pair;
  any one occurrence is representative), since both move on every release and
  this line will be stale again the next time either bumps. It has already been
  stale twice.
- **Every** upload needs a **unique, higher build number** — shared across
  *both* platforms, since one app record covers macOS and iOS. Bump
  `CURRENT_PROJECT_VERSION` (`1 → 2 → …`) for re‑uploads of the same version;
  bump `MARKETING_VERSION` (`1.0 → 1.1`) for a new public version.

> ### ⚠️ The direct download must not out-version the App Store
> The DMG channel and the App Store are separate, and the obvious move when the
> DMG falls behind — ship it as the next patch version — is wrong.
> `scripts/check-download-page.sh` compares the website's version against the
> App Store's with **`!=`**, so once the app is public the two must match
> *exactly*. A 1.3.3 disk image passes every check available before approval and
> starts failing the moment Apple approves 1.3.2 — on a page nobody thinks to
> re-run a checker against after an approval they did not perform.
>
> **Re-cut the DMG under the same version instead**, replacing the release
> asset (`gh release upload v<VERSION> … --clobber`). Done twice for 1.3.2, on
> 3 and 4 September. The cost is that several distinct binaries ship under one
> version string, so the release notes carry a **checksum table** — that is what
> lets a user comparing `shasum` output tell "mine is an older 1.3.2" from "this
> download was tampered with", which is the only question a checksum answers.
> See [implemented.md §49](implemented.md).

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
./scripts/run-tests.sh                                              # green (never a bare xcodebuild test)
xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes -skipPackagePluginValidation \
  -destination 'platform=macOS' -configuration Release build         # builds clean
# …and BOTH slices, exactly as the archive builds them:
xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes -skipPackagePluginValidation \
  -destination 'generic/platform=macOS' -configuration Release build
```
**`-skipPackagePluginValidation` is required from 1.3.3.** mlx-swift's `Cmlx`
target carries a `CudaBuild` build-tool plugin (inert on Apple platforms), and
`xcodebuild` refuses to run a package plugin nobody has trusted — the build fails
at *Validate plug-in* before compiling anything. In Xcode's GUI it is a one-time
**Trust & Enable** prompt instead.
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

## 4 · Version metadata — App Store Connect is the source of truth

> **This section used to hold the description verbatim, and that was a trap.**
> The copy it carried still read *"(Anthropic, OpenAI-compatible, Gemini)"* long
> after that phrase had been removed from the live listing — and removing it was
> what resolved a **Guideline 5 (China)** rejection. Anyone pasting the block
> back in would have re-submitted the rejection. A runbook that duplicates live
> metadata does not stay true; it decays silently and then hands you a
> regression with a straight face.
>
> **So: read the live copy out of App Store Connect, per platform, and treat
> what follows as the *constraints* the copy must satisfy — not as the copy.**

**Metadata is per platform.** The macOS description opens "…for your Mac" and
the iOS one "…for iPhone and iPad"; promotional text, screenshots, What's New
and the reviewer notes diverge the same way. Editing one does not edit the
other, and the page gives you no hint that a sibling exists.

### The rules the copy must satisfy

| Rule | Why, and what it cost |
|---|---|
| **No reference to OpenAI or ChatGPT** — and from 1.3.3 no third-party AI service at all — in name, subtitle, promotional text, description, keywords **or screenshots** | Guideline 5. China tightened its rules on generative-AI services, and a metadata mention is enough. The 1.3.2 live text names *Anthropic, Mistral, Gemini*; the 1.3.3 copy names none, and `StoreListingTests.noThirdPartyAIServiceIsNamed` holds it there. China mainland was deselected for 1.3.2 (§7) and is to be re-enabled with 1.3.3. |
| **A link to Apple's standard EULA in the Description** | Guideline 3.1.2(c) has two halves and build 14 was rejected for missing both: the disclosures in the binary (`SupportSettingsView`, guarded by `SupportContractTests`) **and** the EULA link in the description. The app can be perfect and still be rejected for the description. |
| **The subscription's full terms in the Description** | The live copy ends with a `SUPPORTING HELLONOTES (OPTIONAL)` section naming the price (A$50/year), that it is auto-renewable, when it renews, and how to cancel (`Settings > your name > Subscriptions`). |
| **Both policy URLs resolve** | Check with `curl`, never by reading. The privacy one takes **no trailing slash**: `…/privacy` is 200, `…/privacy/` is 404. |

```bash
# the two links the description must carry, verified rather than eyeballed
curl -sIL -o /dev/null -w '%{http_code}\n' https://hellotham.com/hellonotes/privacy
curl -sIL -o /dev/null -w '%{http_code}\n' https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
```

**The copy for the version being prepared lives in [`app-store-listing.md`](app-store-listing.md)**
— subtitle, promotional text, keywords, What's New, both descriptions and the
reviewer notes — where `StoreListingTests` checks it against the limits and the
rules above before anything is pasted. Refresh that file from App Store Connect
before editing it for a new version.

### Reviewer notes — what must be covered

Live text lives in ASC (≈3,300 chars, per platform). It has to answer, in this
order, every question a reviewer has actually asked:

1. **"What do I need to set up?"** — nothing. `DefaultCollection` ships *inside
   the binary*, is copied into the app's documents on first launch and opened
   automatically. Name it, and say where to reopen it (`File ▸ Open Default
   Collection`, or the **+** at the top of the sidebar; on iPhone the overflow
   menu on the Notes tab). **An earlier note pointed at a `SampleVault` in the
   source repository, which a reviewer cannot see** — that cost a Guideline 2.1
   "Information Needed" round trip. Both folders still exist in the repo; only
   `DefaultCollection` is in the app.
2. **"Where are the purchases?"** — the exact path to Settings ▸ Support ▸
   Support HelloNotes, and what that one screen shows (title, length, price per
   period, renewal and cancellation terms, working EULA and privacy links).
3. **"What do they unlock?"** — every feature is included for everyone; backing
   the app adds an in-app **support request** and nothing else. Say that
   plainly. It must **not** claim nothing is gated — something is.
4. **Guideline 5** — the app ships no third-party AI service, no ChatGPT or
   OpenAI integration, and no AI credentials of any kind: its AI is Apple
   Foundation Models, plus open models the person may choose to download and run
   on the device with MLX.

`assets/iap-review/` holds the App Review screenshot and an 82-second recording
that walks the purchase path and follows both policy links into Safari, for the
Resolution Center if 3.1.2(c) is raised. See §8 for that screenshot's size rule,
which is not the app-screenshot rule.

- **Sign-in required:** No. The app has no account of any kind. The optional
  screens where a user supplies *their own* third-party credentials (Git, a cloud
  folder — and before 1.3.3, an AI provider key) are not logins to a HelloNotes
  service — an automated scan has flagged them as such before, so the notes say
  so explicitly.
- **Contact:** your name, phone, email.

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
- **Notes to reviewer:** paste from [`app-store-listing.md`](app-store-listing.md)
  (*Notes to reviewer*). The 1.3.2 note told reviewers a user "may instead
  configure a cloud provider with their own API key"; that is no longer true and
  must not be pasted again.

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
  goes to **destinations the user directs** — a Git remote under their own
  credentials, a web page or search the assistant makes at their request, or (from
  1.3.3) Hugging Face when they choose to download an MLX model, which sends no
  note content. 1.3.2 also listed a cloud LLM provider under the user's own API
  key; 1.3.3 removes those. Apple's on-device model sends nothing. When Private
  Cloud Compute is enabled (§1b-PCC), re-read Apple's guidance for it before
  answering this again. Disclose these
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
  or **Free** (price tier **AUD 0.00**). Free, with the two optional support
  purchases (§4) — the listing therefore carries an *Offers In-App Purchases*
  badge, so any page of ours claiming the app is simply "free, no purchases"
  contradicts the store one tap later.
- **Availability for 1.3.2: 174 of 175 territories — China mainland
  deliberately deselected.** That is the resolution Apple offered for the
  **Guideline 5** rejection: China requires a permit for generative-AI services,
  and 1.3.2 offered optional third-party AI providers. Deselecting the storefront
  removed the question.
- **For 1.3.3: re-enable China mainland** — a decision taken on 2026-09-15, not
  a row to flip silently. It rests on 1.3.3 removing every third-party AI
  service: the AI is Apple Foundation Models and on-device MLX. Two things are
  still generative AI a Chinese reviewer may ask about, and the reviewer notes
  (`app-store-listing.md`) answer them rather than hide them: an MLX model is an
  open model the person downloads and runs locally (from Hugging Face, which is
  unreachable there, or from a folder they supply), and the Assistant's web tools
  — it searches DuckDuckGo on its own when a question needs it, and reads whole
  pages only on a model with a 16,000-token window — as does Research in New Note
  from a Prompt. If Guideline 5 comes back for China, the answer is in that same
  pair — not in the rest of the app. No AI service is named anywhere in the app's
  own code or bundle (`ShippedContentTests`); the only such strings in the binary
  are swift-huggingface's Inference Providers enum, which HelloNotes does not use.

---

## 8 · Screenshots (required)

**Walk the whole grid and count, every time.** Screenshots are per-platform
*and* per-display-size, and App Store Connect shows one size at a time. Build 13
went to review twice with the iPad tab holding a **single** stale light-mode
shot, because the check was "does the iPhone tab look right". `0 of 10` and
`1 of 10` both read as "there is something there" at a glance; only the count
distinguishes them.

| Platform | Tab | Size | Expect | Committed set |
|---|---|---|---|---|
| iOS | iPhone | 6.5" — **1284×2778** | 3–10 | `dist/Screenshots-iOS/` |
| iOS | **iPad** | 13" — **2064×2752** | 3–10 | `dist/Screenshots-iPad/` |
| macOS | Mac | **2560×1600** (or 1280×800 / 1440×900 / 2880×1800) | 3–10 | `dist/Screenshots-macOS/` |

The undecorated originals are committed in **`assets/screenshots-raw/`**
(`iPhone-6.5/`, `iPad-13/`, `macOS/`) and the branded website frames are
one-way derivatives of them — gradient, caption, rounded corners, shadow, none
of it reversible. That folder exists because the raw Mac captures were once shot
into a session scratchpad and thrown away, and when the store needed
undecorated ones there were none anywhere.

> **Screenshots cannot be edited while a version is *Waiting for Review*** — the
> file input and **Delete All** are simply not in the DOM. Getting one wrong
> therefore costs a removal from review and a resubmission, so inventory
> **before** submitting. And never `Delete All` before the replacements are
> staged and verified at the right pixel size: deletion is per display size and
> immediate.

### Shooting them

- **iOS / iPadOS** — simulators, headless, costs nobody their screen:
  `xcrun simctl io <device> screenshot`. The device must match the store size
  exactly: iPhone 13 Pro Max → 1284×2778; **iPad Pro 13-inch → 2064×2752**. The
  11-inch `HN-iPad` used for day-to-day testing gives 1668×2420, which ASC
  rejects for the 13-inch slot *and* whose aspect ratio differs, so it cannot be
  rescaled into one. Set the clock with
  `xcrun simctl status_bar <device> override --time 9:41 …`.
- **macOS** — the app on a real screen, so it costs the user their session.
  `screencapture -l <windowID>`; a **1280×800 pt** window captures at exactly
  2560×1600 on a 2× display, so size the window rather than padding afterwards.

> ### ⚠️ Shoot from `DefaultCollection`, and confirm it by *reading*
> Capture only the collection that ships inside the binary — it is public
> content by construction and it is what a reviewer opening the app will see.
> `SampleVault` (the repo fixture) is permitted; **a real vault never is.**
>
> Verify which collection is loaded by reading the preferences, never by taking
> a picture to look — *"screenshotting to check" is capturing*:
> ```bash
> /usr/libexec/PlistBuddy -c "Print :collectionPaths" \
>   ~/Library/Containers/com.hellotham.HelloNotes/Data/Library/Preferences/com.hellotham.HelloNotes.plist
> ```
> Back that plist up first and restore it after — opening or closing a
> collection changes the user's state. `.claude/hooks/guard-screencapture.py`
> enforces this.

### The In-App Purchase App Review screenshot is a different thing

Each in-app purchase needs its own **App Review screenshot** before it can be
submitted, and a missing one is the Guideline 2.1(b) rejection. **It does not
accept the sizes app screenshots accept.** An iPad Pro 11-inch capture
(1668×2420) was refused; so was the 13-inch (2064×2752). What uploaded was
**1284×2778** — an iPhone 6.5" capture. The file is
`assets/iap-review/support-screen-iphone.png`; shoot its replacement on an
iPhone simulator, against the **live** store so the prices are real product data
rather than placeholders.

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
xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes -skipPackagePluginValidation \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath build/HelloNotes.xcarchive archive

xcodebuild -exportArchive -archivePath build/HelloNotes.xcarchive \
  -exportOptionsPlist ExportOptions-AppStore-macOS.plist -exportPath build/export \
  -allowProvisioningUpdates
```
The export step uploads directly. (For CI, authenticate `notarytool`/`altool`
with an **App Store Connect API key** instead of your Apple ID.)

**When Xcode's sign-in has lapsed**, both exports fail before anything is sent:
`exportArchive Failed to Use Accounts — App Store Connect access for
"RPL5R637DS" is required`. Sign in again under Xcode ▸ Settings ▸ Accounts.
The team's API key, in `~/.appstoreconnect/private_keys/`, can stand in for
the account on **iOS only**. Add `-authenticationKeyPath`,
`-authenticationKeyID` and `-authenticationKeyIssuerID` to the export. The
issuer ID is at the top of Users and Access ▸ Integrations ▸ App Store Connect
API. The key cannot do a **macOS** export: its Mac Installer Distribution
certificate is cloud-managed, which the key's role may not use, so it fails
with "Cloud signing permission error". Build 28 went up both ways (§10g).

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
xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes -skipPackagePluginValidation \
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

On the version page:

1. **Build** section → **＋** → pick the processed build. To *replace* an
   attached build, hover its row: a red **−** appears at the right-hand end and
   is the only way to detach one.
2. **Export Compliance:** with `ITSAppUsesNonExemptEncryption=false` (§1d) you
   are not asked.
3. **Version Release:** *Automatically release after approval* is what 1.3.2
   used — which means **approval publishes immediately, with no second chance
   to hold it**. Everything downstream (the website, announcements) has to be
   ready *before* approval lands, not after. 1.3.2 went live on 7 September and
   the website did not catch up until the 15th.
4. Confirm §4–§8 are complete, then submit — but read the next box first if
   there are in-app purchases.

> ### ⚠️ In-app purchases must travel in the **same submission** as the build
> This is self-perpetuating and cost two rejection cycles on 1.3.2. App Store
> Connect allows **one open review submission per platform**, and a version
> belongs to exactly one of them:
>
> - IAPs and subscriptions can only be submitted from a **draft submission**,
>   and a draft refuses to submit while it holds no app version — *"To submit
>   your items for review, add an app version for the selected platform."*
> - The version page's button reads **Update Review** whenever a submission is
>   already in flight, and it attaches the version to **that** submission — not
>   to the draft holding the purchases.
>
> So the binary goes to Apple, the products stay behind, and every resubmission
> reproduces **Guideline 2.1(b)** — *"one or more of the In-App Purchase
> products have not been submitted for review"* — exactly.
>
> **The button's label is the whole mechanism.** Only when no submission is open
> does it become **Add for Review ⌄**, a dropdown offering the existing *Draft
> Submission (n)* by name or *Create New Submission*. Picking the draft is what
> puts the version and its purchases in one place.
>
> **The fix, in order:**
> 1. **Reply to App Review first.** The message thread belongs to the in-flight
>    submission and does not survive cancelling it. Put anything Apple asked to
>    be shown into the version's **Notes** and **Attachment** fields as well —
>    those travel with the version into the next submission; a reply does not.
> 2. *Cancel Submission* (page footer) → *Confirm*. The old submission shows
>    **Removed**; the version returns to Prepare for Submission. Nothing is
>    deleted.
> 3. Version page → **Add for Review ⌄** → the draft → **Submit for Review**.
> 4. **Check the count before submitting.** The panel should read *Items Ready
>    to Submit (4)*: the version, the consumable, the subscription, and its
>    group. Three means the version never joined.
>
> IAPs are app-level: they rode the **iOS** submission (4 items) and the macOS
> one needed only its version (1 item).

Review is typically **~1–3 days**; 1.3.2 took three days from the 4 September
resubmission to the 7 September release. Status changes arrive by email.

## 10g · 1.3.3 build 28 — uploaded to TestFlight, 2026-10-09

From `c353ba4`. Both platforms printed `Progress 100%: Upload succeeded` and
`** EXPORT SUCCEEDED **`: iOS at 15:50 and macOS at 15:52. In TestFlight's
Build Uploads, iOS 1.3.3 (28) showed **Complete** within minutes, and macOS 1.3.3 (28) a few minutes after
that. Both are in the internal group HelloNotes testers, which has two
testers. Each is listed as "Ready to Submit", while 27, already installed, is
listed as "Testing". Unlike 27, neither has a "What to Test" note.

The first attempt sent nothing on either platform: `Failed to Use Accounts`.
Xcode's sign-in had lapsed since 27 went up that morning.
- The team's API key uploaded the iOS build.
- macOS cannot go that way: "Cloud signing permission error", no local Mac
  Installer Distribution certificate.
- So macOS went through the Xcode account once it was signed in again (§9).

Read back from each archive, not from the project:
- Both archives read 1.3.3 (28), as do all six extensions.
- Both apps are arm64 only. The minimums are macOS 27.0 and iOS 27.0.
- Neither app nor any extension carries a temporary-exception entitlement.
- All five cloud-provider keys are present (checked by length).
- `ITSAppUsesNonExemptEncryption` is false.
- The bundled manual is the corrected one.

28 carries the rearrangement asked for after testing 27 on the Mac
(implemented.md §51.37):
- **The sidebar is the collection's.** The Mind Map, the Assistant, Ask Your
  Library and Git sit above the tree. New Folder, New Collection, Open
  Collection and Open Default Collection sit below it. A phone's Notes place
  carries the same rows.
- **The bar is the notes'.** It holds New Note (into the selected note's
  folder), Today's Note, Find & Replace and More ⋯.
- **The panel is the open note's.** It holds Summary & Outline, Tags, Links,
  Properties, History and Graph.
- **The bottom bar is the four view modes.**
- **The Graph and the Mind Map are each their own thing.** The Graph is one
  note's links in and out. The Mind Map is the links across the collection,
  in a tab.
- **27's Graph drew every label in one pile.** That is fixed.

Before archiving, on the committed tree:
- 843 app tests.
- The new and changed suites on iOS, and the iOS interface suite.
- `chrome-parity.sh`, 16/16.
- A Swift 6 type-check: 0 errors, with a planted error caught.

Not run again, because nothing they cover has changed since 27:
- the editor package's 506 + 487 tests,
- `render-parity.sh`,
- the on-device evaluations.

## 10f · 1.3.3 build 27 — uploaded to TestFlight, 2026-10-09

From `b819c1b`. Both platforms printed `Progress 100%: Upload succeeded` and
`** EXPORT SUCCEEDED **`: macOS at 08:41 and iOS at 08:44.

Read back from each archive, not from the project:
- Both archives read 1.3.3 (27), as do all six extensions.
- Both apps are arm64 only. 1.3.3 is the first Mac release that is not
  universal, because its macOS 27 floor runs only on Apple silicon.
- Neither app nor any extension carries a temporary-exception entitlement.
- All five cloud-provider keys are present (checked by length).
- `ITSAppUsesNonExemptEncryption` is false. The iOS minimum is 27.0.

27 carries everything since 26, implemented.md §51.5–§51.36:
- The Mac and the iPad draw the same pixels.
- The data-safety work on what reaches the file and when.
- Cloud collections' changes reach the provider.
- Incremental parsing converges.
- The Assistant edits a note on Apple's own model, which no build had done.
- Every open defect in unimplemented.md is fixed.

Before archiving, on the committed tree:
- 830 app tests.
- 506 + 487 editor tests (macOS + iOS).
- The iOS interface suite.
- The on-device evaluations, three times over (18/18).
- `render-parity.sh` and `chrome-parity.sh`.
- A Swift 6 type-check with a planted error caught.
- Release builds of both platforms.

The iOS interface tests found that the iOS build crashed the compiler, which
no Mac check could see. An archive would have been the first to say so.

**Check the builds in TestFlight.** An upload that reports success is not a
build that arrived (§10a).

## 10e · 1.3.3 build 26 — uploaded to TestFlight, 2026-09-22

From `1b17834`; `Progress 100%: Upload succeeded` and `** EXPORT SUCCEEDED **`
on both, macOS at 16:24 and iOS at 16:29, archives reading 1.3.3 (26), and the
archived Mac app carrying zero temporary exceptions.

**Build 25 passed Beta App Review**, and its **Access MLX Models…** panel opened
the last folder the app had used — an Obsidian vault — instead of the Hugging
Face cache: `fileDialogDefaultDirectory` sat inside the `fileImporter` it was
meant to configure, where the importer could not see it. 26 moves it outside,
proved by a probe that read the panel's own `directoryURL` both ways
(implemented.md, the MLX section).

## 10d · 1.3.3 build 25 — the entitlement App Review refused, 2026-09-20

From `17b2894`; `Progress 100%: Upload succeeded` and `** EXPORT SUCCEEDED **`
on both, macOS at 07:44 and iOS at 07:49, archives reading 1.3.3 (25), and the
archived Mac app carrying **zero** temporary exceptions.

**Builds 23 and 24 were both rejected by Beta App Review**, guideline 2.4.5(i),
identically: `com.apple.security.temporary-exception.files.home-relative-path.read-write`
for `/.cache/huggingface/` is *"not appropriate and will not be granted."* A
refusal, not a request for justification — so reviewer notes cannot rescue it,
and read-only would be the same request. 23's row in the submissions list reads
"Completed" because that is the status of the *submission*; the build inside it
reads Rejected.

25 removes it. The Hugging Face cache is reached the way the sandbox intends:
**Access MLX Models…** opens a panel already pointed at
`~/.cache/huggingface/hub`, one click on Open grants it, and the security-scoped
bookmark keeps it. Until then the models folder is the app's own container.

## 10c · 1.3.3 build 24 — uploaded to TestFlight, 2026-09-19

From `97dd99d`; `Progress 100%: Upload succeeded` and `** EXPORT SUCCEEDED **`
on both, macOS at 08:33 and iOS at 08:38, archives reading 1.3.3 (24).

**One fix over 23, found on the narrowest shell there is.** An iPad mini in
portrait with the collections band and the right panel both open folds the bar
into the system overflow, and the overflow titles each row from the item's
*label*. The note menu's label was an `Image`, so its row drew as a bare chevron
with a disclosure arrow and no name — with the view modes behind it — beside a
row that read "Panel". The Library sidebar's ellipsis menu had the same shape.
Both carry titles now, and `ShellComplianceTests` allows exactly one image-only
label (the search field's clear button, which never folds).

## 10b · 1.3.3 build 23 — uploaded to TestFlight, 2026-09-18

Both platforms, one build number, from a clean tree at `8821301`. Same two
commands per platform as Appendix A; both reported `Progress 100%: Upload
succeeded` and `** EXPORT SUCCEEDED **`, macOS at 17:18 and iOS at 17:23.

What 23 carries over 22: one model choice instead of two roles, with the
Foundation Models knobs exposed (temperature 0–2, sampling, reply cap,
reasoning); **every MLX model in the models folder is its own entry in the
picker**, and choosing one switches to it; the Hugging Face cache is the models
folder by entitlement; the right panel holds all nine ancillary views and drags
to resize; the app opens no window of its own on either platform.

Three gates that had stopped working were repaired before this build, all of
them silent: `dropDestination` had rebound to a new macOS 27 overload that
discards the refusal a drop returns; both editor test suites (795 tests) had
stopped compiling under Xcode 27; and `render-parity.sh` was reporting build
failure as layout drift. Full run before upload — 508 app tests, 12 interface
tests, 408 + 387 editor tests, 5 on-device evaluations, 7 MLX evaluations on a
real model, and Edit ≡ Preview green at every size and width.

## 10a · 1.3.3 — uploaded to TestFlight, 2026-09-16

Both platforms, one build number, from a clean tree at `3af6676`:

| | macOS | iOS |
|---|---|---|
| Archive | `build/HelloNotes.xcarchive` | `build/HelloNotes-iOS.xcarchive` |
| Export plist (the export *is* the upload) | `ExportOptions-AppStore-macOS.plist` | `ExportOptions-AppStore-iOS.plist` |
| Reported | `Progress 100%: Upload succeeded` · `Uploaded package is processing` · `** EXPORT SUCCEEDED **` | the same |

Version `1.3.3`, build `22` — read back from each archive's
`ApplicationProperties`, not from the project file. Before archiving: the whole
unit suite (507 in 79 suites), the iOS interface suite (12), the on-device model
evaluations, and a **Release-configuration build of both platforms** — Debug
proves nothing about Release, and an archive is the slowest way to find that out.

Both builds showed **Complete** in TestFlight (macOS 5:24 PM, iOS 5:29 PM), which
is the check this runbook insists on: an upload that reports success is not a
build that arrived.

**Prepared in App Store Connect the same day**, both platforms: version 1.3.3
created, promotional text, description, What's New and App Review notes pasted
from `docs/app-store-listing.md` (the 1.3.2 notes carried a reply to an old
rejection and were replaced), build 22 attached, and every field read back after
a reload rather than trusted to the save. The live **Mac** description was read
first and its Mac-only lines carried into the listing file — *Multi-tab editing
and open-in-new-window*, *keyboard-first*, and "Manage or cancel it in your Apple
Account settings", which replaces a guessed Settings path. Screenshots carry over
from 1.3.2 and were checked against the new build: the AI ones still show what
the app does and name no provider. Both platforms report **Add for Review**
enabled. Release is set to automatic on approval.

**Two things were deliberately not done**, because each is a decision rather than
a step:

1. **China mainland is still deselected.** Availability is a property of the
   *app*, not of a version, and this page says changes reach the App Store
   within 24 hours — so enabling it today would publish **1.3.2**, the version
   whose third-party AI providers earned the Guideline 5 rejection, into the
   storefront that rejected it, days before 1.3.3 could replace it. The order
   that avoids that is: submit 1.3.3 → approved → released → then add China.
   The cost of that order is that the review never sees the app as a China
   submission; and whether mainland distribution also needs an ICP filing number
   is unanswered, because finding out means selecting the territory, which is
   the change itself.
2. **Nothing has been submitted.** "Add for Review" is enabled on both
   platforms and is one click away.

The website branch `website/1.3.3-foundation-models` stays unmerged until Apple
approves — a site that describes a version the store has not got is the
sequencing mistake recorded in [[ios-app-store-website-sequencing]].

---

## 11 · After submission — what actually got rejected

Generic advice first, then the four that 1.3.2 was actually rejected on — which
is the more useful list, because every one of them was invisible from the repo.

- **Incomplete metadata / missing screenshots** → the #1 delay. §8's grid.
- **Placeholder content** (the `com.example.*` UTIs) → fixed in §1c.
- **Broken Support or Privacy URLs** → `curl` them; the privacy one takes no
  trailing slash.
- **Crash on a clean machine** → test from a fresh vault before submitting.

### The 1.3.2 rejections, and what each really was

| Guideline | What Apple said | What it actually was |
|---|---|---|
| **2.1(b)** App Completeness | "one or more of the In-App Purchase products have not been submitted for review" | Structural, not an oversight — the version and the purchases could not reach the same submission. §10's box. |
| **3.1.2(c)** Subscriptions | required subscription info missing | Two halves: the disclosures in the binary **and** the EULA link in the App Description. The app was already correct; the description was not. |
| **5** Legal (China) | metadata references OpenAI | A provider name in the description. Removed, and China mainland deselected (§7). |
| **2.1** Information Needed | "where to locate the demo SampleVault" | Our own earlier reviewer note pointed at the **source repository**, which a reviewer cannot see. The sample now ships in the binary (§4). |

**Three of those four were App Store Connect state, not code.** No rebuild would
have moved them, and nothing in the repo reported them. When a rejection arrives,
check what the *listing* says before checking what the app does.

**And fix a thing on every platform it exists on.** The "SampleVault" correction
was applied to the app and to the iOS screenshots while all ten **macOS**
screenshots still showed a `SampleVault` sidebar — a picture of the exact folder
the reviewer had just said they could not find. Metadata is per-platform (§4);
so is being wrong.

## Appendix A · One‑command App Store upload

> **This appendix used to contradict §9 and would have signed for the wrong
> channel.** It exported through the repo-root `ExportOptions.plist`, which is
> `method = developer-id` — the *notarised DMG* plist — while §9 Option B warns
> in bold that it is not the App Store one. It also told you to save the script
> as `scripts/release.sh`, which has never existed; `scripts/` holds
> `package-dmg.sh`, `check-download-page.sh`, `render-parity.sh`,
> `run-tests.sh`, `relaunch-debug.sh`, `make-screenshots.py`,
> `clean-preview-stubs.sh` and `winid.swift`. Both are fixed below.

The **`/release` skill** (`.claude/skills/release/`) is the maintained path for
the *DMG* channel and already sequences build → notarise → publish → site sync.
For an App Store upload there is no script — it is two commands, and the export
*is* the upload because both AppStore plists carry `destination = upload`:

```bash
# macOS
xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes -skipPackagePluginValidation \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath build/HelloNotes.xcarchive archive
xcodebuild -exportArchive -archivePath build/HelloNotes.xcarchive \
  -exportOptionsPlist ExportOptions-AppStore-macOS.plist \
  -exportPath build/export -allowProvisioningUpdates

# iOS
xcodebuild -project HelloNotes.xcodeproj -scheme HelloNotes -skipPackagePluginValidation \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/HelloNotes-iOS.xcarchive archive
xcodebuild -exportArchive -archivePath build/HelloNotes-iOS.xcarchive \
  -exportOptionsPlist ExportOptions-AppStore-iOS.plist \
  -exportPath build/export-ios -allowProvisioningUpdates
```

**Four plists live in the repo root and only two of them upload.** Picking the
wrong one fails in a way that looks like success:

| Plist | `method` | `destination` | Use |
|---|---|---|---|
| `ExportOptions.plist` | `developer-id` | export | The notarised DMG (Appendix A2) — **never the store** |
| `ExportOptions-AppStore-macOS.plist` | `app-store-connect` | **upload** | macOS → App Store Connect |
| `ExportOptions-AppStore-iOS.plist` | `app-store-connect` | **upload** | iOS → App Store Connect |
| `ExportOptions-iOS.plist` | `app-store-connect` | export | Writes a local `.ipa` and uploads **nothing** |

> **Verify the build arrived; do not trust the command.** Build 18 reported
> nothing wrong and never appeared, because a detached upload never ran. A real
> upload prints `Progress NN%: Upload succeeded` and `** EXPORT SUCCEEDED **`,
> and the build then shows up in TestFlight. Check there before assuming.

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
# 1 · Archive (arm64 — from 1.3.3, whose macOS 27 floor runs only on Apple silicon;
#     Xcode 27's ARCHS_STANDARD is `arm64` at that deployment target. 1.3.2 and
#     earlier, at 26.5, were universal.)
xcodebuild archive -project HelloNotes.xcodeproj -scheme HelloNotes \
  -destination 'generic/platform=macOS' -skipPackagePluginValidation \
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
lipo -info /tmp/hn/HelloNotes.app/Contents/MacOS/HelloNotes   # arm64 (1.3.3+)
spctl --assess --type execute --verbose /tmp/hn/HelloNotes.app
xcrun stapler validate /tmp/hn/HelloNotes.app                 # works offline
hdiutil detach /tmp/hn
```

> **Gotchas learned the hard way**
> - `package-dmg.sh` **overwrites `dist/HelloNotes.dmg` (`rm -f`)**. Move the previous
>   build aside first if you want to keep it.
> - The DMG bakes in whatever `Config/Secrets.xcconfig` held at build time. Building
>   on a machine without it ships with **empty cloud-storage keys** (Dropbox, Box,
>   Google Drive, OneDrive) — the app still runs, those providers just report
>   "not configured". There are no AI keys in it from 1.3.3.
> - Do §1h's Release check *before* archiving: an archive is the slowest possible way
>   to discover a Release‑only compile failure.

## Appendix B · Pre‑submission checklist

**Before the build**
- [ ] Paid **and** Free Apps agreements Active; tax & banking Active; the
      **Compliance** rows at the bottom of Business ▸ Agreements not sitting at
      *Missing Info* (§0)
- [ ] §1 hardening done (min OS, entitlements, Info.plist, encryption key,
      Release signs as Apple Distribution / Hello Tham)
- [ ] `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` **read fresh** from
      `project.pbxproj`; build number unique and higher than any prior upload
- [ ] **Release** build clean on both platforms — Debug proves nothing (§1h)
- [ ] `Config/Secrets.xcconfig` present, or the build ships empty cloud-storage keys
- [ ] `./scripts/run-tests.sh` green, including `StoreListingTests` and
      `PrivateCloudComputeEntitlementTests`; and the model evaluations
      (`TEST_RUNNER_HN_EVALUATIONS=1 ./scripts/run-tests.sh -only-testing:HelloNotesTests/IntelligenceEvaluationTests`)
      green on an Apple Intelligence Mac

**Metadata — per platform, both of them**
- [ ] Description carries the **EULA link** and the subscription's full terms
- [ ] **No OpenAI/ChatGPT reference, and no third-party AI service**, in name,
      subtitle, promo, description, keywords **or screenshots** — and Private
      Cloud Compute mentioned only if the build carries its entitlement (§1b-PCC)
- [ ] Privacy and EULA URLs `curl` to 200 (privacy takes no trailing slash)
- [ ] Reviewer notes answer all four questions in §4 — and point at
      `DefaultCollection` *in the binary*, never at the repo
- [ ] App Privacy = *Data Not Collected*; age rating 4+; pricing set
- [ ] Availability matches the version's decision (§7): China mainland
      **excluded for 1.3.2**, **re-enabled for 1.3.3**

**Screenshots — walk the grid and count (§8)**
- [ ] iPhone 6.5" 1284×2778 · **iPad 13" 2064×2752** · Mac 2560×1600, 3–10 each
- [ ] Every shot is `DefaultCollection` — verified by *reading* the prefs plist
- [ ] Each in-app purchase has an App Review screenshot at **1284×2778**

**Submitting (§10)**
- [ ] Build attached and processed
- [ ] Release option chosen deliberately — *Automatic* means approval publishes
      with no second chance to hold it, so the website and anything else
      downstream is ready **now**
- [ ] Draft submission reads **Items Ready to Submit (4)** — version +
      consumable + subscription + group — before you press submit
- [ ] Submitted ✅

**After approval**
- [ ] Listing live (`itunes.apple.com/lookup?bundleId=com.hellotham.HelloNotes`)
- [ ] Website merged and deployed; `scripts/check-download-page.sh` passes
      **with** the App Store comparison active
- [ ] Release recorded in `docs/implemented.md`

## Appendix C · Privacy policy — the live page is the source of truth

> **Live: <https://hellotham.com/hellonotes/privacy>. Read it there.** The text
> below is the original draft and has already drifted from what is published
> (the live page words the cloud-provider paragraph differently). It is kept for
> the *shape* of what the policy has to cover, not as the copy — the same
> mistake §4 used to make with the App Store description, and the reason that
> section now points at App Store Connect instead of duplicating it.

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
>
> *(1.3.3 draft of the two bullets above, for the live page when 1.3.3 ships:)*
> **AI:** summarise, suggest, rewrite, “ask your library” and the Assistant use
> Apple Foundation Models on your device, or an open model you choose to download
> and run on your device with MLX; content processed this way never leaves your
> device. Downloading an MLX model contacts Hugging Face and sends none of your
> notes. HelloNotes has no third‑party AI services and stores no AI credentials;
> keys stored by earlier versions are deleted. *(Add Private Cloud Compute here
> only when §1b-PCC is done.)*
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
