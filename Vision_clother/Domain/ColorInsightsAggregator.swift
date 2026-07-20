//
//  ColorInsightsAggregator.swift
//  Vision_clother
//
//  Analytics & Insights, Phase 5 — Favorite Colors (Style sub-tab, highest
//  spec priority). Pure, NaN-safe (Domain/CLAUDE.md) aggregation over real
//  wardrobe/combination data only — no invented metrics. Reuses
//  `Domain/ColorHarmony.swift`'s existing HSL parser for the dark/light
//  split (no new luminance math) and `AnalyticsAggregator.shareBreakdown`
//  for the count/sort/percentage shape every breakdown here shares.
//
//  Composition sections (swatches, dark/light, warm/cool, seasonal,
//  primary/accent) are current-wardrobe snapshots — `WardrobeItem` has no
//  acquisition date, so there's nothing to time-window there (same scope
//  cut as `Domain/AnalyticsAggregator.swift`'s Overview). Only Favorite
//  Combos, drawn from `SavedCombination.savedAt`, is time-windowed.
//

import Foundation
import os

enum ColorInsightsAggregator {
    struct SwatchShare: Identifiable, Equatable {
        let hex: String
        let count: Int
        let percentage: Double
        var id: String { hex }
    }

    struct LightnessBreakdown: Equatable {
        let darkCount: Int
        let mediumCount: Int
        let lightCount: Int
        let total: Int

        var darkPercentage: Double { total > 0 ? Double(darkCount) / Double(total) : 0 }
        var mediumPercentage: Double { total > 0 ? Double(mediumCount) / Double(total) : 0 }
        var lightPercentage: Double { total > 0 ? Double(lightCount) / Double(total) : 0 }
    }

    struct UndertoneShare: Identifiable, Equatable {
        /// `nil` = undertone not tagged (pre-2026-07-10 items or manual
        /// entry) — reported as "Unknown," never silently dropped.
        let undertone: Undertone?
        let count: Int
        let percentage: Double
        var id: String { undertone?.rawValue ?? "unknown" }
    }

    struct SeasonalColors: Identifiable, Equatable {
        let season: Season
        let topColors: [AnalyticsAggregator.ColorShare]
        var id: String { season.rawValue }
    }

    struct AccentUsage: Equatable {
        let withAccentCount: Int
        let withoutAccentCount: Int
        let total: Int
        let topAccentSwatches: [SwatchShare]

        var withAccentPercentage: Double { total > 0 ? Double(withAccentCount) / Double(total) : 0 }
    }

    struct ComboShare: Identifiable, Equatable {
        let colorA: ColorVibe
        let colorB: ColorVibe
        let count: Int
        let percentage: Double
        var id: String { "\(colorA.rawValue)-\(colorB.rawValue)" }
    }

    struct StyleColorSnapshot: Equatable {
        let primarySwatches: [SwatchShare]
        let categoryBreakdown: [AnalyticsAggregator.ColorShare]
        let lightness: LightnessBreakdown
        let undertones: [UndertoneShare]
        let seasonalColors: [SeasonalColors]
        let accentUsage: AccentUsage
        /// Windowed by the caller-supplied `comboTimeRange` — the only
        /// section of this snapshot that is.
        let combos: [ComboShare]
        /// `nil` when there isn't enough rating data yet to make a taste
        /// claim, or the wardrobe is empty — never a guessed insight.
        let whyInsight: String?
    }

    /// A color category needs to clear this share of the closet before a
    /// combo/ownership claim about it is worth surfacing — mirrors
    /// `Domain/AnalyticsAggregator.dominantShareThreshold`'s reasoning.
    private static let wellRepresentedThreshold = 0.25
    /// Affinity strictly above neutral 0.5 by this much before a color is
    /// treated as a genuine taste signal rather than noise.
    private static let meaningfulAffinityThreshold = 0.6

