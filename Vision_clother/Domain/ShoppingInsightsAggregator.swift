//
//  ShoppingInsightsAggregator.swift
//  Vision_clother
//
//  Analytics & Insights, Phase 9 — Shopping Insights, folded into the
//  Wardrobe sub-tab per the Phase 1 plan ("shopping suggestions are derived
//  directly from wardrobe balance"). Pure, NaN-safe (Domain/CLAUDE.md).
//  Every suggestion here is a literal count-based fact — zero real items
//  for a season+slot combination, the already-computed bottleneck slot from
//  `Domain/WardrobeInsightsAggregator.swift`, or an already-computed
//  redundant group — never a guess at what the user "needs" or "would
//  like." Takes Phase 8's `WardrobeInsightsSnapshot` as input rather than
//  recomputing wear counts/redundancy itself.
//

import Foundation
import os

enum ShoppingInsightsAggregator {
    struct SeasonalGap: Identifiable, Equatable {
        let season: Season
        let slot: Slot
        var id: String { "\(season.rawValue)-\(slot.rawValue)" }
    }

    struct ShoppingSuggestion: Identifiable, Equatable {
        let id: String
        let text: String
    }

    struct ShoppingInsightsSnapshot: Equatable {
        let seasonalGaps: [SeasonalGap]
        let suggestions: [ShoppingSuggestion]
        let hasEnoughItems: Bool
    }

    private static let maxSuggestions = 4
    /// Seasonal-gap detection is scoped to the 3 slots every outfit needs
    /// (`Slot.isRequired`) — a missing headwear/accessory/bag item isn't a
    /// structural gap the same way a missing top/bottom/footwear is.
    private static let requiredSlots = Slot.allCases.filter(\.isRequired)
    /// A redundant group only becomes a "don't overbuy" suggestion once it
    /// has at least this many items and a clear unworn tail.
    private static let minRedundantGroupSize = 3

    static func buildSnapshot(
        inventory: [WardrobeItem],
        wardrobeSnapshot: WardrobeInsightsAggregator.WardrobeInsightsSnapshot,
        attributeProfile: AttributePreferenceProfile = AttributePreferenceProfile()
    ) -> ShoppingInsightsSnapshot {
        guard wardrobeSnapshot.hasEnoughItems else {
            return ShoppingInsightsSnapshot(seasonalGaps: [], suggestions: [], hasEnoughItems: false)
        }

        let realItems = inventory.filter { !$0.isGhostElement }
        let seasonalGaps = findSeasonalGaps(items: realItems)

        // Taste hint (Unified Preference Engine, 2026-07-24): steer *what* to
        // buy toward the user's strongest learned color vibe / material so a
        // structural gap gets filled in their taste. Empty at cold start, in
        // which case every suggestion keeps its original taste-free phrasing.
        let tasteClause = preferredTasteClause(
            vibe: topPreferred(attributeProfile.colorVibeAffinity, min: 0.55),
            material: topPreferred(attributeProfile.materialAffinity, min: 0.6)
        )

        var suggestions: [ShoppingSuggestion] = []

        for gap in seasonalGaps.prefix(2) {
            suggestions.append(ShoppingSuggestion(
                id: "gap-\(gap.id)",
                text: "You have no \(gap.slot.rawValue) items tagged for \(seasonLabel(gap.season)) — worth adding one before the season shifts.\(tasteClause)"
            ))
        }

        if let bottleneck = wardrobeSnapshot.bottleneckSlot {
            let count = wardrobeSnapshot.slotBalance.first { $0.slot == bottleneck }?.count ?? 0
            suggestions.append(ShoppingSuggestion(
                id: "bottleneck-\(bottleneck.rawValue)",
                text: "Consider adding \(bottleneck.rawValue) — you only have \(count), the fewest of your essential categories, which limits your outfit combinations.\(tasteClause)"
            ))
        }

        if wardrobeSnapshot.hasEnoughWearData,
           let largestGroup = wardrobeSnapshot.redundantGroups.first,
           largestGroup.itemIDs.count >= minRedundantGroupSize {
            let colorLabel = largestGroup.colorVibe.rawValue.replacingOccurrences(of: "_", with: " ")
            suggestions.append(ShoppingSuggestion(
                id: "dont-overbuy-\(largestGroup.id)",
                text: "You already own \(largestGroup.itemIDs.count) similar \(largestGroup.pattern.rawValue) \(colorLabel) \(largestGroup.slot.rawValue)s — before buying another, revisit the ones you already have."
            ))
        }

        let snapshot = ShoppingInsightsSnapshot(
            seasonalGaps: seasonalGaps,
            suggestions: Array(suggestions.prefix(maxSuggestions)),
            hasEnoughItems: true
        )

        AnalyticsLog.logger.notice("[Insights] shopping built: gaps=\(seasonalGaps.count, privacy: .public) suggestions=\(snapshot.suggestions.count, privacy: .public)")

        return snapshot
    }

    private static func findSeasonalGaps(items: [WardrobeItem]) -> [SeasonalGap] {
        var counts: [SeasonalGap: Int] = [:]
        for season in Season.allCases {
            for slot in requiredSlots {
                counts[SeasonalGap(season: season, slot: slot)] = 0
            }
        }
        for item in items where requiredSlots.contains(item.slot) {
            for season in item.seasonality {
                let key = SeasonalGap(season: season, slot: item.slot)
                counts[key, default: 0] += 1
            }
        }
        return counts
            .filter { $0.value == 0 }
            .map(\.key)
            .sorted { ($0.season.rawValue, $0.slot.rawValue) < ($1.season.rawValue, $1.slot.rawValue) }
    }

    private static func seasonLabel(_ season: Season) -> String {
        switch season {
        case .summer: return "summer"
        case .springFall: return "spring/fall"
        case .winter: return "winter"
        }
    }

    /// Strongest-affinity key above `min` (0.5 = neutral), or `nil` at cold
    /// start — taste hints only ever *add* direction, never fabricate one.
    /// Mirrors `ClosetGapAnalyzer`'s helper of the same shape.
    private static func topPreferred<Key: Hashable>(_ map: [Key: Double], min: Double) -> Key? {
        map.filter { $0.value >= min }.max(by: { $0.value < $1.value })?.key
    }

    private static func preferredTasteClause(vibe: ColorVibe?, material: String?) -> String {
        let vibeText = vibe.map { $0.rawValue.replacingOccurrences(of: "_", with: " ") }
        switch (vibeText, material) {
        case let (vibe?, material?):
            return " Ideally in your go-to \(vibe) tones and a material like \(material.lowercased())."
        case let (vibe?, nil):
            return " Ideally in your go-to \(vibe) tones."
        case let (nil, material?):
            return " Ideally in a material you favor, like \(material.lowercased())."
        case (nil, nil):
            return ""
        }
    }
}

extension ShoppingInsightsAggregator.SeasonalGap: Hashable {}
