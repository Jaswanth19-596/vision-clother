//
//  AnalyticsAggregator.swift
//  Vision_clother
//
//  Analytics & Insights, Phase 4 — Overview tab. Pure, NaN-safe aggregation
//  over data that's already local (`WardrobeItem`, `ItemRating`,
//  `OutfitFeedback`, `WornLogEntry`) per the Phase 1 plan's "compute
//  on-device" decision — no server round trip, no invented metrics.
//  Deliberately does not report wardrobe-growth ("N items added this
//  period"): `WardrobeItem` has no acquisition-date field, and adding one
//  just to synthesize a stat is out of scope for this phase (see the Phase 4
//  plan's scope note). Every number here traces back to a real timestamped
//  row; nothing is estimated.
//
//  Follows the isolation rules in Domain/CLAUDE.md: no UIKit/SwiftUI
//  imports, NaN-safe for empty input, mockable by construction (plain
//  functions over value types, no singletons).
//

import Foundation
import os

enum AnalyticsAggregator {
    struct ColorShare: Identifiable, Equatable {
        let colorVibe: ColorVibe
        let count: Int
        let percentage: Double
        var id: String { colorVibe.rawValue }
    }

    struct CategoryShare: Identifiable, Equatable {
        let slot: Slot
        let count: Int
        let percentage: Double
        var id: String { slot.rawValue }
    }

    struct ActivityDelta: Equatable {
        let currentCount: Int
        let previousCount: Int

        /// `nil` when there's nothing to compare (`.allTime` range, or both
        /// periods empty) — the caller shows a neutral state rather than a
        /// misleading "+0%".
        var change: Int? {
            guard previousCount > 0 || currentCount > 0 else { return nil }
            return currentCount - previousCount
        }
    }

    struct Discovery: Identifiable, Equatable {
        let id: String
        let text: String
    }

    struct OverviewSnapshot: Equatable {
        /// Current wardrobe composition by color — not time-windowed (a
        /// `WardrobeItem` has no acquisition date), sorted descending,
        /// highest share first.
        let topColors: [ColorShare]
        /// Current wardrobe composition by slot, same sort order.
        let topCategories: [CategoryShare]
        let ratingActivity: ActivityDelta
        let wearLogActivity: ActivityDelta
        /// One glanceable sentence describing the wardrobe's composition —
        /// `nil` when the wardrobe is empty.
        let styleSummary: String?
        /// Up to 3 short natural-language highlights, most relevant first —
        /// empty when there isn't enough real data yet to say anything.
        let discoveries: [Discovery]
        /// `itemRatings.count + detailedOutfitFeedbacks.count` — the sample
        /// size backing `ratingActivity`/rating-derived discoveries, for
        /// `Domain/AnalyticsConfidence.swift` banding.
        let ratingSampleSize: Int
        let wearLogSampleSize: Int
    }

    /// Composition highlight is only worth surfacing as a discovery once a
    /// single color/slot dominates the wardrobe by a clear margin — below
    /// this share, "your top color is X" reads as noise on a fairly balanced
    /// closet.
    private static let dominantShareThreshold = 0.4

    static func buildOverview(
        inventory: [WardrobeItem],
        itemRatings: [ItemRating],
        outfitFeedbacks: [OutfitFeedback],
        wornLogEntries: [WornLogEntry],
        timeRange: AnalyticsTimeRange,
        now: Date = .now
    ) -> OverviewSnapshot {
        let realItems = inventory.filter { !$0.isGhostElement }

        let topColors = shareBreakdown(
            of: realItems.map(\.colorProfile.category),
            total: realItems.count
        ).map { ColorShare(colorVibe: $0.value, count: $0.count, percentage: $0.percentage) }

        let topCategories = shareBreakdown(
            of: realItems.map(\.slot),
            total: realItems.count
        ).map { CategoryShare(slot: $0.value, count: $0.count, percentage: $0.percentage) }

        let currentInterval = timeRange.currentInterval(now: now)
        let previousInterval = timeRange.previousInterval(now: now)

        // Detailed outfit ratings only — a bare auto-recorded "liked" save
        // isn't a deliberate rating action, same distinction
        // `Data/WardrobeRepository.fetchFeedbackHistory()` draws via
        // `normalizedRating != nil`.
        let detailedOutfitFeedbacks = outfitFeedbacks.filter { $0.normalizedRating != nil }

        let ratingDatesCurrent = itemRatings.filter { currentInterval.contains($0.recordedAt) }.count
            + detailedOutfitFeedbacks.filter { currentInterval.contains($0.recordedAt) }.count
        let ratingDatesPrevious = previousInterval.map { interval in
            itemRatings.filter { interval.contains($0.recordedAt) }.count
                + detailedOutfitFeedbacks.filter { interval.contains($0.recordedAt) }.count
        } ?? 0
        let ratingActivity = ActivityDelta(currentCount: ratingDatesCurrent, previousCount: ratingDatesPrevious)

        let wearsCurrent = wornLogEntries.filter { currentInterval.contains($0.wornAt) }.count
        let wearsPrevious = previousInterval.map { interval in
            wornLogEntries.filter { interval.contains($0.wornAt) }.count
        } ?? 0
        let wearLogActivity = ActivityDelta(currentCount: wearsCurrent, previousCount: wearsPrevious)

        let styleSummary = buildStyleSummary(topColors: topColors, topCategories: topCategories)
        let discoveries = buildDiscoveries(
            ratingActivity: ratingActivity,
            wearLogActivity: wearLogActivity,
            topColors: topColors,
            hasPreviousPeriod: previousInterval != nil
        )

        let snapshot = OverviewSnapshot(
            topColors: topColors,
            topCategories: topCategories,
            ratingActivity: ratingActivity,
            wearLogActivity: wearLogActivity,
            styleSummary: styleSummary,
            discoveries: discoveries,
            ratingSampleSize: itemRatings.count + detailedOutfitFeedbacks.count,
            wearLogSampleSize: wornLogEntries.count
        )

        AnalyticsLog.logger.notice("[Insights] overview built: items=\(realItems.count, privacy: .public) ratingSample=\(snapshot.ratingSampleSize, privacy: .public) wearSample=\(snapshot.wearLogSampleSize, privacy: .public) discoveries=\(discoveries.count, privacy: .public)")

        return snapshot
    }

