//
//  WardrobeCatalogBuilder.swift
//  Vision_clother
//
//  Builds the bounded wardrobe catalog sent to the recommendation LLM
//  (PRD.md §3.7, the 2026-07-10 LLM-as-Recommender reversal — see
//  docs/decisions/resolved-v1.md). This is the deterministic gate that keeps
//  the payload small and text-only: Ghost Elements are excluded (the LLM
//  should only pick items the user actually owns), descriptions are
//  truncated, and an oversized inventory is prefiltered before truncation
//  rather than silently dropped in insertion order.
//
//  Pure, no I/O (Domain/CLAUDE.md). Returns both the serializable catalog
//  entries and an `id -> WardrobeItem` index so
//  `Domain/OutfitRecommendationValidator.swift` can map the LLM's picks back
//  to real items without re-querying the repository.
//

import Foundation
import os

/// Compact, snake_case-keyed catalog entry — the *only* per-item shape sent
/// to the recommendation LLM. Never includes image data.
struct CatalogEntry: Codable, Equatable {
    var id: String
    var slot: Slot
    var formality: Double
    var colorCategory: ColorVibe
    var primaryHex: String
    var secondaryHex: String?
    var undertone: Undertone?
    var pattern: GarmentPattern
    var seasonality: [Season]
    var fabricWeight: FabricWeight
    var description: String?

    // Rich styling attributes (added 2026-07-10)
    var garmentSubtype: String?
    var fit: String?
    var silhouette: String?
    var material: String?
    var texture: String?

    /// 0-100 aggregate of past user feedback on this exact item (same score
    /// `Domain/ItemRatingScoring.swift` computes for the Closet UI's rating
    /// badge — a freshly uploaded item with no feedback yet naturally reads
    /// as a neutral 50, not a special "unrated" value). `nil` only when no
    /// `FeedbackHistory` was supplied to `build` at all. Lets the LLM avoid
    /// re-recommending a specific item the user has rated poorly, which the
    /// validator/deterministic engine could previously only correct for
    /// *after* the LLM had already picked it.
    var userRating: Int?

    /// Prospective Purchase Evaluation (2026-07-15): true for the single
    /// catalog entry (if any) representing an item the user is considering
    /// buying — not yet saved to their closet. `StylistBrain`'s prompt
    /// instructs the model to build every outfit around this item, and
    /// `Domain/OutfitRecommendationValidator.swift`'s `mustIncludeItemID`
    /// deterministically enforces it. `false` for every ordinary catalog
    /// entry (the vast majority of calls to `build` never set this at all).
    var isProspectivePurchase: Bool = false

    enum CodingKeys: String, CodingKey {
        case id
        case slot
        case formality
        case colorCategory = "color_category"
        case primaryHex = "primary_hex"
        case secondaryHex = "secondary_hex"
        case undertone
        case pattern
        case seasonality
        case fabricWeight = "fabric_weight"
        case description
        case garmentSubtype = "garment_subtype"
        case fit
        case silhouette
        case material
        case texture
        case userRating = "user_rating"
        case isProspectivePurchase = "is_prospective_purchase"
    }
}

enum WardrobeCatalogBuilder {
    /// Default cap on catalog size — bounds recommendation-call payload size
    /// and cost regardless of how large the user's closet grows.
    static let defaultMaxItems = 150
    /// Matches the vision-tagging prompt's own limit
    /// (`Services/VisionMetadataExtractionService.swift`).
    static let defaultDescriptionCharLimit = 140

