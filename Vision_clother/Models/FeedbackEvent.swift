//
//  FeedbackEvent.swift
//  Vision_clother
//
//  Three-Tier User Feedback Architecture (PRD.md §3.6). Each tier is
//  persisted independently via SwiftData so the scoring engine can query
//  pair-level history (`∑Feedback` in the PRD §3.4 formula) without loading
//  entire outfit records.
//

import Foundation
import SwiftData

/// Outfit-Level Event — did the overall combination work? [Yes/No]
@Model
final class OutfitFeedback {
    @Attribute(.unique) var id: UUID
    var outfitID: UUID
    var likedOverall: Bool
    var recordedAt: Date

    init(id: UUID = UUID(), outfitID: UUID, likedOverall: Bool, recordedAt: Date = .now) {
        self.id = id
        self.outfitID = outfitID
        self.likedOverall = likedOverall
        self.recordedAt = recordedAt
    }
}

/// Item-Level Assessment — fabric comfort / fit / confidence per garment.
@Model
final class ItemFeedback {
    @Attribute(.unique) var id: UUID
    var itemID: UUID
    var likedFit: Bool
    var recordedAt: Date

    init(id: UUID = UUID(), itemID: UUID, likedFit: Bool, recordedAt: Date = .now) {
        self.id = id
        self.itemID = itemID
        self.likedFit = likedFit
        self.recordedAt = recordedAt
    }
}

/// Pair-Level Relational Array — did this specific top/bottom (etc.) pair
/// combine cleanly? This is the `∑Feedback` input to
/// `Domain/PairCompatibilityScoring.swift`.
@Model
final class PairFeedback {
    @Attribute(.unique) var id: UUID
    /// Item IDs are stored order-independently (min/max) so a lookup for
    /// (A, B) matches history recorded as (B, A).
    var itemAID: UUID
    var itemBID: UUID
    var likedTogether: Bool
    var recordedAt: Date

    init(id: UUID = UUID(), itemAID: UUID, itemBID: UUID, likedTogether: Bool, recordedAt: Date = .now) {
        let ordered = [itemAID, itemBID].sorted { $0.uuidString < $1.uuidString }
        self.id = id
        self.itemAID = ordered[0]
        self.itemBID = ordered[1]
        self.likedTogether = likedTogether
        self.recordedAt = recordedAt
    }
}
