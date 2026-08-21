//
//  ExternalURL.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  Hand a URL to whatever the system opens URLs with.
//
//  Two lines that differ — `NSWorkspace.shared.open` and
//  `UIApplication.shared.open` — and they were two of the last things keeping
//  the editor hosts apart. A link tap is the same decision on both platforms;
//  only the call is different, so the call moves down here where it has an
//  `#else` and the hosts above it are one host.
//

import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
enum ExternalURL {
    /// Open `url` in the system's handler for it.
    static func open(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
