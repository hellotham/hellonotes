//
//  PanelFrame.swift
//  HelloNotes
//
//  Created by Chris Tham on 16/8/2026.
//
//  One size for a panel presented as a sheet, on both platforms.
//
//  It was a fixed size on the Mac and "whatever the device gives a sheet" on
//  iOS — so the iPad's form sheet drew the same panel at its own width and
//  height, and the two were different layouts of one screen. Now both take the
//  panel's size (`chromeSheetFrame`): the Mac's sheet is that size, the iPad's
//  sheet fits itself to it, and a phone — narrower than the panel — still gets
//  a sheet that fits the screen. A hard 520pt width would be 130pt wider than
//  an iPhone 15 and clip the Replace button off the edge, which is why the
//  width is a maximum there rather than a demand.
//

import SwiftUI

extension View {
    /// The panel's size, as a sheet, on both platforms.
    func panelFrame(width: CGFloat, height: CGFloat) -> some View {
        chromeSheetFrame(width: width, height: height)
    }
}
