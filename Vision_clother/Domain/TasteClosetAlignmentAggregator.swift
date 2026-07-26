//
//  TasteClosetAlignmentAggregator.swift
//  Vision_clother
//
//  Analytics & Insights — the bridge between the two things the app already
//  knows in isolation: what the user *loves* (`AttributePreferenceProfile`,
//  the same affinity maps the Taste tab renders) and what the user *owns*
//  (their live wardrobe composition). Every other Insights aggregator reports
//  one or the other; this one contrasts them per attribute dimension to answer
//  "does my closet actually match my taste?" — surfacing a headline alignment
//  score plus two actionable lists: values the user loves but under-owns
//  (a grounded shopping signal) and values that dominate the closet despite a
//  weak preference (a declutter / stop-buying signal).
//
//  Pure, no SwiftUI (per Domain/CLAUDE.md) and NaN-safe for empty input:
//  an empty closet or a signal-free profile yields a neutral, `hasSignal:
//  false` snapshot with both lists empty and no division by zero. Ghost
//  elements flow through the identical exclusion `WardrobeCatalogBuilder`
//  uses (they are virtual placeholders, not owned garments); laundry items are
//  still owned and count toward composition. Reuses the plain-language
//  labels/swatches from `TasteInsightsAggregator` so a value reads identically
//  here and on the affinity cards below it.
//

import Foundation

struct TasteClosetAlignmentSnapshot: Equatable {
    /// One place the closet diverges from taste — either a loved value the
    /// user barely owns, or an over-owned value they aren't drawn to.
    struct Divergence: Identifiable, Equatable {
        let id: String
        /// The dimension this belongs to, e.g. "Colors" — shown as a small tag.
        let dimensionTitle: String
        /// Plain-language value label, e.g. "Bright & Bold".
        let valueLabel: String
        /// Fraction of owned items in this dimension with this value, `[0,1]`.
        let ownershipShare: Double
        /// Learned affinity for the value, `[0,1]`, 0.5 = neutral.
        let affinity: Double
        /// Representative colour swatches for colour-based dimensions; empty
        /// otherwise (reused by the card exactly like `TasteInsightsSnapshot.Row`).
        let swatchHexes: [String]
        /// Ready-to-render sentence, e.g. "You're drawn to bright & bold, but
        /// it's only 8% of your closet."
        let message: String
    }

    /// 0–100 — how well closet composition matches learned taste, i.e. the
    /// ownership-weighted average affinity of what the user owns, across the
    /// dimensions that carry real signal. ~50 for a neutral/unlearned profile.
    let alignmentScore: Int
    /// One-line headline built off `alignmentScore`.
    let headline: String
    /// Loved-but-under-owned values, strongest signal first (shopping cue).
    let buyMore: [Divergence]
    /// Over-owned-but-weak-preference values, biggest share first (declutter cue).
    let reconsider: [Divergence]
    /// False for a brand-new user (no profile signal or no composition), which
    /// gates the whole card in the UI — mirrors `AttributePreferenceProfile.hasSignal`.
    let hasSignal: Bool
}

enum TasteClosetAlignmentAggregator {
    private typealias Divergence = TasteClosetAlignmentSnapshot.Divergence

    /// A loved value owning less than this share of its dimension reads as
    /// "under-owned" — a buy signal. Shared `lovedThreshold` (0.6) decides what
    /// counts as "loved," so the wording matches the Taste tab and the
    /// recommender's favorites list.
    private static let underOwnedShareCeiling: Double = 0.15
    /// A value filling at least this share of its dimension is "over-owned";
    /// paired with a below-neutral affinity it becomes a "reconsider" cue.
    private static let overOwnedShareFloor: Double = 0.25
    /// Affinity strictly below this reads as "not a strong preference." Because
    /// an unrated value defaults to exactly 0.5 in the affinity map (Bayesian
    /// neutral seed), `< 0.5` never fires on a value the profile knows nothing
    /// about — we only flag things the user has actually rated down.
    private static let indifferenceCeiling: Double = 0.5
    /// At most this many rows per list, keeping the card scannable.
    private static let maxRowsPerList: Int = 4

