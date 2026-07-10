//
//  ContentView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import SwiftUI

struct ContentView: View {
    @Binding var document: HelloNotesDocument

    var body: some View {
        TextEditor(text: $document.text)
    }
}

#Preview {
    ContentView(document: .constant(HelloNotesDocument()))
}
