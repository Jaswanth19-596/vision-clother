//
//  TrendsAggregator.swift
//  Vision_clother
//
//  Analytics & Insights, Phase 7 — Style Trends. Pure, NaN-safe (Domain/CLAUDE.md)
//  aggregation over real, timestamped engagement events only:
//  `ItemRating.recordedAt`, detailed `OutfitFeedback.recordedAt` (joined to
//  the items in the `SavedCombination` it rated), and `WornLogEntry.wornAt`
//  — the same three signals `Domain/AnalyticsAggregator.swift`'s Overview
//  activity deltas already draw from. Deliberately tracks *engagement
//  frequency* over time (how often you rated/wore items of a given
//  color/category/pattern/style, per period), not a per-bucket rating
//  average — per-bucket sample sizes here are often tiny, and averaging a
//  handful of stars per bucket would be noisier and less honest than a
//  plain count. `WardrobeItem` has no acquisition date, so wardrobe
//  *composition* itself still isn't time-series data (same scope cut as
//  Phase 4/5); only real per-event timestamps get plotted here.
//

import Foundation
import os

enum TrendsAggregator {
    struct Bucket: Identifiable {
        let id: Int
        let interval: DateInterval
        /// Short x-axis label, e.g. "Jun 1".
        let label: String
    }

    struct SeriesPoint: Identifiable, Equatable {
        var id: String { "\(seriesLabel)-\(bucketIndex)" }
        let bucketIndex: Int
        let bucketLabel: String
        let seriesLabel: String
        let count: Int
    }

    struct TrendChart: Equatable {
        /// Fixed draw order — top `maxSeries` values by total frequency
        /// across the whole interval, most frequent first. Assign chart
        /// color by this order, never re-sorted per bucket.
        let seriesLabels: [String]
        let bucketLabels: [String]
        let points: [SeriesPoint]
        /// Gated on `AnalyticsConfigResponse.trendsMinDataPoints` — `false`
        /// means there's a real chart shape here but too few real events to
        /// be a meaningful trend yet, so the caller shows an honest empty
        /// state instead of a noisy line.
        let hasEnoughData: Bool

        static let empty = TrendChart(seriesLabels: [], bucketLabels: [], points: [], hasEnoughData: false)
    }

    struct TrendsSnapshot: Equatable {
        let colorTrend: TrendChart
        let categoryTrend: TrendChart
        let patternTrend: TrendChart
        let styleTrend: TrendChart
    }

    /// One "you engaged with this item on this date" observation — the
    /// common shape every source (`ItemRating`, detailed `OutfitFeedback`,
    /// `WornLogEntry`) is flattened into before bucketing.
    private struct EngagementEvent {
        let date: Date
        let item: WardrobeItem
    }

    private static let bucketCount = 6
    /// How many top series each chart plots — keeps the legend small and
    /// legible (dataviz skill: a categorical chart with many series folds
    /// the rest into "Other" rather than drawing them all).
    private static let maxSeriesPerChart = 3

