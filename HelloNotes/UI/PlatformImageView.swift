//
//  PlatformImageView.swift
//  HelloNotes
//
//  `Image(nsImage:)` and `Image(uiImage:)` are the same idea with two names,
//  and every view that showed a rendered diagram or thumbnail had to pick one —
//  which is a small reason for a whole file to end up `#if os(macOS)`.
//

import SwiftUI
import MarkdownEditor

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}
