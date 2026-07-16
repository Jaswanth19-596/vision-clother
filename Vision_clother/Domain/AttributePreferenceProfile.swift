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
/// never touches SwiftData or `WardrobeItem` lookups itself. Each field below
/// is a dedicated per-attribute answer (`ItemRating.colorLike`/`patternLike`/
/// `formalityFit`/etc., normalized to `[0,1]`) rather than one blended score
/// reused for every affinity — see docs/decisions/stylist-intelligence-engine.md.
struct RatedAttributes {
    /// `ItemRating.colorLike` — feeds `colorVibeAffinity[colorVibe]`.
    let colorLike: Double
    /// `ItemRating.patternLike` — feeds `patternAffinity[pattern]`. `nil`
    /// when the Pattern question was skipped (solid-pattern item), in which
    /// case this rating simply doesn't contribute to `patternAffinity`.
    let patternLike: Double?
    /// `ItemRating.formalityFit` — feeds `formalityAffinity[formalityBand]`.
    let formalityFit: Double
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
    /// `ItemRating.recordedAt` — feeds `build(from:)`'s exponential
    /// time-decay weighting. Defaulted to `.now` so existing call sites
    /// (tests, and any future direct construction) that don't care about
    /// recency keep contributing at full weight, unchanged from before decay
    /// existed.
    let recordedAt: Date
    /// `WardrobeItem.slot` for the rated item — feeds `colorVibeAffinityBySlot`.
    /// Defaulted to `nil` so existing call sites (tests, and any code that
    /// only cares about the flat `colorVibeAffinity`) keep compiling; a `nil`
    /// slot simply doesn't contribute to the per-slot breakdown.
    let slot: Slot?
    /// `WardrobeItem.silhouette` for the rated item, paired with
    /// `silhouetteFit` below — feeds `silhouetteAffinity`. `nil` for items
    /// with no silhouette tag (most of the closet, currently), same as the
    /// outfit-level `Fit & Silhouette` question's `silhouetteTag`.
    let silhouetteTag: String?
    /// `ItemRating.fit.centeredness` — item-level companion to the
    /// outfit-level `Fit & Silhouette` question, feeding the same
    /// `silhouetteAffinity` map. `nil` whenever `silhouetteTag` is `nil`
    /// (nothing to key the affinity by), so it never contributes alone.
    let silhouetteFit: Double?
    /// `WardrobeItem.fabricWeight` for the rated item — feeds
    /// `fabricWeightAffinity`, alongside the outfit-level Weather
    /// Suitability + Practicality average.
    let fabricWeight: FabricWeight
    /// `ItemRating.comfort` ("how did the fabric feel?"), normalized to
    /// `[0,1]` — the item-level signal for `fabricWeightAffinity`.
    let fabricComfort: Double

