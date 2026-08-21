//
//  GlobalHotKey.swift
//  HelloNotes
//
//  A system-wide hotkey (Carbon RegisterEventHotKey — no special entitlement is
//  needed for a hotkey that activates our own app). Default ⌥⌘N summons quick
//  capture: brings HelloNotes forward and starts a fresh note ready to type.
//

#if os(macOS)
import AppKit
import Carbon.HIToolbox

final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onFire: () -> Void

    /// `keyCode` is a virtual key (e.g. `kVK_ANSI_N`); `modifiers` are Carbon
    /// flags (`cmdKey`, `optionKey`, …).
    init(keyCode: UInt32, modifiers: UInt32, onFire: @escaping () -> Void) {
        self.onFire = onFire
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().onFire()
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x484B4559 /* "HKEY" */), id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// ⌃⌥⌘N → activate the app and start a fresh note. Uses three modifiers so it
    /// doesn't shadow the app's own ⌥⌘N (File ▸ New Window) or a system shortcut.
    static func makeDefault() -> GlobalHotKey {
        GlobalHotKey(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey | cmdKey)) {
            NSApp.activate(ignoringOtherApps: true)
            Task { await NavigationRouter.shared?.createNote(collectionNamed: nil, title: nil) }
        }
    }
}

#else
/// iOS has no system-wide hot key: a background app cannot register one, and
/// the OS reserves the gesture space that would stand in for it. The nearest
/// equivalents — a Control Center control, a Home Screen widget, a Shortcuts
/// action — all *launch* the app rather than acting while another is frontmost,
/// so they are different features rather than this one's implementation.
///
/// A no-op that exists is better than a type that does not: the call site stays
/// one line on both platforms, and the reason is here rather than in a `#if`
/// wrapped around the caller.
@MainActor
final class GlobalHotKey {
    /// Deliberately empty. See the comment above.
    init() {}

    static func makeDefault() -> GlobalHotKey { GlobalHotKey() }
}
#endif
