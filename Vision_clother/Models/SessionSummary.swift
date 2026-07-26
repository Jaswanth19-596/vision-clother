//
//  SessionSummary.swift
//  Vision_clother
//
//  Compressed cross-session memory (Hermes-inspired session-summary feature,
//  see docs/decisions/resolved-v1.md). A short, LLM-written recap of one
//  Daily Assistant conversation's occasion plus preferred/rejected
//  attributes — piggybacked onto the recommendation call's existing
//  structured response (`Models/OutfitRecommendationResponse.swift`'s
//  `sessionSummary` field) rather than a separate summarization call.
//
//  Deliberately NOT a single continuously-rewritten "running profile": each
//  row is an independent, one-time write, and retention is a rolling window
//  (`Data/WardrobeRepository.swift`'s `pruneOldSessionSummaries`) rather than
//  an LLM-maintained rewrite, so a bad write can never corrupt prior history.
//

import Foundation
import SwiftData

@Model
final class SessionSummary {
    @Attribute(.unique) var id: UUID
    var summaryText: String
    var createdAt: Date

    /// Defensive cap on stored text — the LLM is asked for "1-2 sentences"
    /// but nothing server-side enforces that, and this text is re-injected
    /// into every future recommendation prompt.
    static let maxSummaryTextLength = 240

    init(
        id: UUID = UUID(),
        summaryText: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.summaryText = String(summaryText.prefix(Self.maxSummaryTextLength))
        self.createdAt = createdAt
    }
}
