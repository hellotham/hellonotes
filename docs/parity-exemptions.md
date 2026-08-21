# Platform parity exemptions

**Nothing on this page is decided by Claude.** An entry is only in force once the
project owner has added an `Approved:` line to it. Until then the exemption does
not exist, `.claude/hooks/platform-parity-check.py` refuses the gate it covers,
and the correct action is to share the implementation rather than to wait.

## Why this file exists

The hook originally accepted an inline `// PARITY-EXEMPT: <reason>` written by
whoever added the gate. That is not a control — it is the same self-granted
permission that produced every divergence this audit found, each of which arrived
with a comment defending it:

- *"the iPad is never wide enough for a third column"* — it was about window
  width, which `ShellKind` already decides.
- *"touch sizing, not arrangement"* — it was about whether a pointer is attached,
  which `GCMouse` answers.
- *"Move to Trash"* catching its own throw — it was about whether the platform
  has a Trash for that location.

Each reason was written in good faith and each was wrong. A reason authored by
the same party that wants the exemption cannot be the check on it.

## How an exemption works

1. A gate is proposed. The hook refuses it and names the file and line.
2. Someone adds an entry below with an `id`, the gate it covers, and the argument
   for it — including what fact the gate is really about, and why that fact
   cannot be asked directly.
3. **The owner adds `Approved:`** with their name and the date. Claude cannot:
   `.claude/hooks/protect-files.py` refuses any model edit to this file.
4. The gate carries `// PARITY-EXEMPT: <id>` and the hook lets it through.

An entry with no `Approved:` line is a *request*, not an exemption.

---

## Entries

### `reveal-in-finder`

- **Covers:** `HelloNotes/UI/AppCommands.swift` — the `#if os(macOS)` around the
  "Reveal in Finder" menu item, and `revealInFinder` in
  `PlatformParityTests.platformSpecific`.
- **Argument:** the gate is about whether the OS has a file manager that can be
  told to select a path. macOS has `NSWorkspace.activateFileViewerSelecting`;
  iOS exposes no public API to reveal an arbitrary path in Files. Unlike the
  three cases above, there is no fact available to ask instead — the capability
  is absent rather than differently named.
- **Alternative considered:** a Share sheet over the note's file. It is a
  different action (hand this file to another app) rather than the same one, so
  it belongs on both platforms as its own command or on neither, not as iOS's
  substitute for this.
- **Approved:** _pending — not in force_

### `editor-selection-affordance`

- **Covers:** the divergence between `SelectionActionBar` (a floating bar over a
  selection, macOS) and `selectionMenuItems` (items added to the system edit
  menu, iOS). It is what currently stops `NewEditorHost` and `iOSLiveEditor`
  merging into one host.
- **Argument:** iOS already floats a system menu over a selection, and a second
  one competing for the same few hundred points reads as a bug. macOS has no
  equivalent floating menu, and its convention is the right-click menu, which a
  trackpad-only selection gesture does not reach. So the gate is about *which
  affordance each platform's users already reach for* — a convention rather than
  a capability, which makes it weaker than `reveal-in-finder` and worth deciding
  deliberately.
- **Alternative considered:** put the vault actions in the context menu on both
  and delete the floating bar. This unifies the code and costs Mac users a
  discoverable affordance; it may well be the right call.
- **Approved:** _pending — not in force_
