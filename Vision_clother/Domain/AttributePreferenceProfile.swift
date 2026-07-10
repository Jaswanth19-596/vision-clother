//
//  AttributePreferenceProfile.swift
//  Vision_clother
//
//  Item Rating & Preference Learning: turns accumulated `ItemRating` events
//  (Models/ItemRating.swift) into per-attribute "taste" affinities — which
//  color vibes, patterns, and formality bands the user tends to rate well —
//  so `Domain/OutfitRecommendationEngine.swift` can bias (re-rank) candidates
//  toward them. Pure, no I/O, NaN-safe for empty input, and ghost elements
//  flow through the identical path as real items — no `isGhostElement`
//  branch anywhere in this file (Domain/CLAUDE.md).
//
//  Deliberately a *bias*, not a filter: with sparse ratings every affinity
//  defaults to a neutral 0.5, so `affinityBonus` is 0 and recommendations are
//  byte-for-byte unchanged from today's behavior. This keeps new/unrated
//  items and small wardrobes from being starved out (the "re-rank, don't
//  hard-filter" decision).
//

import Foundation

/// One `ItemRating`, already joined to the attributes of the item it rated —
/// prepared by the caller (`Data/WardrobeRepository.swift`) so this module
/// never touches SwiftData or `WardrobeItem` lookups itself.
struct RatedAttributes {
    /// `ItemRating.normalizedValue`, already in `[0,1]`.
    let value: Double
    let colorVibe: ColorVibe
    let pattern: GarmentPattern
    /// `Int(formalityScore.rounded())`, banding the continuous formality
    /// score so shrinkage has repeat keys to accumulate against.
    let formalityBand: Int
    /// `ItemRating.styleIdentity`, normalized to `[0,1]` — item-level mirror
    /// of the outfit-level Personal Style Match question, feeding the same
    /// `styleTagAffinity` map. Defaulted so pre-existing call sites that only
    /// care about color/pattern/formality don't need to change.
    let styleIdentity: Double
    /// `WardrobeItem.styleTags` for the rated item — paired with
    /// `styleIdentity` above.
    let styleTags: [String]

    /// Explicit init (rather than relying on the synthesized memberwise
    /// init's default-value support) — with two trailing defaulted
    /// parameters, SourceKit/xcodebuild inference for this struct's implicit
    /// memberwise init proved unreliable at call sites.
    init(value: Double, colorVibe: ColorVibe, pattern: GarmentPattern, formalityBand: Int, styleIdentity: Double = 0.5, styleTags: [String] = []) {
        self.value = value
        self.colorVibe = colorVibe
        self.pattern = pattern
        self.formalityBand = formalityBand
        self.styleIdentity = styleIdentity
        self.styleTags = styleTags
    }
}

/// One detailed `OutfitFeedback` (Stylist Intelligence Engine Phase 1),
/// expanded by the caller into one entry per real item in the rated outfit —
/// the outfit-level questions are asked once but must bias every item that
/// was actually worn. Each dimension is already normalized to `[0,1]` and
/// keyed to the specific attribute it teaches, per the mapping in
/// `docs/decisions/stylist-intelligence-engine.md`:
/// Color Harmony -> `colorVibeAffinity`, Occasion Match -> `formalityAffinity`,
/// Personal Style Match -> `styleTagAffinity`, Fit & Silhouette ->
/// `silhouetteAffinity`, Weather Suitability + Practicality (folded into one
/// bucket — both describe "does this garment work for the conditions") ->
/// `fabricWeightAffinity`.
struct OutfitDimensionRatedAttributes {
    let colorHarmony: Double
    let occasionMatch: Double
    let styleMatch: Double
    let silhouette: Double
    /// Mean of Weather Suitability and Practicality — see file header.
    let weatherFit: Double

    let colorVibe: ColorVibe
    let styleTags: [String]
    /// `WardrobeItem.silhouette` — `nil` for items without a silhouette tag
    /// (pre-2026-07-10 ingestion or manual entry), skipped for this axis.
    let silhouetteTag: String?
    let formalityBand: Int
    let fabricWeight: FabricWeight
}

/// Bayesian-shrunk affinity per attribute value, in `[0,1]`, seeded at a
/// neutral 0.5 — same shrinkage shape as `PairCompatibilityScoring.itemPreference`.
struct AttributePreferenceProfile {
    var colorVibeAffinity: [ColorVibe: Double] = [:]
    var patternAffinity: [GarmentPattern: Double] = [:]
    var formalityAffinity: [Int: Double] = [:]
    /// Personal Style Match (Stylist Intelligence Engine Phase 1), keyed by
    /// `WardrobeItem.styleTags` — the first scoring consumer of that field,
    /// previously LLM-prompt-only.
    var styleTagAffinity: [String: Double] = [:]
    /// Fit & Silhouette, keyed by `WardrobeItem.silhouette`.
    var silhouetteAffinity: [String: Double] = [:]
    /// Weather Suitability + Practicality (folded into one bucket), keyed by
    /// `WardrobeItem.fabricWeight`.
    var fabricWeightAffinity: [FabricWeight: Double] = [:]

    /// Bounds how far `affinityBonus` can push a score, so attribute bias
    /// can re-rank candidates but never overwhelm the deterministic
    /// aesthetic prior or the existing item/pair preference terms.
    static let maxBonusMagnitude: Double = 0.3

