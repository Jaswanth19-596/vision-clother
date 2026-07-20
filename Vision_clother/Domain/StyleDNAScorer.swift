//
//  StyleDNAScorer.swift
//  Vision_clother
//
//  Analytics & Insights, Phase 10 — Style DNA (Style sub-tab, joining
//  Phase 5's Favorite Colors on the same screen per the Phase 1 plan). Pure,
//  NaN-safe (Domain/CLAUDE.md) — 12 named 0-100 spectrums (50 = neutral/no
//  lean), each derived from a specific field already computed elsewhere
//  (`Domain/AttributePreferenceProfile.swift`'s learned affinities, or raw
//  `ItemRating`/`OutfitFeedback`/`WornLogEntry` rows) — never an invented
//  number. Gated behind `AnalyticsConfigResponse.styleDNAMinRatings`; the
//  whole section stays locked until then, per spec.
//
//  Two computation shapes recur:
//  - "Difference" dimensions (Color Boldness, Pattern Adventurousness,
//    Practicality Orientation, Comfort Priority) contrast two group means,
//    defaulting a missing affinity to neutral 0.5 — same convention
//    `AttributePreferenceProfile.affinityBonus` already uses — so an absent
//    signal contributes zero pull rather than skewing the score.
//  - "Weighted centroid" dimensions (Formality Lean, Fabric Weight Lean)
//    use *only* affinity keys with real data (no 0.5 default) — defaulting
//    every missing band to neutral would flatten the centroid toward the
//    middle regardless of how lopsided the real signal actually is.
//

import Foundation
import os

enum StyleDNAScorer {
    struct DimensionScore: Identifiable, Equatable {
        let id: String
        let name: String
        let score: Double
        let why: String
    }

    struct StyleDNASnapshot: Equatable {
        /// Fixed order, always 12 entries when `isUnlocked`, empty otherwise.
        let dimensions: [DimensionScore]
        let isUnlocked: Bool
        let ratingSampleSize: Int
    }

    static func buildSnapshot(
        attributeProfile: AttributePreferenceProfile,
        itemRatings: [ItemRating],
        outfitFeedbacks: [OutfitFeedback],
        wornLogEntries: [WornLogEntry],
        ratingSampleSize: Int,
        thresholds: AnalyticsConfigResponse
    ) -> StyleDNASnapshot {
        guard ratingSampleSize >= thresholds.styleDNAMinRatings else {
            return StyleDNASnapshot(dimensions: [], isUnlocked: false, ratingSampleSize: ratingSampleSize)
        }

        let detailedOutfitFeedbacks = outfitFeedbacks.filter { $0.normalizedRating != nil }

        let dimensions = [
            colorBoldness(attributeProfile),
            patternAdventurousness(attributeProfile),
            formalityLean(attributeProfile),
            silhouetteConsistency(attributeProfile),
            fabricWeightLean(attributeProfile),
            signatureStyleStrength(attributeProfile),
            colorPaletteBreadth(attributeProfile),
            wearLoyalty(wornLogEntries),
            practicalityOrientation(detailedOutfitFeedbacks),
            confidenceBoost(detailedOutfitFeedbacks),
            comfortPriority(itemRatings),
            occasionVersatility(detailedOutfitFeedbacks),
        ]

        AnalyticsLog.logger.notice("[Insights] style DNA built: sampleSize=\(ratingSampleSize, privacy: .public) dimensions=\(dimensions.count, privacy: .public)")

        return StyleDNASnapshot(dimensions: dimensions, isUnlocked: true, ratingSampleSize: ratingSampleSize)
    }

    // MARK: - Shared helpers

