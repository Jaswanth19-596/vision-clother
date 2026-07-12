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
    /// Why one wire outfit was hard-dropped (Tier A, Stylist Intelligence
    /// Engine ADR §8) — previously a silent `nil` from a `compactMap`. Not
    /// consumed by any caller yet; exists so telemetry/debugging can answer
    /// "why did the LLM path yield nothing" instead of guessing.
    enum RejectionReason: Error, Equatable {
        case unknownID(slot: Slot)
        case wrongSlot(slot: Slot)
        case duplicateID
        case ghostElement(slot: Slot)
    }

    /// Validates and re-scores every outfit in `response`, dropping any that
    /// fail a hard check. An empty result signals the caller to fall back to
    /// `Domain/OutfitRecommendationEngine.generateCandidates`.
    static func validate(
        _ response: OutfitRecommendationResponse,
        index: [String: WardrobeItem],
        constraints: StyleConstraints? = nil,
        profile: UserStyleProfile? = nil,
        weather: WeatherContext? = nil,
        history: FeedbackHistory = FeedbackHistory()
    ) -> [OutfitCombination] {
        validateVerbose(
            response, index: index, constraints: constraints, profile: profile, weather: weather, history: history
        ).valid
    }

    /// Same validation as `validate`, plus the reason each dropped wire
    /// outfit failed — for telemetry/debugging, never for gating behavior.
    static func validateVerbose(
        _ response: OutfitRecommendationResponse,
        index: [String: WardrobeItem],
        constraints: StyleConstraints? = nil,
        profile: UserStyleProfile? = nil,
        weather: WeatherContext? = nil,
        history: FeedbackHistory = FeedbackHistory()
    ) -> (valid: [OutfitCombination], rejections: [RejectionReason]) {
        var combinations: [OutfitCombination] = []
        var rejections: [RejectionReason] = []

        for wire in response.outfits {
            switch resolve(wire, index: index) {
            case .success(let combo):
                combinations.append(combo)
            case .failure(let reason):
                rejections.append(reason)
            }
        }

        let scored = combinations.map { combo -> OutfitCombination in
            var combo = combo
            combo.score = OutfitRecommendationEngine.outfitScore(
                for: combo.items,
                constraints: constraints,
                profile: profile,
                weather: weather,
                history: history
            )
            return combo
        }

        return (scored.sorted { $0.score > $1.score }, rejections)
    }

    /// Resolves one wire outfit into a validated `OutfitCombination`, or the
    /// `RejectionReason` the first failing check hit:
    /// - every referenced id must parse to a real, non-ghost item;
    /// - each id must resolve to an item in the slot it was placed in
    ///   (`top_id` -> `.top`, etc.);
    /// - no id may be reused across slots in the same outfit.
    private static func resolve(_ wire: RecommendedOutfitWire, index: [String: WardrobeItem]) -> Result<OutfitCombination, RejectionReason> {
        switch item(for: wire.topID, expectedSlot: .top, index: index) {
        case .failure(let reason): return .failure(reason)
        case .success(let top):
            switch item(for: wire.bottomID, expectedSlot: .bottom, index: index) {
            case .failure(let reason): return .failure(reason)
            case .success(let bottom):
                switch item(for: wire.footwearID, expectedSlot: .footwear, index: index) {
                case .failure(let reason): return .failure(reason)
                case .success(let footwear):
                    var outerwear: WardrobeItem? = nil
                    if let outerwearID = wire.outerwearID {
                        switch item(for: outerwearID, expectedSlot: .outerwear, index: index) {
                        case .failure(let reason): return .failure(reason)
                        case .success(let resolved): outerwear = resolved
                        }
                    }

                    let usedIDs = [top.id, bottom.id, footwear.id] + (outerwear.map { [$0.id] } ?? [])
                    guard Set(usedIDs).count == usedIDs.count else { return .failure(.duplicateID) }

                    let structured = StructuredRationale(
                        summary: wire.rationale.summary,
                        confidence: wire.rationale.confidence
                    )

                    // Score is a placeholder here — `validate`/`validateVerbose`
                    // always overwrite it via `OutfitRecommendationEngine.outfitScore`
                    // before returning, so this initial value never reaches a caller.
                    return .success(OutfitCombination(
                        top: top,
                        bottom: bottom,
                        footwear: footwear,
                        outerwear: outerwear,
                        score: 0,
                        structuredRationale: structured
                    ))
                }
            }
        }
    }

    private static func item(for idString: String, expectedSlot: Slot, index: [String: WardrobeItem]) -> Result<WardrobeItem, RejectionReason> {
        guard let item = index[idString] else { return .failure(.unknownID(slot: expectedSlot)) }
        guard !item.isGhostElement else { return .failure(.ghostElement(slot: expectedSlot)) }
        guard item.slot == expectedSlot else { return .failure(.wrongSlot(slot: expectedSlot)) }
        return .success(item)
    }
}
