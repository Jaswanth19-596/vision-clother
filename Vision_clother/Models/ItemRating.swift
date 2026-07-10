//
//  ItemRating.swift
//  Vision_clother
//
//  Rich per-item rating captured after wearing/trying a garment — the
//  "Item Rating & Preference Learning" feature. Deliberately a *new* model
//  rather than an extension of `ItemFeedback` (Models/FeedbackEvent.swift):
//  that type's binary `likedFit` channel already feeds
//  `Domain/PairCompatibilityScoring.itemPreference`, and adding fields to an
//  existing `@Model` would require a SwiftData migration. `ItemRating` is
//  additive — the repository folds its derived "liked" signal into the same
//  `FeedbackHistory.itemFeedback` channel (see Data/WardrobeRepository.swift)
//  and its per-attribute values into `Domain/AttributePreferenceProfile.swift`.
//

import Foundation
import SwiftData

/// Fit direction on a 5-point scale, centered on "just right". Distinct from
/// a plain 1–5 magnitude scale because fit has two failure directions (too
/// tight vs. too loose) that a single ascending scale would conflate.
enum FitRating: Int, Codable, CaseIterable, Identifiable {
    case tooTight = -2
    case slightlyTight = -1
    case justRight = 0
    case slightlyLoose = 1
    case tooLoose = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .tooTight: return "Too tight"
        case .slightlyTight: return "Slightly tight"
        case .justRight: return "Just right"
        case .slightlyLoose: return "Slightly loose"
        case .tooLoose: return "Too loose"
        }
    }

    /// 1.0 at "just right", 0.0 at either extreme — the fit question's
    /// contribution to the overall normalized rating (see `ItemRating.normalizedValue`).
    var centeredness: Double {
        1.0 - Double(abs(rawValue)) / 2.0
    }

    /// "Liked" scoring formula for `ItemRating`'s Level 1 (Fit/Comfort/
    /// Confidence/Wear-again) + Level 2 (Versatility/Frequency/Style
    /// Identity/Quality Perception) question set — the item-level mirror of
    /// `OutfitFeedback.normalizedRating` (Stylist Intelligence Engine Phase 1
    /// addendum, item granularity). Sole consumer is `ItemRating.normalizedValue`.
    static func normalizedRating(
        fit: FitRating,
        comfort: Int,
        confidence: Int,
        wearAgain: Bool,
        versatility: Int,
        frequency: Int,
        styleIdentity: Int,
        qualityPerception: Int
    ) -> Double {
        let comfortNorm = Double(comfort - 1) / 4.0
        let confidenceNorm = Double(confidence - 1) / 4.0
        let wearAgainNorm = wearAgain ? 1.0 : 0.0
        let versatilityNorm = Double(versatility - 1) / 4.0
        let frequencyNorm = Double(frequency - 1) / 4.0
        let styleIdentityNorm = Double(styleIdentity - 1) / 4.0
        let qualityPerceptionNorm = Double(qualityPerception - 1) / 4.0
        return (
            fit.centeredness + comfortNorm + confidenceNorm + wearAgainNorm
            + versatilityNorm + frequencyNorm + styleIdentityNorm + qualityPerceptionNorm
        ) / 8.0
    }

    /// Fallback for `ItemRating` rows recorded before the Level 2 Fashion
    /// Evaluation questions existed (`versatility`/`frequency`/`styleIdentity`/
    /// `qualityPerception` are `nil`) — the original Level 1-only
    /// (Fit/Comfort/Confidence/Wear-again) formula, so legacy rows keep
    /// contributing a meaningful "liked" signal to `impliesLiked` and
    /// `Domain/AttributePreferenceProfile` instead of crashing or being
    /// silently dropped. Sole consumer is `ItemRating.normalizedValue`.
    static func legacyNormalizedRating(fit: FitRating, comfort: Int, confidence: Int, wearAgain: Bool) -> Double {
        let comfortNorm = Double(comfort - 1) / 4.0
        let confidenceNorm = Double(confidence - 1) / 4.0
        let wearAgainNorm = wearAgain ? 1.0 : 0.0
        return (fit.centeredness + comfortNorm + confidenceNorm + wearAgainNorm) / 4.0
    }
}

