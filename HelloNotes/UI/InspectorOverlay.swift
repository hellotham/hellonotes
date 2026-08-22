//
//  InspectorOverlay.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  The inspector, where the shell has no column to put it in.
//
//  `AdaptiveShell` gives the inspector a column at `.wideInspector` (1400pt) or
//  in a tall shell at 900pt, and nothing below that — on both platforms. The
//  iPad shell added an overlay for the rest; the Mac's did not.
//
//  **So the Mac's own default window had no inspector at all.** It opens at
//  1100×720, which `shellKind` calls `.wide`: no column. The five toolbar
//  toggles were there, they set `inspectorPresented`, and nothing appeared.
//  Outline, Tags, References, Properties and History were unreachable at the
//  size the app itself chooses to open at, on the platform where they were
//  written — while an iPad the same size showed them.
//
//  The overlay does not appear on its own. `inspectorPresented` is a stored
//  scene preference and defaults to shown, which is right for a *column*; as an
//  overlay it is modal over the note, and a window that opens with its content
//  covered is a window that opens broken. So the overlay additionally requires
//  that the inspector was opened while there was no column — an intent from
//  this session, not a preference from the last one.
//

import SwiftUI

extension View {
    /// Show `inspector` over this view when the shell has no inspector column.
    func inspectorOverlay<Inspector: View>(
        presented: Binding<Bool>,
        @ViewBuilder inspector: @escaping () -> Inspector
    ) -> some View {
        modifier(InspectorOverlay(presented: presented, inspector: inspector))
    }
}

struct InspectorOverlay<Inspector: View>: ViewModifier {
    @Binding var presented: Bool
    @ViewBuilder let inspector: () -> Inspector

    @Environment(\.shell) private var shell

    /// Whether the shell is already drawing an inspector *column*, in which
    /// case there is nothing for this overlay to do.
    ///
    /// Two shells draw one: `.wideInspector` always, and `.tall` once it is
    /// also wide enough for its right rail (`AdaptiveShell.tallShell`). This
    /// asked only about `.wideInspector`, so on anything tall and ≥900pt — an
    /// iPad Pro 13" in portrait, a 1000×1200 Mac window — this presented the
    /// modal panel *over* the column that was already there: the inspector
    /// twice, the second copy behind a scrim, with the note dimmed underneath.
    private var hasColumn: Bool {
        switch shell.kind {
        case .wideInspector: return true
        case .tall: return shell.size.width >= ShellMetrics.tallRailMin
        default: return false
        }
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if !hasColumn, presented {
                    ZStack(alignment: .trailing) {
                        // Tap anywhere on the note to dismiss — the panel is
                        // modal over the note, so there is no reason to hunt
                        // for the close button.
                        Color.black.opacity(0.12)
                            .ignoresSafeArea()
                            .onTapGesture { close() }
                        inspector()
                            .frame(width: 360)
                            .background(.regularMaterial)
                            .overlay(alignment: .leading) { Divider() }
                            .transition(.move(edge: .trailing))
                    }
                }
            }
    }

    private func close() {
        withAnimation(.easeInOut(duration: 0.2)) { presented = false }
    }
}

/// The inspector's own title bar: which tab, and a way to close it.
///
/// Drawn by the overlay's content on both platforms — a column gets its header
/// from the shell's chrome, an overlay has none of its own.
struct InspectorOverlayHeader: View {
    @Binding var tabRaw: String
    let onClose: () -> Void

    private var tab: InspectorTab { InspectorTab(rawValue: tabRaw) ?? .outline }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tab.title).font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Inspector")
            }
            HStack(spacing: 0) {
                ForEach(InspectorTab.allCases) { candidate in
                    Button {
                        tabRaw = candidate.rawValue
                    } label: {
                        Image(systemName: candidate.systemImage)
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(candidate == tab ? Color.accentColor : .secondary)
                    .background(
                        candidate == tab ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .accessibilityLabel(candidate.title)
                    .accessibilityAddTraits(candidate == tab ? [.isSelected] : [])
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}