    static func buildTrendsSnapshot(
        inventory: [WardrobeItem],
        itemRatings: [ItemRating],
        outfitFeedbacks: [OutfitFeedback],
        wornLogEntries: [WornLogEntry],
        savedCombinations: [SavedCombination],
        timeRange: AnalyticsTimeRange,
        thresholds: AnalyticsConfigResponse,
        now: Date = .now
    ) -> TrendsSnapshot {
        let itemsByID = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })
        let combinationsByID = Dictionary(uniqueKeysWithValues: savedCombinations.map { ($0.id, $0) })

        let events = engagementEvents(
            itemRatings: itemRatings,
            outfitFeedbacks: outfitFeedbacks,
            wornLogEntries: wornLogEntries,
            itemsByID: itemsByID,
            combinationsByID: combinationsByID
        )

        let interval = anchoredInterval(for: timeRange, events: events, now: now)
        let buckets = makeBuckets(spanning: interval)
        let eventsInRange = events.filter { interval.contains($0.date) }
        let hasEnoughData = eventsInRange.count >= thresholds.trendsMinDataPoints

        let colorTrend = buildTrendChart(events: eventsInRange, buckets: buckets, hasEnoughData: hasEnoughData) { $0.colorProfile.category.rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
        let categoryTrend = buildTrendChart(events: eventsInRange, buckets: buckets, hasEnoughData: hasEnoughData) { $0.slot.rawValue.capitalized }
        let patternTrend = buildTrendChart(events: eventsInRange, buckets: buckets, hasEnoughData: hasEnoughData) { $0.pattern.rawValue.capitalized }
        let styleTrend = buildTrendChart(events: eventsInRange, buckets: buckets, hasEnoughData: hasEnoughData, keys: { $0.styleTags })

        AnalyticsLog.logger.notice("[Insights] trends built: events=\(eventsInRange.count, privacy: .public) buckets=\(buckets.count, privacy: .public) enough=\(hasEnoughData, privacy: .public)")

        return TrendsSnapshot(colorTrend: colorTrend, categoryTrend: categoryTrend, patternTrend: patternTrend, styleTrend: styleTrend)
    }

    private static func engagementEvents(
        itemRatings: [ItemRating],
        outfitFeedbacks: [OutfitFeedback],
        wornLogEntries: [WornLogEntry],
        itemsByID: [UUID: WardrobeItem],
        combinationsByID: [UUID: SavedCombination]
    ) -> [EngagementEvent] {
        var events: [EngagementEvent] = []

        for rating in itemRatings {
            guard let item = itemsByID[rating.itemID], !item.isGhostElement else { continue }
            events.append(EngagementEvent(date: rating.recordedAt, item: item))
        }

        let detailedOutfitFeedbacks = outfitFeedbacks.filter { $0.normalizedRating != nil }
        for feedback in detailedOutfitFeedbacks {
            guard let combination = combinationsByID[feedback.outfitID] else { continue }
            for itemID in combination.itemIDsBySlot.values {
                guard let item = itemsByID[itemID], !item.isGhostElement else { continue }
                events.append(EngagementEvent(date: feedback.recordedAt, item: item))
            }
        }

        for entry in wornLogEntries {
            for itemID in entry.itemIDs {
                guard let item = itemsByID[itemID], !item.isGhostElement else { continue }
                events.append(EngagementEvent(date: entry.wornAt, item: item))
            }
        }

        return events
    }

    /// For a fixed-length range, the plain `currentInterval`. For
    /// `.allTime`, anchors the start to the earliest real engagement event
    /// instead of `.distantPast` — an interval spanning back to the Unix
    /// epoch would put every real event in one degenerate final bucket.
    /// Falls back to a 1-year window if there's no data at all (the
    /// `hasEnoughData` gate hides the chart in that case regardless).
    private static func anchoredInterval(for timeRange: AnalyticsTimeRange, events: [EngagementEvent], now: Date) -> DateInterval {
        guard timeRange == .allTime else { return timeRange.currentInterval(now: now) }
        let earliest = events.map(\.date).min() ?? now.addingTimeInterval(-365 * 24 * 60 * 60)
        return DateInterval(start: min(earliest, now), end: now)
    }

    private static func makeBuckets(spanning interval: DateInterval) -> [Bucket] {
        let totalSeconds = max(interval.duration, 1)
        let bucketSeconds = totalSeconds / Double(bucketCount)
        let formatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter
        }()

        return (0..<bucketCount).map { index in
            let start = interval.start.addingTimeInterval(Double(index) * bucketSeconds)
            let end = index == bucketCount - 1 ? interval.end : start.addingTimeInterval(bucketSeconds)
            return Bucket(id: index, interval: DateInterval(start: start, end: end), label: formatter.string(from: start))
        }
    }

    /// `keys` maps one item to every series key it contributes to (e.g. a
    /// single-valued color/slot/pattern via the single-key overload below,
    /// or every `styleTag` an item carries for the style trend, which can
    /// be zero, one, or several).
    private static func buildTrendChart(
        events: [EngagementEvent],
        buckets: [Bucket],
        hasEnoughData: Bool,
        keys: (WardrobeItem) -> [String]
    ) -> TrendChart {
        guard hasEnoughData, !buckets.isEmpty else { return .empty }

        var totalCounts: [String: Int] = [:]
        for event in events {
            for key in keys(event.item) {
                totalCounts[key, default: 0] += 1
            }
        }
        let topSeries = totalCounts
            .sorted { $0.value > $1.value }
            .prefix(maxSeriesPerChart)
            .map(\.key)
        guard !topSeries.isEmpty else { return .empty }
        let topSeriesSet = Set(topSeries)

        var points: [SeriesPoint] = []
        for (bucketIndex, bucket) in buckets.enumerated() {
            var bucketCounts: [String: Int] = [:]
            for event in events where bucket.interval.contains(event.date) {
                for key in keys(event.item) where topSeriesSet.contains(key) {
                    bucketCounts[key, default: 0] += 1
                }
            }
            for series in topSeries {
                points.append(SeriesPoint(
                    bucketIndex: bucketIndex,
                    bucketLabel: bucket.label,
                    seriesLabel: series,
                    count: bucketCounts[series] ?? 0
                ))
            }
        }

        return TrendChart(seriesLabels: topSeries, bucketLabels: buckets.map(\.label), points: points, hasEnoughData: true)
    }

    /// Single-valued convenience over the `keys:` overload above, for
    /// color/category/pattern (each item has exactly one value).
    private static func buildTrendChart(
        events: [EngagementEvent],
        buckets: [Bucket],
        hasEnoughData: Bool,
        key: @escaping (WardrobeItem) -> String
    ) -> TrendChart {
        buildTrendChart(events: events, buckets: buckets, hasEnoughData: hasEnoughData, keys: { [key($0)] })
    }
}
