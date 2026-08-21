//
//  AppearanceSettingsView.swift
//  HelloNotes
//
//  Created by Chris Tham on 13/7/2026.
//

import SwiftUI

/// The "Appearance" preferences tab: light / dark / auto, an accent colour
/// (macOS-style swatches plus a custom colour), and a text-size slider.
struct AppearanceSettingsView: View {
    @Bindable var settings: AppearanceSettings

    // The controls live in `AppearanceSettingsSections`, shared with
    // `iOSSettingsView`. This screen and the iPad's drew the same four groups
    // over the same object, which is how Reading width, Editor width and Wrap
    // guide came to exist here and not there — and how they were "fixed",
    // earlier in this audit, by adding a second copy of each control rather
    // than by removing the reason a second copy was needed.
    var body: some View {
        Form {
            AppearanceSettingsSections(settings: settings, accentLayout: .row)
        }
        .formStyle(.grouped)
    }
}
