//
//  OutfitRecommendationValidator.swift
//  Vision_clother
//
//  Validation gate for the primary recommendation LLM call (PRD.md §2.1a,
//  the 2026-07-10 LLM-as-Recommender reversal — see
//  docs/decisions/resolved-v1.md). This is the deterministic guarantee that
//  no outfit surfaced to the user can reference a garment they don't own: it
//  hard-rejects any pick with an unknown/malformed id, a wrong slot, a
//  duplicated id across slots, or a Ghost Element, then re-scores survivors
//  with the existing Pair-Compatibility Scoring Engine (now color-harmony-
//  aware, see `Domain/ColorHarmony.swift`) so ranking stays consistent with
//  the deterministic fallback path.
//
//  Pure, no I/O (Domain/CLAUDE.md) — calls
//  `Domain/OutfitRecommendationEngine.outfitScore(for:history:)` but never
//  modifies that file or its tests; this module only consumes it.
//

import Foundation

enum OutfitRecommendationValidator {
    /// Validates and re-scores every outfit in `response`, dropping any that
    /// fail a hard check. An empty result signals the caller to fall back to
    /// `Domain/OutfitRecommendationEngine.generateCandidates`.
    static func validate(
        _ response: OutfitRecommendationResponse,
        index: [String: WardrobeItem],
        history: FeedbackHistory = FeedbackHistory()
    ) -> [OutfitCombination] {
        let combinations: [OutfitCombination] = response.outfits.compactMap { wire in
            resolve(wire, index: index)
        }

        let scored = combinations.map { combo -> OutfitCombination in
            var combo = combo
            combo.score = OutfitRecommendationEngine.outfitScore(for: combo.items, history: history)
            return combo
        }

        return scored.sorted { $0.score > $1.score }
    }

    /// Resolves one wire outfit into a validated `OutfitCombination`, or
    /// `nil` if any hard check fails:
    /// - every referenced id must parse to a real, non-ghost item;
    /// - each id must resolve to an item in the slot it was placed in
    ///   (`top_id` -> `.top`, etc.);
    /// - no id may be reused across slots in the same outfit.
    private static func resolve(_ wire: RecommendedOutfitWire, index: [String: WardrobeItem]) -> OutfitCombination? {
        guard let top = item(for: wire.topID, expectedSlot: .top, index: index),
              let bottom = item(for: wire.bottomID, expectedSlot: .bottom, index: index),
              let footwear = item(for: wire.footwearID, expectedSlot: .footwear, index: index)
        else {
            return nil
        }

        var outerwear: WardrobeItem? = nil
        if let outerwearID = wire.outerwearID {
            guard let resolved = item(for: outerwearID, expectedSlot: .outerwear, index: index) else {
                return nil
            }
            outerwear = resolved
        }

        let usedIDs = [top.id, bottom.id, footwear.id] + (outerwear.map { [$0.id] } ?? [])
        guard Set(usedIDs).count == usedIDs.count else { return nil }

        // Score is a placeholder here — `validate(_:index:history:)` always
        // overwrites it via `OutfitRecommendationEngine.outfitScore` before
        // returning, so this initial value never reaches a caller.
        return OutfitCombination(
            top: top,
            bottom: bottom,
            footwear: footwear,
            outerwear: outerwear,
            score: 0,
            rationale: wire.rationale
        )
    }

    private static func item(for idString: String, expectedSlot: Slot, index: [String: WardrobeItem]) -> WardrobeItem? {
        guard let item = index[idString], !item.isGhostElement, item.slot == expectedSlot else { return nil }
        return item
    }
}
