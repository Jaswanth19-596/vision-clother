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
//  Question set redesigned (2026-07-15) so every question maps to a specific
//  garment attribute the scoring engine can act on, instead of blending
//  everything (including questions with no scoring hook at all, like the
//  former Versatility/Frequency/Quality Perception) into one mushy score
//  that got reused as the signal for color/pattern/formality alike. See
//  docs/decisions/stylist-intelligence-engine.md.
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

    /// "Liked" scoring formula for `ItemRating`'s attribute-targeted question
    /// set — the item-level mirror of `OutfitFeedback.normalizedRating`.
    /// `patternLike` is optional because `Features/Rating/RateItemView.swift`
    /// skips the Pattern question for solid-pattern items (nothing to ask);
    /// when absent, the average is taken over the remaining 6 dimensions
    /// instead of 7 rather than assuming a neutral answer.
    static func normalizedRating(
        fit: FitRating,
        comfort: Int,
        colorLike: Int,
        patternLike: Int?,
        formalityFit: Int,
        styleIdentity: Int,
        wearAgain: Bool
    ) -> Double {
        let comfortNorm = Double(comfort - 1) / 4.0
        let colorLikeNorm = Double(colorLike - 1) / 4.0
        let formalityFitNorm = Double(formalityFit - 1) / 4.0
        let styleIdentityNorm = Double(styleIdentity - 1) / 4.0
        let wearAgainNorm = wearAgain ? 1.0 : 0.0

        var sum = fit.centeredness + comfortNorm + colorLikeNorm + formalityFitNorm + styleIdentityNorm + wearAgainNorm
        var count = 6.0
        if let patternLike {
            sum += Double(patternLike - 1) / 4.0
            count += 1
        }
        return sum / count
    }
}

/// One rating event for a single garment, gathered from
/// `Features/Rating/RateItemView.swift`: Fit, Comfort (fabric feel), Color
/// ("do you like this color on you"), Pattern (skipped for solids),
/// Formality Fit ("did this feel right for how formal/casual you needed
/// it"), Style Identity ("does this feel like you"), and Wear Again.
/// Event-sourced like the other feedback tables (Models/FeedbackEvent.swift)
/// so re-rating a garment over time accumulates history rather than
/// overwriting it.
@Model
final class ItemRating {
    @Attribute(.unique) var id: UUID
    var itemID: UUID
    /// Raw `FitRating.rawValue` — stored as `Int` for SwiftData compatibility.
    var fitRaw: Int
    /// 1...5, fabric comfort / feel — also the item-level signal for
    /// `Domain/AttributePreferenceProfile.swift`'s `fabricWeightAffinity`.
    var comfort: Int
    /// 1...5, "do you like this color on you?" — feeds `colorVibeAffinity`
    /// for `WardrobeItem.colorProfile.category`, replacing the old blended
    /// `value` that had no dedicated color question at all.
    var colorLike: Int
    /// 1...5, "how do you feel about this pattern?" — feeds `patternAffinity`
    /// for `WardrobeItem.pattern`. `nil` when the item's pattern is `.solid`
    /// (`RateItemView` skips the question; nothing meaningful to ask).
    var patternLike: Int?
    /// 1...5, "did this feel right for how formal/casual you needed it?" —
    /// feeds `formalityAffinity` for the item's formality band.
    var formalityFit: Int
    /// 1...5, "does this feel like you?" — feeds `styleTagAffinity`, the
    /// same map the outfit-level Personal Style Match question feeds.
    var styleIdentity: Int
    var wearAgain: Bool
    var recordedAt: Date

    init(
        id: UUID = UUID(),
        itemID: UUID,
        fit: FitRating,
        comfort: Int,
        colorLike: Int,
        patternLike: Int?,
        formalityFit: Int,
        styleIdentity: Int,
        wearAgain: Bool,
        recordedAt: Date = .now
    ) {
        self.id = id
        self.itemID = itemID
        self.fitRaw = fit.rawValue
        self.comfort = comfort
        self.colorLike = colorLike
        self.patternLike = patternLike
        self.formalityFit = formalityFit
        self.styleIdentity = styleIdentity
        self.wearAgain = wearAgain
        self.recordedAt = recordedAt
    }

    var fit: FitRating {
        FitRating(rawValue: fitRaw) ?? .justRight
    }

    /// Mean of every answered question, normalized to `[0,1]`. Used both as
    /// the "liked" threshold input (see `impliesLiked`) and as the per-rating
    /// value fed into `Domain/AttributePreferenceProfile`'s overall-liked
    /// channel (distinct from the dedicated per-attribute fields above, which
    /// each feed their own affinity map directly).
    var normalizedValue: Double {
        FitRating.normalizedRating(
            fit: fit, comfort: comfort, colorLike: colorLike, patternLike: patternLike,
            formalityFit: formalityFit, styleIdentity: styleIdentity, wearAgain: wearAgain
        )
    }

    /// Threshold that folds this rich rating into the existing binary
    /// item-preference channel (`ItemFeedback.likedFit` / `FeedbackHistory.itemFeedback`)
    /// and into the Swipe-to-Learn visual centroids as an implicit swipe
    /// (`Data/WardrobeRepository.swift`'s `applyImplicitSwipe`).
    var impliesLiked: Bool {
        normalizedValue >= 0.6
    }
}
