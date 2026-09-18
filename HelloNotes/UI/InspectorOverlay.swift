//
//  InspectorOverlay.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  The right panel, where the shell has no column to put it in.
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
    /// Show `panel` over this view when the shell has no column for it.
    func sidePanelOverlay<Panel: View>(
        presented: Binding<Bool>,
        @ViewBuilder panel: @escaping () -> Panel
    ) -> some View {
        modifier(InspectorOverlay(presented: presented, inspector: panel))
    }
}

struct InspectorOverlay<Inspector: View>: ViewModifier {
    @Binding var presented: Bool
    @ViewBuilder let inspector: () -> Inspector

    @Environment(\.shell) private var shell

    /// Whether the shell is already drawing the panel as a *column*, in which
    /// case there is nothing for this overlay to do — and it must not draw, or
    /// the panel appears twice with the note dimmed behind the second copy.
    ///
    /// One question, asked in one place: `ShellMetrics.hasPanelColumn`.
    /// It answers yes almost everywhere now, so this overlay is what a canvas
    /// too small for a column falls back to — where the editor has no room to
    /// be typed in beside a panel anyway.
    private var hasColumn: Bool {
        ShellMetrics.hasPanelColumn(kind: shell.kind, width: shell.size.width)
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
                            .frame(width: ShellMetrics.panelIdeal)
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
