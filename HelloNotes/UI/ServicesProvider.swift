//
//  ServicesProvider.swift
//  HelloNotes
//
//  Backs the "New HelloNotes Note from Selection" Services-menu item (declared
//  in Info.plist under NSServices). System-wide capture on the Mac: select text
//  in any app → Services → new note. Registered as `NSApp.servicesProvider`.
//

#if os(macOS)
import AppKit

final class ServicesProvider: NSObject {
    /// `NSMessage` = "newNoteFromSelection" in the Info.plist NSServices entry.
    @objc func newNoteFromSelection(_ pboard: NSPasteboard,
                                    userData: String?,
                                    error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let text = pboard.string(forType: .string) ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error?.pointee = "No text was selected." as NSString
            return
        }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            guard let router = NavigationRouter.shared,
                  await router.captureNote(text: text) else { return }
        }
    }
}

#else
/// iOS has no Services menu. The equivalent — offering "New Note from
/// Selection" to other apps — is a Share or Action extension, which is a
/// separate target with its own bundle and lifecycle, not an implementation of
/// this type.
///
/// A no-op that exists is better than a type that does not: `TerminationGuard`
/// installs it on both platforms and only one of them has anywhere to put it.
@MainActor
final class ServicesProvider {
    /// Deliberately empty. See the comment above.
    init() {}
}
#endif
