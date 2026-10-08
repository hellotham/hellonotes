//
//  PropertiesEditor.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import SwiftUI

/// The Properties panel's rows: a draft of a note's front matter.
///
/// Typing in a field changes the draft, and a commit — Return, leaving the
/// field, a toggle, a property added or removed — writes it into the note. The
/// inspector bound the rows straight to the note, so every character typed in
/// a field rewrote the front matter and, in Edit, replaced the whole note on
/// screen and cleared its undo (implemented.md §51.15).
struct PropertyDraft: Equatable {
    /// What the fields show and edit.
    var rows: [Property] = []
    /// The note's properties when the rows were last taken from it.
    private(set) var taken: [Property] = []
    /// Whose note the rows are, at which version of its text.
    private(set) var source: EditorModel.TextVersion?

    /// An edit to one note, to be written into it.
    struct Commit: Equatable {
        let rows: [Property]
        let note: EditorModel.TextVersion
    }

    /// Whether the rows hold what the note does not.
    var isEdited: Bool { rows != taken }

    /// The rows, for the note they belong to.
    var commit: Commit? { source.map { Commit(rows: rows, note: $0) } }

    /// Follow the note, which is at `version` now and whose front matter says
    /// `properties`:
    ///
    /// - **the same note, its front matter as the rows were taken from it** —
    ///   what moved was the body, so what is being typed stays;
    /// - **another note** — a tab switch — the rows are that note's now, and an
    ///   edit still pending for the one left is handed back, to be written into
    ///   *it*, neither lost nor written into this one;
    /// - **the same note, its front matter changed** — a commit landing, a
    ///   reload, a tag accepted — the rows are what the note says.
    mutating func follow(_ version: EditorModel.TextVersion?, properties: [Property]) -> Commit? {
        let sameNote = source?.editor == version?.editor
        let pending = sameNote || !isEdited ? nil : commit
        source = version
        if sameNote && properties == taken { return nil }
        rows = properties
        taken = properties
        return pending
    }
}

/// An editable panel for a note's YAML front-matter properties. Booleans are
/// toggles, lists get add/remove rows, everything else is a text field. Any
/// commit calls `onChange`, which the editor uses to splice the properties back
/// into the note — and typing is not a commit: Return is, and so is leaving the
/// field.
struct PropertiesEditor: View {
    @Binding var properties: [Property]
    var onChange: () -> Void

    @State private var newKey = ""
    /// The field being typed in. Leaving it commits: a value typed and then
    /// left — a tap back into the note — would otherwise never be written.
    @FocusState private var focused: Field?

    private enum Field: Hashable {
        case value(Property.ID)
        case item(Property.ID, Int)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Properties")
                .font(Chrome.Style.caption)
                .foregroundStyle(Chrome.Colour.secondaryLabel)

            ForEach(properties) { property in
                HStack(alignment: .top, spacing: 8) {
                    Text(property.key)
                        .font(Chrome.Style.caption.weight(.semibold))
                        .foregroundStyle(Chrome.Colour.secondaryLabel)
                        .frame(width: 96, alignment: .leading)
                    valueEditor(row(property.id))
                    Button {
                        remove(property)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(ChromeBorderlessStyle())
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                }
            }

            HStack(spacing: 8) {
                TextField("", text: $newKey)
                    .textFieldStyle(.plain)
                    .focusEffectDisabled()
                    .onSubmit(addProperty)
                    .chromePlaceholder("Add property…", showing: newKey.isEmpty)
                    .accessibilityLabel("New property name")
                    .chromeFieldBox()
                    .frame(width: 180)
                Button("Add", action: addProperty)
                    .disabled(trimmedNewKey.isEmpty)
            }
            .font(Chrome.Style.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Chrome.Colour.quaternaryLabel.opacity(0.3))
        .onChange(of: focused) { left, _ in
            if left != nil { onChange() }
        }
        // Closing the panel, or the popover, with a field still being typed in
        // is leaving it too. Only then: every other edit was committed when it
        // was made, and rows written back unedited could put a popover's copy,
        // taken when it opened, over a change made since.
        .onDisappear { if focused != nil { onChange() } }
    }

