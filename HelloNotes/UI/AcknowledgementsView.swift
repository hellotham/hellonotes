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
        .init(name: "MLX Swift", license: "MIT", url: "https://github.com/ml-explore/mlx-swift", role: "On-device model inference (Apple silicon)"),
        .init(name: "MLX Swift LM", license: "MIT", url: "https://github.com/ml-explore/mlx-swift-lm", role: "Open language models for Foundation Models"),
        .init(name: "swift-transformers", license: "Apache-2.0", url: "https://github.com/huggingface/swift-transformers", role: "Tokenizers (MLX)"),
        .init(name: "swift-huggingface", license: "Apache-2.0", url: "https://github.com/huggingface/swift-huggingface", role: "Model downloads (MLX)"),
        .init(name: "swift-jinja", license: "Apache-2.0", url: "https://github.com/huggingface/swift-jinja", role: "Chat templates (transitive)"),
        .init(name: "yyjson", license: "MIT", url: "https://github.com/ibireme/yyjson", role: "JSON parsing (transitive)"),
        .init(name: "swift-crypto", license: "Apache-2.0", url: "https://github.com/apple/swift-crypto", role: "Hashing (transitive)"),
        .init(name: "EventSource", license: "MIT", url: "https://github.com/mattt/EventSource", role: "Streaming downloads (transitive)"),
        .init(name: "swift-collections", license: "Apache-2.0", url: "https://github.com/apple/swift-collections", role: "Data structures (transitive)"),
        .init(name: "swift-numerics", license: "Apache-2.0", url: "https://github.com/apple/swift-numerics", role: "Numerics (transitive)"),
    ]
}

/// The app's open-source acknowledgements — a sheet of their own, opened
/// beside About (**Acknowledgements…**), with its title and the way out in a
/// bar above a scrolling page.
struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ChromeSheetBar("Acknowledgements") {
                EmptyView()
            } trailing: {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ChromeForm {
                ChromeSection {
                    Text("HelloNotes is built with these open-source projects. Thank you to their authors and contributors.")
                        .font(Chrome.Style.callout)
                        .foregroundStyle(Chrome.Colour.secondaryLabel)
                }
                ChromeSection("Open-source packages") {
                    ForEach(Acknowledgements.all) { ack in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(ack.name).font(Chrome.Style.headline)
                                Spacer()
                                Text(ack.license)
                                    .font(Chrome.Style.caption.monospaced())
                                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                            }
                            Text(ack.role)
                                .font(Chrome.Style.caption)
                                .foregroundStyle(Chrome.Colour.secondaryLabel)
                            if let link = URL(string: ack.url) {
                                ChromeLink(ack.url, destination: link)
                                    .font(Chrome.Style.caption)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        // The size the Mac's sheet has always been, now on both platforms.
        .chromeSheetFrame(width: 560, height: 620)
    }
}

#Preview {
    AcknowledgementsView()
}
