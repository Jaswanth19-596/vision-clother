//
//  PairCompatibilityScoring.swift
//  Vision_clother
//
//  Mathematical Pair-Compatibility Scoring Engine (PRD.md §3.4).
//
//  Isolated, mockable, pure — no I/O, no SwiftData context, 100% immune to
//  NaN (CLAUDE.md §4). Ghost elements (PRD §3.2) flow through the identical
//  code path as real items — there is no `isGhostElement` branch anywhere in
//  this file, by design (see the plan's "Ghost elements: scored normally,
//  labeled distinctly" decision).
//
//  Fix applied vs. the PRD's literal formula: PRD §3.4 sums raw ±1.0 feedback
//  into a [0,1] aesthetic prior, which can push the posterior negative or
//  above 1. Here, feedback is normalized to [0,1] before summing (each liked
//  pairing contributes 1.0, each disliked pairing 0.0), so the posterior is
//  always a weighted average of two [0,1] quantities and never leaves
//  [0,1] — the `w0`-shrinkage behavior the PRD intended is preserved exactly.
//

import Foundation

enum PairCompatibilityScoring {
    /// Prior weight constant. PRD §3.4 recommends 3.0 so a single extreme
    /// feedback event can't instantly overwhelm the deterministic prior.
    static let defaultPriorWeight: Double = 3.0

    /// Deterministic aesthetic prior in `[0,1]`, based only on the two
    /// items' attributes (formality spread, pattern clash, color-vibe
    /// clash). No history, no randomness — safe to call on ghost elements.
    static func aestheticPrior(_ a: WardrobeItem, _ b: WardrobeItem) -> Double {
        var score = 1.0

        let formalityDelta = abs(a.formalityScore - b.formalityScore)
        if formalityDelta > FashionKnowledgeConstants.DressCode.majorFormalityMismatchDelta {
            score -= 0.4
        } else if formalityDelta > FashionKnowledgeConstants.DressCode.minorFormalityMismatchDelta {
            score -= 0.15
        }

        if a.pattern != .solid, b.pattern != .solid, a.pattern != b.pattern {
            score -= 0.3
        }

        // Fit & Silhouette Harmony (added 2026-07-10)
        if let fitA = a.fit?.lowercased(), let fitB = b.fit?.lowercased() {
            let isLooseA = fitA.contains("oversized") || fitA.contains("relaxed") || fitA.contains("boxy") || fitA.contains("loose")
            let isLooseB = fitB.contains("oversized") || fitB.contains("relaxed") || fitB.contains("boxy") || fitB.contains("loose") || fitB.contains("wide")
            let isSlimA = fitA.contains("slim") || fitA.contains("fitted") || fitA.contains("tailored")
            let isSlimB = fitB.contains("slim") || fitB.contains("fitted") || fitB.contains("tailored")

            if (isLooseA && isSlimB) || (isSlimA && isLooseB) {
                score += 0.15 // Classically balanced proportions (loose + slim)
            } else if isLooseA && isLooseB {
                score += 0.10 // Oversized/relaxed casual statement look
            } else if isSlimA && isSlimB {
                score += 0.05 // Fitted silhouette
            }
        }

        // Fabric & Material Harmony (added 2026-07-10)
        if let matA = a.material?.lowercased(), let matB = b.material?.lowercased() {
            let isLinenA = matA.contains("linen")
            let isLinenB = matB.contains("linen")
            let isWoolA = matA.contains("wool")
            let isWoolB = matB.contains("wool")
            let isCottonA = matA.contains("cotton")
            let isCottonB = matB.contains("cotton")
            let isDenimA = matA.contains("denim")
            let isDenimB = matB.contains("denim")

            if (isLinenA && isWoolB) || (isWoolA && isLinenB) {
                score -= 0.20 // Fabric weight clash: heavy wool and lightweight linen
            } else if (isLinenA && isLinenB) || (isLinenA && isCottonB) || (isCottonA && isLinenB) {
                score += 0.15 // Harmonious lightweight warm-weather fabrics
            } else if (isDenimA && isCottonB) || (isCottonA && isDenimB) {
                score += 0.10 // Classic denim + cotton pairing
            }
        }

        if ColorHarmony.hsl(fromHex: a.colorProfile.primaryHex) != nil,
           ColorHarmony.hsl(fromHex: b.colorProfile.primaryHex) != nil {
            // Real hue-based color theory (Domain/ColorHarmony.swift) —
            // rewards complementary/analogous/monochrome pairings and
            // penalizes muddy mid-hue clashes, replacing the old flat
            // "both vibrant" penalty below.
            let harmony = ColorHarmony.harmonyScore(a.colorProfile.primaryHex, b.colorProfile.primaryHex)
            score += (harmony - 0.5) * 0.4

            let undertone = ColorHarmony.undertoneCompatibility(a.colorProfile.undertone, b.colorProfile.undertone)
            score += (undertone - 0.5) * 0.2
        } else if a.colorProfile.category == .vibrant, b.colorProfile.category == .vibrant {
            // Graceful degrade: malformed/missing hex on either item falls
            // back to the coarse category-level clash check.
            score -= 0.2
        }

        return score.clamped(to: 0...1)
    }

    /// `P(Pair_A,B | History)` — PRD §3.4's Prior-Adjusted-History formula,
    /// with feedback normalized to `[0, evaluationCount]` (see file header).
    ///
    /// NaN-safe: `priorWeight` defaults to 3.0 per CLAUDE.md, and the
    /// denominator is guarded even if a caller passes `priorWeight: 0` with
    /// `evaluationCount: 0` — falls back to the raw prior rather than
    /// dividing by zero.
    static func pairCompatibilityScore(
        aestheticPrior: Double,
        feedbackSum: Double,
        evaluationCount: Int,
        priorWeight: Double = defaultPriorWeight
    ) -> Double {
        let denominator = priorWeight + Double(evaluationCount)
        guard denominator > 0 else { return aestheticPrior.clamped(to: 0...1) }
        let numerator = priorWeight * aestheticPrior + feedbackSum
        return (numerator / denominator).clamped(to: 0...1)
    }

    /// `Preference(Item)` — same Bayesian-shrinkage shape as the pair score,
    /// but seeded at a neutral 0.5 prior: unlike a pair, a single item has
    /// no deterministic aesthetic signal for "do I like owning this,"
    /// so with zero feedback it contributes a neutral midpoint rather than 0.
    static func itemPreference(
        likeCount: Int,
        dislikeCount: Int,
        priorWeight: Double = defaultPriorWeight
    ) -> Double {
        let evaluationCount = likeCount + dislikeCount
        let denominator = priorWeight + Double(evaluationCount)
        guard denominator > 0 else { return 0.5 }
        let numerator = priorWeight * 0.5 + Double(likeCount)
        return (numerator / denominator).clamped(to: 0...1)
    }

    /// All unordered 2-item combinations from a slot-mixed set of garments
    /// (e.g. the up-to-4 items in one `OutfitCombination`). Empty/singleton
    /// input yields an empty array rather than crashing.
    static func pairwiseCombinations(_ items: [WardrobeItem]) -> [(WardrobeItem, WardrobeItem)] {
        guard items.count > 1 else { return [] }
        var pairs: [(WardrobeItem, WardrobeItem)] = []
        for i in 0..<(items.count - 1) {
            for j in (i + 1)..<items.count {
                pairs.append((items[i], items[j]))
            }
        }
        return pairs
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
