//
//  ClosetGapAnalyzer.swift
//  Vision_clother
//
//  Analytics & Insights — Closet Gap Analysis Engine.
//  Pure, NaN-safe domain aggregator (Domain/CLAUDE.md).
//  Analyzes wardrobe inventory across 4 structural dimensions:
//  1. Essential Slot Bottlenecks (Top/Bottom/Footwear balance)
//  2. Seasonal Coverage Gaps (Zero or low items for essential slots in specific seasons)
//  3. Formality & Occasion Alignment (Casual vs Smart-Casual vs Formal coverage)
//  4. Color Palette & Neutral Anchor Coverage (Recommended profile colors)
//

import Foundation
import os

enum GapPriority: String, Codable, Comparable {
    case critical
    case recommended
    case optional

    private var sortOrder: Int {
        switch self {
        case .critical: return 0
        case .recommended: return 1
        case .optional: return 2
        }
    }

    static func < (lhs: GapPriority, rhs: GapPriority) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

enum GapCategory: String, Codable {
    case bottleneck
    case seasonal
    case formality
    case colorPalette
}

struct ClosetGap: Identifiable, Equatable {
    let id: String
    let title: String
    let description: String
    let priority: GapPriority
    let category: GapCategory
    let suggestedSlot: Slot
    let targetSeason: Season?
    let targetFormalityBand: String?
    let targetColorVibe: ColorVibe?
}

struct ClosetGapReport: Equatable {
    let gaps: [ClosetGap]
    let healthScore: Int // 0 to 100
    let totalRealItems: Int
    let seasonalCoveragePercent: Int
    let formalityBalancePercent: Int
    let hasEnoughItems: Bool
}

enum ClosetGapAnalyzer {
    private static let requiredSlots = Slot.allCases.filter(\.isRequired)
    private static let minItemsForAnalysis = 3