    static func build(
        profile: AttributePreferenceProfile,
        inventory: [WardrobeItem]
    ) -> TasteClosetAlignmentSnapshot {
        let owned = inventory.filter { !$0.isGhostElement }

        // Each dimension becomes a uniform bag of values carrying both signals.
        var dimensions: [(title: String, values: [Value])] = []
        dimensions.append(("Colors", enumValues(
            affinity: profile.colorVibeAffinity,
            counts: counts(owned) { $0.colorProfile.category },
            label: { TasteInsightsAggregator.colorVibeLabel($0) },
            swatches: { TasteInsightsAggregator.colorVibeSwatches($0) })))
        dimensions.append(("Color Warmth", enumValues(
            affinity: profile.undertoneAffinity,
            counts: counts(owned) { $0.colorProfile.undertone },
            label: { TasteInsightsAggregator.undertoneLabel($0) },
            swatches: { [TasteInsightsAggregator.undertoneSwatch($0)] })))
        dimensions.append(("Patterns", enumValues(
            affinity: profile.patternAffinity,
            counts: counts(owned) { $0.pattern },
            label: { TasteInsightsAggregator.prettify($0.rawValue) },
            swatches: { _ in [] })))
        dimensions.append(("Fabric Weight", enumValues(
            affinity: profile.fabricWeightAffinity,
            counts: counts(owned) { $0.fabricWeight },
            label: { "\(TasteInsightsAggregator.prettify($0.rawValue)) weight" },
            swatches: { _ in [] })))
        dimensions.append(("Fit", stringValues(
            affinity: profile.fitAffinity,
            counts: stringCounts(owned) { $0.fit })))
        dimensions.append(("Materials", stringValues(
            affinity: profile.materialAffinity,
            counts: stringCounts(owned) { $0.material })))
        dimensions.append(("Texture", stringValues(
            affinity: profile.textureAffinity,
            counts: stringCounts(owned) { $0.texture })))
        dimensions.append(("Style", stringValues(
            affinity: profile.styleTagAffinity,
            counts: stringCountsMulti(owned) { $0.styleTags })))
        dimensions.append(("Formality", stringValues(
            affinity: mergedFormalityAffinity(profile.formalityAffinity),
            counts: mergedFormalityCounts(owned))))

        var buyMore: [Divergence] = []
        var reconsider: [Divergence] = []
        var scoreContributions: [Double] = []

        for (title, values) in dimensions {
            let ownedTotal = values.reduce(0) { $0 + $1.count }
            guard ownedTotal > 0 else { continue }
            let hasAffinitySignal = values.contains { $0.hasAffinity && abs($0.affinity - 0.5) > 0.02 }

            var weightedAffinity = 0.0
            for value in values {
                let share = Double(value.count) / Double(ownedTotal)
                weightedAffinity += share * value.affinity

                if value.affinity > TasteInsightsAggregator.lovedThreshold, share < underOwnedShareCeiling {
                    buyMore.append(divergence(title: title, value: value, share: share, kind: .buyMore))
                } else if share >= overOwnedShareFloor, value.hasAffinity, value.affinity < indifferenceCeiling {
                    reconsider.append(divergence(title: title, value: value, share: share, kind: .reconsider))
                }
            }
            // Only dimensions with a real preference signal shape the score, so
            // an all-neutral dimension doesn't drag every user toward 50%.
            if hasAffinitySignal { scoreContributions.append(weightedAffinity) }
        }

        // Strongest first: loves you own least of, over-owned pieces you like least.
        buyMore.sort { ($0.affinity - $0.ownershipShare) > ($1.affinity - $1.ownershipShare) }
        reconsider.sort { $0.ownershipShare > $1.ownershipShare }
        buyMore = Array(buyMore.prefix(maxRowsPerList))
        reconsider = Array(reconsider.prefix(maxRowsPerList))

        let hasSignal = profile.hasSignal && !scoreContributions.isEmpty
        let scoreFraction = scoreContributions.isEmpty
            ? 0.5
            : scoreContributions.reduce(0, +) / Double(scoreContributions.count)
        let score = Int((scoreFraction * 100).rounded())

        return TasteClosetAlignmentSnapshot(
            alignmentScore: score,
            headline: headline(score: score, hasSignal: hasSignal),
            buyMore: buyMore,
            reconsider: reconsider,
            hasSignal: hasSignal
        )
    }

    // MARK: - Value bag

    /// One attribute value with both signals joined. `hasAffinity` records
    /// whether the affinity was a real learned number or the defaulted neutral
    /// 0.5, so "reconsider" never fires on an unrated value.
    private struct Value {
        let label: String
        let affinity: Double
        let hasAffinity: Bool
        let count: Int
        let swatches: [String]
    }

    private enum DivergenceKind { case buyMore, reconsider }

    private static func divergence(
        title: String, value: Value, share: Double, kind: DivergenceKind
    ) -> Divergence {
        Divergence(
            id: "\(title)-\(value.label)",
            dimensionTitle: title,
            valueLabel: value.label,
            ownershipShare: share,
            affinity: value.affinity,
            swatchHexes: value.swatches,
            message: message(label: value.label, share: share, kind: kind)
        )
    }

