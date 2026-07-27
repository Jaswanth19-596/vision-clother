//
//  FashionKnowledgeConstants.swift
//  Vision_clother
//
//  Single-sourced numeric thresholds for knowledge that has both a *prompt
//  projection* (StylistBrain's system prompt, read by the LLM) and a
//  *deterministic projection* (PairCompatibilityScoring's aesthetic prior,
//  run on-device). Before this file existed, the "how big a formality gap
//  is too big" rule lived only as an unlabeled magic number inside the
//  scoring math, while the prompt described the same rule in prose with no
//  number attached — the two could drift apart silently. Both sides now read
//  the same constant, so a future change to one is a change to both.
//
//  Pure data, no I/O (Domain/CLAUDE.md).
//

import Foundation

enum FashionKnowledgeConstants {
    /// Dress-code / formality-alignment thresholds (Decision Hierarchy Tier 1,
    /// `docs/decisions/stylist-intelligence-engine.md`).
    enum DressCode {
        /// Formality-score delta beyond which two items read as a hard
        /// dress-code mismatch (e.g. a gym tee with dress trousers).
        static let majorFormalityMismatchDelta: Double = 2.0
        /// Softer delta — still noticeable, not disqualifying.
        static let minorFormalityMismatchDelta: Double = 1.0
        /// Multi-Accessory Outfits (Stylist Intelligence Engine ADR, closed
        /// 2026-07-15): the max number of *supplementary* accessories an
        /// outfit may carry alongside the primary `accessory_id` signature
        /// piece — e.g. a belt (primary) plus a watch or necklace
        /// (supplementary). Read by both the JSON schema's `maxItems`
        /// (`Services/OutfitRecommendationService.swift`) and the
        /// validator's cap (`Domain/OutfitRecommendationValidator.swift`).
        static let maxSupplementaryAccessories = 2
    }

    /// Anti-Repetition's rotation-novelty window (`Domain/RecentOutfitHistoryBuilder.swift`).
    /// Same rationale as `DressCode` above: these two numbers appear both in
    /// `RecentOutfitHistoryBuilder`'s bucketing logic and in `StylistBrain`'s
    /// prompt prose ("last 7 days" / "8-14 days"), so they live once here.
    enum Rotation {
        /// A whole-outfit combination worn within this many days is a hard
        /// avoid — see `StylistBrain`'s OUTFIT ROTATION section.
        static let hardAvoidWindowDays = 7
        /// A combination worn up to this many days ago is soft-penalized
        /// (deprioritized, not blocked). Beyond this window, no penalty.
        static let softPenalizeWindowDays = 14
    }

    /// Item-Level Feedback's `itemSuitability` tier
    /// (`Domain/StylistBrain.swift`, 2026-07-27). Same rationale as the two
    /// groups above: the tier's prompt prose names the situations a note
    /// bites in ("an interview, wedding, or formal-event outfit", "a
    /// cold-weather outfit") and `OutfitRecommendationEngine.outfitScore`
    /// enforces the matching numbers, so they live once here.
    enum ItemSuitability {
        /// A scenario whose required formality floor is at or above this is
        /// "dressed up" for the purposes of an `ItemNoteContext.formalOccasions`
        /// note. Sits above the smart-casual band so an ordinary
        /// smart-casual request isn't treated as a formal one.
        static let formalOccasionFormalityFloor: Double = 3.5
        /// Below this, a `coldWeather` note applies — matches `outfitScore`'s
        /// existing cold threshold so "cold" means one thing in this file.
        static let coldTemperatureFahrenheit: Double = 50
        /// Above this, a `hotWeather` note applies.
        static let hotTemperatureFahrenheit: Double = 80
        /// Score penalty when a note's context matches the request. Sized
        /// between the weather penalty (0.15) and the whole-outfit dislike
        /// penalty (0.25): a garment the user has explicitly complained about
        /// in exactly this situation is a stronger signal than a generic
        /// fabric-weight mismatch, but weaker than having rejected the entire
        /// combination before.
        static let contextMatchPenalty: Double = 0.2
        /// Penalty for an `extendedWear` note, which has no external trigger
        /// to gate on and so applies to every outfit containing the item.
        /// Deliberately small for that reason — it is always on.
        static let extendedWearPenalty: Double = 0.05
    }
}