    /// Explicit init (rather than relying on the synthesized memberwise
    /// init's default-value support) — with trailing defaulted parameters,
    /// SourceKit/xcodebuild inference for this struct's implicit memberwise
    /// init proved unreliable at call sites.
    init(
        colorLike: Double, patternLike: Double? = nil, formalityFit: Double,
        colorVibe: ColorVibe, pattern: GarmentPattern, formalityBand: Int,
        styleIdentity: Double = 0.5, styleTags: [String] = [], recordedAt: Date = .now, slot: Slot? = nil,
        silhouetteTag: String? = nil, silhouetteFit: Double? = nil,
        fabricWeight: FabricWeight = .medium, fabricComfort: Double = 0.5
    ) {
        self.colorLike = colorLike
        self.patternLike = patternLike
        self.formalityFit = formalityFit
        self.colorVibe = colorVibe
        self.pattern = pattern
        self.formalityBand = formalityBand
        self.styleIdentity = styleIdentity
        self.styleTags = styleTags
        self.recordedAt = recordedAt
        self.slot = slot
        self.silhouetteTag = silhouetteTag
        self.silhouetteFit = silhouetteFit
        self.fabricWeight = fabricWeight
        self.fabricComfort = fabricComfort
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
    /// "What would you change?" checklist (Level 3, Stylist Intelligence
    /// Engine ADR) — `nil` unless "Wrong pattern" was flagged, in which case
    /// this is the *only* outfit-level signal that feeds `patternAffinity`
    /// (the Level 2 question set has no dedicated Pattern star question;
    /// only item-level `ItemRating.patternLike` fed this map before).
    let patternDissatisfaction: Double?

    let colorVibe: ColorVibe
    let styleTags: [String]
    /// `WardrobeItem.silhouette` — `nil` for items without a silhouette tag
    /// (pre-2026-07-10 ingestion or manual entry), skipped for this axis.
    let silhouetteTag: String?
    let formalityBand: Int
    let fabricWeight: FabricWeight
    /// The rated item's actual pattern — always known, pairs with
    /// `patternDissatisfaction` above to key `patternAffinity`.
    let pattern: GarmentPattern
    /// `OutfitFeedback.recordedAt` — feeds `build(from:)`'s exponential
    /// time-decay weighting, same as `RatedAttributes.recordedAt`.
    let recordedAt: Date
    /// `WardrobeItem.slot` for the rated item — feeds `colorVibeAffinityBySlot`,
    /// same as `RatedAttributes.slot`.
    let slot: Slot?

    init(
        colorHarmony: Double, occasionMatch: Double, styleMatch: Double, silhouette: Double, weatherFit: Double,
        colorVibe: ColorVibe, styleTags: [String], silhouetteTag: String?, formalityBand: Int,
        fabricWeight: FabricWeight, pattern: GarmentPattern = .solid, patternDissatisfaction: Double? = nil,
        recordedAt: Date = .now, slot: Slot? = nil
    ) {
        self.colorHarmony = colorHarmony
        self.occasionMatch = occasionMatch
        self.styleMatch = styleMatch
        self.silhouette = silhouette
        self.weatherFit = weatherFit
        self.patternDissatisfaction = patternDissatisfaction
        self.colorVibe = colorVibe
        self.styleTags = styleTags
        self.silhouetteTag = silhouetteTag
        self.formalityBand = formalityBand
        self.fabricWeight = fabricWeight
        self.pattern = pattern
        self.recordedAt = recordedAt
        self.slot = slot
    }
}

/// Sendable projection of a `WardrobeItem`'s attribute fields — the only
/// subset `AttributePreferenceProfile.build()` reads. Used by
/// `WardrobeRepository.fetchFeedbackHistory()` to pass inventory data across
/// an actor boundary (into `Task.detached`) without transmitting live
/// `@Model` instances, which are not `Sendable`.
struct ItemAttributeSnapshot: Sendable {
    let colorCategory: ColorVibe
    let pattern: GarmentPattern
    let formalityBand: Int
    let styleTags: [String]
    let silhouette: String?
    let fabricWeight: FabricWeight
    let slot: Slot

    init(colorCategory: ColorVibe, pattern: GarmentPattern, formalityBand: Int, styleTags: [String], silhouette: String?, fabricWeight: FabricWeight, slot: Slot) {
        self.colorCategory = colorCategory
        self.pattern = pattern
        self.formalityBand = formalityBand
        self.styleTags = styleTags
        self.silhouette = silhouette
        self.fabricWeight = fabricWeight
        self.slot = slot
    }
}

/// Bayesian-shrunk affinity per attribute value, in `[0,1]`, seeded at a
/// neutral 0.5 — same shrinkage shape as `PairCompatibilityScoring.itemPreference`.
struct AttributePreferenceProfile {
    var colorVibeAffinity: [ColorVibe: Double] = [:]
    /// Same shrunk affinity as `colorVibeAffinity`, but broken out per
    /// `Slot` (e.g. "which colors do I like in tops" vs. "in shoes") — used
    /// by the Style Analytics "Color Affinity Breakdown" chart. Only
    /// populated from ratings/outfit-dimension feedback whose `slot` is
    /// known; `RatedAttributes`/`OutfitDimensionRatedAttributes` entries
    /// with `slot == nil` still contribute to the flat `colorVibeAffinity`
    /// above, just not here.
    var colorVibeAffinityBySlot: [Slot: [ColorVibe: Double]] = [:]
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

    /// Exponential time-decay rate for taste signals, corresponding to a
    /// 60-day half-life (`ln(2) / 60 ≈ 0.01155`) — a rating from 60 days ago
    /// contributes half the weight of one recorded today, so recent taste
    /// shifts (e.g. a seasonal wardrobe change) outweigh stale history
    /// without discarding it outright.
    static let decayLambda: Double = 0.01155

    /// `e^(-λ·t)` where `t` is the age of the signal in days. Clamped to
    /// non-negative elapsed time so a `recordedAt` at or after `now` (e.g.
    /// same-instant test construction) never produces a weight above 1.0.
    static func decayWeight(recordedAt: Date, now: Date = .now) -> Double {
        let elapsedDays = max(0, now.timeIntervalSince(recordedAt) / 86400)
        return exp(-decayLambda * elapsedDays)
    }

