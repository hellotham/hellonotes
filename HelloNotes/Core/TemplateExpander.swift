//
//  TemplateExpander.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation

/// Expands template placeholders (`{{date}}`, `{{time}}`, `{{title}}`) in a
/// template's text (Core layer). Date/time use the given date so callers can
/// test deterministically.
nonisolated enum TemplateExpander {
    static func expand(_ text: String, title: String, date: Date, timeZone: TimeZone = .current) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = timeZone

        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: date)
        dateFormatter.dateFormat = "HH:mm"
        let timeString = dateFormatter.string(from: date)

        return text
            .replacingOccurrences(of: "{{date}}", with: dateString)
            .replacingOccurrences(of: "{{time}}", with: timeString)
            .replacingOccurrences(of: "{{title}}", with: title)
    }

    /// The `yyyy-MM-dd`-style filename (no extension) for a daily note.
    static func dailyNoteName(for date: Date, format: String, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format.isEmpty ? "yyyy-MM-dd" : format
        return formatter.string(from: date)
    }
}
