import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    if let owner = w[kCGWindowOwnerName as String] as? String, owner == "HelloNotes",
       let id = w[kCGWindowNumber as String] as? Int,
       let b = w[kCGWindowBounds as String] as? [String: Any] {
        // Origin as well as size: a popover is its *own* CGWindow, so
        // `screencapture -l<main>` never contains one. Compositing the two
        // captures needs the popover's position relative to the window, and
        // that is the only place to get it.
        print("\(id) \(b["Width"] ?? "?")x\(b["Height"] ?? "?") at \(b["X"] ?? "?"),\(b["Y"] ?? "?") layer=\(w[kCGWindowLayer as String] ?? "?")")
    }
}
