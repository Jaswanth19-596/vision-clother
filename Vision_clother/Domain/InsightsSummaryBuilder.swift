//
//  InsightsSummaryBuilder.swift
//  Vision_clother
//
//  Wardrobe/Insights Q&A (2026-07-20): condenses the same pure aggregators
//  that power `Features/Insights/` (Overview, Colors, Wardrobe, Shopping,
//  Style DNA — Trends is deliberately excluded, time-series data doesn't
//  compress usefully into static prompt text) into compact prose for
//  `Services/StylistQAService.swift`'s dedicated, separate prompt. Reuses
//  each aggregator's already-computed human-readable strings
//  (`Discovery.text`, `ShoppingSuggestion.text`, `DimensionScore.why`,
//  `StyleColorSnapshot.whyInsight`) instead of re-deriving new phrasing —
//  every number here still traces back to the same real rows the Insights
//  tab reads, per that layer's "never an invented metric" convention.
//
//  Pure, no I/O (Domain/CLAUDE.md) — the caller (`DailyAssistantViewModel`)
//  fetches the rows via `WardrobeRepository` and passes them in.
//

import Foundation

enum InsightsSummaryBuilder {
    static func buildSummaryText(
        inventory: [WardrobeItem],
        itemRatings: [ItemRating],
        outfitFeedbacks: [OutfitFeedback],
        wornLogEntries: [WornLogEntry],
        savedCombinations: [SavedCombination],
        attributeProfile: AttributePreferenceProfile,
        thresholds: AnalyticsConfigResponse = .conservativeDefault,
        now: Date = .now
    ) -> String {
        let realItems = inventory.filter { !$0.isGhostElement }
        guard !realItems.isEmpty else {
            return "The user's wardrobe is currently empty — there is no Insights data to report yet."
        }
        let itemsByID = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })
        func label(_ id: UUID) -> String { itemsByID[id]?.displayLabel ?? "an item no longer in the closet" }

        let overview = AnalyticsAggregator.buildOverview(
            inventory: inventory,
            itemRatings: itemRatings,
            outfitFeedbacks: outfitFeedbacks,
            wornLogEntries: wornLogEntries,
            timeRange: .allTime,
            now: now
        )
        let colorSnapshot = ColorInsightsAggregator.buildStyleColorSnapshot(
            inventory: inventory,
            savedCombinations: savedCombinations,
            colorVibeAffinity: attributeProfile.colorVibeAffinity,
            ratingSampleSize: overview.ratingSampleSize,
            thresholds: thresholds,
            comboTimeRange: .allTime,
            now: now
        )
        let wardrobeSnapshot = WardrobeInsightsAggregator.buildSnapshot(
            inventory: inventory,
            wornLogEntries: wornLogEntries,
            thresholds: thresholds
        )
        let shoppingSnapshot = ShoppingInsightsAggregator.buildSnapshot(
            inventory: inventory,
            wardrobeSnapshot: wardrobeSnapshot
        )
        let styleDNA = StyleDNAScorer.buildSnapshot(
            attributeProfile: attributeProfile,
            itemRatings: itemRatings,
            outfitFeedbacks: outfitFeedbacks,
            wornLogEntries: wornLogEntries,
            ratingSampleSize: overview.ratingSampleSize,
            thresholds: thresholds
        )

        var sections: [String?] = []
        sections.append(overviewSection(overview))
        sections.append(colorsSection(colorSnapshot))
        sections.append(wardrobeSection(wardrobeSnapshot, label: label))
        sections.append(shoppingSection(shoppingSnapshot))
        sections.append(styleDNASection(styleDNA))

        return sections.compactMap { $0 }.joined(separator: "\n\n")
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private static func overviewSection(_ overview: AnalyticsAggregator.OverviewSnapshot) -> String? {
        var lines: [String] = []
        if let styleSummary = overview.styleSummary { lines.append(styleSummary) }
        if !overview.topColors.isEmpty {
            lines.append("Color mix by item count: " + overview.topColors.prefix(6).map {
                "\($0.colorVibe.rawValue) \(percent($0.percentage))"
            }.joined(separator: ", "))
        }
        if !overview.topCategories.isEmpty {
            lines.append("Category mix: " + overview.topCategories.map {
                "\($0.slot.rawValue) x\($0.count)"
            }.joined(separator: ", "))
        }
        lines.append(contentsOf: overview.discoveries.map(\.text))
        guard !lines.isEmpty else { return nil }
        return "OVERVIEW:\n" + lines.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func colorsSection(_ snapshot: ColorInsightsAggregator.StyleColorSnapshot) -> String? {
        var lines: [String] = []
        if !snapshot.primarySwatches.isEmpty {
            lines.append("Most common exact shades owned: " + snapshot.primarySwatches.prefix(5).map {
                "\($0.hex) (\($0.count) items)"
            }.joined(separator: ", "))
        }
        let lightness = snapshot.lightness
        if lightness.total > 0 {
            lines.append("Lightness mix: dark \(percent(lightness.darkPercentage)), medium \(percent(lightness.mediumPercentage)), light \(percent(lightness.lightPercentage))")
        }
        if !snapshot.undertones.isEmpty {
            lines.append("Undertone mix: " + snapshot.undertones.map {
                "\($0.undertone?.rawValue.capitalized ?? "Unknown") \(percent($0.percentage))"
            }.joined(separator: ", "))
        }
        if !snapshot.seasonalColors.isEmpty {
            lines.append("Colors by season: " + snapshot.seasonalColors.map { seasonal in
                "\(seasonal.season.rawValue): " + seasonal.topColors.map(\.colorVibe.rawValue).joined(separator: "/")
            }.joined(separator: "; "))
        }
        if snapshot.accentUsage.total > 0 {
            lines.append("Accessorizes with a bag/headwear/accessory in \(percent(snapshot.accentUsage.withAccentPercentage)) of saved outfits.")
        }
        if !snapshot.combos.isEmpty {
            lines.append("Most-repeated color pairings in saved outfits: " + snapshot.combos.prefix(3).map {
                "\($0.colorA.rawValue)+\($0.colorB.rawValue)"
            }.joined(separator: ", "))
        }
        if let why = snapshot.whyInsight { lines.append(why) }
        guard !lines.isEmpty else { return nil }
        return "COLORS:\n" + lines.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func wardrobeSection(
        _ snapshot: WardrobeInsightsAggregator.WardrobeInsightsSnapshot,
        label: (UUID) -> String
    ) -> String? {
        var lines: [String] = ["Total real (non-ghost) items: \(snapshot.totalRealItems)."]
        if !snapshot.hasEnoughItems {
            lines.append("Wardrobe is still small — utilization/redundancy stats aren't unlocked yet.")
        } else {
            if let rate = snapshot.utilizationRate {
                lines.append("Utilization: \(percent(rate)) of the closet has a logged wear.")
            } else {
                lines.append("Not enough logged wears yet to compute utilization.")
            }
            if !snapshot.mostWorn.isEmpty {
                lines.append("Most-worn: " + snapshot.mostWorn.prefix(5).map { "\(label($0.itemID)) (\($0.wearCount)x)" }.joined(separator: ", "))
            }
            if !snapshot.leastWorn.isEmpty {
                lines.append("Never logged as worn: " + snapshot.leastWorn.prefix(5).map(\.itemID).map(label).joined(separator: ", "))
            }
            if !snapshot.redundantGroups.isEmpty {
                lines.append("Possible duplicate groups (same slot/color/pattern): " + snapshot.redundantGroups.prefix(3).map {
                    "\($0.itemIDs.count)x \($0.pattern.rawValue) \($0.colorVibe.rawValue) \($0.slot.rawValue)"
                }.joined(separator: "; "))
            }
            if !snapshot.slotBalance.isEmpty {
                lines.append("Balance by category: " + snapshot.slotBalance.map { "\($0.slot.rawValue) \(percent($0.percentage))" }.joined(separator: ", "))
            }
            if let bottleneck = snapshot.bottleneckSlot {
                lines.append("Thinnest essential category: \(bottleneck.rawValue) — this caps how many complete outfits the wardrobe can produce.")
            }
        }
        return "WARDROBE:\n" + lines.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func shoppingSection(_ snapshot: ShoppingInsightsAggregator.ShoppingInsightsSnapshot) -> String? {
        guard snapshot.hasEnoughItems, !snapshot.suggestions.isEmpty else { return nil }
        let lines = snapshot.suggestions.map(\.text)
        return "SHOPPING SUGGESTIONS:\n" + lines.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func styleDNASection(_ snapshot: StyleDNAScorer.StyleDNASnapshot) -> String? {
        guard snapshot.isUnlocked, !snapshot.dimensions.isEmpty else {
            return "STYLE DNA:\n- Not enough ratings yet to compute this — tell the user to keep rating items/outfits to unlock it."
        }
        let lines = snapshot.dimensions.map { "\($0.name): \(Int($0.score))/100 — \($0.why)" }
        return "STYLE DNA (0-100 per spectrum, 50 = neutral):\n" + lines.map { "- \($0)" }.joined(separator: "\n")
    }
}
