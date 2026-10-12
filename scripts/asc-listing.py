#!/usr/bin/env python3
"""
asc-listing.py — put a version's App Store listing in place, and read it back.

The listing was last set by hand in App Store Connect's pages: two
descriptions, the What's New, a build and twenty-one screenshots across three
display sizes, each checked by looking. Build 13 went to review twice with the
iPad on one stale picture, because a page shows one size at a time and "1 of
10" reads as "there is something there". This does it through the App Store
Connect API and prints what Apple then reports — every set, counted, with each
file's processing state and pixel size — so the check is a read, not a look.

    export ASC_KEY_ID=…  ASC_ISSUER_ID=…      # the team key's identifiers; this
                                              # repository is public and does not
                                              # carry them. The key itself is
                                              # ~/.appstoreconnect/private_keys/AuthKey_<id>.p8
    scripts/asc-listing.py status 1.3.3       # what each platform's version holds now
    scripts/asc-listing.py text 1.3.3         # description + What's New from docs/app-store-listing.md
    scripts/asc-listing.py build 1.3.3 31     # attach build 31 to both platforms' versions
    scripts/asc-listing.py screenshots 1.3.3  # replace every set from dist/Screenshots-*
    scripts/asc-listing.py submit 1.3.3       # one review submission a platform
    scripts/asc-listing.py withdraw 1.3.3     # take a version Waiting for Review out of it

`--platform IOS` (or `MAC_OS`), anywhere after the command, keeps it to one
platform — for the day one build is up and the other is not: the Mac's upload
needs Xcode's account and an unlocked keychain, and the iPhone's needs only
the team key.

`text` prints the difference before it writes and reads back after; nothing is
written when the store already matches. `screenshots` removes a set's pictures
and uploads the folder's in name order — a set holds ten, so the old ones go
first, which is why the folders are checked for pixel size before anything is
deleted. Screenshots cannot be changed once a version is Waiting for Review.

`submit` is the one that cannot be taken back without removing the version
from review. It refuses unless every set is complete and a build is attached.

`withdraw` is that removal: the version leaves the queue, and goes to the back
of it when it is submitted again. It is how a newer build replaces one already
waiting — withdraw, `build`, `submit` — and it touches only a submission that
is still Waiting for Review; one a reviewer has started on is left alone,
unless `--in-review` says to take that one too. That throws away a review
under way, and is the person's to decide each time.

Never prints the token or reads the key into a variable: `openssl` signs with
the file.
"""
import base64, difflib, hashlib, json, os, pathlib, re, struct, subprocess, sys, time, urllib.error, urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP_ID = "6803259848"
BASE = "https://api.appstoreconnect.apple.com"
PLATFORMS = ("IOS", "MAC_OS")
# Display type → the folder of pictures for it, and the size every one must be.
SETS = {
    "IOS": {"APP_IPHONE_65": ("dist/Screenshots-iOS", (1284, 2778)),
            "APP_IPAD_PRO_3GEN_129": ("dist/Screenshots-iPad", (2064, 2752))},
    "MAC_OS": {"APP_DESKTOP": ("dist/Screenshots-macOS", (2560, 1600))},
}
DESCRIPTION = {"IOS": "**Description** — iPhone and iPad", "MAC_OS": "**Description** — Mac"}

# `withdraw --in-review`: a submission a reviewer has started on goes too.
IN_REVIEW_TOO = False

_token = [None, 0]


