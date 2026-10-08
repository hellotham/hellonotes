//
//  ChromeParityTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 23/9/2026.
//
//  Renders the app's chrome — the bar, the rows, the tab strip, the mode
//  switch, the status bar, the panel header — at fixed sizes, in both
//  appearances, and writes the pixels out, so the same scenes rendered on the
//  Mac and in the iOS simulator can be compared **pixel for pixel**
//  (`scripts/chrome-parity.sh`).
//
//  The requirement is that the two platforms draw the same picture, and the
//  only instrument that can confirm that is one that looks at both pictures.
//  A source check can prove a view uses `Chrome` tokens; it cannot prove the
//  tokens render the same, which is the claim. Every scene uses fixed data
//  and a fixed accent, so nothing in it can differ except the drawing.
//
//  What is not rendered: a `Menu`'s button and a `TextField`, which are
//  platform controls that `ImageRenderer` does not draw. Their *faces* are
//  here — the glyph a menu button draws is `ChromeGlyph`, and the search
//  field's box is drawn — and the full window is compared separately.
//

import Testing
import SwiftUI
import ImageIO
@testable import HelloNotes

@MainActor
struct ChromeParityTests {

    /// The default purple, fixed, so the system accent cannot enter.
    static let accent = Color(red: 0.494, green: 0.341, blue: 0.761)

    static let notes: [Note] = [
        Note(title: "Meeting Notes", fileURL: URL(fileURLWithPath: "/tmp/Meeting Notes.md"),
             lastModified: Date(timeIntervalSince1970: 1_790_000_000)),
        Note(title: "Start Here", fileURL: URL(fileURLWithPath: "/tmp/Start Here.md"),
             lastModified: Date(timeIntervalSince1970: 1_790_000_000)),
    ]

    /// Where the renders go: a folder inside this process's own temporary
    /// directory — the app's container on both platforms — named for the
    /// platform, printed so the comparison script can find it.
    static var output: URL {
        #if os(macOS)
        let platform = "macos"
        #else
        let platform = "ios"
        #endif
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("ChromeParity", isDirectory: true)
            .appendingPathComponent(platform, isDirectory: true)
    }

    // MARK: - Scenes

