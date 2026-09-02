//
//  KeyboardOverlap.swift
//  HelloNotes
//
//  How much of the window the keyboard — *including its input accessory view*
//  — is covering right now.
//
//  ## Why SwiftUI's own keyboard safe area is not enough here
//
//  The editor's `UITextView` carries an `inputAccessoryView`: the format bar
//  (B / I / lists / headings). iOS docks that above the software keyboard, and
//  **at the bottom of the screen when a hardware keyboard is attached** — an
//  iPad with a Magic Keyboard, or any iPad in the Simulator.
//
//  In that hardware case SwiftUI reports a keyboard safe area of **zero**: as
//  far as it is concerned no keyboard is on screen. The 44pt accessory bar is
//  on screen all the same, in the keyboard's own window, on top of everything
//  the app draws. So the editor's bottom bar — word count, save status, the
//  four mode buttons — was laid out flush to the bottom edge and the format bar
//  was painted straight over it. Moving that bar into a `safeAreaInset` did not
//  help, and could not: the inset was correct, the *inset amount* was zero.
//
//  `keyboardWillChangeFrameNotification` does report it, because the frame it
//  carries is the whole input view — accessory included — so the part of it
//  that intersects the window is exactly what has to be avoided. That number is
//  what this publishes.
//
//  Paired with `.ignoresSafeArea(.keyboard)` at the call site so the two
//  mechanisms cannot both apply and shift the bar twice.
//

import SwiftUI
import MarkdownEditor
#if canImport(UIKit)
import UIKit
#endif

@Observable
@MainActor
final class KeyboardOverlap {

    /// Points of the window covered from the bottom, accessory bar included.
    /// Zero when nothing is up.
    private(set) var height: CGFloat = 0

    #if canImport(UIKit)
    private var observers: [NSObjectProtocol] = []

    init() {
        let centre = NotificationCenter.default
        for name in [UIResponder.keyboardWillChangeFrameNotification,
                     UIResponder.keyboardWillShowNotification] {
            observers.append(centre.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { self.apply(note) }
            })
        }
        observers.append(centre.addObserver(forName: UIResponder.keyboardWillHideNotification,
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.height = 0 }
        })
    }

    // No `deinit` unregistration.
    //
    // The block-based observers capture `self` strongly, so this object lives
    // exactly as long as its registrations do and `deinit` cannot run while
    // they are live — and a `deinit` is nonisolated, so it could not read the
    // main-actor `observers` array anyway. Since iOS 9 an un-removed
    // block observer is not a dangling-pointer crash; it is at worst a leak
    // bounded by the number of editor columns, which is one.

    private func apply(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                as? NSValue else { return }
        // The scene's own coordinate space. The notification's frame is in
        // screen coordinates, which on iPad differ from the window's whenever
        // the app is not full screen — Split View, Slide Over, or a resized
        // window — so intersecting with the window is the only reading that is
        // right in every one of them.
        guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) else { return }
        let covered = window.frame.intersection(frame.cgRectValue)
        let next = covered.isNull ? 0 : covered.height
        if next != height {
            MarkdownEditor.EditorProbe.logEdit(
                "keyboard overlap \(Int(height)) -> \(Int(next))  (bottom bar moves)")
        }
        height = next
    }
    #else
    init() {}
    #endif
}
