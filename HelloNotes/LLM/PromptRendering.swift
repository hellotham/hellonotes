//
//  PromptRendering.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Helpers for the on-device providers (FoundationModels, MLX), which take a
//  single prompt string rather than a structured message list. We flatten the
//  conversation into a labelled transcript so multi-turn context is preserved.
//

import Foundation

enum PromptRendering {
    /// Flatten a conversation into a "User:/Assistant:" transcript, ready to hand
    /// to a single-prompt model. Tool parts are omitted (on-device path is chat).
    static func transcript(_ messages: [LLMMessage]) -> String {
        messages.compactMap { message -> String? in
            switch message.role {
            case .user:
                let t = message.text
                return t.isEmpty ? nil : "User: \(t)"
            case .assistant:
                let t = message.text
                return t.isEmpty ? nil : "Assistant: \(t)"
            case .system, .tool:
                return nil
            }
        }
        .joined(separator: "\n\n")
    }
}
