//
//  AppearanceSettingsSections.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  Theme, accent, text size and text width — written once, for Settings on
//  both platforms.
//
//  They were written twice: `AppearanceSettingsView` (a Preferences tab) and a
//  stretch of `iOSSettingsView`, drawing the same four groups over the same
//  `AppearanceSettings`. Duplicated settings screens are how a setting quietly
//  stops existing on one platform, and this pair had already lost three —
//  Reading width, Editor width and Wrap guide were on the Mac's screen and not
//  on the iPad's, and were fixed earlier in this audit by adding a second copy
//  of each control rather than by removing the reason a second copy was needed.
//
//  This is that reason removed — and, with Settings now one container drawn
//  the same on both platforms, so is the last difference that was left. The
//  accent swatches were a line on the Mac and an adaptive grid on the iPad,
//  because the iPad's settings sheet was narrower and its targets 44pt. The
//  page is the same width on both now, and each 22pt swatch answers a 44pt
//  target, so the line serves both.
//

import SwiftUI

/// The Appearance / Accent / Text size / Text width sections, for a
/// `ChromeForm` — Settings' Appearance page (`AppearanceSettingsView`).
struct AppearanceSettingsSections: View {
    @Bindable var settings: AppearanceSettings

    private let swatchAccents: [AppearanceSettings.Accent] =
        [.multicolor, .lavender, .blue, .purple, .pink, .red, .orange, .yellow, .green, .graphite]

    var body: some View {
        ChromeSection("Appearance") {
            HStack(spacing: 8) {
                Text("Theme")
                Spacer(minLength: 8)
                ChromeSegmented(selection: $settings.mode,
                                options: AppearanceSettings.Mode.allCases.map {
                                    .init(value: $0, systemImage: $0.symbol, label: $0.label)
                                },
                                showsTitles: true)
                    .fixedSize()
            }
            caption("“Auto” follows the system light/dark setting.")

            Toggle("Increase contrast", isOn: $settings.increaseContrast)
            caption("Deepens the accent color and makes colored text easier to read.")
        }

        ChromeSection("Accent color") {
            HStack(spacing: 10) {
                ForEach(swatchAccents) { swatch($0) }
                customSwatch
            }
            .padding(.vertical, 2)
        }

        ChromeSection("Text size") {
            HStack(spacing: 12) {
                Text("A").font(Chrome.Style.footnote).foregroundStyle(Chrome.Colour.secondaryLabel)
                ChromeSlider(value: $settings.textScale,
                             in: AppearanceSettings.minScale...AppearanceSettings.maxScale)
                Text("A").font(Chrome.Style.title2).foregroundStyle(Chrome.Colour.secondaryLabel)
                Button("Reset") { settings.textScale = 1.0 }
                    .buttonStyle(ChromeBorderlessStyle())
                    .font(Chrome.Style.caption)
                    .disabled(abs(settings.textScale - 1.0) < 0.001)
            }
            // A live specimen, so the slider shows what it is doing rather than
            // asking you to close settings and look.
            Text("The quick brown fox jumps over the lazy dog.")
                .font(Chrome.Style.body)
                .scaleEffect(settings.textScale, anchor: .leading)
                .frame(height: 22 * settings.textScale, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.default, value: settings.textScale)
            caption("Scales the note editor and preview.")
        }

        // Reading and editing want different widths, so they get different
        // settings (docs/layout-architecture.md, decision 5).
        ChromeSection("Text width") {
            ChromePopUp("Reading width", selection: $settings.readingWidth,
                        options: ReadingWidth.allCases.map { ChromeOption(value: $0, title: $0.label) })
            caption("How wide a line gets in Reading mode. A comfortable measure is about 80 characters; the column is centred in the pane.")

            ChromePopUp("Editor width", selection: $settings.editorWidth,
                        options: EditorWidth.allCases.map { ChromeOption(value: $0, title: $0.label) })
            caption("How much of the pane you write in. Full uses the whole pane, left-aligned — tables and diagrams need the room.")

            ChromePopUp("Wrap guide", selection: $settings.wrapGuide,
                        options: AppearanceSettings.wrapGuideChoices.map { columns in
                            ChromeOption(value: columns, title: columns == 0 ? "Off" : "\(columns) characters")
                        })
            caption("A line you can see while editing, not a wrap point — text still runs to the edge of the pane.")

            ChromePopUp("Sort notes by", selection: $settings.noteSortOrder,
                        options: SortOrder.allCases.map { order in
                            ChromeOption(value: order, title: order.rawValue, systemImage: order.systemImage)
                        })
            caption("How notes are ordered inside each folder of the sidebar. Folders always come first, sorted by name.")

            Toggle("Show note title", isOn: $settings.showInlineTitle)
            caption("Shows the file's name above the note as a heading. Editing it renames the file and updates every link to it.")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(Chrome.Style.caption).foregroundStyle(Chrome.Colour.secondaryLabel)
    }

    private func swatch(_ accent: AppearanceSettings.Accent) -> some View {
        Button {
            settings.accent = accent
        } label: {
            Circle()
                .fill(accent.swatch)
                .frame(width: 22, height: 22)
                .overlay(
                    Circle()
                        .strokeBorder(Chrome.Colour.label.opacity(settings.accent == accent ? 0.9 : 0), lineWidth: 2)
                        .padding(-3)
                )
                .overlay {
                    if accent == .multicolor {
                        Image(systemName: "circle.hexagongrid.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                // The finger's target, not the drawing's: 44pt around 22, so
                // the one line serves a touch-only iPad as well as a pointer.
                .contentShape(.rect.inset(by: -(Chrome.Metric.touchTarget - 22) / 2))
        }
        .buttonStyle(ChromePlainStyle())
        .help(accent.label)
        .accessibilityLabel("\(accent.label) accent")
        .accessibilityAddTraits(settings.accent == accent ? [.isButton, .isSelected] : .isButton)
    }

    /// Any colour at all, from the OS's colour panel — a well drawn by the app,
    /// ringed like a swatch when it is the accent in use.
    private var customSwatch: some View {
        ChromeColorWell("Custom color", selection: $settings.customAccent)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Chrome.Colour.label.opacity(settings.accent == .custom ? 0.9 : 0), lineWidth: 2)
                    .padding(-3)
                    .allowsHitTesting(false)
            )
            .onChange(of: settings.customAccent) { _, _ in settings.accent = .custom }
            .help("Custom color")
    }
}
