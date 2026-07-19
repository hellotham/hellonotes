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
#endif
