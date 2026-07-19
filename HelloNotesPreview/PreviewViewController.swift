//
//  PreviewViewController.swift
//  HelloNotesPreview
//
//  Quick Look preview for `.md` files: a lightweight native render (headings,
//  bullets, fenced code) into a read-only NSTextView. Self-contained (no app
//  dependency) — Quick Look hands us the file directly.
//

import Cocoa
import Quartz

class PreviewViewController: NSViewController, QLPreviewingController {

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 800))
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let attributed = QLMarkdown.attributed(text)
        await MainActor.run {
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = view.bounds
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = true
            if let tv = scroll.documentView as? NSTextView {
                tv.isEditable = false
                tv.textContainerInset = NSSize(width: 24, height: 24)
                tv.textStorage?.setAttributedString(attributed)
            }
            view.addSubview(scroll)
        }
    }
}

/// Minimal, dependency-free Markdown → attributed string for previews.
enum QLMarkdown {
    static func attributed(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 13)
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); continue }
            if inFence {
                out.append(NSAttributedString(string: line + "\n",
                    attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor]))
            } else if let m = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let size: CGFloat = [22, 19, 17, 15, 14, 13][min(level - 1, 5)]
                out.append(NSAttributedString(string: String(trimmed[m.upperBound...]) + "\n",
                    attributes: [.font: NSFont.boldSystemFont(ofSize: size)]))
            } else if let m = line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
                out.append(NSAttributedString(string: "•  " + String(line[m.upperBound...]) + "\n",
                    attributes: [.font: body]))
            } else {
                out.append(NSAttributedString(string: line + "\n", attributes: [.font: body]))
            }
        }
        return out
    }
}