def _b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def token():
    now = int(time.time())
    if _token[0] and _token[1] > now + 60:
        return _token[0]
    key_id, issuer = os.environ.get("ASC_KEY_ID"), os.environ.get("ASC_ISSUER_ID")
    if not key_id or not issuer:
        sys.exit("Set ASC_KEY_ID and ASC_ISSUER_ID (Users and Access ▸ Integrations ▸ App Store Connect API).")
    key = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8")
    head = _b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    body = _b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}).encode())
    signing = head + b"." + body
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key], input=signing,
                         capture_output=True, check=True).stdout
    # An ECDSA signature comes out of openssl as DER; a JWT wants r‖s, 32 bytes each.
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    r_len = der[i + 1]; r = der[i + 2:i + 2 + r_len]; i += 2 + r_len
    s_len = der[i + 1]; s = der[i + 2:i + 2 + s_len]
    raw = r[-32:].rjust(32, b"\0") + s[-32:].rjust(32, b"\0")
    _token[0], _token[1] = (signing + b"." + _b64(raw)).decode(), now + 900
    return _token[0]


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(path if path.startswith("http") else BASE + path, data=data, method=method)
    request.add_header("Authorization", "Bearer " + token())
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            text = response.read().decode()
            return response.status, (json.loads(text) if text else {})
    except urllib.error.HTTPError as error:
        text = error.read().decode()
        try:
            return error.code, json.loads(text)
        except ValueError:
            return error.code, {"errors": [{"status": str(error.code), "detail": text[:300]}]}


def problems(response):
    return [f"{e.get('status')} {e.get('code', '')} {e.get('detail', '')}".strip() for e in response.get("errors", [])]


def must(status, response, what, ok=(200, 201, 204)):
    if status not in ok:
        sys.exit(f"✗ {what}: {status} {problems(response)}")
    return response


def versions(version):
    """The version's id on each platform."""
    _, r = call("GET", f"/v1/apps/{APP_ID}/appStoreVersions?filter[versionString]={version}&limit=10")
    found = {v["attributes"]["platform"]: v for v in must(_, r, "versions")["data"]}
    missing = [p for p in PLATFORMS if p not in found]
    if missing:
        sys.exit(f"✗ no {version} version in App Store Connect for {missing}")
    return found


