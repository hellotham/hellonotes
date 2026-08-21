//
//  WebAuthAnchor.swift
//  HelloNotes
//
//  Created by Chris Tham on 21/8/2026.
//
//  The window `ASWebAuthenticationSession` presents its login sheet over, for
//  every provider that signs in through OAuth (Dropbox, Box, Google Drive,
//  OneDrive).
//
//  This exists because the obvious iOS answer is wrong in a way that fails
//  silently. `ASPresentationAnchor` is `NSWindow` on macOS and `UIWindow` on
//  iOS, so `ASPresentationAnchor()` *looks* like a harmless placeholder on both
//  — but a bare `UIWindow()` belongs to no `UIWindowScene`, and a scene-less
//  window is not somewhere iOS can present anything. `start()` fails with
//  `presentationContextInvalid`, no sheet appears, and "Connect…" reads as a
//  dead button. All four providers shipped that placeholder, so the whole
//  direct-API cloud feature was unreachable on iPad.
//
//  One helper rather than four copies: the anchor is a property of the *app*,
//  not of any provider, and four identical answers to one question is how three
//  of them end up drifting.
//

import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if canImport(AuthenticationServices)
/// Supplies the presentation anchor for `ASWebAuthenticationSession`.
///
/// `@MainActor` because both platforms' window lookups are — and because
/// `ASWebAuthenticationPresentationContextProviding` is itself declared
/// `NS_SWIFT_UI_ACTOR`, so every caller is already on the main actor.
@MainActor
enum WebAuthAnchor {
    /// The window to present the OAuth sheet over: the app's frontmost real
    /// window, never a freshly conjured one.
    static func presentationAnchor() -> ASPresentationAnchor {
        #if os(macOS)
        // `keyWindow` is nil while a panel or a menu holds focus — which is
        // exactly when a "Connect…" button gets clicked — so fall through to the
        // main window and then to any window rather than to an empty one.
        return NSApplication.shared.keyWindow
            ?? NSApplication.shared.mainWindow
            ?? NSApplication.shared.windows.first
            ?? orphanAnchor()
        #elseif canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // Prefer the scene the user is actually looking at. A backgrounded or
        // unattached scene's window is a valid anchor *object* but the wrong
        // place to put a sheet, so it is only a fallback.
        let scene = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
        if let window = scene?.keyWindow ?? scene?.windows.first { return window }

        // No window anywhere: the app has nothing on screen, so there is nothing
        // to present over and the session will refuse to start whatever we hand
        // back. The point of this branch is the log line — a dead window in
        // silence is what made the original bug take a device to notice.
        #if DEBUG
        print("WebAuthAnchor: no UIWindow on screen — ASWebAuthenticationSession will fail with presentationContextInvalid.")
        #endif
        return orphanAnchor()
        #else
        return orphanAnchor()
        #endif
    }

    /// A window attached to nothing, for the unreachable branches above.
    ///
    /// Built generically because iOS 26 deprecates every scene-less `UIWindow`
    /// initialiser — the SDK making the same point this file does, that a window
    /// outside a scene has no use. `UIView.init(frame:)` is not deprecated, so
    /// reaching it through a generic keeps the build clean without pretending
    /// the result is usable.
    private static func orphanAnchor() -> ASPresentationAnchor {
        #if os(macOS)
        return ASPresentationAnchor()
        #else
        return make(ASPresentationAnchor.self)
        #endif
    }

    #if !os(macOS) && canImport(UIKit)
    private static func make<T: UIView>(_ type: T.Type) -> T { T(frame: .zero) }
    #endif
}
#endif
