//
//  window-names.swift — is a name that should not be there in the window?
//
//  Before a capture of the Mac app is taken, the window is *read*, through
//  Accessibility, for the names of the person's other collections and their
//  top-level folders — and what is printed is a count, never a name. A capture
//  run opens the sample collection alone (`-HNCaptureSession YES` with all
//  three collection lists named in the argument domain), so the count is 0 by
//  construction; this is the check that the construction held, made without
//  looking — "screenshotting to check *is* capturing" (AGENTS.md).
//
//  The names file has one name a line: `=name` matches an element whose text
//  is exactly that, `~name` one whose text contains it (a collection's own
//  name, which a title may wrap).
//
//  Usage: window-names <pid> <names file>     →  windows=1 matches=0
//
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func texts(_ element: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute]
        .compactMap { attribute(element, $0) as? String }
        .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}
func walk(_ element: AXUIElement, depth: Int = 0, _ visit: (AXUIElement) -> Void) {
    visit(element)
    guard depth < 60 else { return }
    for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth: depth + 1, visit) }
}

guard CommandLine.arguments.count == 3, let pid = pid_t(CommandLine.arguments[1]) else {
    print("usage: window-names <pid> <names file>"); exit(2)
}
let lines = ((try? String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)) ?? "")
    .split(separator: "\n").map { $0.lowercased() }
let exact = Set(lines.filter { $0.hasPrefix("=") }.map { String($0.dropFirst()) })
let within = lines.filter { $0.hasPrefix("~") }.map { String($0.dropFirst()) }
let windows = (attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? []
var matches = 0
for window in windows {
    walk(window) { element in
        if texts(element).contains(where: { text in exact.contains(text) || within.contains(where: { text.contains($0) }) }) {
            matches += 1
        }
    }
}
print("windows=\(windows.count) matches=\(matches)")