    /// Builds the bounded catalog + its `id -> WardrobeItem` index.
    ///
    /// - Ghost Elements are always excluded — the LLM should only ever
    ///   choose items the user actually owns.
    /// - When the real (non-ghost) inventory exceeds `maxItems`, it's
    ///   deterministically prefiltered (season + formality against
    ///   `fallbackConstraints`, when provided) and then slot-balanced —
    ///   evenly capped per slot rather than dropping later slots entirely —
    ///   so every required slot still has candidates.
    /// - Prospective Purchase Evaluation: when `prospectiveItemID` matches an
    ///   item in `inventory`, that item's catalog entry is flagged
    ///   (`isProspectivePurchase`) and is guaranteed to survive both the
    ///   constraints prefilter and the `maxItems` cap — the whole point of
    ///   this catalog build is to evaluate that specific item, so it can
    ///   never be the one thing silently dropped for space. `inventory`
    ///   itself may include an item that was never `repository.save`d (e.g.
    ///   a photo the user is only considering buying); this builder has no
    ///   opinion on persistence, it just needs the id to match.
    static func build(
        from inventory: [WardrobeItem],
        constraints: StyleConstraints? = nil,
        maxItems: Int = defaultMaxItems,
        descriptionCharLimit: Int = defaultDescriptionCharLimit,
        history: FeedbackHistory? = nil,
        prospectiveItemID: UUID? = nil
    ) -> (entries: [CatalogEntry], index: [String: WardrobeItem]) {
        let ghostCount = inventory.filter(\.isGhostElement).count
        var candidates = inventory.filter { !$0.isGhostElement }

        if let constraints {
            let prefiltered = candidates.filter {
                $0.seasonality.contains(constraints.seasonSuitability)
                    && constraints.formalityRange.contains($0.formalityScore, tolerance: 0.5)
            }
            // Only apply the prefilter if it leaves enough to work with —
            // an overly narrow constraint shouldn't starve the catalog.
            if !prefiltered.isEmpty {
                candidates = prefiltered
            } else {
                MLLog.logger.notice("catalogBuild: constraints prefilter would leave 0 items, skipped")
            }
        }

        let prospectiveItem = prospectiveItemID.flatMap { id in inventory.first { $0.id == id } }
        if let prospectiveItem, !candidates.contains(where: { $0.id == prospectiveItem.id }) {
            candidates.append(prospectiveItem)
        }

        if candidates.count > maxItems {
            if let prospectiveItem {
                let rest = candidates.filter { $0.id != prospectiveItem.id }
                candidates = [prospectiveItem] + slotBalancedSample(rest, maxItems: maxItems - 1, history: history)
            } else {
                candidates = slotBalancedSample(candidates, maxItems: maxItems, history: history)
            }
        }

        var index: [String: WardrobeItem] = [:]
        index.reserveCapacity(candidates.count)

        let entries: [CatalogEntry] = candidates.map { item in
            let idString = item.id.uuidString
            index[idString] = item
            return CatalogEntry(
                id: idString,
                slot: item.slot,
                formality: item.formalityScore,
                colorCategory: item.colorProfile.category,
                primaryHex: item.colorProfile.primaryHex,
                secondaryHex: item.colorProfile.secondaryHex,
                undertone: item.colorProfile.undertone,
                pattern: item.pattern,
                seasonality: item.seasonality,
                fabricWeight: item.fabricWeight,
                description: truncate(item.itemDescription, to: descriptionCharLimit),
                garmentSubtype: item.garmentSubtype,
                fit: item.fit,
                silhouette: item.silhouette,
                material: item.material,
                texture: item.texture,
                userRating: history.map { ItemRatingScoring.score(for: item.id, history: $0) },
                isProspectivePurchase: item.id == prospectiveItemID
            )
        }

        MLLog.logger.notice("catalogBuild: inventory=\(inventory.count) ghostExcluded=\(ghostCount) entries=\(entries.count) prospectiveItem=\(prospectiveItemID != nil)")
        return (entries, index)
    }

    /// Caps each slot's share of `maxItems` roughly evenly, so a closet
    /// dominated by e.g. tops can't crowd out bottoms/footwear/outerwear
    /// entirely when the overall inventory exceeds the cap. Within a slot,
    /// survivors are chosen by learned visual-taste ranking (`rank(_:history:)`)
    /// rather than arbitrary insertion order — the embedding-ranked catalog
    /// retrieval half of the swipe-deck plan.
    private static func slotBalancedSample(_ items: [WardrobeItem], maxItems: Int, history: FeedbackHistory?) -> [WardrobeItem] {
        let bySlot = Dictionary(grouping: items, by: \.slot)
        let slotCount = max(bySlot.count, 1)
        let perSlot = max(maxItems / slotCount, 1)

        var sampled: [WardrobeItem] = []
        for (_, slotItems) in bySlot {
            let ranked = rank(slotItems, history: history)
            sampled.append(contentsOf: ranked.prefix(perSlot))
        }
        return Array(sampled.prefix(maxItems))
    }

    /// Orders one slot's candidates by learned visual-taste affinity,
    /// descending, before `slotBalancedSample` caps to `perSlot` — items with
    /// no cached embedding (no photo yet) or with no learned taste at all
    /// score a neutral 0 via `VisualPreferenceProfile.affinityBonus`, so a
    /// cold-start profile leaves every item at the same rank. Swift's `sorted`
    /// is a stable sort, so in that case this is a byte-for-byte no-op versus
    /// the original insertion order — the ranking only ever *breaks* ties
    /// once real taste data exists, never reorders in its absence.
    private static func rank(_ items: [WardrobeItem], history: FeedbackHistory?) -> [WardrobeItem] {
        guard let history else { return items }

        // Verification/logging (see docs/decisions/stylist-intelligence-engine.md):
        // only worth emitting once real taste data exists — a cold-start
        // profile scores every item 0, which would just be noise.
        let isTrainedProfile = !history.visualProfile.likedCentroids.isEmpty
            || !history.visualProfile.dislikedCentroids.isEmpty
        if isTrainedProfile {
            for item in items {
                let bonus = history.visualProfile.affinityBonus(forEmbedding: history.itemEmbeddings[item.id])
                MLLog.logger.debug("[AI-Stylist-ML] visual affinity: item=\(item.id, privacy: .public) slot=\(item.slot.rawValue, privacy: .public) bonus=\(bonus, format: .fixed(precision: 3), privacy: .public)")
            }
        }

        return items.sorted { a, b in
            let scoreA = history.visualProfile.affinityBonus(forEmbedding: history.itemEmbeddings[a.id])
            let scoreB = history.visualProfile.affinityBonus(forEmbedding: history.itemEmbeddings[b.id])
            return scoreA > scoreB
        }
    }

    private static func truncate(_ text: String?, to limit: Int) -> String? {
        guard let text, !text.isEmpty else { return nil }
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }
}
