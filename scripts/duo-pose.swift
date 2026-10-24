//
//  duo-pose.swift
//  HelloNotes
//
//  Presses a button in Device Hub for one simulator — the iPhone Duo's poses.
//  Device Hub (Xcode 27.1's simulator app) draws its controls in SwiftUI,
//  which System Events cannot see, so this goes through the Accessibility
//  API — `ax-press.swift`'s job for the Mac app, with the row Device Hub
//  needs selected first. `scripts/duo-pose.sh` builds and drives it; by hand:
//
//      duo-pose <Device Hub pid> <device UDID, or a prefix of it> [button]
//
//  With no button it selects the device's row and lists every button in the
//  window, which is how to learn the poses' names (Closed, Partially Open,
//  Open, Rotate Right — and Start, which a device needs pressed before its
//  pose buttons appear). Exit 2 with "no window" when Device Hub has none
//  open (it closes its window and keeps running), 1 when the row or the
//  button is not there.
//

import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else {
    print("usage: duo-pose <pid> <udid> [button]")
    exit(64)
}
let wanted = args[2]
let press: String? = args.count > 3 ? args[3] : nil

func value(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var r: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &r) == .success ? r : nil
}
func children(_ e: AXUIElement) -> [AXUIElement] { (value(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func string(_ e: AXUIElement, _ a: String) -> String { (value(e, a) as? String) ?? "" }
func find(_ e: AXUIElement, depth: Int = 0, _ test: (AXUIElement) -> Bool) -> AXUIElement? {
    if test(e) { return e }
    guard depth < 40 else { return nil }
    for c in children(e) { if let f = find(c, depth: depth + 1, test) { return f } }
    return nil
}

guard AXIsProcessTrusted() else {
    print("not trusted: give this process Accessibility access (System Settings ▸ Privacy & Security ▸ Accessibility)")
    exit(3)
}
let app = AXUIElementCreateApplication(pid)
let windows = (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
guard !windows.isEmpty else {
    print("no window")
    exit(2)
}

// The device's row: an AXRow holding an element whose identifier names the
// device (`TableRow.Device.<udid>`), in whichever window holds the list — a
// started device has a window of its own, untitled, listed first.
guard let row = windows.lazy.compactMap({ window in
    find(window, { e in
        string(e, kAXRoleAttribute) == "AXRow"
            && children(e).contains { c in find(c, { string($0, "AXIdentifier").contains(wanted) }) != nil }
    })
}).first else {
    print("row not found for \(wanted)")
    exit(1)
}
let selected = AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
let pressed = AXUIElementPerformAction(row, kAXPressAction as CFString)
print("row selected: \(selected.rawValue) pressed: \(pressed.rawValue)")
usleep(2_000_000)   // the detail pane follows the selection

// Every button in the window, by description; press the one asked for.
var found: AXUIElement?
func walk(_ e: AXUIElement, _ depth: Int = 0) {
    guard depth < 40 else { return }
    let role = string(e, kAXRoleAttribute)
    if ["AXButton", "AXRadioButton", "AXMenuButton", "AXPopUpButton"].contains(role) {
        let d = string(e, kAXDescriptionAttribute), t = string(e, kAXTitleAttribute), i = string(e, "AXIdentifier")
        if !(d.isEmpty && t.isEmpty && i.isEmpty) { print("\(role) desc=\"\(d)\" title=\"\(t)\" id=\"\(i)\"") }
        if let press, found == nil, d == press || t == press || i == press { found = e }
    }
    for c in children(e) { walk(c, depth + 1) }
}
for w in (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
    print("== window: \(string(w, kAXTitleAttribute))")
    walk(w)
}
if let press {
    guard let found else { print("no button \(press)"); exit(1) }
    print("press \(press): \(AXUIElementPerformAction(found, kAXPressAction as CFString).rawValue)")
}
