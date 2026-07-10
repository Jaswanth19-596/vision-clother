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

/// Outfit-level "wear again?" answer. Three-state rather than a plain Bool —
/// "Maybe" is a distinct, valuable signal (Stylist Intelligence Engine
/// Phase 1: dimension-based outfit feedback), not a fence-sitting default
/// that should collapse into yes/no.
enum WearAgainAnswer: String, Codable, CaseIterable, Identifiable {
    case yes, maybe, no

    var id: String { rawValue }

    var label: String {
        switch self {
        case .yes: return "Yes"
        case .maybe: return "Maybe"
        case .no: return "No"
        }
    }

    /// Contribution to `OutfitFeedback.normalizedRating`, in `[0,1]` —
    /// "Maybe" sits at the midpoint rather than being forced toward either
    /// extreme.
    var normalizedValue: Double {
        switch self {
        case .yes: return 1.0
        case .maybe: return 0.5
        case .no: return 0.0
        }
    }
}

/// Outfit-Level Event — dimension-based feedback on a whole saved outfit
/// (Stylist Intelligence Engine Phase 1, superseding the earlier blended
/// Fit/Comfort/Confidence/Wear-again form). Every Level 2 question exists
/// because it updates a specific part of the recommendation engine — see
/// `Data/WardrobeRepository.fetchFeedbackHistory()` and
/// `Domain/AttributePreferenceProfile.swift` for the join.
///
/// Two write paths share this table: the simple auto-recorded "liked" event
/// from a save action (`likedOverall` only, every detailed field left
/// `nil`), and the deliberate multi-question "Rate this outfit" flow
/// (`Features/Rating/RateCombinationView.swift`), which populates every
/// detailed field and derives `likedOverall` from them. `outfitID` must be a
/// durable `SavedCombination.id`, never an ephemeral in-memory
/// `OutfitCombination.id`, or history can never be looked back up.
@Model
final class OutfitFeedback {
    @Attribute(.unique) var id: UUID
    var outfitID: UUID
    var likedOverall: Bool
    var recordedAt: Date

    // Level 1 — Overall Experience. Measures whether the recommendation
    // succeeded; does not teach fashion. `nil` unless recorded via the
    // detailed "Rate this outfit" flow.
    var overallSatisfaction: Int?
    var wearAgainRaw: String?
    var confidence: Int?
    var comfort: Int?

    // Level 2 — Fashion Evaluation. Each dimension is a distinct teaching
    // signal for the Stylist Brain (see the table in
    // `docs/decisions/stylist-intelligence-engine.md`). `nil` unless
    // recorded via the detailed flow.
    var occasionMatch: Int?
    var styleMatch: Int?
    var colorHarmony: Int?
    var silhouette: Int?
    var weatherSuitability: Int?
    var practicality: Int?

    // Level 4/5 — Favorite / Weakest item in the outfit, feeding the item
    // affinity / negative-affinity graph (`WardrobeRepository.fetchFeedbackHistory()`).
    var favoriteItemID: UUID?
    var weakestItemID: UUID?

    init(
        id: UUID = UUID(),
        outfitID: UUID,
        likedOverall: Bool,
        recordedAt: Date = .now,
        overallSatisfaction: Int? = nil,
        wearAgain: WearAgainAnswer? = nil,
        confidence: Int? = nil,
        comfort: Int? = nil,
        occasionMatch: Int? = nil,
        styleMatch: Int? = nil,
        colorHarmony: Int? = nil,
        silhouette: Int? = nil,
        weatherSuitability: Int? = nil,
        practicality: Int? = nil,
        favoriteItemID: UUID? = nil,
        weakestItemID: UUID? = nil
    ) {
        self.id = id
        self.outfitID = outfitID
        self.likedOverall = likedOverall
        self.recordedAt = recordedAt
        self.overallSatisfaction = overallSatisfaction
        self.wearAgainRaw = wearAgain?.rawValue
        self.confidence = confidence
        self.comfort = comfort
        self.occasionMatch = occasionMatch
        self.styleMatch = styleMatch
        self.colorHarmony = colorHarmony
        self.silhouette = silhouette
        self.weatherSuitability = weatherSuitability
        self.practicality = practicality
        self.favoriteItemID = favoriteItemID
        self.weakestItemID = weakestItemID
    }

    var wearAgain: WearAgainAnswer? {
        wearAgainRaw.flatMap(WearAgainAnswer.init(rawValue:))
    }

    /// Mean of every Level 1 + Level 2 question, normalized to `[0,1]`:
    /// star questions map 1...5 -> 0...1, `wearAgain` uses `normalizedValue`.
    /// `nil` if any detailed field is missing (i.e. this is a simple
    /// auto-recorded event, not a detailed rating) — mirrors
    /// `FitRating.normalizedRating`'s role for `ItemRating`.
    var normalizedRating: Double? {
        guard let overallSatisfaction, let wearAgain, let confidence, let comfort,
              let occasionMatch, let styleMatch, let colorHarmony, let silhouette,
              let weatherSuitability, let practicality
        else { return nil }

        return Self.normalizedRating(
            overallSatisfaction: overallSatisfaction, wearAgain: wearAgain, confidence: confidence, comfort: comfort,
            occasionMatch: occasionMatch, styleMatch: styleMatch, colorHarmony: colorHarmony, silhouette: silhouette,
            weatherSuitability: weatherSuitability, practicality: practicality
        )
    }

    /// Shared formula for the Level 1 + Level 2 question set — used by both
    /// the `normalizedRating` instance property (read path, persisted rows)
    /// and `Data/WardrobeRepository.recordOutfitRating` (write path, a fresh
    /// `OutfitRatingSubmission`), so the two can never silently drift apart.
    static func normalizedRating(
        overallSatisfaction: Int,
        wearAgain: WearAgainAnswer,
        confidence: Int,
        comfort: Int,
        occasionMatch: Int,
        styleMatch: Int,
        colorHarmony: Int,
        silhouette: Int,
        weatherSuitability: Int,
        practicality: Int
    ) -> Double {
        let starValues = [overallSatisfaction, confidence, comfort, occasionMatch, styleMatch, colorHarmony, silhouette, weatherSuitability, practicality]
        let starSum = starValues.reduce(0.0) { $0 + Double($1 - 1) / 4.0 }
        return (starSum + wearAgain.normalizedValue) / Double(starValues.count + 1)
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
