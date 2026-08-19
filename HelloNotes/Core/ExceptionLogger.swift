//
//  ExceptionLogger.swift
//  HelloNotes
//
//  Created by Chris Tham on 18/8/2026.
//
//  Name the frame that threw.
//
//  A device crash reaches the console as bare addresses:
//
//      *** Terminating app due to uncaught exception 'NSRangeException' …
//      (0x18fd8e23c 0x18c85d224 0x19b63a888 …)
//
//  Those are dyld-shared-cache addresses; without the device's cache they
//  cannot be symbolicated from here, and guessing which system API is reading
//  our text storage is how two suspects were eliminated and neither was the
//  cause. `NSException.callStackSymbols` is already symbolicated, so the app
//  can simply say what threw — the same lesson as the main-actor watchdog:
//  build the instrument rather than reason about the crash.
//

import Foundation

enum ExceptionLogger {

    /// Install a handler that prints the symbolicated stack of any uncaught
    /// exception. Debug builds only — a shipping app must not rely on this.
    static func install() {
        #if DEBUG
        NSSetUncaughtExceptionHandler { exception in
            let lines = [
                "",
                "════════ UNCAUGHT \(exception.name.rawValue) ════════",
                exception.reason ?? "(no reason)",
                "──────── symbolicated stack ────────",
            ] + exception.callStackSymbols
            let text = lines.joined(separator: "\n")
            // Both, deliberately: the console is what `devicectl --console`
            // shows, and the file survives the process dying mid-write.
            print(text)
            fflush(stdout)
            if let url = try? FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("hn-exception.log") {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        #endif
    }
}
