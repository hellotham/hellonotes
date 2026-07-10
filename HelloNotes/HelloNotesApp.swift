//
//  HelloNotesApp.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import SwiftUI

@main
struct HelloNotesApp: App {
    @State private var indexer = WorkspaceIndexer()

    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            MacContentView()
                .environment(indexer)
            #elseif os(iOS)
            Text("iOS coming soon")
                .environment(indexer)
            #endif
        }
    }
}
