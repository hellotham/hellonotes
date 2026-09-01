# App Review screenshots for the in-app purchases

App Store Connect requires a screenshot per in-app purchase before the product
can be submitted, and a missing one is a Guideline 2.1(b) rejection ("one or
more of the In-App Purchase products have not been submitted for review") —
which is exactly what happened to build 14.

`support-screen-ipad.png` is Settings ▸ Support on an iPad Pro 11-inch M4
simulator (1668 × 2420), captured with `xcrun simctl io HN-iPad screenshot`
against the **live** App Store, so the prices in it are real product data rather
than placeholders. Both products had to be loading for it to be worth taking:
the Champion consumable was created the same morning and returned nothing for
roughly forty-five minutes while it propagated, and a screenshot taken in that
window would have shown "Champion is unavailable right now".

It is committed rather than left in a scratchpad because remaking it needs a
booted simulator, a build, and both products live — the same rule that lost the
undecorated App Store screenshots once already.

To retake it: build for the simulator, install, launch, then compose button
(press and hold) ▸ Settings… ▸ scroll to the bottom ▸ Support ▸ Support
HelloNotes.
