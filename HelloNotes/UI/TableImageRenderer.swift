//
//  TableImageRenderer.swift
//  HelloNotes
//
//  Created by Chris Tham on 17/7/2026.
//
//  The picture of a GFM pipe table that the editor's block-embed renderer draws
//  in place of the table's concealed source — the same "render a block to an
//  image" path as math, Mermaid and images, so a table reads as a real grid and
//  reveals its Markdown source when the caret enters it.
//
//  The drawing is the editor package's (`GFMTableImage`), beside the geometry
//  it draws from (`GFMTableGeometry`). It lived here and drew each cell as the
//  string typed into it — `| Ask Library (**⇧⌘J**) |` with its asterisks,
//  `` `summary:` `` with its backticks — while Preview showed bold and code; a
//  cell is styled text now, measured and drawn as one value, and the parity
//  harness, which cannot link the app, draws the same picture it grades. What
//  is left here is the app's part: its text size and the accent the person
//  chose, which colours a link in a cell as it colours one in Preview.
//

import CoreGraphics
import MarkdownEditor

@MainActor
enum TableImageRenderer {

    static func image(source: String, maxWidth: CGFloat, fontSize: CGFloat = 15,
                      accent: PlatformColor? = nil, isDark: Bool) -> PlatformImage? {
        GFMTableImage.image(source: source, maxWidth: maxWidth,
                            theme: EditorTheme(fontSize: fontSize, accent: accent), isDark: isDark)
    }
}
