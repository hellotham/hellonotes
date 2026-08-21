//
//  CSVTableView.swift
//  HelloNotes
//
//  Created by Chris Tham on 21/8/2026.
//
//  A spreadsheet, shown as a table.
//
//  Lifted out of `FileViewerView`, which is `#if os(macOS)` end to end. Nothing
//  in here was ever Mac-shaped — SwiftUI `Grid`, `FileIO.readString`, a string
//  parser — it was simply born inside a gated file and inherited the gate. iPad
//  therefore sent `.csv` to Quick Look with everything else, which renders a
//  spreadsheet as a wall of comma-separated text: the file opened, so nothing
//  looked broken, and the columns were just gone.
//
//  `CSVParser` moves with it rather than being left behind: a parser and its
//  only view on opposite sides of a platform gate is how the next port starts
//  by writing a second parser.
//

import SwiftUI

// MARK: - CSV / TSV

struct CSVTableView: View {
    let url: URL

    @State private var rows: [[String]] = []
    @State private var truncated = false
    @State private var error: String?

    private let rowCap = 2000

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Couldn't read this file", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if rows.isEmpty {
                ContentUnavailableView("Empty", systemImage: "tablecells")
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    Text(cell)
                                        .font(index == 0 ? .callout.bold() : .callout)
                                        .lineLimit(1)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .frame(minWidth: 60, maxWidth: 320, alignment: .leading)
                                }
                            }
                            .background(index == 0 ? Color.secondary.opacity(0.18)
                                        : (index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.06)))
                            Divider()
                        }
                    }
                    if truncated {
                        Text("… showing the first \(rowCap) rows")
                            .font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                }
            }
        }
        .task(id: url) { await load() }
    }

    /// Read and parse off the main actor. A coordinated read of a file that
    /// isn't local yet blocks for as long as its provider takes, and parsing a
    /// large CSV is not free either — neither belongs on the thread drawing the
    /// window.
    private func load() async {
        rows = []; truncated = false; error = nil
        let url = self.url
        let cap = rowCap
        let parsed = await offMain { () -> (rows: [[String]], truncated: Bool)? in
            guard let text = try? FileIO.readString(at: url) else { return nil }
            let delimiter: Character = url.pathExtension.lowercased() == "tsv" ? "\t" : ","
            var rows = CSVParser.parse(text, delimiter: delimiter)
            let truncated = rows.count > cap
            if truncated { rows = Array(rows.prefix(cap)) }
            return (rows, truncated)
        }
        guard let parsed else {
            error = "The file isn't valid UTF-8 text."
            return
        }
        rows = parsed.rows
        truncated = parsed.truncated
    }
}

/// Minimal RFC-4180-ish CSV parser: handles quoted fields, escaped quotes
/// (`""`), and embedded newlines/delimiters inside quotes.
///
/// `nonisolated` because it is called from inside `offMain` and the app target
/// is MainActor-by-default — without it, the parse of a large spreadsheet is
/// hopped back onto the main thread, which is the one place the doc comment on
/// `load()` says it must not run.
nonisolated enum CSVParser {
    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func nextChar() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let ch = nextChar() {
            if inQuotes {
                if ch == "\"" {
                    if let peek = iterator.next() {
                        if peek == "\"" { field.append("\"") }       // escaped quote
                        else { inQuotes = false; pending = peek }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case "\"": inQuotes = true
                case delimiter: record.append(field); field = ""
                case "\n":
                    record.append(field); field = ""
                    rows.append(record); record = []
                case "\r":
                    break  // handle CRLF: ignore CR; LF ends the row
                default: field.append(ch)
                }
            }
        }
        // Flush the final field/record if the file didn't end with a newline.
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            rows.append(record)
        }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}
