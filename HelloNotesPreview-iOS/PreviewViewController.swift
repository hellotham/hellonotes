//
//  PreviewViewController.swift
//  HelloNotesPreview-iOS
//
//  Quick Look preview for `.md` files (iOS): a lightweight native render into a
//  read-only UITextView. Self-contained — Quick Look hands us the file.
//

import UIKit
import QuickLook

class PreviewViewController: UIViewController, QLPreviewingController {
    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        textView.isEditable = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let attributed = QLMarkdown.attributed(text)
        await MainActor.run { textView.attributedText = attributed }
    }
}

/// Minimal, dependency-free Markdown → attributed string for previews.
enum QLMarkdown {
    static func attributed(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = UIFont.systemFont(ofSize: 15)
        let mono = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); continue }
            if inFence {
                out.append(NSAttributedString(string: line + "\n",
                    attributes: [.font: mono, .foregroundColor: UIColor.secondaryLabel]))
            } else if let m = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let size: CGFloat = [26, 22, 20, 18, 16, 15][min(level - 1, 5)]
                out.append(NSAttributedString(string: String(trimmed[m.upperBound...]) + "\n",
                    attributes: [.font: UIFont.boldSystemFont(ofSize: size), .foregroundColor: UIColor.label]))
            } else if let m = line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
                out.append(NSAttributedString(string: "•  " + String(line[m.upperBound...]) + "\n",
                    attributes: [.font: body, .foregroundColor: UIColor.label]))
            } else {
                out.append(NSAttributedString(string: line + "\n",
                    attributes: [.font: body, .foregroundColor: UIColor.label]))
            }
        }
        return out
    }
}