    /// Dynamic Bayesian shrinkage prior — how strongly `shrunkAffinity` pulls
    /// a sparsely-rated bucket back toward neutral 0.5 scales with how
    /// common that attribute value already is in the closet: a user with 40
    /// casual items needs more contrary feedback to move the "Casual"
    /// affinity than a user with 2 formal items needs to move "Formal,"
    /// since the former reflects a much more entrenched, well-sampled
    /// pattern of behavior. Floors at the original flat constant (3.0) so a
    /// rarely-owned attribute never becomes *more* volatile than before this
    /// existed.
    private static func dynamicPriorWeight(baselineCount: Int) -> Double {
        max(PairCompatibilityScoring.defaultPriorWeight, Double(baselineCount) * 0.1)
    }

    /// Folds one decay-weighted `(colorVibe, value)` observation into
    /// `sums`, nested under `slot` — a no-op when `slot` is `nil` (rating
    /// has no known slot, so it only contributes to the flat `colorSums`
    /// the caller tracks separately).
    private static func accumulateSlotColor(
        _ slot: Slot?, colorVibe: ColorVibe, value: Double, weight: Double,
        into sums: inout [Slot: [ColorVibe: (sum: Double, count: Double)]]
    ) {
        guard let slot else { return }
        var slotMap = sums[slot] ?? [:]
        var entry = slotMap[colorVibe] ?? (0, 0)
        entry.sum += value * weight
        entry.count += weight
        slotMap[colorVibe] = entry
        sums[slot] = slotMap
    }

    static func build(
        from ratings: [RatedAttributes],
        outfitDimensionRatings: [OutfitDimensionRatedAttributes] = [],
        inventory: [WardrobeItem] = [],
        now: Date = .now
    ) -> AttributePreferenceProfile {
        let snapshots = inventory.map { item in
            ItemAttributeSnapshot(
                colorCategory: item.colorProfile.category,
                pattern: item.pattern,
                formalityBand: Int(item.formalityScore.rounded()),
                styleTags: item.styleTags,
                silhouette: item.silhouette,
                fabricWeight: item.fabricWeight,
                slot: item.slot
            )
        }
        return build(
            from: ratings,
            outfitDimensionRatings: outfitDimensionRatings,
            inventorySnapshots: snapshots,
            now: now
        )
    }

