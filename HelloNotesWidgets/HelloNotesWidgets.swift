//
//  HelloNotesWidgets.swift
//  HelloNotesWidgets
//
//  Recent-notes widget. Reads the App Group snapshot the app writes on each
//  note change; each row deep-links to its note via the `hellonotes://` scheme.
//

import WidgetKit
import SwiftUI

struct RecentsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> RecentsEntry {
        RecentsEntry(date: .now, snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentsEntry) -> Void) {
        completion(RecentsEntry(date: .now, snapshot: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentsEntry>) -> Void) {
        // The app calls WidgetCenter.reloadAllTimelines() on change, so the
        // hourly refresh is only a safety net.
        let entry = RecentsEntry(date: .now, snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3600))))
    }
}

struct HelloNotesWidgetsEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: Provider.Entry

    private var rowCount: Int {
        switch family {
        case .systemSmall: 3
        case .systemMedium: 4
        default: 8
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 6) {
            Label("Recent Notes", systemImage: "note.text")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if entry.snapshot.recents.isEmpty {
                Spacer()
                Text("Open a collection in HelloNotes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(entry.snapshot.recents.prefix(rowCount)) { item in
                    Link(destination: item.deepLink) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text").font(.caption2).foregroundStyle(.tint)
                            Text(item.title).font(.footnote).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct HelloNotesWidgets: Widget {
    let kind = "HelloNotesRecents"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            HelloNotesWidgetsEntryView(entry: entry)
        }
        .configurationDisplayName("Recent Notes")
        .description("Your most recently edited HelloNotes notes.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
