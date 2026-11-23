//
//  CloudPrefsTests.swift
//  HelloNotesTests
//
//  The settings that follow the person between devices through iCloud's
//  key-value store — what the person set, and never what a launch was handed.
//  `push()` read `object(forKey:)`, which answers from the launch's arguments
//  first, so a capture session's `-textScale 1` went to iCloud as the person's
//  text size and the next launch pulled it into their own settings
//  (2026-11-22). A launch argument is a string, which is how the store tells
//  one from a setting.
//
//  These hold the rule and not the store: a hosted test that pushed would push
//  to the person's own iCloud.
//

import Foundation
import Testing
@testable import HelloNotes

@Suite struct CloudPrefsTests {

    @Test func aLaunchArgumentIsNotASetting() {
        // What `-textScale 1`, `-increaseContrast NO`, `-showInlineTitle NO`
        // and `-wrapGuide 80` arrive as.
        #expect(!CloudPrefs.isSetting("1", for: "textScale"))
        #expect(!CloudPrefs.isSetting("NO", for: "increaseContrast"))
        #expect(!CloudPrefs.isSetting("NO", for: "showInlineTitle"))
        #expect(!CloudPrefs.isSetting("80", for: "wrapGuide"))
        // What the app writes for them.
        #expect(CloudPrefs.isSetting(1.15, for: "textScale"))
        #expect(CloudPrefs.isSetting(NSNumber(value: false), for: "increaseContrast"))
        #expect(CloudPrefs.isSetting(true, for: "showInlineTitle"))
        #expect(CloudPrefs.isSetting(80, for: "wrapGuide"))
        // And a string where the app writes one.
        #expect(CloudPrefs.isSetting("light", for: "appearanceMode"))
        #expect(CloudPrefs.isSetting("assets", for: "attachmentFolder"))
        #expect(!CloudPrefs.isSetting(1, for: "appearanceMode"))
    }

    @Test func onlySettingsArePushed() {
        let own: [String: Any] = ["textScale": "1", "increaseContrast": false,
                                  "appearanceMode": "dark", "unsynced": 3]
        let pushed = CloudPrefs.pushable(own, keys: ["textScale", "increaseContrast",
                                                     "appearanceMode", "accentChoice"])
        #expect(Set(pushed.keys) == ["increaseContrast", "appearanceMode"])
    }
}