    static func analyze(
        inventory: [WardrobeItem],
        profile: UserStyleProfile? = nil
    ) -> ClosetGapReport {
        let realItems = inventory.filter { !$0.isGhostElement }
        guard realItems.count >= minItemsForAnalysis else {
            return ClosetGapReport(
                gaps: [],
                healthScore: 50,
                totalRealItems: realItems.count,
                seasonalCoveragePercent: 0,
                formalityBalancePercent: 0,
                hasEnoughItems: false
            )
        }

        var gaps: [ClosetGap] = []

        // 1. Essential Slot Bottlenecks
        let countsBySlot = Dictionary(grouping: realItems, by: \.slot).mapValues(\.count)
        let reqCounts = requiredSlots.map { (slot: $0, count: countsBySlot[$0] ?? 0) }
        let maxReqCount = reqCounts.map(\.count).max() ?? 1
        let minReqItem = reqCounts.min(by: { $0.count < $1.count })

        if let minReq = minReqItem, minReq.count < maxReqCount {
            let diff = maxReqCount - minReq.count
            if diff >= 2 || minReq.count == 0 {
                let priority: GapPriority = minReq.count == 0 ? .critical : .recommended
                gaps.append(ClosetGap(
                    id: "bottleneck-\(minReq.slot.rawValue)",
                    title: "Essential Category Shortage: \(minReq.slot.rawValue.capitalized)",
                    description: "You have only \(minReq.count) \(minReq.slot.rawValue)\(minReq.count == 1 ? "" : "s") compared to \(maxReqCount) in your largest essential category. This severely restricts combination variety.",
                    priority: priority,
                    category: .bottleneck,
                    suggestedSlot: minReq.slot,
                    targetSeason: nil,
                    targetFormalityBand: nil,
                    targetColorVibe: nil
                ))
            }
        }

        // 2. Seasonal Coverage Gaps
        var totalSeasonSlotPairs = 0
        var coveredSeasonSlotPairs = 0
        for season in Season.allCases {
            for slot in requiredSlots {
                totalSeasonSlotPairs += 1
                let count = realItems.filter { $0.slot == slot && $0.seasonality.contains(season) }.count
                if count == 0 {
                    let seasonLabel = formatSeason(season)
                    gaps.append(ClosetGap(
                        id: "seasonal-\(season.rawValue)-\(slot.rawValue)",
                        title: "Missing \(seasonLabel) \(slot.rawValue.capitalized)",
                        description: "You have zero \(slot.rawValue)s tagged for \(seasonLabel). Adding one will unlock outfits when weather shifts.",
                        priority: .critical,
                        category: .seasonal,
                        suggestedSlot: slot,
                        targetSeason: season,
                        targetFormalityBand: nil,
                        targetColorVibe: nil
                    ))
                } else {
                    coveredSeasonSlotPairs += 1
                }
            }
        }
        let seasonalCoveragePercent = totalSeasonSlotPairs > 0
            ? Int((Double(coveredSeasonSlotPairs) / Double(totalSeasonSlotPairs) * 100).rounded())
            : 100

        // 3. Formality & Occasion Alignment
        var casualCount = 0
        var smartCasualCount = 0
        var formalCount = 0
        for item in realItems {
            switch item.formalityScore {
            case ..<2.0: casualCount += 1
            case 2.0..<3.5: smartCasualCount += 1
            default: formalCount += 1
            }
        }
        let totalItems = Double(realItems.count)
        let casualShare = Double(casualCount) / totalItems
        let smartCasualShare = Double(smartCasualCount) / totalItems

        let formalityBalancePercent = Int(((1.0 - abs(casualShare - 0.4) - abs(smartCasualShare - 0.4)) * 100).clamped(to: 0...100))

        if smartCasualCount == 0 && realItems.count >= 5 {
            gaps.append(ClosetGap(
                id: "formality-smart-casual",
                title: "Smart-Casual Void",
                description: "Your wardrobe is split between extreme casual and formal. Adding smart-casual pieces improves versatile daily pairing.",
                priority: .recommended,
                category: .formality,
                suggestedSlot: .top,
                targetSeason: nil,
                targetFormalityBand: "Smart-Casual",
                targetColorVibe: nil
            ))
        }

        // 4. Color Palette & Neutral Anchor Coverage
        let neutralCount = realItems.filter { $0.colorProfile.category == .neutral || $0.colorProfile.category == .monochrome }.count
        let neutralShare = Double(neutralCount) / totalItems
        if neutralShare < 0.3 {
            gaps.append(ClosetGap(
                id: "color-neutral-anchor",
                title: "Lack of Neutral Anchor Pieces",
                description: "Only \(Int(neutralShare * 100))% of your closet features neutral or monochrome colors. Neutral bottoms or tops make vibrant pieces easier to pair.",
                priority: .recommended,
                category: .colorPalette,
                suggestedSlot: .bottom,
                targetSeason: nil,
                targetFormalityBand: nil,
                targetColorVibe: .neutral
            ))
        }

        // Calculate Overall Health Score
        var penalty = 0
        for gap in gaps {
            switch gap.priority {
            case .critical: penalty += 15
            case .recommended: penalty += 8
            case .optional: penalty += 4
            }
        }
        let healthScore = max(100 - penalty, 20)

        let sortedGaps = gaps.sorted { $0.priority < $1.priority }

        AnalyticsLog.logger.notice("[GapAnalysis] completed: items=\(realItems.count, privacy: .public) gaps=\(sortedGaps.count, privacy: .public) health=\(healthScore, privacy: .public)")

        return ClosetGapReport(
            gaps: sortedGaps,
            healthScore: healthScore,
            totalRealItems: realItems.count,
            seasonalCoveragePercent: seasonalCoveragePercent,
            formalityBalancePercent: formalityBalancePercent,
            hasEnoughItems: true
        )
    }

    private static func formatSeason(_ season: Season) -> String {
        switch season {
        case .summer: return "Summer"
        case .springFall: return "Spring/Fall"
        case .winter: return "Winter"
        }
    }
}
