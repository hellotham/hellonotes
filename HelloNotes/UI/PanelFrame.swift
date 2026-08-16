//
//  PanelFrame.swift
//  HelloNotes
//
//  Created by Chris Tham on 16/8/2026.
//
//  One rule for the AI panels that now ship on both platforms.
//
//  A Mac panel is sized by its content — nothing else decides how big a sheet
//  is. An iOS sheet is sized by the *device*, and a hard 520pt width is 130pt
//  wider than an iPhone 15's screen, so carrying the Mac's number across is not
//  a cosmetic difference: it clips the Replace button off the edge.
//

import SwiftUI

extension View {
    /// A fixed panel size on the Mac; device-sized on iOS.
    func panelFrame(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        return frame(width: width, height: height)
        #else
        return frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}
