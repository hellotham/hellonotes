//
//  LabeledField.swift
//  HelloNotes
//
//  Created by Chris Tham on 27/8/2026.
//
//  A text field whose name is visible on **both** platforms.
//
//  `TextField("Date format", text: $x, prompt: Text("yyyy-MM-dd"))` reads
//  correctly on the Mac, where the title is drawn to the left of the field. On
//  iOS a `TextField`'s title is only ever shown *as the placeholder*, and a
//  supplied `prompt:` replaces the placeholder — so the title is drawn nowhere
//  at all. Ten fields shipped that way: iOS Settings showed a "Daily notes"
//  section containing two anonymous boxes reading "Collection root" and
//  "yyyy-MM-dd", and a Git section whose two fields were distinguishable only
//  by guessing that "Ada Lovelace" meant name and "ada@example.com" meant email.
//
//  The rule this encodes: **a field must be identifiable without typing in it.**
//  A prompt that names the field ("Filter repositories") does that on its own
//  and needs no label; a prompt that shows an example does not.
//

import SwiftUI

struct LabeledField: View {
    let label: String
    @Binding var text: String
    /// The example or hint shown while the field is empty.
    var prompt: String
    /// Paths and format strings are not prose: no autocorrect, no
    /// autocapitalisation.
    var isPath = false

    var body: some View {
        LabeledContent(label) {
            field
        }
    }

    @ViewBuilder
    private var field: some View {
        let base = TextField("", text: $text, prompt: Text(prompt))
            .multilineTextAlignment(.trailing)
        if isPath {
            base.pathStyled()
        } else {
            base
        }
    }
}

private extension View {
    /// A field holding a path fragment, a host or a format string — not prose:
    /// no autocorrection and no capitalisation. Only iOS has either, so only
    /// iOS has anything to turn off; the *intent* belongs to the field, which
    /// is why it is spelled once here rather than at each call site.
    @ViewBuilder
    func pathStyled() -> some View {
        #if os(iOS)
        self.autocorrectionDisabled().textInputAutocapitalization(.never)
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