def localization(version_id):
    _, r = call("GET", f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations")
    data = must(_, r, "localizations")["data"]
    if len(data) != 1:
        sys.exit(f"✗ expected one localization, found {[l['attributes']['locale'] for l in data]} — this script writes one")
    return data[0]


def screenshot_sets(localization_id):
    _, r = call("GET", f"/v1/appStoreVersionLocalizations/{localization_id}/appScreenshotSets?limit=50")
    return {s["attributes"]["screenshotDisplayType"]: s["id"] for s in must(_, r, "screenshot sets")["data"]}


def screenshots(set_id):
    _, r = call("GET", f"/v1/appScreenshotSets/{set_id}/appScreenshots?limit=50")
    return must(_, r, "screenshots")["data"]


def listing_field(label):
    doc = (ROOT / "docs/app-store-listing.md").read_text()
    match = re.search(re.escape(label) + r".*?\n```\n(.*?)\n```", doc, re.S)
    if not match:
        sys.exit(f"✗ docs/app-store-listing.md has no field {label!r}")
    return match.group(1)


def png_size(path):
    with open(path, "rb") as handle:
        header = handle.read(24)
    return struct.unpack(">II", header[16:24])


def inventory(found, quiet=False):
    """Every set, counted. Returns whether all of it is ready to submit."""
    ready = True
    for platform in PLATFORMS:
        version = found[platform]
        sets = screenshot_sets(localization(version["id"])["id"])
        _, b = call("GET", f"/v1/appStoreVersions/{version['id']}/build?fields[builds]=version,processingState")
        build = (b.get("data") or {}).get("attributes", {})
        if not quiet:
            print(f"{platform}: {version['attributes'].get('appVersionState')} · build {build.get('version', 'none')} "
                  f"({build.get('processingState', '—')})")
        ready &= build.get("processingState") == "VALID"
        for kind, (_, size) in SETS[platform].items():
            shots = screenshots(sets[kind]) if kind in sets else []
            states = [(s["attributes"].get("assetDeliveryState") or {}).get("state") for s in shots]
            sizes = {((s["attributes"].get("imageAsset") or {}).get("width"),
                      (s["attributes"].get("imageAsset") or {}).get("height")) for s in shots}
            good = 3 <= len(shots) <= 10 and all(state == "COMPLETE" for state in states) and sizes == {size}
            ready &= good
            if not quiet:
                print(f"  {'✓' if good else '✗'} {kind}: {len(shots)} screenshots, "
                      f"{states.count('COMPLETE')} complete, sizes {sorted(sizes)}")
    return ready


def cmd_status(version):
    found = versions(version)
    inventory(found)
    for platform in PLATFORMS:
        attributes = localization(found[platform]["id"])["attributes"]
        same = (attributes.get("description") == listing_field(DESCRIPTION[platform]),
                attributes.get("whatsNew") == listing_field("**Version** — What's New"))
        print(f"{platform} text matches docs/app-store-listing.md — description: {same[0]}, What's New: {same[1]}")


def cmd_text(version):
    found = versions(version)
    whats_new = listing_field("**Version** — What's New")
    for platform in PLATFORMS:
        loc = localization(found[platform]["id"])
        want = {"description": listing_field(DESCRIPTION[platform]), "whatsNew": whats_new}
        changed = {k: v for k, v in want.items() if loc["attributes"].get(k) != v}
        if not changed:
            print(f"{platform}: already as the file has it")
            continue
        for key, value in changed.items():
            print(f"{platform} {key}:")
            for line in difflib.unified_diff((loc["attributes"].get(key) or "").splitlines(), value.splitlines(),
                                             lineterm="", n=0):
                if not line.startswith(("---", "+++", "@@")):
                    print("   " + line[:160])
        _, r = call("PATCH", f"/v1/appStoreVersionLocalizations/{loc['id']}",
                    {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": changed}})
        must(_, r, f"{platform} text")
        back = localization(found[platform]["id"])["attributes"]
        if any(back.get(k) != v for k, v in want.items()):
            sys.exit(f"✗ {platform}: written, and it does not read back equal")
        print(f"{platform}: written and read back equal")


def cmd_build(version, number):
    found = versions(version)
    _, r = call("GET", f"/v1/builds?filter[app]={APP_ID}&filter[version]={number}&include=preReleaseVersion&limit=10")
    must(_, r, "builds")
    platform_of = {i["id"]: i["attributes"]["platform"] for i in r.get("included", [])}
    builds = {platform_of[b["relationships"]["preReleaseVersion"]["data"]["id"]]: b for b in r["data"]}
    for platform in PLATFORMS:
        build = builds.get(platform)
        if not build or build["attributes"].get("processingState") != "VALID":
            sys.exit(f"✗ {platform}: build {number} is not there or not processed yet")
        _, r = call("PATCH", f"/v1/appStoreVersions/{found[platform]['id']}/relationships/build",
                    {"data": {"type": "builds", "id": build["id"]}})
        must(_, r, f"{platform} build")
        print(f"{platform}: build {number} attached")


def cmd_screenshots(version):
    found = versions(version)
    plan = []
    for platform in PLATFORMS:
        for kind, (folder, size) in SETS[platform].items():
            files = sorted((ROOT / folder).glob("*.png"))
            wrong = [f.name for f in files if png_size(f) != size]
            if not 3 <= len(files) <= 10 or wrong:
                sys.exit(f"✗ {folder}: {len(files)} files, wrong size {wrong} — nothing was deleted")
            plan.append((platform, kind, files))
    for platform, kind, files in plan:
        sets = screenshot_sets(localization(found[platform]["id"])["id"])
        if kind not in sets:
            sys.exit(f"✗ {platform} has no {kind} set — make it in App Store Connect first")
        for old in screenshots(sets[kind]):
            must(*call("DELETE", f"/v1/appScreenshots/{old['id']}"), f"delete {old['attributes'].get('fileName')}")
        ids = []
        for path in files:
            data = path.read_bytes()
            _, r = call("POST", "/v1/appScreenshots", {"data": {"type": "appScreenshots",
                "attributes": {"fileName": path.name, "fileSize": len(data)},
                "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": sets[kind]}}}}})
            shot = must(_, r, f"reserve {path.name}")["data"]
            for operation in shot["attributes"]["uploadOperations"]:
                part = urllib.request.Request(operation["url"], method=operation["method"],
                                              data=data[operation["offset"]:operation["offset"] + operation["length"]])
                for header in operation["requestHeaders"]:
                    part.add_header(header["name"], header["value"])
                urllib.request.urlopen(part, timeout=300).close()
            _, r = call("PATCH", f"/v1/appScreenshots/{shot['id']}", {"data": {"type": "appScreenshots", "id": shot["id"],
                "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
            must(_, r, f"commit {path.name}")
            ids.append(shot["id"])
        _, r = call("PATCH", f"/v1/appScreenshotSets/{sets[kind]}/relationships/appScreenshots",
                    {"data": [{"type": "appScreenshots", "id": i} for i in ids]})
        must(_, r, f"{kind} order")
        print(f"{platform} {kind}: {len(ids)} uploaded")
    print("Processing…")
    for _ in range(30):
        time.sleep(10)
        if inventory(found, quiet=True):
            break
    inventory(found)


def cmd_withdraw(version):
    """Cancel each platform's submission that is still waiting, and wait for it to have gone."""
    versions(version)   # the version exists; a typo should not go looking for submissions
    states = "WAITING_FOR_REVIEW,IN_REVIEW" if IN_REVIEW_TOO else "WAITING_FOR_REVIEW"
    for platform in PLATFORMS:
        _, r = call("GET", f"/v1/reviewSubmissions?filter[app]={APP_ID}&filter[platform]={platform}"
                           f"&filter[state]={states}&limit=10")
        waiting = must(_, r, f"{platform} submissions")["data"]
        if not waiting:
            print(f"{platform}: nothing is {states.replace(',', ' or ')}")
            continue
        print(f"{platform}: withdrawing a submission that is {waiting[0]['attributes'].get('state')}")
        for submission in waiting:
            _, r = call("PATCH", f"/v1/reviewSubmissions/{submission['id']}",
                        {"data": {"type": "reviewSubmissions", "id": submission["id"],
                                  "attributes": {"canceled": True}}})
            must(_, r, f"{platform} withdraw")
        # Cancelling is not instant, and nothing can be attached or submitted
        # until it is done.
        state = None
        for _ in range(40):
            _, r = call("GET", f"/v1/reviewSubmissions/{waiting[0]['id']}")
            state = must(_, r, f"{platform} submission")["data"]["attributes"].get("state")
            if state not in ("WAITING_FOR_REVIEW", "IN_REVIEW", "CANCELING"):
                break
            time.sleep(5)
        print(f"{platform}: withdrawn — the submission is {state}")


def cmd_submit(version):
    found = versions(version)
    if not inventory(found):
        sys.exit("✗ not submitted: a set is short, a picture has not finished processing, or no build is attached")
    for platform in PLATFORMS:
        _, r = call("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions",
            "attributes": {"platform": platform}, "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}})
        submission = must(_, r, f"{platform} submission")["data"]["id"]
        _, r = call("POST", "/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission}},
            "appStoreVersion": {"data": {"type": "appStoreVersions", "id": found[platform]["id"]}}}}})
        must(_, r, f"{platform} submission item")
        _, r = call("PATCH", f"/v1/reviewSubmissions/{submission}",
                    {"data": {"type": "reviewSubmissions", "id": submission, "attributes": {"submitted": True}}})
        print(f"{platform}: {must(_, r, f'{platform} submit')['data']['attributes'].get('state')}")


if __name__ == "__main__":
    commands = {"status": cmd_status, "text": cmd_text, "build": cmd_build,
                "screenshots": cmd_screenshots, "submit": cmd_submit, "withdraw": cmd_withdraw}
    arguments = sys.argv[1:]
    IN_REVIEW_TOO = "--in-review" in arguments
    arguments = [a for a in arguments if a != "--in-review"]
    if "--platform" in arguments:
        at = arguments.index("--platform")
        if at + 1 >= len(arguments) or arguments[at + 1] not in PLATFORMS:
            sys.exit(f"--platform takes one of {PLATFORMS}")
        PLATFORMS = (arguments[at + 1],)
        del arguments[at:at + 2]
    if len(arguments) < 2 or arguments[0] not in commands:
        sys.exit(__doc__)
    commands[arguments[0]](*arguments[1:])
