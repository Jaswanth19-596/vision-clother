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
        profile: UserStyleProfile? = nil,
        attributeProfile: AttributePreferenceProfile = AttributePreferenceProfile()
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

        // Taste hints (Unified Preference Engine, 2026-07-24): the user's
        // strongest learned color vibe / material / style, if any — used to
        // steer *what* to buy toward their taste, so a structural gap is
        // filled in the direction that improves their style rather than a
        // generic neutral. Empty/cold-start profile => `nil`, and every gap
        // below falls back to its original taste-free phrasing.
        let preferredVibe = topPreferred(attributeProfile.colorVibeAffinity, min: 0.55)
        let preferredMaterial = topPreferred(attributeProfile.materialAffinity, min: 0.6)
        let tasteClause = preferredTasteClause(vibe: preferredVibe, material: preferredMaterial)

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
                    description: "You have only \(minReq.count) \(minReq.slot.rawValue)\(minReq.count == 1 ? "" : "s") compared to \(maxReqCount) in your largest essential category. This severely restricts combination variety.\(tasteClause)",
                    priority: priority,
                    category: .bottleneck,
                    suggestedSlot: minReq.slot,
                    targetSeason: nil,
                    targetFormalityBand: nil,
                    targetColorVibe: preferredVibe
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

        // 5. Preferred Style Underrepresented (Unified Preference Engine,
        // 2026-07-24): a style the user has clearly demonstrated they love
        // (learned affinity > 0.6, from ratings AND swipes) but owns almost
        // nothing in — the highest-leverage "buy this to improve your style"
        // signal, since it's grounded in their own taste rather than pure
        // structural balance. Only the single strongest such style, to avoid
        // burying the structural gaps.
        let ownedStyleTags = realItems.reduce(into: [String: Int]()) { counts, item in
            for tag in item.styleTags { counts[tag, default: 0] += 1 }
        }
        let underrepresentedStyle = attributeProfile.styleTagAffinity
            .filter { $0.value > 0.6 && (ownedStyleTags[$0.key] ?? 0) < 2 }
            .max(by: { $0.value < $1.value })?.key
        if let underrepresentedStyle {
            let owned = ownedStyleTags[underrepresentedStyle] ?? 0
            gaps.append(ClosetGap(
                id: "preferred-style-\(underrepresentedStyle)",
                title: "Lean Into Your \(underrepresentedStyle.capitalized) Side",
                description: "You consistently rate and swipe toward \"\(underrepresentedStyle)\" pieces, but own \(owned == 0 ? "none" : "just \(owned)"). Adding a \(underrepresentedStyle) piece\(tasteClause) is the highest-impact way to build the look you keep reaching for.",
                priority: .recommended,
                category: .colorPalette,
                suggestedSlot: .top,
                targetSeason: nil,
                targetFormalityBand: nil,
                targetColorVibe: preferredVibe
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

    /// Strongest-affinity key above `min` (0.5 = neutral), or `nil` when the
    /// profile is cold-start or has no clear lean — so taste hints only ever
    /// *add* direction, never fabricate one.
    private static func topPreferred<Key: Hashable>(_ map: [Key: Double], min: Double) -> Key? {
        map.filter { $0.value >= min }.max(by: { $0.value < $1.value })?.key
    }

    /// A trailing sentence fragment naming the user's go-to vibe/material, or
    /// "" when nothing is learned yet. Kept as one place so every gap's
    /// description phrases the taste hint identically.
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