    /// Generic count-and-sort-descending helper shared by the color and
    /// category breakdowns — NaN-safe: `total == 0` short-circuits to an
    /// empty array rather than dividing by zero. Not `private`: also reused
    /// by `Domain/ColorInsightsAggregator.swift`'s category breakdown, so
    /// the count/sort/percentage logic lives once.
    static func shareBreakdown<Value: Hashable>(
        of values: [Value],
        total: Int
    ) -> [(value: Value, count: Int, percentage: Double)] {
        guard total > 0 else { return [] }
        var counts: [Value: Int] = [:]
        for value in values {
            counts[value, default: 0] += 1
        }
        return counts
            .map { (value: $0.key, count: $0.value, percentage: Double($0.value) / Double(total)) }
            .sorted { $0.count > $1.count }
    }

    private static func buildStyleSummary(topColors: [ColorShare], topCategories: [CategoryShare]) -> String? {
        guard let leadColor = topColors.first, let leadCategory = topCategories.first else { return nil }
        let colorLabel = leadColor.colorVibe.rawValue.replacingOccurrences(of: "_", with: " ")
        let categoryLabel = leadCategory.slot.rawValue

        if leadColor.percentage >= dominantShareThreshold {
            return "Your closet leans \(colorLabel), with \(categoryLabel)s making up the largest share of your wardrobe."
        }
        return "Your closet is a mix of colors, with \(categoryLabel)s making up the largest share of your wardrobe."
    }

    private static func buildDiscoveries(
        ratingActivity: ActivityDelta,
        wearLogActivity: ActivityDelta,
        topColors: [ColorShare],
        hasPreviousPeriod: Bool
    ) -> [Discovery] {
        var discoveries: [Discovery] = []

        if hasPreviousPeriod, let change = ratingActivity.change, ratingActivity.currentCount > 0 {
            let text: String
            if change > 0 {
                text = "You've rated \(ratingActivity.currentCount) outfit\(ratingActivity.currentCount == 1 ? "" : "s") this period — \(change) more than last period."
            } else if change < 0 {
                text = "You've rated \(ratingActivity.currentCount) outfit\(ratingActivity.currentCount == 1 ? "" : "s") this period, down from \(ratingActivity.previousCount) last period."
            } else {
                text = "You've rated \(ratingActivity.currentCount) outfit\(ratingActivity.currentCount == 1 ? "" : "s") this period, same as last period."
            }
            discoveries.append(Discovery(id: "ratingActivity", text: text))
        }

        if hasPreviousPeriod, let change = wearLogActivity.change, wearLogActivity.currentCount > 0 {
            let text: String
            if change > 0 {
                text = "You've logged \(wearLogActivity.currentCount) wear\(wearLogActivity.currentCount == 1 ? "" : "s") this period — \(change) more than last period."
            } else if change < 0 {
                text = "You've logged \(wearLogActivity.currentCount) wear\(wearLogActivity.currentCount == 1 ? "" : "s") this period, down from \(wearLogActivity.previousCount) last period."
            } else {
                text = "You've logged \(wearLogActivity.currentCount) wear\(wearLogActivity.currentCount == 1 ? "" : "s") this period, same as last period."
            }
            discoveries.append(Discovery(id: "wearActivity", text: text))
        }

        if let leadColor = topColors.first, leadColor.percentage >= dominantShareThreshold {
            let colorLabel = leadColor.colorVibe.rawValue.replacingOccurrences(of: "_", with: " ")
            let percent = Int((leadColor.percentage * 100).rounded())
            discoveries.append(Discovery(id: "dominantColor", text: "\(percent)% of your wardrobe is \(colorLabel)-toned."))
        }

        return Array(discoveries.prefix(3))
    }
}
