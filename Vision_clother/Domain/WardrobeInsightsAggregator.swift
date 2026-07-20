//
//  WardrobeInsightsAggregator.swift
//  Vision_clother
//
//  Analytics & Insights, Phase 8 — Wardrobe Insights (utilization,
//  unused/redundant items, closet balance). Pure, NaN-safe (Domain/CLAUDE.md)
//  aggregation over `WardrobeItem` + `WornLogEntry` only — every stat here
//  traces to a real logged wear or a real attribute match, never an
//  invented score. Utilization/most-worn/least-worn are all gated on
//  `AnalyticsConfigResponse.wardrobeInsightsMinWornLogs`, the config field
//  made exactly for this — without enough logged wears, "you've never worn
//  60% of your closet" would just mean "you haven't opened the app's wear
//  logger much," not a real usage pattern.
//

import Foundation
import os

enum WardrobeInsightsAggregator {
    struct ItemUtilization: Identifiable, Equatable {
        let itemID: UUID
        let wearCount: Int
        var id: UUID { itemID }
    }

    /// Items sharing the same slot + color vibe + pattern — a real
    /// attribute-duplication signal, not an invented similarity score.
    /// `itemIDs` is sorted most-worn first (ties broken by wear count
    /// descending), so the view can call out which items in the group
    /// actually get worn.
    struct RedundantGroup: Identifiable, Equatable {
        let slot: Slot
        let colorVibe: ColorVibe
        let pattern: GarmentPattern
        let itemIDs: [UUID]
        var id: String { "\(slot.rawValue)-\(colorVibe.rawValue)-\(pattern.rawValue)" }
    }

    struct SlotBalance: Identifiable, Equatable {
        let slot: Slot
        let count: Int
        let percentage: Double
        var id: String { slot.rawValue }
    }

    struct WardrobeInsightsSnapshot: Equatable {
        let totalRealItems: Int
        /// `nil` when `hasEnoughWearData` is `false` — never a misleading
        /// 0%/low number computed from too little logging.
        let utilizationRate: Double?
        let mostWorn: [ItemUtilization]
        let leastWorn: [ItemUtilization]
        let redundantGroups: [RedundantGroup]
        let slotBalance: [SlotBalance]
        /// The required slot (top/bottom/footwear, `Slot.isRequired`) with
        /// the fewest items — this is what actually caps how many complete
        /// outfits the wardrobe can produce, so it's the most actionable
        /// single balance callout. `nil` when there aren't enough items yet
        /// to make the claim meaningful.
        let bottleneckSlot: Slot?
        let hasEnoughItems: Bool
        let hasEnoughWearData: Bool
    }

    private static let maxListSize = 5

    static func buildSnapshot(
        inventory: [WardrobeItem],
        wornLogEntries: [WornLogEntry],
        thresholds: AnalyticsConfigResponse
    ) -> WardrobeInsightsSnapshot {
        let realItems = inventory.filter { !$0.isGhostElement }
        let hasEnoughItems = realItems.count >= thresholds.wardrobeInsightsMinItems
        let hasEnoughWearData = wornLogEntries.count >= thresholds.wardrobeInsightsMinWornLogs

        var wearCounts: [UUID: Int] = [:]
        for entry in wornLogEntries {
            for itemID in entry.itemIDs {
                wearCounts[itemID, default: 0] += 1
            }
        }

        let utilizations = realItems.map { ItemUtilization(itemID: $0.id, wearCount: wearCounts[$0.id] ?? 0) }

        let utilizationRate: Double?
        let mostWorn: [ItemUtilization]
        let leastWorn: [ItemUtilization]
        if hasEnoughWearData, !realItems.isEmpty {
            let wornCount = utilizations.filter { $0.wearCount > 0 }.count
            utilizationRate = Double(wornCount) / Double(realItems.count)
            mostWorn = utilizations.filter { $0.wearCount > 0 }.sorted { $0.wearCount > $1.wearCount }.prefix(maxListSize).map { $0 }
            leastWorn = utilizations.filter { $0.wearCount == 0 }.prefix(maxListSize).map { $0 }
        } else {
            utilizationRate = nil
            mostWorn = []
            leastWorn = []
        }

        let redundantGroups = buildRedundantGroups(items: realItems, wearCounts: wearCounts)

        let slotBalance = AnalyticsAggregator.shareBreakdown(
            of: realItems.map(\.slot),
            total: realItems.count
        ).map { SlotBalance(slot: $0.value, count: $0.count, percentage: $0.percentage) }

        let bottleneckSlot: Slot?
        if hasEnoughItems {
            let countsBySlot = Dictionary(uniqueKeysWithValues: slotBalance.map { ($0.slot, $0.count) })
            bottleneckSlot = Slot.allCases
                .filter(\.isRequired)
                .min { (countsBySlot[$0] ?? 0, $0.rawValue) < (countsBySlot[$1] ?? 0, $1.rawValue) }
        } else {
            bottleneckSlot = nil
        }

        let snapshot = WardrobeInsightsSnapshot(
            totalRealItems: realItems.count,
            utilizationRate: utilizationRate,
            mostWorn: mostWorn,
            leastWorn: leastWorn,
            redundantGroups: redundantGroups,
            slotBalance: slotBalance,
            bottleneckSlot: bottleneckSlot,
            hasEnoughItems: hasEnoughItems,
            hasEnoughWearData: hasEnoughWearData
        )

        AnalyticsLog.logger.notice("[Insights] wardrobe built: items=\(realItems.count, privacy: .public) redundantGroups=\(redundantGroups.count, privacy: .public) enoughWear=\(hasEnoughWearData, privacy: .public)")

        return snapshot
    }

    private static func buildRedundantGroups(items: [WardrobeItem], wearCounts: [UUID: Int]) -> [RedundantGroup] {
        struct Key: Hashable {
            let slot: Slot
            let colorVibe: ColorVibe
            let pattern: GarmentPattern
        }

        var groups: [Key: [WardrobeItem]] = [:]
        for item in items {
            let key = Key(slot: item.slot, colorVibe: item.colorProfile.category, pattern: item.pattern)
            groups[key, default: []].append(item)
        }

        return groups
            .compactMap { key, groupItems -> RedundantGroup? in
                guard groupItems.count >= 2 else { return nil }
                let sortedIDs = groupItems
                    .sorted { (wearCounts[$0.id] ?? 0) > (wearCounts[$1.id] ?? 0) }
                    .map(\.id)
                return RedundantGroup(slot: key.slot, colorVibe: key.colorVibe, pattern: key.pattern, itemIDs: sortedIDs)
            }
            .sorted { $0.itemIDs.count > $1.itemIDs.count }
            .prefix(maxListSize)
            .map { $0 }
    }
}