    /// The row with `id`, read and written by its identity — never by its
    /// place. A field hands its text back as it stops being edited, and that
    /// can come after the rows have changed under it: switching notes with a
    /// field still being typed in trapped on `ForEach($properties)`'s bindings,
    /// which read the row at the index it had. A row that is gone reads as
    /// empty and takes nothing.
    private func row(_ id: Property.ID) -> Binding<Property> {
        Binding(
            get: {
                properties.first { $0.id == id }
                    ?? Property(key: "", kind: .text, text: "", bool: false, items: [], id: id)
            },
            set: { row in
                guard let index = properties.firstIndex(where: { $0.id == id }) else { return }
                properties[index] = row
            }
        )
    }

    @ViewBuilder
    private func valueEditor(_ property: Binding<Property>) -> some View {
        switch property.wrappedValue.kind {
        case .checkbox:
            Toggle("", isOn: Binding(
                get: { property.wrappedValue.bool },
                set: { property.wrappedValue.bool = $0; onChange() }
            ))
            .labelsHidden()
            .accessibilityLabel(property.wrappedValue.key)
            Spacer(minLength: 0)

        case .list:
            listEditor(property)

        case .text, .number, .date:
            TextField("", text: Binding(
                get: { property.wrappedValue.text },
                set: { property.wrappedValue.text = $0 }
            ))
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .focused($focused, equals: .value(property.wrappedValue.id))
            .onSubmit(onChange)
            .accessibilityLabel(property.wrappedValue.key)
            .chromeFieldBox()
        }
    }

    private func listEditor(_ property: Binding<Property>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(property.wrappedValue.items.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 4) {
                    // Bounds-guard the index: removing a non-last item leaves
                    // surviving rows whose captured `index` is momentarily stale,
                    // and SwiftUI can evaluate their `get` before re-diffing — an
                    // unguarded `items[index]` would trap with Index out of range.
                    TextField("", text: Binding(
                        get: { index < property.wrappedValue.items.count ? property.wrappedValue.items[index] : "" },
                        set: { if index < property.wrappedValue.items.count { property.wrappedValue.items[index] = $0 } }
                    ))
                    .textFieldStyle(.plain)
                    .focusEffectDisabled()
                    .focused($focused, equals: .item(property.wrappedValue.id, index))
                    .onSubmit(onChange)
                    .accessibilityLabel("\(property.wrappedValue.key) item \(index + 1)")
                    .chromeFieldBox()
                    Button {
                        guard index < property.wrappedValue.items.count else { return }
                        property.wrappedValue.items.remove(at: index)
                        onChange()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(ChromeBorderlessStyle())
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                }
            }
            Button {
                // Not a commit. Written at once, an empty item became `- ""`,
                // which parses back as no item — so in the inspector the row
                // vanished before anything could be typed in it. The new
                // field takes the typing, and is written when it is left.
                property.wrappedValue.items.append("")
                focused = .item(property.wrappedValue.id, property.wrappedValue.items.count - 1)
            } label: {
                Label("Add item", systemImage: "plus")
            }
            .buttonStyle(ChromeBorderlessStyle())
            .font(Chrome.Style.caption)
        }
    }

    private var trimmedNewKey: String {
        newKey.trimmingCharacters(in: .whitespaces)
    }

    private func addProperty() {
        let key = trimmedNewKey
        guard !key.isEmpty, !properties.contains(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) else { return }
        properties.append(Property(key: key, kind: .text, text: "", bool: false, items: []))
        newKey = ""
        onChange()
    }

    private func remove(_ property: Property) {
        properties.removeAll { $0.id == property.id }
        onChange()
    }
}