/// One rating event for a single garment — Level 1 (fit, comfort,
/// confidence, wear-again) plus Level 2 Fashion Evaluation (versatility,
/// predicted wear frequency, style identity, quality perception — Stylist
/// Intelligence Engine Phase 1 addendum, item granularity), gathered from
/// `Features/Rating/RateItemView.swift`. Event-sourced like the other
/// feedback tables (Models/FeedbackEvent.swift) so re-rating a garment over
/// time accumulates history rather than overwriting it.
@Model
final class ItemRating {
    @Attribute(.unique) var id: UUID
    var itemID: UUID
    /// Raw `FitRating.rawValue` — stored as `Int` for SwiftData compatibility.
    var fitRaw: Int
    /// 1...5, fabric comfort / feel.
    var comfort: Int
    /// 1...5, how confident/good the user felt wearing it.
    var confidence: Int
    var wearAgain: Bool
    /// 1...5, how versatile/restylable the user judges this piece to be.
    /// Optional so existing persisted rows (recorded before this question
    /// existed) decode as `nil` under SwiftData's automatic lightweight
    /// migration — no schema version bump needed. `nil` on legacy rows
    /// falls back to the pre-Level-2 formula (see `normalizedValue`).
    var versatility: Int? = nil
    /// 1...5, predicted future wear frequency. Optional — see `versatility`.
    var frequency: Int? = nil
    /// 1...5, "does this feel like you" — feeds
    /// `Domain/AttributePreferenceProfile.swift`'s `styleTagAffinity`,
    /// the same map the outfit-level Personal Style Match question feeds.
    /// Optional — see `versatility`.
    var styleIdentity: Int? = nil
    /// 1...5, perceived craftsmanship/quality. Optional — see `versatility`.
    var qualityPerception: Int? = nil
    var recordedAt: Date

    init(
        id: UUID = UUID(),
        itemID: UUID,
        fit: FitRating,
        comfort: Int,
        confidence: Int,
        wearAgain: Bool,
        versatility: Int,
        frequency: Int,
        styleIdentity: Int,
        qualityPerception: Int,
        recordedAt: Date = .now
    ) {
        self.id = id
        self.itemID = itemID
        self.fitRaw = fit.rawValue
        self.comfort = comfort
        self.confidence = confidence
        self.wearAgain = wearAgain
        self.versatility = versatility
        self.frequency = frequency
        self.styleIdentity = styleIdentity
        self.qualityPerception = qualityPerception
        self.recordedAt = recordedAt
    }

    var fit: FitRating {
        FitRating(rawValue: fitRaw) ?? .justRight
    }

    /// Mean of all 8 Level 1 + Level 2 questions normalized to `[0,1]`, or —
    /// for legacy rows recorded before Level 2 existed — the Level 1-only
    /// fallback (`FitRating.legacyNormalizedRating`). Used both as the
    /// "liked" threshold input (see `impliesLiked`) and as the per-rating
    /// value fed into `Domain/AttributePreferenceProfile`.
    var normalizedValue: Double {
        guard let versatility, let frequency, let styleIdentity, let qualityPerception else {
            return FitRating.legacyNormalizedRating(fit: fit, comfort: comfort, confidence: confidence, wearAgain: wearAgain)
        }
        return FitRating.normalizedRating(
            fit: fit, comfort: comfort, confidence: confidence, wearAgain: wearAgain,
            versatility: versatility, frequency: frequency, styleIdentity: styleIdentity, qualityPerception: qualityPerception
        )
    }

    /// Threshold that folds this rich rating into the existing binary
    /// item-preference channel (`ItemFeedback.likedFit` / `FeedbackHistory.itemFeedback`).
    var impliesLiked: Bool {
        normalizedValue >= 0.6
    }
}