    private static func affinityOrNeutral<Key: Hashable>(_ map: [Key: Double], _ key: Key) -> Double {
        map[key] ?? 0.5
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func neutralScore(id: String, name: String, why: String) -> DimensionScore {
        DimensionScore(id: id, name: name, score: 50, why: why)
    }

    // MARK: - Dimensions

    private static func colorBoldness(_ profile: AttributePreferenceProfile) -> DimensionScore {
        let bold = (affinityOrNeutral(profile.colorVibeAffinity, .vibrant) + affinityOrNeutral(profile.colorVibeAffinity, .pastel)) / 2
        let muted = (affinityOrNeutral(profile.colorVibeAffinity, .neutral) + affinityOrNeutral(profile.colorVibeAffinity, .monochrome)) / 2
        let score = (50 + (bold - muted) * 100).clamped(to: 0...100)
        let why: String
        if score >= 60 { why = "You rate vibrant and pastel pieces higher than neutrals and monochrome." }
        else if score <= 40 { why = "You rate neutral and monochrome pieces higher than vibrant color." }
        else { why = "Your color taste is fairly balanced between bold and neutral." }
        return DimensionScore(id: "colorBoldness", name: "Color Boldness", score: score, why: why)
    }

    private static func patternAdventurousness(_ profile: AttributePreferenceProfile) -> DimensionScore {
        let patterned = mean([.striped, .plaid, .graphic, .textured].map { affinityOrNeutral(profile.patternAffinity, $0) }) ?? 0.5
        let solid = affinityOrNeutral(profile.patternAffinity, .solid)
        let score = (50 + (patterned - solid) * 100).clamped(to: 0...100)
        let why: String
        if score >= 60 { why = "You rate patterned pieces higher than solids." }
        else if score <= 40 { why = "You rate solid pieces higher than patterns." }
        else { why = "You're evenly split between solids and patterns." }
        return DimensionScore(id: "patternAdventurousness", name: "Pattern Adventurousness", score: score, why: why)
    }

    private static func formalityLean(_ profile: AttributePreferenceProfile) -> DimensionScore {
        guard !profile.formalityAffinity.isEmpty else {
            return neutralScore(id: "formalityLean", name: "Formality Lean", why: "Rate a few more items to see your formality lean.")
        }
        let weightedSum = profile.formalityAffinity.reduce(0.0) { $0 + Double($1.key) * $1.value }
        let weightSum = profile.formalityAffinity.values.reduce(0, +)
        guard weightSum > 0 else {
            return neutralScore(id: "formalityLean", name: "Formality Lean", why: "Rate a few more items to see your formality lean.")
        }
        let centroid = weightedSum / weightSum
        let score = ((centroid - 1) / 4 * 100).clamped(to: 0...100)
        let why: String
        if score >= 60 { why = "You favor more formal, dressed-up pieces." }
        else if score <= 40 { why = "You favor more casual, relaxed pieces." }
        else { why = "You dress across a wide formality range." }
        return DimensionScore(id: "formalityLean", name: "Formality Lean", score: score, why: why)
    }

    private static func silhouetteConsistency(_ profile: AttributePreferenceProfile) -> DimensionScore {
        guard !profile.silhouetteAffinity.isEmpty else {
            return neutralScore(id: "silhouetteConsistency", name: "Silhouette Consistency", why: "Rate a few more items to see your silhouette consistency.")
        }
        let values = Array(profile.silhouetteAffinity.values)
        let maxValue = values.max() ?? 0.5
        let meanValue = mean(values) ?? 0.5
        let score = (50 + (maxValue - meanValue) * 100).clamped(to: 0...100)
        let why: String
        if score >= 60 { why = "You consistently favor one fit and silhouette." }
        else { why = "Your fit and silhouette preferences vary across pieces." }
        return DimensionScore(id: "silhouetteConsistency", name: "Silhouette Consistency", score: score, why: why)
    }

    private static func fabricWeightLean(_ profile: AttributePreferenceProfile) -> DimensionScore {
        let positions: [(FabricWeight, Double)] = [(.light, 0), (.medium, 50), (.heavy, 100)]
        let present = positions.compactMap { weight, position -> (Double, Double)? in
            guard let affinity = profile.fabricWeightAffinity[weight] else { return nil }
            return (position, affinity)
        }
        guard !present.isEmpty else {
            return neutralScore(id: "fabricWeightLean", name: "Fabric Weight Lean", why: "Rate a few more items to see your fabric weight lean.")
        }
        let weightSum = present.reduce(0.0) { $0 + $1.1 }
        guard weightSum > 0 else {
            return neutralScore(id: "fabricWeightLean", name: "Fabric Weight Lean", why: "Rate a few more items to see your fabric weight lean.")
        }
        let centroid = present.reduce(0.0) { $0 + $1.0 * $1.1 } / weightSum
        let score = centroid.clamped(to: 0...100)
        let why: String
        if score >= 60 { why = "You favor heavier, structured fabrics." }
        else if score <= 40 { why = "You favor lighter fabrics." }
        else { why = "You favor mid-weight fabrics." }
        return DimensionScore(id: "fabricWeightLean", name: "Fabric Weight Lean", score: score, why: why)
    }

    private static func signatureStyleStrength(_ profile: AttributePreferenceProfile) -> DimensionScore {
        guard let top = profile.styleTagAffinity.max(by: { $0.value < $1.value }) else {
            return neutralScore(id: "signatureStyleStrength", name: "Signature Style Strength", why: "Rate a few more items to see your signature style.")
        }
        let score = (top.value * 100).clamped(to: 0...100)
        return DimensionScore(
            id: "signatureStyleStrength",
            name: "Signature Style Strength",
            score: score,
            why: "\"\(top.key.capitalized)\" is your strongest style identity, rated \(Int(score))/100."
        )
    }

    private static func colorPaletteBreadth(_ profile: AttributePreferenceProfile) -> DimensionScore {
        guard !profile.colorVibeAffinity.isEmpty else {
            return neutralScore(id: "colorPaletteBreadth", name: "Color Palette Breadth", why: "Rate a few more items to see your color palette breadth.")
        }
        let likedCount = profile.colorVibeAffinity.values.filter { $0 > 0.55 }.count
        let score = (Double(likedCount) / Double(ColorVibe.allCases.count) * 100).clamped(to: 0...100)
        let why: String
        if score >= 60 { why = "You enjoy a wide range of color categories." }
        else { why = "You tend to stick to a focused color palette." }
        return DimensionScore(id: "colorPaletteBreadth", name: "Color Palette Breadth", score: score, why: why)
    }

    private static func wearLoyalty(_ wornLogEntries: [WornLogEntry]) -> DimensionScore {
        guard !wornLogEntries.isEmpty else {
            return neutralScore(id: "wearLoyalty", name: "Wear Loyalty", why: "Log a few wears to see your wear loyalty.")
        }
        var counts: [UUID: Int] = [:]
        for entry in wornLogEntries {
            for itemID in entry.itemIDs {
                counts[itemID, default: 0] += 1
            }
        }
        let totalWears = counts.values.reduce(0, +)
        guard totalWears > 0 else {
            return neutralScore(id: "wearLoyalty", name: "Wear Loyalty", why: "Log a few wears to see your wear loyalty.")
        }
        let sortedCounts = counts.values.sorted(by: >)
        let topN = max(1, Int((Double(sortedCounts.count) * 0.2).rounded(.up)))
        let topSum = sortedCounts.prefix(topN).reduce(0, +)
        let score = (Double(topSum) / Double(totalWears) * 100).clamped(to: 0...100)
        let why: String
        if score >= 60 { why = "A small set of favorites accounts for most of your wears." }
        else { why = "Your wears are spread fairly evenly across your closet." }
        return DimensionScore(id: "wearLoyalty", name: "Wear Loyalty", score: score, why: why)
    }

    private static func practicalityOrientation(_ detailedOutfitFeedbacks: [OutfitFeedback]) -> DimensionScore {
        let practicalityValues = detailedOutfitFeedbacks.compactMap { $0.practicality.map(Double.init) }
        let styleColorValues = detailedOutfitFeedbacks.flatMap { feedback -> [Double] in
            guard let styleMatch = feedback.styleMatch, let colorHarmony = feedback.colorHarmony else { return [] }
            return [Double(styleMatch), Double(colorHarmony)]
        }
        guard let avgPracticality = mean(practicalityValues), let avgStyleColor = mean(styleColorValues) else {
            return neutralScore(id: "practicalityOrientation", name: "Practicality Orientation", why: "Rate a few more outfits to see this.")
        }
        let score = (50 + (avgPracticality - avgStyleColor) / 4 * 100).clamped(to: 0...100)
        let why: String
        if score >= 60 { why = "You rate practicality and weather-fit higher than style and color impact." }
        else if score <= 40 { why = "You prioritize style and color impact over pure practicality." }
        else { why = "You balance style and practicality evenly." }
        return DimensionScore(id: "practicalityOrientation", name: "Practicality Orientation", score: score, why: why)
    }

    private static func confidenceBoost(_ detailedOutfitFeedbacks: [OutfitFeedback]) -> DimensionScore {
        guard let avg = mean(detailedOutfitFeedbacks.compactMap { $0.confidence.map(Double.init) }) else {
            return neutralScore(id: "confidenceBoost", name: "Confidence Boost", why: "Rate a few more outfits to see this.")
        }
        let score = ((avg - 1) / 4 * 100).clamped(to: 0...100)
        let why: String
        if score >= 70 { why = "Your outfits consistently make you feel confident." }
        else if score <= 40 { why = "Your outfits don't often boost your confidence — worth exploring what's not working." }
        else { why = "Your outfits give you a moderate confidence boost." }
        return DimensionScore(id: "confidenceBoost", name: "Confidence Boost", score: score, why: why)
    }

    private static func comfortPriority(_ itemRatings: [ItemRating]) -> DimensionScore {
        guard !itemRatings.isEmpty,
              let avgComfort = mean(itemRatings.map { Double($0.comfort) }),
              let avgStyle = mean(itemRatings.map { Double($0.styleIdentity) })
        else {
            return neutralScore(id: "comfortPriority", name: "Comfort Priority", why: "Rate a few more items to see this.")
        }
        let score = (50 + (avgComfort - avgStyle) / 4 * 100).clamped(to: 0...100)
        let why: String
        if score >= 60 { why = "Comfort matters more to you than pure style impact." }
        else if score <= 40 { why = "Style impact matters more to you than comfort." }
        else { why = "You balance comfort and style evenly." }
        return DimensionScore(id: "comfortPriority", name: "Comfort Priority", score: score, why: why)
    }

    private static func occasionVersatility(_ detailedOutfitFeedbacks: [OutfitFeedback]) -> DimensionScore {
        let occasions = Set(detailedOutfitFeedbacks.compactMap(\.occasion))
        guard !occasions.isEmpty else {
            return neutralScore(id: "occasionVersatility", name: "Occasion Versatility", why: "Tag a few more outfits with an occasion to see this.")
        }
        let score = (Double(occasions.count) / Double(OutfitOccasion.allCases.count) * 100).clamped(to: 0...100)
        let why: String
        if score >= 60 { why = "You dress for a wide range of occasions." }
        else { why = "You tend to dress for a narrow set of occasions." }
        return DimensionScore(id: "occasionVersatility", name: "Occasion Versatility", score: score, why: why)
    }
}
