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
}

/// One rating event for a single garment — fit, comfort, confidence, and a
/// wear-again signal, gathered from `Features/Rating/RateItemView.swift`.
/// Event-sourced like the other feedback tables (Models/FeedbackEvent.swift)
/// so re-rating a garment over time accumulates history rather than
/// overwriting it.
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
    var recordedAt: Date

    init(
        id: UUID = UUID(),
        itemID: UUID,
        fit: FitRating,
        comfort: Int,
        confidence: Int,
        wearAgain: Bool,
        recordedAt: Date = .now
    ) {
        self.id = id
        self.itemID = itemID
        self.fitRaw = fit.rawValue
        self.comfort = comfort
        self.confidence = confidence
        self.wearAgain = wearAgain
        self.recordedAt = recordedAt
    }

    var fit: FitRating {
        FitRating(rawValue: fitRaw) ?? .justRight
    }

    /// Mean of the four questions normalized to `[0,1]`:
    /// `comfort`/`confidence` map 1...5 -> 0...1, `wearAgain` maps
    /// true/false -> 1.0/0.0, and fit uses `centeredness` (already 0...1).
    /// Used both as the "liked" threshold input (see `impliesLiked`) and as
    /// the per-rating value fed into `Domain/AttributePreferenceProfile`.
    var normalizedValue: Double {
        let comfortNorm = Double(comfort - 1) / 4.0
        let confidenceNorm = Double(confidence - 1) / 4.0
        let wearAgainNorm = wearAgain ? 1.0 : 0.0
        return (fit.centeredness + comfortNorm + confidenceNorm + wearAgainNorm) / 4.0
    }

    /// Threshold that folds this rich rating into the existing binary
    /// item-preference channel (`ItemFeedback.likedFit` / `FeedbackHistory.itemFeedback`).
    var impliesLiked: Bool {
        normalizedValue >= 0.6
    }
}
