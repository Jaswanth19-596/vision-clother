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

    /// Multi-Accessory Outfits (Stylist Intelligence Engine ADR, closed
    /// 2026-07-15): the LLM occasionally sends more supplementary
    /// accessories than the schema's `maxItems` permits (a schema violation
    /// on the model's part, not something to hard-reject the whole outfit
    /// over) — extras beyond the cap are silently dropped rather than
    /// failing the outfit.
    private static let maxSupplementaryAccessories = FashionKnowledgeConstants.DressCode.maxSupplementaryAccessories

    /// Validates and re-scores every outfit in `response`, dropping any that
    /// fail a hard check. An empty result signals the caller to fall back to
    /// `Domain/OutfitRecommendationEngine.generateCandidates`.
    ///
    /// - Parameter mustIncludeItemID: Prospective Purchase Evaluation
    ///   (2026-07-15) — when set, any surviving outfit that doesn't actually
    ///   reference this id (in any slot or as a supplementary accessory) is
    ///   dropped too. `nil` (the default) is every ordinary recommendation
    ///   call, which has no such requirement.
    static func validate(
        _ response: OutfitRecommendationResponse,
        index: [String: WardrobeItem],
        constraints: StyleConstraints? = nil,
        profile: UserStyleProfile? = nil,
        weather: WeatherContext? = nil,
        history: FeedbackHistory = FeedbackHistory(),
        mustIncludeItemID: UUID? = nil
    ) -> [OutfitCombination] {
        validateVerbose(
            response, index: index, constraints: constraints, profile: profile, weather: weather, history: history,
            mustIncludeItemID: mustIncludeItemID
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
        history: FeedbackHistory = FeedbackHistory(),
        mustIncludeItemID: UUID? = nil
    ) -> (valid: [OutfitCombination], rejections: [RejectionReason]) {
        var combinations: [OutfitCombination] = []
        var rejections: [RejectionReason] = []

        // The wardrobe's real slot coverage (Domain/WardrobeCatalogBuilder.swift
        // excludes ghosts before building `index`, so this is exactly what the
        // LLM's catalog offered it). A required slot absent here means the
        // catalog had nothing valid to fill it with — `resolve` treats that as
        // "not owned yet," not as a rejection-worthy LLM error.
        let availableSlots = Set(index.values.map(\.slot))

        for wire in response.outfits {
            switch resolve(wire, index: index, availableSlots: availableSlots) {
            case .success(let combo):
                combinations.append(combo)
            case .failure(let reason):
                rejections.append(reason)
            }
        }

        // Prospective Purchase Evaluation: a hard structural drop, applied
        // before scoring — an outfit that omits the one item this whole
        // request exists to evaluate is useless output regardless of how
        // well it would otherwise score.
        if let mustIncludeItemID {
            combinations = combinations.filter { combo in
                combo.items.contains { $0.id == mustIncludeItemID }
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
    ///
    /// A required slot (top/bottom/footwear, `Slot.isRequired`) missing or
    /// unresolvable is only a hard rejection when `availableSlots` says the
    /// wardrobe actually had a candidate for it — i.e. the LLM had a real
    /// option and either skipped it or sent a garbage id. When the wardrobe
    /// has zero real items in that slot, there was nothing valid to offer,
    /// so the slot is simply left absent from `itemsBySlot` (same treatment
    /// as an ordinary optional slot) instead of failing the whole outfit.
    private static func resolve(
        _ wire: RecommendedOutfitWire, index: [String: WardrobeItem], availableSlots: Set<Slot>
    ) -> Result<OutfitCombination, RejectionReason> {
        var itemsBySlot: [Slot: WardrobeItem] = [:]

        for slot in Slot.allCases {
            guard let idString = wire.itemIDsBySlot[slot] else {
                if slot.isRequired && availableSlots.contains(slot) {
                    return .failure(.unknownID(slot: slot))
                }
                continue
            }
            switch item(for: idString, expectedSlot: slot, index: index) {
            case .failure(let reason):
                if case .unknownID = reason, !availableSlots.contains(slot) {
                    continue
                }
                return .failure(reason)
            case .success(let resolved): itemsBySlot[slot] = resolved
            }
        }

        // Multi-Accessory Outfits: a separate, explicit step alongside the
        // generic per-slot loop above (not woven into it) — every other
        // slot stays singular, this is the one deliberate additive
        // exception (Domain/CLAUDE.md's guardrail against ad hoc per-slot
        // special-casing is about the generic Slot.allCases loop itself,
        // which is unchanged here).
        var supplementaryAccessories: [WardrobeItem] = []
        for idString in wire.supplementaryAccessoryIDs.prefix(maxSupplementaryAccessories) {
            switch item(for: idString, expectedSlot: .accessory, index: index) {
            case .failure(let reason): return .failure(reason)
            case .success(let resolved): supplementaryAccessories.append(resolved)
            }
        }

        let usedIDs = itemsBySlot.values.map(\.id) + supplementaryAccessories.map(\.id)
        guard Set(usedIDs).count == usedIDs.count else { return .failure(.duplicateID) }

        let structured = StructuredRationale(
            summary: wire.rationale.summary,
            confidence: wire.rationale.confidence
        )

        // Score is a placeholder here — `validate`/`validateVerbose`
        // always overwrite it via `OutfitRecommendationEngine.outfitScore`
        // before returning, so this initial value never reaches a caller.
        return .success(OutfitCombination(
            itemsBySlot: itemsBySlot,
            score: 0,
            structuredRationale: structured,
            supplementaryAccessories: supplementaryAccessories
        ))
    }

    private static func item(for idString: String, expectedSlot: Slot, index: [String: WardrobeItem]) -> Result<WardrobeItem, RejectionReason> {
        guard let item = index[idString] else { return .failure(.unknownID(slot: expectedSlot)) }
        guard !item.isGhostElement else { return .failure(.ghostElement(slot: expectedSlot)) }
        guard item.slot == expectedSlot else { return .failure(.wrongSlot(slot: expectedSlot)) }
        return .success(item)
    }
}
