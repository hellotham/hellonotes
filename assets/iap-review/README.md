# App Review assets for the in-app purchases

Two artifacts, for the two things App Review asks for separately.

## `support-screen-ipad.png` — the App Review screenshot (Guideline 2.1(b))

App Store Connect requires a screenshot per in-app purchase before the product
can be submitted, and a missing one is a Guideline 2.1(b) rejection ("one or
more of the In-App Purchase products have not been submitted for review") —
which is exactly what happened to build 14. One file serves both products,
because both appear on the one screen.

Settings ▸ Support on an iPad Pro 11-inch M4 simulator (1668 × 2420), captured
with `xcrun simctl io HN-iPad screenshot` against the **live** App Store, so the
prices in it are real product data rather than placeholders. Both products have
to be loading for it to be worth taking: the Champion consumable was created one
morning and returned nothing for roughly forty-five minutes while it propagated,
and a screenshot taken in that window would have shown "Champion is unavailable
right now".

## `support-flow-ipad.mp4` — the 3.1.2(c) demonstration

82 seconds, 834 × 1210, 1.7 MB. Attach it in Resolution Center when App Review
asks to be shown the subscription disclosures in the binary.

It walks the whole path in one take — compose ▸ Settings… ▸ Support ▸ Support
HelloNotes — and then shows every one of the five things 3.1.2(c) requires *on
the screen where the purchase happens*:

| Requirement | Where it appears in the video |
|---|---|
| Subscription title | "Commercial" |
| Length | "per year", and the sentence "renews automatically each year unless it is turned off at least 24 hours before the period ends" |
| Price per period | "$30.00 per year", live from the App Store |
| Terms of Use (EULA) | tapped — Safari loads Apple's standard EULA |
| Privacy policy | tapped — Safari loads `hellotham.com/hellonotes/privacy` |

**Both links are followed on camera rather than merely shown.** "Functional
links" is the wording of the guideline, and a screenshot cannot demonstrate
function. It also happens to be the check that catches a dead link: the privacy
URL takes **no trailing slash** — `…/privacy` is 200 and `…/privacy/` is 404 —
and a dead policy link on the one screen a reviewer must open is a rejection.
Verify with `curl`, never by reading the URL.

The recording is sped up 3.5× from a 5-minute capture; the raw pace was an
artifact of driving the simulator one tool call at a time, not of the app.

## Retaking either

Build for the simulator, install, launch, then compose button (press and hold) ▸
Settings… ▸ scroll to the bottom ▸ Support ▸ Support HelloNotes. For the video,
start `xcrun simctl io HN-iPad recordVideo --codec h264 out.mp4` first and stop
it with SIGINT.

Both are committed rather than left in a scratchpad because remaking them needs
a booted simulator, a build, and both products live — the same rule that lost
the undecorated App Store screenshots once already.
