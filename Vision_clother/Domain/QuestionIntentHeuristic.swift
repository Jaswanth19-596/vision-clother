//
//  QuestionIntentHeuristic.swift
//  Vision_clother
//
//  Wardrobe/Insights Q&A (2026-07-20): a cheap, on-device pre-filter that
//  decides whether a free-text turn is even worth routing through
//  `Services/StylistQAService.swift` before touching the network. Purely a
//  latency/cost gate, never the actual classifier — the real "is this a
//  question or a recommendation request" decision is made by the QA LLM
//  call itself (`StylistQAResponse.isWardrobeQuestion`), which also has the
//  final say and can route back to the ordinary recommendation flow. A
//  false negative here (a genuine question phrased without an interrogative
//  opener or "?") just falls through to today's existing recommend flow —
//  no worse than before this feature existed. A false positive costs one
//  extra small network round trip before the QA call correctly routes to
//  the recommender.
//
//  Pure, no I/O (Domain/CLAUDE.md).
//

import Foundation

enum QuestionIntentHeuristic {
    /// First-word openers strongly associated with a question or an
    /// information request, as opposed to a scenario/occasion statement
    /// ("date night", "job interview tomorrow"). Punctuation-stripped
    /// (`firstWord(of:)`) so "what's"/"What?" both normalize to "whats"/"what".
    private static let questionOpeners: Set<String> = [
        "what", "whats", "how", "which", "why", "when", "whens", "who", "whos",
        "do", "does", "did", "am", "is", "are", "was", "were",
        "can", "could", "should", "would", "will",
        "tell", "show",
    ]

    static func looksLikeWardrobeQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix("?") { return true }
        return questionOpeners.contains(firstWord(of: trimmed))
    }

    private static func firstWord(of text: String) -> String {
        guard let word = text.lowercased().split(separator: " ").first else { return "" }
        return String(word.filter(\.isLetter))
    }
}
