//
//  PropertiesEditor.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import SwiftUI

/// An editable panel for a note's YAML front-matter properties. Booleans are
/// toggles, lists get add/remove rows, everything else is a text field. Any
/// commit calls `onChange`, which the editor uses to splice the properties back
/// into the note.
struct PropertiesEditor: View {
    @Binding var properties: [Property]
    var onChange: () -> Void

    @State private var newKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PROPERTIES")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach($properties) { $property in
                HStack(alignment: .top, spacing: 8) {
                    Text(property.key)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .leading)
                    valueEditor($property)
                    Button {
                        remove($property.wrappedValue)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                TextField("Add property…", text: $newKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(addProperty)
                Button("Add", action: addProperty)
                    .disabled(trimmedNewKey.isEmpty)
            }
            .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3))
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
            Spacer(minLength: 0)

        case .list:
            listEditor(property)

        case .text, .number, .date:
            TextField("", text: Binding(
                get: { property.wrappedValue.text },
                set: { property.wrappedValue.text = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .onSubmit(onChange)
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
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onChange)
                    Button {
                        guard index < property.wrappedValue.items.count else { return }
                        property.wrappedValue.items.remove(at: index)
                        onChange()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            Button {
                property.wrappedValue.items.append("")
                onChange()
            } label: {
                Label("Add item", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .font(.caption)
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
#endif