    private static func message(label: String, share: Double, kind: DivergenceKind) -> String {
        let pct = Int((share * 100).rounded())
        let lowered = label.lowercased()
        switch kind {
        case .buyMore:
            return share <= 0
                ? "You're drawn to \(lowered), but don't own any yet."
                : "You're drawn to \(lowered), but it's only \(pct)% of your closet."
        case .reconsider:
            return "\(label) fills \(pct)% of your closet, but it isn't a strong preference of yours."
        }
    }

    private static func headline(score: Int, hasSignal: Bool) -> String {
        guard hasSignal else {
            return "Rate a few more items and we can measure how well your closet matches your taste."
        }
        switch score {
        case 66...100: return "Your closet is \(score)% aligned with your taste — you buy what you love."
        case 45..<66: return "Your closet is \(score)% aligned with your taste — a few gaps worth closing."
        default: return "Your closet is only \(score)% aligned with your taste — worth a rethink."
        }
    }

    // MARK: - Composition counts

    private static func counts<Key: Hashable>(
        _ owned: [WardrobeItem], _ key: (WardrobeItem) -> Key?
    ) -> [Key: Int] {
        var out: [Key: Int] = [:]
        for item in owned {
            if let k = key(item) { out[k, default: 0] += 1 }
        }
        return out
    }

    /// Case-folds free-text keys ("Cotton"/"cotton") into one bucket, keeping
    /// the first-seen spelling as the display seed — same folding
    /// `TasteInsightsAggregator.makeStringDimension` applies to affinities.
    private static func stringCounts(
        _ owned: [WardrobeItem], _ key: (WardrobeItem) -> String?
    ) -> [String: (seed: String, count: Int)] {
        stringCountsMulti(owned) { key($0).map { [$0] } ?? [] }
    }

    private static func stringCountsMulti(
        _ owned: [WardrobeItem], _ keys: (WardrobeItem) -> [String]
    ) -> [String: (seed: String, count: Int)] {
        var out: [String: (seed: String, count: Int)] = [:]
        for item in owned {
            for raw in keys(item) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let fold = trimmed.lowercased()
                let existing = out[fold]
                out[fold] = (existing?.seed ?? trimmed, (existing?.count ?? 0) + 1)
            }
        }
        return out
    }

    // MARK: - Value builders (join affinity + composition per dimension)

    private static func enumValues<Key: Hashable>(
        affinity: [Key: Double],
        counts: [Key: Int],
        label: (Key) -> String,
        swatches: (Key) -> [String]
    ) -> [Value] {
        var keys = Set(counts.keys)
        keys.formUnion(affinity.keys)
        return keys.map { key in
            Value(
                label: label(key),
                affinity: affinity[key] ?? 0.5,
                hasAffinity: affinity[key] != nil,
                count: counts[key] ?? 0,
                swatches: swatches(key)
            )
        }
    }

    private static func stringValues(
        affinity: [String: Double],
        counts: [String: (seed: String, count: Int)]
    ) -> [Value] {
        // Fold affinity keys the same way composition keys are folded, then
        // merge on the shared lowercased key so a value's like and its
        // ownership share line up.
        var affFolded: [String: (seed: String, total: Double, n: Int)] = [:]
        for (rawKey, value) in affinity {
            let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let fold = trimmed.lowercased()
            let existing = affFolded[fold]
            affFolded[fold] = (existing?.seed ?? trimmed, (existing?.total ?? 0) + value, (existing?.n ?? 0) + 1)
        }

        var keys = Set(counts.keys)
        keys.formUnion(affFolded.keys)
        return keys.map { fold in
            let aff = affFolded[fold]
            let seed = counts[fold]?.seed ?? aff?.seed ?? fold
            return Value(
                label: TasteInsightsAggregator.prettify(seed),
                affinity: aff.map { $0.total / Double($0.n) } ?? 0.5,
                hasAffinity: aff != nil,
                count: counts[fold]?.count ?? 0,
                swatches: []
            )
        }
    }

    // MARK: - Formality (numeric bands → shared descriptor buckets)

    private static func mergedFormalityAffinity(_ map: [Int: Double]) -> [String: Double] {
        var sums: [String: (total: Double, n: Int)] = [:]
        for (band, affinity) in map {
            let key = TasteInsightsAggregator.formalityDescriptor(band)
            let existing = sums[key] ?? (0, 0)
            sums[key] = (existing.total + affinity, existing.n + 1)
        }
        return sums.mapValues { $0.total / Double($0.n) }
    }

    private static func mergedFormalityCounts(_ owned: [WardrobeItem]) -> [String: (seed: String, count: Int)] {
        var out: [String: (seed: String, count: Int)] = [:]
        for item in owned {
            let descriptor = TasteInsightsAggregator.formalityDescriptor(Int(item.formalityScore.rounded()))
            let fold = descriptor.lowercased()
            let existing = out[fold]
            out[fold] = (descriptor, (existing?.count ?? 0) + 1)
        }
        return out
    }
}
