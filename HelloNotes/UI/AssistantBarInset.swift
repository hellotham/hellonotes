//
//  AssistantBarInset.swift
//  HelloNotes
//
//  How much of the window iPad's floating shortcuts pill is covering.
//
//  ## Why SwiftUI does not already know
//
//  With a **software** keyboard, the shortcuts bar is part of the keyboard, so
//  SwiftUI's keyboard safe area already accounts for it and nothing here is
//  needed. With a **hardware** keyboard there is no software keyboard to inset
//  for — SwiftUI reports a keyboard safe area of zero — and yet iPadOS still
//  floats the pill (the `EN AU` selector, the formatting commands, the mic)
//  near the bottom of the window, drawn over whatever the app put there. That
//  is how it came to sit on top of the word count and the mode picker.
//
//  So this reports only the part SwiftUI misses, and the test for "SwiftUI
//  missed it" is the size of the reported frame: a real keyboard is hundreds of
//  points tall and SwiftUI will have insetted for it; the pill alone is a
//  strip. Padding by the strip and not by the keyboard is what keeps the bar
//  from moving twice.
//
//  ## What this is *not*
//
//  It is not `.ignoresSafeArea(.keyboard)`. An earlier version suppressed
//  SwiftUI's avoidance entirely so that only this number applied — which also
//  told the *editor* to ignore the keyboard, so the text ran underneath it, the
//  caret hid behind the status row, and the end of a note could not be scrolled
//  to. The editor keeps normal avoidance; only the bar consults this.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@Observable
@MainActor
final class AssistantBarInset {

    /// Points of the window covered by the floating pill, and nothing else.
    /// Zero whenever a real keyboard is on screen, because SwiftUI has already
    /// dealt with that one.
    private(set) var height: CGFloat = 0

    #if canImport(UIKit)
    /// Above this, the reported frame is a keyboard rather than a bare pill.
    /// The pill runs to roughly 55pt with the largest Dynamic Type; the
    /// shortest software keyboard is several times that, so the gap between
    /// them is wide and this does not need to be precise.
    private static let pillCeiling: CGFloat = 140

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

    private func apply(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue,
              let window = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .flatMap(\.windows)
                  .first(where: \.isKeyWindow)
        else { return }
        // Intersected with the window rather than taken raw: the notification's
        // frame is in screen coordinates, which differ from the window's in
        // Split View, Slide Over, or any resized iPad window.
        let covered = window.frame.intersection(frame.cgRectValue)
        let overlap = covered.isNull ? 0 : covered.height
        height = overlap > Self.pillCeiling ? 0 : overlap
    }
    #else
    init() {}
    #endif
}
