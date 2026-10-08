//
//  InspectorOverlay.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  The right panel, where the shell has no column to put it in.
//
//  `AdaptiveShell` gave the inspector a column only at `.wideInspector`
//  (1400pt) or in a tall shell at 900pt, and nothing below that — on both
//  platforms. The iPad shell added an overlay for the rest; the Mac's did not.
//
//  **So the Mac's own default window had no inspector at all.** It opens at
//  1100×720, which `shellKind` calls `.wide`: no column. The five toolbar
//  toggles were there, they set `inspectorPresented`, and nothing appeared.
//  Outline, Tags, References, Properties and History were unreachable at the
//  size the app itself chooses to open at, on the platform where they were
//  written — while an iPad the same size showed them.
//
//  A column fits almost everywhere now (`ShellMetrics.hasPanelColumn`), so
//  this is what a canvas too small for one falls back to — the phone above
//  all. It follows `presented` and nothing else. A session-scoped "opened by
//  hand" gate once kept a stored `true` from covering a window at launch, and
//  made the toggle say on with nothing shown; the default is `false` instead
//  (`ShellComplianceTests.inspectorDefaultIsOffAndTheOverlayHasNoHiddenGate`).
//  Following `presented` asks one thing of the shell: something to draw on in
//  every state. `ContentView` puts one over the whole detail, and one over the
//  compact shell's places for when no note is up — without that, the phone's
//  Graph View and AI buttons set the panel showing and nothing drew it.
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
                            // The panel's own colour, as its column draws it —
                            // not a material, which is the platform's blur.
                            .background(Chrome.Colour.chrome)
                            // Said: a rule outside a stack has no axis to
                            // infer, and a horizontal one crossed the panel.
                            .overlay(alignment: .leading) { ChromeDivider(.vertical) }
                            .transition(.move(edge: .trailing))
                    }
                }
            }
    }

    private func close() {
        withAnimation(.easeInOut(duration: 0.2)) { presented = false }
    }
}