    static func build(
        from ratings: [RatedAttributes],
        outfitDimensionRatings: [OutfitDimensionRatedAttributes] = [],
        inventorySnapshots: [ItemAttributeSnapshot],
        now: Date = .now
    ) -> AttributePreferenceProfile {
        var colorSums: [ColorVibe: (sum: Double, count: Double)] = [:]
        var colorSumsBySlot: [Slot: [ColorVibe: (sum: Double, count: Double)]] = [:]
        var patternSums: [GarmentPattern: (sum: Double, count: Double)] = [:]
        var formalitySums: [Int: (sum: Double, count: Double)] = [:]
        var styleTagSums: [String: (sum: Double, count: Double)] = [:]
        var silhouetteSums: [String: (sum: Double, count: Double)] = [:]
        var fabricWeightSums: [FabricWeight: (sum: Double, count: Double)] = [:]

        for rating in ratings {
            let weight = decayWeight(recordedAt: rating.recordedAt, now: now)

            colorSums[rating.colorVibe, default: (0, 0)].sum += rating.colorLike * weight
            colorSums[rating.colorVibe, default: (0, 0)].count += weight
            accumulateSlotColor(rating.slot, colorVibe: rating.colorVibe, value: rating.colorLike, weight: weight, into: &colorSumsBySlot)

            if let patternLike = rating.patternLike {
                patternSums[rating.pattern, default: (0, 0)].sum += patternLike * weight
                patternSums[rating.pattern, default: (0, 0)].count += weight
            }

            formalitySums[rating.formalityBand, default: (0, 0)].sum += rating.formalityFit * weight
            formalitySums[rating.formalityBand, default: (0, 0)].count += weight

            for tag in rating.styleTags {
                styleTagSums[tag, default: (0, 0)].sum += rating.styleIdentity * weight
                styleTagSums[tag, default: (0, 0)].count += weight
            }

            if let silhouetteTag = rating.silhouetteTag, let silhouetteFit = rating.silhouetteFit {
                silhouetteSums[silhouetteTag, default: (0, 0)].sum += silhouetteFit * weight
                silhouetteSums[silhouetteTag, default: (0, 0)].count += weight
            }

            fabricWeightSums[rating.fabricWeight, default: (0, 0)].sum += rating.fabricComfort * weight
            fabricWeightSums[rating.fabricWeight, default: (0, 0)].count += weight
        }

        for rating in outfitDimensionRatings {
            let weight = decayWeight(recordedAt: rating.recordedAt, now: now)

            colorSums[rating.colorVibe, default: (0, 0)].sum += rating.colorHarmony * weight
            colorSums[rating.colorVibe, default: (0, 0)].count += weight
            accumulateSlotColor(rating.slot, colorVibe: rating.colorVibe, value: rating.colorHarmony, weight: weight, into: &colorSumsBySlot)

            formalitySums[rating.formalityBand, default: (0, 0)].sum += rating.occasionMatch * weight
            formalitySums[rating.formalityBand, default: (0, 0)].count += weight

            if let patternDissatisfaction = rating.patternDissatisfaction {
                patternSums[rating.pattern, default: (0, 0)].sum += patternDissatisfaction * weight
                patternSums[rating.pattern, default: (0, 0)].count += weight
            }

            for tag in rating.styleTags {
                styleTagSums[tag, default: (0, 0)].sum += rating.styleMatch * weight
                styleTagSums[tag, default: (0, 0)].count += weight
            }

            if let silhouetteTag = rating.silhouetteTag {
                silhouetteSums[silhouetteTag, default: (0, 0)].sum += rating.silhouette * weight
                silhouetteSums[silhouetteTag, default: (0, 0)].count += weight
            }

            fabricWeightSums[rating.fabricWeight, default: (0, 0)].sum += rating.weatherFit * weight
            fabricWeightSums[rating.fabricWeight, default: (0, 0)].count += weight
        }

        var colorBaseline: [ColorVibe: Int] = [:]
        var colorBaselineBySlot: [Slot: [ColorVibe: Int]] = [:]
        var patternBaseline: [GarmentPattern: Int] = [:]
        var formalityBaseline: [Int: Int] = [:]
        var styleTagBaseline: [String: Int] = [:]
        var silhouetteBaseline: [String: Int] = [:]
        var fabricWeightBaseline: [FabricWeight: Int] = [:]
        for item in inventorySnapshots {
            colorBaseline[item.colorCategory, default: 0] += 1
            var slotBaselineMap = colorBaselineBySlot[item.slot] ?? [:]
            slotBaselineMap[item.colorCategory, default: 0] += 1
            colorBaselineBySlot[item.slot] = slotBaselineMap
            patternBaseline[item.pattern, default: 0] += 1
            formalityBaseline[item.formalityBand, default: 0] += 1
            for tag in item.styleTags {
                styleTagBaseline[tag, default: 0] += 1
            }
            if let silhouette = item.silhouette {
                silhouetteBaseline[silhouette, default: 0] += 1
            }
            fabricWeightBaseline[item.fabricWeight, default: 0] += 1
        }

        func affinityMap<Key: Hashable>(
            sums: [Key: (sum: Double, count: Double)],
            baseline: [Key: Int]
        ) -> [Key: Double] {
            sums.reduce(into: [Key: Double]()) { result, entry in
                let (key, aggregate) = entry
                let priorWeight = dynamicPriorWeight(baselineCount: baseline[key] ?? 0)
                result[key] = shrunkAffinity(sum: aggregate.sum, count: aggregate.count, priorWeight: priorWeight)
            }
        }

        var colorVibeAffinityBySlot: [Slot: [ColorVibe: Double]] = [:]
        for (slot, sums) in colorSumsBySlot {
            colorVibeAffinityBySlot[slot] = affinityMap(sums: sums, baseline: colorBaselineBySlot[slot] ?? [:])
        }

        var profile = AttributePreferenceProfile()
        profile.colorVibeAffinity = affinityMap(sums: colorSums, baseline: colorBaseline)
        profile.colorVibeAffinityBySlot = colorVibeAffinityBySlot
        profile.patternAffinity = affinityMap(sums: patternSums, baseline: patternBaseline)
        profile.formalityAffinity = affinityMap(sums: formalitySums, baseline: formalityBaseline)
        profile.styleTagAffinity = affinityMap(sums: styleTagSums, baseline: styleTagBaseline)
        profile.silhouetteAffinity = affinityMap(sums: silhouetteSums, baseline: silhouetteBaseline)
        profile.fabricWeightAffinity = affinityMap(sums: fabricWeightSums, baseline: fabricWeightBaseline)
        return profile
    }

    /// `(w0 * 0.5 + sum) / (w0 + count)`, clamped to `[0,1]`. NaN-safe: the
    /// denominator is `priorWeight + count`, and `priorWeight` is always
    /// positive by default, so this only divides by zero if a caller passes
    /// `priorWeight: 0` with `count: 0` — guarded explicitly anyway. `count`
    /// is a decay-weighted sum (not a raw tally) now that `build(from:)`
    /// applies exponential time-decay, but the shrinkage shape is identical.
    private static func shrunkAffinity(sum: Double, count: Double, priorWeight: Double) -> Double {
        let denominator = priorWeight + count
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
