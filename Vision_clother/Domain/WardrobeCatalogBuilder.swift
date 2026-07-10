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
    static func build(
        from inventory: [WardrobeItem],
        constraints: StyleConstraints? = nil,
        maxItems: Int = defaultMaxItems,
        descriptionCharLimit: Int = defaultDescriptionCharLimit
    ) -> (entries: [CatalogEntry], index: [String: WardrobeItem]) {
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
            }
        }

        if candidates.count > maxItems {
            candidates = slotBalancedSample(candidates, maxItems: maxItems)
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
                texture: item.texture
            )
        }

        return (entries, index)
    }

    /// Caps each slot's share of `maxItems` roughly evenly, so a closet
    /// dominated by e.g. tops can't crowd out bottoms/footwear/outerwear
    /// entirely when the overall inventory exceeds the cap.
    private static func slotBalancedSample(_ items: [WardrobeItem], maxItems: Int) -> [WardrobeItem] {
        let bySlot = Dictionary(grouping: items, by: \.slot)
        let slotCount = max(bySlot.count, 1)
        let perSlot = max(maxItems / slotCount, 1)

        var sampled: [WardrobeItem] = []
        for (_, slotItems) in bySlot {
            sampled.append(contentsOf: slotItems.prefix(perSlot))
        }
        return Array(sampled.prefix(maxItems))
    }

    private static func truncate(_ text: String?, to limit: Int) -> String? {
        guard let text, !text.isEmpty else { return nil }
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }
}
