//
//  TasteSynthesis.swift
//  Vision_clother
//
//  Turns the numeric affinity maps `Domain/AttributePreferenceProfile.swift`
//  already computes into a short, ranked list of plain-language-ready
//  "taste signals" for the Profile tab's "Your Taste, In Words" section —
//  pure ranking/filtering over existing data, not a new preference formula.
//  No I/O, no SwiftUI (Domain/CLAUDE.md); English copy for each signal is
//  composed in the Features layer, not here.
//

import Foundation

/// One synthesized observation about the user's taste, carrying just enough
/// structured data for the Features layer to render a sentence + icon.
enum TasteSignal: Equatable {
    /// A color vibe the user consistently rates well within one slot (e.g.
    /// "earth tones for tops") — drawn from `colorVibeAffinityBySlot`.
    case colorInSlot(slot: Slot, vibe: ColorVibe, affinity: Double)
    /// The formality band the user's ratings cluster around most positively.
    case formalitySweetSpot(band: Int, affinity: Double)
    case pattern(GarmentPattern, affinity: Double)
    /// `WardrobeItem.silhouette` is a free-form string tag, not an enum.
    case silhouette(String, affinity: Double)
    case fabricWeight(FabricWeight, affinity: Double)
    /// A color vibe the user consistently rates poorly (flat, unslotted
    /// `colorVibeAffinity`) — the symmetric "tends to dislike" counterpart
    /// already surfaced to the recommendation LLM by `StylistBrain`.
    case avoidedColor(ColorVibe, affinity: Double)

    /// Distance from the neutral 0.5 prior — how confidently this signal
    /// says something, used purely for ranking.
    var magnitude: Double {
        switch self {
        case .colorInSlot(_, _, let affinity),
             .formalitySweetSpot(_, let affinity),
             .pattern(_, let affinity),
             .silhouette(_, let affinity),
             .fabricWeight(_, let affinity),
             .avoidedColor(_, let affinity):
            return abs(affinity - 0.5)
        }
    }
}

enum TasteSynthesis {
    /// An affinity at or above this reads as "confident enough to say out
    /// loud" as a positive preference.
    static let confidenceThreshold = 0.58
    /// An affinity at or below this reads as a confidently negative signal.
    static let avoidThreshold = 0.40

    /// Ranked, thresholded taste signals, most confident first. Only
    /// attributes with real feedback behind them (affinity meaningfully off
    /// the neutral 0.5 default) are included — a sparse or empty profile
    /// yields `[]`, never a fabricated statement.
    static func rank(from profile: AttributePreferenceProfile, limit: Int = 5) -> [TasteSignal] {
        var candidates: [TasteSignal] = []

        for (slot, colorMap) in profile.colorVibeAffinityBySlot {
            if let (vibe, affinity) = colorMap.max(by: { $0.value < $1.value }), affinity >= confidenceThreshold {
                candidates.append(.colorInSlot(slot: slot, vibe: vibe, affinity: affinity))
            }
        }

        if let (band, affinity) = profile.formalityAffinity.max(by: { $0.value < $1.value }), affinity >= confidenceThreshold {
            candidates.append(.formalitySweetSpot(band: band, affinity: affinity))
        }

        if let (pattern, affinity) = profile.patternAffinity.max(by: { $0.value < $1.value }), affinity >= confidenceThreshold {
            candidates.append(.pattern(pattern, affinity: affinity))
        }

        if let (silhouette, affinity) = profile.silhouetteAffinity.max(by: { $0.value < $1.value }), affinity >= confidenceThreshold {
            candidates.append(.silhouette(silhouette, affinity: affinity))
        }

        if let (fabricWeight, affinity) = profile.fabricWeightAffinity.max(by: { $0.value < $1.value }), affinity >= confidenceThreshold {
            candidates.append(.fabricWeight(fabricWeight, affinity: affinity))
        }

        if let (vibe, affinity) = profile.colorVibeAffinity.min(by: { $0.value < $1.value }), affinity <= avoidThreshold {
            candidates.append(.avoidedColor(vibe, affinity: affinity))
        }

        return candidates
            .sorted { $0.magnitude > $1.magnitude }
            .prefix(limit)
            .map { $0 }
    }
}
