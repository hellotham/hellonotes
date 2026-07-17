//
//  AcknowledgementsView.swift
//  HelloNotes
//
//  Third-party open-source acknowledgements. Several bundled Swift packages
//  carry attribution requirements (MIT/BSD/Apache; libgit2 is GPLv2 with the
//  linking exception), so we surface them in-app. Keep this list in sync with
//  the package dependencies in the Xcode project / Package.resolved.
//

import SwiftUI

/// One acknowledged open-source dependency.
struct Acknowledgement: Identifiable {
    var id: String { name }
    let name: String
    let license: String
    let url: String
    let role: String
}

enum Acknowledgements {
    /// The third-party packages HelloNotes links, with their licenses. Ordered
    /// roughly by prominence in the app.
    static let all: [Acknowledgement] = [
        .init(name: "swift-cmark (cmark-gfm)", license: "BSD-2-Clause / MIT", url: "https://github.com/apple/swift-cmark", role: "GitHub-Flavored-Markdown rendering & spec parity"),
        .init(name: "swift-markdown", license: "Apache-2.0", url: "https://github.com/swiftlang/swift-markdown", role: "Markdown AST (headings, export, Marp)"),
        .init(name: "SwiftGitX", license: "MIT", url: "https://github.com/ibrahimcetin/SwiftGitX", role: "Async/await Git engine"),
        .init(name: "libgit2", license: "GPL-2.0 WITH linking exception", url: "https://github.com/libgit2/libgit2", role: "Git implementation (via SwiftGitX)"),
        .init(name: "HighlighterSwift", license: "MIT", url: "https://github.com/smittytone/HighlighterSwift", role: "Code-block syntax highlighting"),
        .init(name: "SwiftMath", license: "MIT", url: "https://github.com/mgriebling/SwiftMath", role: "LaTeX math rendering"),
        .init(name: "beautiful-mermaid-swift", license: "MIT", url: "https://github.com/lukilabs/beautiful-mermaid-swift", role: "Mermaid diagram rendering"),
        .init(name: "elk-swift", license: "MIT", url: "https://github.com/lukilabs/elk-swift", role: "ELK graph/diagram layout"),
        .init(name: "MLX Swift", license: "MIT", url: "https://github.com/ml-explore/mlx-swift", role: "On-device LLM inference (Apple silicon)"),
        .init(name: "swift-transformers", license: "Apache-2.0", url: "https://github.com/huggingface/swift-transformers", role: "Tokenizers & model downloads (MLX)"),
        .init(name: "OpenAI (MacPaw)", license: "MIT", url: "https://github.com/MacPaw/OpenAI", role: "OpenAI-compatible provider transport"),
        .init(name: "GzipSwift", license: "MIT", url: "https://github.com/1024jp/GzipSwift", role: "Compression (transitive)"),
        .init(name: "swift-collections", license: "Apache-2.0", url: "https://github.com/apple/swift-collections", role: "Data structures (transitive)"),
        .init(name: "swift-numerics", license: "Apache-2.0", url: "https://github.com/apple/swift-numerics", role: "Numerics (transitive)"),
        .init(name: "swift-http-types", license: "Apache-2.0", url: "https://github.com/apple/swift-http-types", role: "HTTP types (transitive)"),
    ]
}

/// A scrollable list of the app's open-source acknowledgements.
struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section {
                Text("HelloNotes is built with these open-source projects. Thank you to their authors and contributors.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Open-source packages") {
                ForEach(Acknowledgements.all) { ack in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(ack.name).font(.headline)
                            Spacer()
                            Text(ack.license)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text(ack.role)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let link = URL(string: ack.url) {
                            Link(ack.url, destination: link)
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Acknowledgements")
    }
}

#Preview {
    AcknowledgementsView().frame(width: 560, height: 640)
}