    static func buildStyleColorSnapshot(
        inventory: [WardrobeItem],
        savedCombinations: [SavedCombination],
        colorVibeAffinity: [ColorVibe: Double],
        ratingSampleSize: Int,
        thresholds: AnalyticsConfigResponse,
        comboTimeRange: AnalyticsTimeRange,
        now: Date = .now
    ) -> StyleColorSnapshot {
        let realItems = inventory.filter { !$0.isGhostElement }

        let primarySwatches = swatchBreakdown(hexes: realItems.map(\.colorProfile.primaryHex))
        let categoryBreakdown = AnalyticsAggregator.shareBreakdown(
            of: realItems.map(\.colorProfile.category),
            total: realItems.count
        ).map { AnalyticsAggregator.ColorShare(colorVibe: $0.value, count: $0.count, percentage: $0.percentage) }

        let lightness = lightnessBreakdown(items: realItems)
        let undertones = undertoneBreakdown(items: realItems)
        let seasonalColors = Season.allCases.compactMap { season -> SeasonalColors? in
            let seasonItems = realItems.filter { $0.seasonality.contains(season) }
            guard !seasonItems.isEmpty else { return nil }
            let top = AnalyticsAggregator.shareBreakdown(
                of: seasonItems.map(\.colorProfile.category),
                total: seasonItems.count
            ).prefix(2).map { AnalyticsAggregator.ColorShare(colorVibe: $0.value, count: $0.count, percentage: $0.percentage) }
            return SeasonalColors(season: season, topColors: Array(top))
        }

        let accentUsage = buildAccentUsage(items: realItems)

        let itemsByID = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })
        let combos = favoriteCombos(
            savedCombinations: savedCombinations,
            itemsByID: itemsByID,
            interval: comboTimeRange.currentInterval(now: now)
        )

        let whyInsight = buildWhyInsight(
            categoryBreakdown: categoryBreakdown,
            colorVibeAffinity: colorVibeAffinity,
            ratingSampleSize: ratingSampleSize,
            thresholds: thresholds
        )

        let snapshot = StyleColorSnapshot(
            primarySwatches: primarySwatches,
            categoryBreakdown: categoryBreakdown,
            lightness: lightness,
            undertones: undertones,
            seasonalColors: seasonalColors,
            accentUsage: accentUsage,
            combos: combos,
            whyInsight: whyInsight
        )

        AnalyticsLog.logger.notice("[Insights] style colors built: items=\(realItems.count, privacy: .public) swatches=\(primarySwatches.count, privacy: .public) combos=\(combos.count, privacy: .public)")

        return snapshot
    }

    private static func swatchBreakdown(hexes: [String]) -> [SwatchShare] {
        guard !hexes.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for hex in hexes {
            let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            counts[normalized, default: 0] += 1
        }
        let total = hexes.count
        return counts
            .map { SwatchShare(hex: $0.key, count: $0.value, percentage: Double($0.value) / Double(total)) }
            .sorted { $0.count > $1.count }
    }

    /// Buckets by HSL lightness (`Domain/ColorHarmony.swift`'s existing
    /// parser) — malformed hex is skipped from the bucket counts entirely
    /// (there's no honest dark/medium/light label to give it), so `total`
    /// here can be less than `items.count`.
    private static func lightnessBreakdown(items: [WardrobeItem]) -> LightnessBreakdown {
        var dark = 0, medium = 0, light = 0
        for item in items {
            guard let hsl = ColorHarmony.hsl(fromHex: item.colorProfile.primaryHex) else { continue }
            if hsl.l < 0.35 { dark += 1 }
            else if hsl.l > 0.65 { light += 1 }
            else { medium += 1 }
        }
        return LightnessBreakdown(darkCount: dark, mediumCount: medium, lightCount: light, total: dark + medium + light)
    }

    private static func undertoneBreakdown(items: [WardrobeItem]) -> [UndertoneShare] {
        guard !items.isEmpty else { return [] }
        var counts: [Undertone?: Int] = [:]
        for item in items {
            counts[item.colorProfile.undertone, default: 0] += 1
        }
        let total = items.count
        return counts
            .map { UndertoneShare(undertone: $0.key, count: $0.value, percentage: Double($0.value) / Double(total)) }
            .sorted { $0.count > $1.count }
    }

    private static func buildAccentUsage(items: [WardrobeItem]) -> AccentUsage {
        let withAccent = items.filter { ($0.colorProfile.secondaryHex?.isEmpty == false) }
        let topAccentSwatches = swatchBreakdown(hexes: withAccent.compactMap(\.colorProfile.secondaryHex))
        return AccentUsage(
            withAccentCount: withAccent.count,
            withoutAccentCount: items.count - withAccent.count,
            total: items.count,
            topAccentSwatches: Array(topAccentSwatches.prefix(8))
        )
    }

    private struct ComboKey: Hashable {
        let a: ColorVibe
        let b: ColorVibe
    }

    /// Every `SavedCombination` in `interval` is an implicit "I liked this
    /// combo enough to keep it" signal — no separate rating needed. Ghost
    /// elements are excluded (they render from a placeholder color, not a
    /// real garment choice).
    private static func favoriteCombos(
        savedCombinations: [SavedCombination],
        itemsByID: [UUID: WardrobeItem],
        interval: DateInterval
    ) -> [ComboShare] {
        var counts: [ComboKey: Int] = [:]
        var totalCombosConsidered = 0

        for combination in savedCombinations where interval.contains(combination.savedAt) {
            let categories = Set(combination.itemIDsBySlot.values.compactMap { id -> ColorVibe? in
                guard let item = itemsByID[id], !item.isGhostElement else { return nil }
                return item.colorProfile.category
            })
            guard categories.count >= 2 else { continue }
            totalCombosConsidered += 1

            let sorted = categories.sorted { $0.rawValue < $1.rawValue }
            for i in 0..<sorted.count {
                for j in (i + 1)..<sorted.count {
                    counts[ComboKey(a: sorted[i], b: sorted[j]), default: 0] += 1
                }
            }
        }

        guard totalCombosConsidered > 0 else { return [] }
        return counts
            .map { ComboShare(colorA: $0.key.a, colorB: $0.key.b, count: $0.value, percentage: Double($0.value) / Double(totalCombosConsidered)) }
            .sorted { $0.count > $1.count }
    }

    /// Contrasts what the user *owns* (`categoryBreakdown`) against what
    /// they *rate highly* (`colorVibeAffinity`, from the existing
    /// `AttributePreferenceProfile`) — the "why" the spec asks for. Gated on
    /// `thresholds.stillLearningBelowRatings` so this never makes a taste
    /// claim before there's enough rating data to back it.
    private static func buildWhyInsight(
        categoryBreakdown: [AnalyticsAggregator.ColorShare],
        colorVibeAffinity: [ColorVibe: Double],
        ratingSampleSize: Int,
        thresholds: AnalyticsConfigResponse
    ) -> String? {
        guard ratingSampleSize >= thresholds.stillLearningBelowRatings, !categoryBreakdown.isEmpty else { return nil }

        let ownershipByVibe = Dictionary(uniqueKeysWithValues: categoryBreakdown.map { ($0.colorVibe, $0.percentage) })
        guard let topAffinity = colorVibeAffinity
            .filter({ $0.value > meaningfulAffinityThreshold })
            .max(by: { $0.value < $1.value })
        else { return nil }

        let ownershipPct = ownershipByVibe[topAffinity.key] ?? 0
        let colorLabel = topAffinity.key.rawValue.replacingOccurrences(of: "_", with: " ")

        if ownershipPct < wellRepresentedThreshold {
            let percent = Int((ownershipPct * 100).rounded())
            return "\(colorLabel.capitalized) is your highest-rated color, but only \(percent)% of your closet is \(colorLabel)-toned — worth adding more."
        }
        return "\(colorLabel.capitalized) is both your highest-rated color and a strong presence in your closet — a clear signature."
    }
}
