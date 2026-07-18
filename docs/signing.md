# Code signing, certificates & entitlements

A first-time walkthrough for configuring signing and capabilities for **HelloNotes**
(macOS + iOS). Everything happens in two apps: **Xcode** (for clicking) and
**Terminal** (for three checks).

- **Team:** Hello Tham Pty. Ltd. — `RPL5R637DS` (an *organization* team, not a free
  personal team)
- **Bundle identifier:** `com.hellotham.HelloNotes`
- **Entitlements file:** `HelloNotes/HelloNotes.entitlements`

> **The two things that break most often**
> 1. *"No signing certificate … with a private key was found."* → your dev
>    certificate exists on Apple's portal but its private key isn't in this Mac's
>    Keychain. **Part 1** fixes it.
> 2. *Network and folder-access stop working in a sandboxed build.* → the
>    `CODE_SIGN_ENTITLEMENTS` link got dropped, so `network.client` and
>    `bookmarks.app-scope` aren't signed in. **Part 3** fixes it.

---

## Which certificate is which

From **developer.apple.com → Certificates, Identifiers & Profiles**:

| Name | Type | Use |
|------|------|-----|
| **Chris Tham** | Apple Development | Everyday dev/debug builds. Per-developer — Apple names it after the person, but it's issued under the org team. This is the identity Xcode's "Apple Development" resolves to. |
| **Hello Tham Pty. Ltd.** | Developer ID Application (macOS) | Notarized distribution *outside* the Mac App Store. The organization/team certificate. |

There is no company-named *development* certificate — development certs are always
per-person. That's expected, not a mistake.

---

## Part 1 — Put your developer certificate on this Mac

A certificate has a matching secret *private key* that must live in your Keychain.
This creates a fresh pair and stores the key.

1. **Xcode ▸ Settings…** (`⌘,`).
2. **Accounts** tab ▸ **+** (bottom-left) ▸ **Apple ID** ▸ sign in with the Apple ID
   that owns *Hello Tham Pty. Ltd.* (skip if already listed).
3. Select the **Hello Tham Pty. Ltd.** team row ▸ **Manage Certificates…**
4. **+** (bottom-left) ▸ **Apple Development** ▸ **Done**. Xcode creates the
   certificate *and* stores its private key.
5. Confirm in Terminal:
   ```sh
   security find-identity -v -p codesigning
   ```
   You should see `Apple Development: Chris Tham (…)`.

---

## Part 2 — Point the project at your team

1. Click the blue **project** icon at the top of the left sidebar. Under **TARGETS**,
   select **HelloNotes** ▸ **Signing & Capabilities** tab.
2. Click the **All** button (so changes cover both Debug and Release).
3. Set:
   - ☑ **Automatically manage signing**
   - **Team:** `Hello Tham Pty. Ltd. (RPL5R637DS)`
   - **Bundle Identifier:** `com.hellotham.HelloNotes` (leave as-is)
4. The **Signing Certificate** line should read `Apple Development: Chris Tham` with
   no red error.

> **Shared repo:** committing a *team* id is fine — it isn't a secret. Don't pin a
> personal *certificate/identity* in the committed project; "Automatically manage
> signing" lets each developer's Xcode fill in their own.

---

## Part 3 — Turn on the app's capabilities

HelloNotes needs four entitlements. Two are checkboxes; two live only in the
entitlements file.

| Entitlement | Why | How to set |
|-------------|-----|-----------|
| `com.apple.security.app-sandbox` | Required for a distributable app | Checkbox |
| `com.apple.security.files.user-selected.read-write` | Open the vault folder you pick | Checkbox |
| `com.apple.security.network.client` | Reach the AI providers & git remotes | Checkbox / file |
| `com.apple.security.files.bookmarks.app-scope` | Remember your vault folder after quitting | **File only** |

1. On **Signing & Capabilities**, click **+ Capability** ▸ double-click **App Sandbox**.
2. In the App Sandbox panel:
   - **Network:** ☑ **Outgoing Connections (Client)**
   - **File Access ▸ User Selected File:** **Read/Write**
3. **+ Capability** ▸ **Hardened Runtime** (needed later for macOS distribution;
   harmless now).
