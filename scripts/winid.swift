import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    if let owner = w[kCGWindowOwnerName as String] as? String, owner == "HelloNotes",
       let id = w[kCGWindowNumber as String] as? Int,
       let b = w[kCGWindowBounds as String] as? [String: Any] {
        print("\(id) \(b["Width"] ?? "?")x\(b["Height"] ?? "?") layer=\(w[kCGWindowLayer as String] ?? "?")")
    }
}
