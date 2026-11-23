//
//  PictureNames.swift
//  MarkdownCore
//
//  Which names name a picture — what `![[…]]` draws rather than transcludes.
//

import Foundation

/// Whether a name written in a note names a picture.
///
/// `![[photo.png]]` is a picture and `![[Meeting notes]]` is a note shown in
/// place, and Obsidian tells the two apart by nothing but the name's
/// extension. The editor has to ask before it asks the host for a picture
/// anywhere but a paragraph of its own: inside a list item or beside a word,
/// a note's card has no place to go, and only a picture is drawn there.
public enum PictureNames {
    /// What Obsidian calls a picture, with the Apple formats both of the
    /// app's renderers draw — TextKit's and WebKit's — lowercased. Narrower
    /// than what the system calls an image (`CollectionFileKind`, which lists
    /// a camera's raw files and icons among a collection's files): a file
    /// named here is one Edit and Preview can each show, so this is what
    /// Insert Image offers and what `![[…]]` is looked up among.
    public static let extensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "avif", "bmp", "svg",
        "heic", "heif", "tif", "tiff",
    ]

    /// Whether `name` — a file name or a path, as written — ends in a
    /// picture's extension.
    public static func isPicture<S: StringProtocol>(_ name: S) -> Bool {
        guard let dot = name.lastIndex(of: "."),
              !name[name.index(after: dot)...].contains("/") else { return false }
        return extensions.contains(name[name.index(after: dot)...].lowercased())
    }

    /// The name a `![[…]]` embed's inner text gives, as written: up to its
    /// alias's pipe (`WikiLinkSyntax`), less a `#…` subpath, trimmed. What
    /// `isPicture` is asked of.
    public static func embedTarget<S: StringProtocol>(_ inner: S) -> String {
        let target = WikiLinkSyntax.split(Substring(inner)).target
        let named = target.firstIndex(of: "#").map { target[..<$0] } ?? target
        return named.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Sizes

    /// The largest side a size may give, in points. Past it the words are
    /// not a size: no screen is that wide, and a note that asked for
    /// `|100x9223372036854775807` asked Edit for a bitmap no device can
    /// make — a trap converting the height to pixels, or gigabytes asked of
    /// an iPhone at every launch, since the last note opens again.
    public static let largestSize = 10_000

    /// `300` or `300x200`, as Obsidian writes a picture's size: whole
    /// numbers above nought and no more than `largestSize`, in CSS pixels —
    /// which are points.
    public static func size<S: StringProtocol>(_ text: S) -> (width: Int, height: Int?)? {
        let parts = text.trimmingCharacters(in: .whitespaces).lowercased()
            .split(separator: "x", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let width = Int(parts[0]), (1...largestSize).contains(width) else { return nil }
        guard parts.count == 2 else { return (width, nil) }
        guard let height = Int(parts[1]), (1...largestSize).contains(height) else { return nil }
        return (width, height)
    }

    /// The size written after the last pipe of a picture's description —
    /// `![A cat|300](cat.png)` — or of an embed's inner text —
    /// `![[cat.png|A cat|300x200]]` — or nil. Obsidian's one way to size a
    /// picture, in both of its spellings. A pipe a backslash escapes is a
    /// pipe here too: a table's row needs the escape, and outside one cmark
    /// reads `\|` as `|`.
    public static func sizeSuffix<S: StringProtocol>(of text: S) -> (width: Int, height: Int?)? {
        guard let pipe = text.lastIndex(of: "|") else { return nil }
        return size(text[text.index(after: pipe)...])
    }

    /// The size a picture is drawn at, in points — what a page gives
    /// `<img width="W" height="H">` under `max-width: 100%`, and so what
    /// Edit draws: the width asked for, up past the picture's own or down,
    /// and never past `maxWidth`; the height asked for, or in proportion to
    /// the width drawn when only a width is. Asked for neither, the picture's
    /// own size, brought down to `maxWidth` and never up.
    ///
    /// One rule, here, for the app's renderer and the parity harness's, so
    /// the harness grades the rule rather than a copy of it.
    public static func drawnSize(natural: CGSize, maxWidth: CGFloat, width: Int?, height: Int?) -> CGSize {
        guard natural.width > 0, natural.height > 0 else { return natural }
        var size = natural
        if let width {
            size = CGSize(width: CGFloat(width),
                          height: height.map(CGFloat.init) ?? natural.height * CGFloat(width) / natural.width)
        } else if let height {
            size = CGSize(width: natural.width * CGFloat(height) / natural.height, height: CGFloat(height))
        }
        guard size.width > maxWidth, maxWidth > 0 else { return size }
        // `max-width` narrows the box; a height given stays as given, and
        // one that follows the width follows it down.
        let keepsHeight = width != nil && height != nil
        return CGSize(width: maxWidth, height: keepsHeight ? size.height : size.height * maxWidth / size.width)
    }
}
