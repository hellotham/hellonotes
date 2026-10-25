//
//  ax-press.swift
//  scripts
//
//  Press the button named `<label>` in the app with process id `<pid>`, through
//  Accessibility — the way `store-shots-mac.sh` opens the panel, which has a
//  button in the bar and no menu command. AXPress on a named element works in
//  this SwiftUI app where a click at a coordinate does not (CLAUDE.md).
//
//      swiftc -O scripts/ax-press.swift -o ax-press && ./ax-press <pid> "Show Panel"
//      ./ax-press <pid> "Message" focus       # a field, by its name: focus it
//
//  Prints "pressed" or "focused", or why not and exits 1 — a script that
//  presses a button fails when the button is not there, and one that types
//  into a field must not type into whatever else has the keyboard: a focus
//  that Accessibility refused, or accepted and did not take, is a failure,
//  never a success to type after.
//

import ApplicationServices
import Foundation

let arguments = CommandLine.arguments
guard (3...4).contains(arguments.count), let pid = pid_t(arguments[1]) else {
    print("usage: ax-press <pid> <label> [focus]")
    exit(2)
}
let label = arguments[2]
let focusing = arguments.count == 4 && arguments[3] == "focus"

func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
}

func find(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 60 else { return nil }
    let role = value(element, kAXRoleAttribute) as? String
    let wanted = focusing ? [kAXTextFieldRole as String, kAXTextAreaRole as String] : [kAXButtonRole as String]
    if let role, wanted.contains(role) {
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute] where (value(element, attribute) as? String) == label {
            return element
        }
    }
    for child in (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        if let found = find(in: child, depth: depth + 1) { return found }
    }
    return nil
}

guard let element = find(in: AXUIElementCreateApplication(pid)) else {
    print("not found")
    exit(1)
}
if focusing {
    let result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard result == .success else {
        print("not focused: AXError \(result.rawValue)")
        exit(1)
    }
    // Asked and answered is not the same as done: read it back.
    var focused = false
    for _ in 0..<20 where !focused {
        focused = (value(element, kAXFocusedAttribute) as? Bool) == true
        if !focused { usleep(50_000) }
    }
    guard focused else {
        print("not focused: the field did not take the keyboard")
        exit(1)
    }
    print("focused")
} else {
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else {
        print("not pressed: AXError \(result.rawValue)")
        exit(1)
    }
    print("pressed")
}
