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

/// "What would you change?" checklist (Stylist Intelligence Engine ADR,
/// Level 3 — closed 2026-07-15): a bounded, multi-select set of structured
/// edit signals, each mapped 1:1 onto one of the six affinity dimensions in
/// `Domain/AttributePreferenceProfile.swift`. A flagged reason forces that
/// dimension's contribution for this feedback event to a strongly negative
/// value regardless of the Level 2 star given — a deliberate signal on top
/// of, not a replacement for, the star rating (see
/// `Data/WardrobeRepository.fetchFeedbackHistory()`). `.tooFormal`/`.tooCasual`
/// are mutually exclusive in the UI (`RateCombinationViewModel.toggleChangeReason`).
enum OutfitChangeReason: String, Codable, CaseIterable, Identifiable {
    case tooFormal, tooCasual, wrongColor, wrongPattern, notMyStyle, didntFitRight, wrongForWeather

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tooFormal: return "Too formal"
        case .tooCasual: return "Too casual"
        case .wrongColor: return "Wrong colors"
        case .wrongPattern: return "Wrong pattern"
        case .notMyStyle: return "Not my style"
        case .didntFitRight: return "Didn't fit right"
        case .wrongForWeather: return "Wrong for the weather"
        }
    }
}

/// "Why did you like this?" chips (Analytics & Insights, Phase 3) — the
/// positive-side counterpart to `OutfitChangeReason`, kept deliberately
/// symmetric (per the Stylist Intelligence Engine's "symmetric taste
/// injection" precedent: likes and dislikes are both surfaced, never just
/// one) so `Domain/AttributePreferenceProfile.swift` can eventually read a
/// positive reason with the same weight it already gives a negative one.
/// Multi-select, optional — empty when nothing was flagged.
enum OutfitLikeReason: String, Codable, CaseIterable, Identifiable {
    case greatColors, veryComfortable, perfectForOccasion, boostedConfidence, feltLikeMe, versatile

    var id: String { rawValue }

    var label: String {
        switch self {
        case .greatColors: return "Great colors"
        case .veryComfortable: return "Very comfortable"
        case .perfectForOccasion: return "Perfect for the occasion"
        case .boostedConfidence: return "Boosted my confidence"
        case .feltLikeMe: return "Felt like me"
        case .versatile: return "Versatile — works for a lot"
        }
    }
}

/// Lightweight occasion tag (Analytics & Insights, Phase 3) — distinct from
/// `occasionMatch` (a 1-5 satisfaction rating of how well the outfit suited
/// whatever the occasion was); this instead records *what* the occasion was,
/// feeding "Wardrobe Insights"/"Style Trends" occasion-mix breakdowns.
/// Single-select, optional.
enum OutfitOccasion: String, Codable, CaseIterable, Identifiable {
    case work, casual, date, specialEvent, weekend, travel

    var id: String { rawValue }

    var label: String {
        switch self {
        case .work: return "Work"
        case .casual: return "Casual"
        case .date: return "Date"
        case .specialEvent: return "Special event"
        case .weekend: return "Weekend"
        case .travel: return "Travel"
        }
    }
}

/// "What would replace it?" chip for the Weakest Piece pick (Analytics &
/// Insights, Phase 3) — a structured, bounded alternative to a free-text
/// suggestion box, matching this feature's "avoid long forms" posture.
/// Single-select, optional, only meaningful when `weakestItemID` is set.
enum ReplacementSuggestion: String, Codable, CaseIterable, Identifiable {
    case differentColor, differentFit, differentStyle, differentFabric

    var id: String { rawValue }

    var label: String {
        switch self {
        case .differentColor: return "A different color"
        case .differentFit: return "A different fit"
        case .differentStyle: return "A different style"
        case .differentFabric: return "A different fabric"
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

    // Level 3 — "What would you change?" checklist. Empty (not nil) when
    // nothing was flagged, mirroring `suggestedChips`'s empty-array-not-null
    // convention. Stored as raw strings (SwiftData-storable), same pattern
    // as `wearAgainRaw`.
    var changeReasonsRaw: [String] = []

    // Analytics & Insights, Phase 3 — Better Feedback Collection. All
    // optional/defaulted (additive-only `SchemaV11` migration, see
    // `Models/SchemaMigrations.swift`): every pre-existing row reads as
    // "nothing flagged," which is correct (they predate these chips).
    /// "Why did you like this?" — only meaningful when `likedOverall`, but
    /// not enforced (the UI only shows the chips on the positive path).
    var likeReasonsRaw: [String] = []
    var occasionRaw: String?
    /// `nil` = not answered; the chip UI is a tri-state Yes/No/unanswered,
    /// not a plain toggle defaulting to false.
    var wouldBuySimilar: Bool?
    var savedForInspiration: Bool = false
    /// Only meaningful when `weakestItemID` is set.
    var replacementSuggestionRaw: String?

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
        weakestItemID: UUID? = nil,
        changeReasons: [OutfitChangeReason] = [],
        likeReasons: [OutfitLikeReason] = [],
        occasion: OutfitOccasion? = nil,
        wouldBuySimilar: Bool? = nil,
        savedForInspiration: Bool = false,
        replacementSuggestion: ReplacementSuggestion? = nil
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
        self.changeReasonsRaw = changeReasons.map(\.rawValue)
        self.likeReasonsRaw = likeReasons.map(\.rawValue)
        self.occasionRaw = occasion?.rawValue
        self.wouldBuySimilar = wouldBuySimilar
        self.savedForInspiration = savedForInspiration
        self.replacementSuggestionRaw = replacementSuggestion?.rawValue
    }

    var wearAgain: WearAgainAnswer? {
        wearAgainRaw.flatMap(WearAgainAnswer.init(rawValue:))
    }

    var changeReasons: [OutfitChangeReason] {
        changeReasonsRaw.compactMap(OutfitChangeReason.init(rawValue:))
    }

    var likeReasons: [OutfitLikeReason] {
        likeReasonsRaw.compactMap(OutfitLikeReason.init(rawValue:))
    }

    var occasion: OutfitOccasion? {
        occasionRaw.flatMap(OutfitOccasion.init(rawValue:))
    }

    var replacementSuggestion: ReplacementSuggestion? {
        replacementSuggestionRaw.flatMap(ReplacementSuggestion.init(rawValue:))
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
