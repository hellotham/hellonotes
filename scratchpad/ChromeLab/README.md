# ChromeLab — a headless bench for the titlebar/column question

Why this exists: five attempts to stop the shell's columns painting under the
window titlebar were made *in the app*, each verified by relaunching and looking.
That is the loop the project's own process forbids — establish the contract,
prove it in a test app headlessly, and launch only to confirm what you already
know.

So this builds the same shell shape as `AdaptiveShell` (a `NavigationSplitView`
with three columns and an inspector) inside an `NSWindow` that is **never ordered
front**, applies each candidate configuration to its own window, measures the
result, and prints a table.

    swift run --package-path scratchpad/ChromeLab ChromeLab

The measurement is the same one the app's `ChromeProbe` makes:

* `titlebarOverlap` — `contentView.height − contentLayoutRect.height`. Zero means
  the titlebar does not overlap the content at all.
* `columnsUnderTitlebar` — how many split-view columns reach above
  `contentLayoutRect.maxY`. Zero is the goal.

A candidate "passes" when both are zero. Anything else is a fix that would have
looked plausible and changed nothing — which is precisely what happened four
times before this existed.