    static func build(
        from ratings: [RatedAttributes],
        outfitDimensionRatings: [OutfitDimensionRatedAttributes] = [],
        priorWeight: Double = PairCompatibilityScoring.defaultPriorWeight
    ) -> AttributePreferenceProfile {
        var colorSums: [ColorVibe: (sum: Double, count: Int)] = [:]
        var patternSums: [GarmentPattern: (sum: Double, count: Int)] = [:]
        var formalitySums: [Int: (sum: Double, count: Int)] = [:]
        var styleTagSums: [String: (sum: Double, count: Int)] = [:]
        var silhouetteSums: [String: (sum: Double, count: Int)] = [:]
        var fabricWeightSums: [FabricWeight: (sum: Double, count: Int)] = [:]

        for rating in ratings {
            colorSums[rating.colorVibe, default: (0, 0)].sum += rating.value
            colorSums[rating.colorVibe, default: (0, 0)].count += 1

            patternSums[rating.pattern, default: (0, 0)].sum += rating.value
            patternSums[rating.pattern, default: (0, 0)].count += 1

            formalitySums[rating.formalityBand, default: (0, 0)].sum += rating.value
            formalitySums[rating.formalityBand, default: (0, 0)].count += 1

            for tag in rating.styleTags {
                styleTagSums[tag, default: (0, 0)].sum += rating.styleIdentity
                styleTagSums[tag, default: (0, 0)].count += 1
            }
        }

        for rating in outfitDimensionRatings {
            colorSums[rating.colorVibe, default: (0, 0)].sum += rating.colorHarmony
            colorSums[rating.colorVibe, default: (0, 0)].count += 1

            formalitySums[rating.formalityBand, default: (0, 0)].sum += rating.occasionMatch
            formalitySums[rating.formalityBand, default: (0, 0)].count += 1

            for tag in rating.styleTags {
                styleTagSums[tag, default: (0, 0)].sum += rating.styleMatch
                styleTagSums[tag, default: (0, 0)].count += 1
            }

            if let silhouetteTag = rating.silhouetteTag {
                silhouetteSums[silhouetteTag, default: (0, 0)].sum += rating.silhouette
                silhouetteSums[silhouetteTag, default: (0, 0)].count += 1
            }

            fabricWeightSums[rating.fabricWeight, default: (0, 0)].sum += rating.weatherFit
            fabricWeightSums[rating.fabricWeight, default: (0, 0)].count += 1
        }

        var profile = AttributePreferenceProfile()
        profile.colorVibeAffinity = colorSums.mapValues { shrunkAffinity(sum: $0.sum, count: $0.count, priorWeight: priorWeight) }
        profile.patternAffinity = patternSums.mapValues { shrunkAffinity(sum: $0.sum, count: $0.count, priorWeight: priorWeight) }
        profile.formalityAffinity = formalitySums.mapValues { shrunkAffinity(sum: $0.sum, count: $0.count, priorWeight: priorWeight) }
        profile.styleTagAffinity = styleTagSums.mapValues { shrunkAffinity(sum: $0.sum, count: $0.count, priorWeight: priorWeight) }
        profile.silhouetteAffinity = silhouetteSums.mapValues { shrunkAffinity(sum: $0.sum, count: $0.count, priorWeight: priorWeight) }
        profile.fabricWeightAffinity = fabricWeightSums.mapValues { shrunkAffinity(sum: $0.sum, count: $0.count, priorWeight: priorWeight) }
        return profile
    }

    /// `(w0 * 0.5 + sum) / (w0 + count)`, clamped to `[0,1]`. NaN-safe: the
    /// denominator is `priorWeight + count`, and `priorWeight` is always
    /// positive by default, so this only divides by zero if a caller passes
    /// `priorWeight: 0` with `count: 0` — guarded explicitly anyway.
    private static func shrunkAffinity(sum: Double, count: Int, priorWeight: Double) -> Double {
        let denominator = priorWeight + Double(count)
        guard denominator > 0 else { return 0.5 }
        let numerator = priorWeight * 0.5 + sum
        return (numerator / denominator).clamped(to: 0...1)
    }

    /// Bounded, NaN-safe bias term for one item, centered at 0 (neutral).
    /// Missing attributes (no ratings yet for that color/pattern/band/tag)
    /// default to the neutral 0.5 affinity, so an unrated attribute
    /// contributes zero bias rather than penalizing the item.
    func affinityBonus(for item: WardrobeItem) -> Double {
        let colorAff = colorVibeAffinity[item.colorProfile.category] ?? 0.5
        let patternAff = patternAffinity[item.pattern] ?? 0.5
        let formalityBand = Int(item.formalityScore.rounded())
        let formalityAff = formalityAffinity[formalityBand] ?? 0.5

        let matchingTagAffinities = item.styleTags.compactMap { styleTagAffinity[$0] }
        let styleTagAff = matchingTagAffinities.isEmpty ? 0.5 : matchingTagAffinities.reduce(0, +) / Double(matchingTagAffinities.count)

        let silhouetteAff = item.silhouette.flatMap { silhouetteAffinity[$0] } ?? 0.5
        let fabricWeightAff = fabricWeightAffinity[item.fabricWeight] ?? 0.5

        let mean = (colorAff + patternAff + formalityAff + styleTagAff + silhouetteAff + fabricWeightAff) / 6.0
        let bonus = (mean - 0.5) * 2.0 * Self.maxBonusMagnitude
        return bonus.clamped(to: -Self.maxBonusMagnitude...Self.maxBonusMagnitude)
    }
}