4. **Build Settings** tab ▸ search `entitlements` ▸ set
   **Code Signing Entitlements** = `HelloNotes/HelloNotes.entitlements`.
   > This is the critical link. The file carries `files.bookmarks.app-scope`, which
   > has **no checkbox anywhere in Xcode**. If the setting is blank, folder-memory
   > silently stops working.
5. Open **HelloNotes ▸ HelloNotes.entitlements** and confirm it has exactly these
   four keys, all `YES`:
   ```xml
   <key>com.apple.security.app-sandbox</key>                        <true/>
   <key>com.apple.security.files.user-selected.read-write</key>     <true/>
   <key>com.apple.security.files.bookmarks.app-scope</key>          <true/>
   <key>com.apple.security.network.client</key>                     <true/>
   ```
   To add a missing key: hover the last row → **+** → type the key → Type **Boolean**
   → value **YES**. (Or right-click the file → **Open As ▸ Source Code**.)

> `REGISTER_APP_GROUPS = YES` may be set without an app group declared. It's
> harmless; set it to `NO` unless you actually add an app group.

---

## Part 4 — Tidy the test targets

The `HelloNotesTests` / `HelloNotesUITests` targets are kept on the team
(`RPL5R637DS`) — that's the known-good config that builds and archives.

If you ever see a **Mac-specific** override `DEVELOPMENT_TEAM[sdk=macosx*] = RPL5R637DS`
(it appears if the project is regenerated), select that nested line under
**Development Team** and press **Delete** — the plain team assignment is enough.

---

## Part 5 — Check it actually worked

1. **Product ▸ Build** (`⌘B`). Wait for "Build Succeeded"; Signing & Capabilities
   shows no red errors.
2. Read back the signed-in permissions:
   ```sh
   codesign -d --entitlements :- \
     "$(ls -d ~/Library/Developer/Xcode/DerivedData/HelloNotes-*/Build/Products/Debug*/HelloNotes.app | head -1)"
   ```
   All four keys must appear:
   ```
   com.apple.security.app-sandbox
   com.apple.security.files.user-selected.read-write
   com.apple.security.files.bookmarks.app-scope
   com.apple.security.network.client
   ```

Parts 1–5 are all you need for day-to-day development.

---

## Part 6 — (Optional) Sign for distribution & notarize

Only when sending the Mac app to others outside the App Store. Uses the
**Developer ID Application: Hello Tham Pty. Ltd.** certificate.

1. Store a notary credential once (App Store Connect API key or app-specific password):
   ```sh
   xcrun notarytool store-credentials AC_NOTARY
   ```
2. Set the run destination to **My Mac** ▸ **Product ▸ Archive**.
3. In the Organizer: **Distribute App ▸ Direct Distribution ▸ Distribute**. Xcode signs
   with Developer ID and can upload for notarization automatically.
4. If you exported the `.app` yourself, staple the ticket:
   ```sh
   xcrun stapler staple /path/to/HelloNotes.app
   ```

> Distributing from another Mac? That Mac needs the **Developer ID** certificate
> *and its private key* — export a `.p12` from Keychain Access here and import it there.

---

## Quick reference

| Setting | Value |
|---------|-------|
| Team | Hello Tham Pty. Ltd. (`RPL5R637DS`) |
| Signing style | Automatically manage signing |
| Bundle Identifier | `com.hellotham.HelloNotes` |
| Code Signing Entitlements | `HelloNotes/HelloNotes.entitlements` |
| Dev certificate | `Apple Development: Chris Tham` |
| Distribution certificate | `Developer ID Application: Hello Tham Pty. Ltd.` |

## Recovering a corrupted project file

If Xcode regenerates `project.pbxproj` and the build suddenly can't resolve *any*
Swift package (`Unable to resolve module dependency: 'Markdown'`, `'SwiftGitX'`, …),
the target's package links were dropped. Restore the committed file and rebuild:

```sh
git checkout HEAD -- HelloNotes.xcodeproj/project.pbxproj
```

Then re-open in Xcode and let it re-resolve packages. Avoid accepting any Xcode prompt
to "modernize"/regenerate the project — this repo uses file-system-synchronized groups,
which don't survive that cleanly.