    static var bar: some View {
        HStack(spacing: Chrome.Metric.barSpacing) {
            // The search field's face: its box, glyph and prompt.
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(Chrome.Typeface.rowIcon)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                ChromeLine("Search", size: 13, colour: Chrome.Colour.tertiaryLabel)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(width: Chrome.Metric.searchWidth, height: Chrome.Metric.control)
            .background(Chrome.Colour.fill, in: RoundedRectangle(cornerRadius: Chrome.Metric.radius))
            ChromeButton(title: "Hide Sidebar", systemImage: "sidebar.leading", accent: accent) {}
            ChromeButton(title: "New Note", systemImage: "square.and.pencil", accent: accent) {}
            ChromeGlyph(systemImage: "ellipsis.circle", isOn: false, hovering: false, accent: accent)
            Spacer(minLength: 8)
            EditorTabBar(notes: notes, activeID: notes[0].id, onSelect: { _ in }, onClose: { _ in },
                         accent: accent)
            Spacer(minLength: 8)
            ChromeGlyph(systemImage: "chevron.down.circle", isOn: false, hovering: false, accent: accent)
            ChromeButton(title: "Hide Panel", systemImage: "sidebar.trailing", isOn: true, accent: accent) {}
        }
        .padding(.horizontal, Chrome.Metric.barPadding)
        .frame(width: 900, height: Chrome.Metric.barHeight)
        .background(Chrome.Colour.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Chrome.Colour.separator).frame(height: 1) }
    }

    static var rows: some View {
        VStack(spacing: 0) {
            ChromeRowFrame(height: Chrome.Metric.rowCollection, accent: accent) {
                ChromeDisclosure(isExpandable: true, isExpanded: true) {}
                ChromeCollectionRow(content: CollectionRowContent(
                    name: "DefaultCollection", unavailable: nil, isScanning: false,
                    isFocused: true, gitIsClean: false))
                Spacer(minLength: 4)
            }
            ChromeRowFrame(height: Chrome.Metric.rowLeaf, depth: 1, accent: accent) {
                ChromeDisclosure(isExpandable: true, isExpanded: false) {}
                ChromeLabelRow(systemImage: "clock", title: "Recents", titleSize: 11,
                               titleColour: Chrome.Colour.secondaryLabel)
                Spacer(minLength: 4)
            }
            ChromeRowFrame(height: Chrome.Metric.rowLeaf, depth: 1, accent: accent) {
                ChromeDisclosure(isExpandable: true, isExpanded: true) {}
                ChromeLabelRow(systemImage: "folder", title: "Examples")
                Spacer(minLength: 4)
            }
            ChromeRowFrame(height: Chrome.Metric.rowNote, depth: 2, isSelected: true, accent: accent) {
                ChromeDisclosure(isExpandable: false, isExpanded: false) {}
                ChromeNoteRow(content: NoteRowContent(title: "Nested Note", date: "16 Sep",
                                                      snippet: nil, isOnlineOnly: false))
                Spacer(minLength: 4)
            }
            ChromeRowFrame(height: Chrome.Metric.rowNote, depth: 2, accent: accent) {
                ChromeDisclosure(isExpandable: false, isExpanded: false) {}
                ChromeNoteRow(content: NoteRowContent(title: "Finding Things", date: "16 Sep",
                                                      snippet: "…the outline lists a note's headings…",
                                                      isOnlineOnly: true))
                Spacer(minLength: 4)
            }
            ChromeRowFrame(height: Chrome.Metric.rowNote, accent: accent) {
                ChromeNoteRow(content: NoteRowContent(title: "Writing", date: "16 Sep",
                                                      snippet: nil, isOnlineOnly: false), wide: true)
            }
            ChromeRowFrame(height: Chrome.Metric.rowLeaf, depth: 2, accent: accent) {
                ChromeDisclosure(isExpandable: false, isExpanded: false) {}
                ChromeLabelRow(systemImage: "doc.richtext", title: "Quarterly Report.pdf")
                Spacer(minLength: 4)
            }
        }
        .frame(width: 300)
        .padding(.vertical, 4)
        .background(Chrome.Colour.chrome)
    }

    static var status: some View {
        HStack(spacing: 8) {
            Label("Clean", systemImage: "pencil.and.list.clipboard")
            ChromeStatusSeparator()
            Text("128 words")
            Spacer(minLength: 12)
            ChromeSegmented(selection: .constant(EditorMode.preview),
                            options: EditorMode.platformCases.map {
                                .init(value: $0, systemImage: $0.symbol, label: $0.label)
                            })
                .fixedSize()
            ChromeStatusSeparator()
            ChromeStatusButton(help: "Find", systemImage: "magnifyingglass") {}
            ChromeStatusButton(help: "Properties", systemImage: "list.bullet.rectangle") {}
            ChromeStatusButton(help: "Links", systemImage: "link") {}
            ChromeStatusButton(help: "Outline", systemImage: "list.bullet.indent") {}
            ChromeStatusButton(help: "Mind map", systemImage: "brain") {}
        }
        .font(Chrome.Typeface.status)
        .foregroundStyle(Chrome.Colour.secondaryLabel)
        .padding(.horizontal, 10)
        .frame(width: 700, height: Chrome.Metric.statusRow)
        .padding(.vertical, 5)
        .background(Chrome.Colour.chrome)
        .overlay(alignment: .top) { Rectangle().fill(Chrome.Colour.separator).frame(height: 1) }
    }

    static var panelHeader: some View {
        SidePanelHeader(panel: .constant(.outline), hasNote: true, accent: accent, onClose: {})
            .frame(width: 380)
    }

    static var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Chrome.Colour.tertiaryLabel)
            Text("Select a Note")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Chrome.Colour.label)
            Text("Choose a note from the list, or create a new one.")
                .font(Chrome.Typeface.body)
                .foregroundStyle(Chrome.Colour.secondaryLabel)
        }
        .frame(width: 420, height: 160)
        .background(Chrome.Colour.content)
    }

    static var form: some View {
        VStack(alignment: .leading, spacing: 30) {
            ChromeSection("Appearance") {
                Toggle("Show word count", isOn: .constant(true))
                Toggle("Wrap lines", isOn: .constant(false))
                LabeledContent("Version", value: "1.3.3")
                HStack(spacing: 16) {
                    Text("Width")
                    ChromeSlider(value: .constant(0.4))
                }
                ChromeStepper(value: .constant(3), in: 1...8) { Text("Indent: 3") }
            } footer: {
                Text("A footer long enough to wrap onto a second line, which is where two platforms that round a line differently would part company.")
            }
            ChromeSection {
                HStack(spacing: 8) {
                    Button("Cancel") {}
                    Button("Save") {}.buttonStyle(ChromePushStyle(prominent: true))
                    Button("Remove", role: .destructive) {}
                    Button("Borderless") {}.buttonStyle(ChromeBorderlessStyle())
                    Button("Link") {}.buttonStyle(ChromeLinkStyle())
                }
                Toggle("Checkbox", isOn: .constant(true)).toggleStyle(ChromeCheckboxStyle())
                Toggle("Unchecked", isOn: .constant(false)).toggleStyle(ChromeCheckboxStyle())
            } header: {
                Text("Other")
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Chrome.Colour.content)
    }

    static var sheetBar: some View {
        VStack(spacing: 0) {
            ChromeSheetBar("New Note") {
                Button("Cancel") {}
            } trailing: {
                Button("Create") {}.buttonStyle(ChromePushStyle(prominent: true))
            }
            ChromeEmptyState("No Results", systemImage: "magnifyingglass",
                             description: Text("Nothing in this collection matches \u{201C}sourdough\u{201D}. Try another word, or search every collection.")) {
                Button("Search Everywhere") {}
            }
            .frame(height: 220)
            HStack(spacing: 12) {
                ChromeProgressBar(fraction: 0.4)
                ChromeSegmented(selection: .constant("edit"), options: [
                    .init(value: "edit", systemImage: "pencil", label: "Edit"),
                    .init(value: "preview", systemImage: "eye", label: "Preview"),
                ])
                .fixedSize()
                Label("Label style", systemImage: "folder")
            }
            .padding(12)
        }
        .frame(width: 520)
        .background(Chrome.Colour.content)
    }

    /// Every text style, and a wrapping paragraph at the sizes where a line
    /// rule is most likely to leave a fraction — the scene that would have
    /// caught `.multiple(factor: 16/13)`, which agreed at the 11 and 13pt the
    /// other scenes use and nowhere else.
    static var type: some View {
        let paragraph = "A paragraph long enough to wrap onto a third line in a column this narrow, which is where two platforms that round a line differently part company."
        return VStack(alignment: .leading, spacing: 10) {
            Text("Large Title").font(Chrome.Style.largeTitle)
            Text("Title").font(Chrome.Style.title)
            Text("Title 2").font(Chrome.Style.title2)
            Text("Title 3").font(Chrome.Style.title3)
            Text("Headline").font(Chrome.Style.headline)
            Text("Body").font(Chrome.Style.body)
            Text("Callout").font(Chrome.Style.callout)
            Text("Subheadline").font(Chrome.Style.subheadline)
            Text("Footnote, caption").font(Chrome.Style.footnote)
            ForEach([10, 12, 15, 17, 22] as [CGFloat], id: \.self) { size in
                Text(paragraph).font(.system(size: size))
            }
            HStack(spacing: 8) {
                Text("Beside a control")
                Button("Push") {}
                Toggle("Switch", isOn: .constant(true)).labelsHidden()
            }
        }
        .frame(width: 360, alignment: .leading)
        .padding(16)
        .background(Chrome.Colour.content)
    }

    // MARK: - Rendering

    @Test("Chrome renders to files for the cross-platform comparison")
    func renderChrome() throws {
        let scenes: [(String, AnyView)] = [
            ("bar", AnyView(Self.bar)),
            ("rows", AnyView(Self.rows)),
            ("status", AnyView(Self.status)),
            ("panelHeader", AnyView(Self.panelHeader)),
            ("emptyState", AnyView(Self.emptyState)),
            ("form", AnyView(Self.form)),
            ("sheetBar", AnyView(Self.sheetBar)),
            ("type", AnyView(Self.type)),
        ]
        // At the defaults, whatever Text Size the host app was left at: the
        // comparison is of drawing, not of two people's settings.
        ChromeTextScale.shared.update(app: .large, system: .large)
        let folder = Self.output
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for (name, view) in scenes {
            for scheme in [ColorScheme.light, .dark] {
                // The window root's defaults, as `ThemedRoot` applies them.
                let renderer = ImageRenderer(content: view
                    .chromeDefaults()
                    .tint(Self.accent)
                    .environment(\.colorScheme, scheme))
                renderer.scale = 2
                let image = try #require(renderer.cgImage, "\(name) did not render")
                let url = folder.appendingPathComponent("\(name)-\(scheme == .light ? "light" : "dark").png")
                try Self.writePNG(image, to: url)
                #expect(image.width > 0 && image.height > 0)
            }
        }
        print("CHROME_PARITY_OUTPUT=\(folder.path)")
    }

    /// **A line is its point size plus 3, in whole points, and three lines
    /// are three times one** — the rule `chromeDefaults()` sets, and the reason
    /// text lands on the same pixels on both platforms.
    ///
    /// Left to the platform, a line box is rounded its own way: the Mac to
    /// whole points and iOS to half — 11pt is 14.0 and 13.5, 17pt 20.0 and
    /// 20.5. A rule fixes that only if its result needs no rounding: the first
    /// one here, `.multiple(factor: 16/13)`, agreed only at the sizes where
    /// 16/13 lands on a whole point (measured: 10pt 13.0 against 12.5, 15pt
    /// 19.0 against 18.5, three 12pt lines 45.0 against 44.5). This holds each
    /// platform to exact arithmetic, so a change in either OS's line layout
    /// fails here on the platform that changed; `scripts/chrome-parity.sh`
    /// compares the two pictures.
    @Test("Every line is its size plus 3, in whole points")
    func everyLineIsItsSizePlusThree() {
        func height(_ text: some View) -> CGFloat {
            #if os(macOS)
            return NSHostingView(rootView: text).fittingSize.height
            #else
            return UIHostingController(rootView: text)
                .sizeThatFits(in: CGSize(width: 1000, height: 1000)).height
            #endif
        }
        for size: CGFloat in [10, 11, 12, 13, 15, 17, 22, 26] {
            let one = height(Text("Ag").font(.system(size: size)).lineHeight(Chrome.lineHeight))
            let three = height(Text("Ag\nAg\nAg").font(.system(size: size)).lineHeight(Chrome.lineHeight))
            #expect(one == size + 3, "\(size)pt: one line is \(one)pt, not \(size + 3)")
            #expect(three == 3 * (size + 3), "\(size)pt: three lines are \(three)pt, not \(3 * (size + 3))")
        }
    }

    /// **No stack is left to SwiftUI's default spacing.** A stack that names
    /// none gets a gap computed from each platform's rounding of the font's
    /// metrics, and the two disagree wherever text meets anything else —
    /// measured, text over a control: 7, 8, 8, 9, 10, 12pt on the Mac at 10–17pt
    /// against 6.5, 7, 7.5, 8.5, 9.5, 11 on iOS; a control over text, 5, 5, 5, 5,
    /// 6, 7 against 4, 4.5, 4.5, 5.5, 6, 7. No rounding of one gives the other,
    /// so the only parity is not to use it. (Horizontal defaults agree — 8pt
    /// for every pair measured — so this is about vertical stacks.) A scroll
    /// view with several views in it stacks them the same way, implicitly,
    /// which a source scan cannot see: the CSV viewer had the one there was,
    /// and it is an explicit stack now.
    @Test("Every vertical stack names its spacing")
    func everyVerticalStackNamesItsSpacing() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "HelloNotes")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        let stack = try Regex(#"\b(?:Lazy)?VStack\s*(\((?:[^()]|\([^()]*\))*\))?\s*\{"#)
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String($0) }
            let text = lines.joined(separator: "\n")
            for match in text.matches(of: stack) where !String(text[match.range]).contains("spacing") {
                let line = text[..<match.range.lowerBound].filter { $0 == "\n" }.count + 1
                offenders.append("\(file.lastPathComponent):\(line)")
            }
        }
        #expect(offenders.isEmpty, "stacks with the platform's default spacing: \(offenders.joined(separator: ", "))")
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
    }
}
