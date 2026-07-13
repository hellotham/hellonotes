//
//  CLAUDE.md
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

# HelloNotes Architecture Rules
- Target Environment: macOS 15+ / Swift 5.10+ / Xcode 26
- Multiplatform: Build platform-specific navigation shells (`NavigationSplitView` for Mac, `NavigationStack` for iOS).
- State: Use the `@Observable` macro exclusively. DO NOT use legacy `@ObservableObject` or `@StateObject`.
- Data Source: No CoreData. The local file system directory is the absolute source of truth.
- Git Operations: Use `SwiftGitX` (Import `SwiftGitX`) utilizing native Swift async/await concurrency.
- Build Verification: After writing code, use the Xcode MCP tool to run a compilation check to ensure 0 errors.
