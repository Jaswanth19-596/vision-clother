//
//  ColorHarmony.swift
//  Vision_clother
//
//  Real color-theory scoring (PRD.md §3.4), replacing the old flat
//  `-0.2` "both vibrant" penalty in `PairCompatibilityScoring.aestheticPrior`
//  with hue/saturation/undertone reasoning over the hex values every
//  `WardrobeItem.colorProfile` already carries. Part of the 2026-07-10
//  LLM-as-Recommender reversal (docs/decisions/resolved-v1.md) — this powers
//  both the deterministic fallback engine and the validator's re-scoring, so
//  outfits stay chromatically sane whether or not the recommendation LLM is
//  reachable.
//
//  Pure, no I/O (Domain/CLAUDE.md). NaN-safe: every division is guarded, and
//  malformed/missing hex degrades to a neutral 0.5 ("no signal") rather than
//  crashing or skewing the score.
//

import Foundation

enum ColorHarmony {
    /// Parses `"#RRGGBB"` (leading `#` optional, case-insensitive) into HSL.
    /// Returns `nil` for anything malformed — callers must treat that as "no
    /// color signal" and degrade gracefully, never force-unwrap.
    static func hsl(fromHex hex: String) -> (h: Double, s: Double, l: Double)? {
        var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized.removeAll { $0 == "#" }
        guard sanitized.count == 6, let value = UInt32(sanitized, radix: 16) else { return nil }

        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255

        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let delta = maxV - minV
        let l = (maxV + minV) / 2

        guard delta > 0.0001 else {
            // Achromatic (gray/white/black) — hue is undefined; report 0 and
            // let callers key off saturation ~0 to treat it as neutral.
            return (h: 0, s: 0, l: l)
        }

        let s = l > 0.5 ? delta / (2 - maxV - minV) : delta / (maxV + minV)

        var h: Double
        switch maxV {
        case r: h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        case g: h = (b - r) / delta + 2
        default: h = (r - g) / delta + 4
        }
        h *= 60
        if h < 0 { h += 360 }

        return (h: h, s: s, l: l)
    }

    /// Smallest angular distance between two hues, in `[0, 180]`.
    private static func hueDistance(_ h1: Double, _ h2: Double) -> Double {
        let diff = abs(h1 - h2).truncatingRemainder(dividingBy: 360)
        return diff > 180 ? 360 - diff : diff
    }

    /// Below this saturation, hue readings are noisy and the color reads as
    /// a neutral (gray/white/black/near-black) that anchors safely with
    /// anything — checked before any hue-distance logic runs.
    private static let achromaticSaturationThreshold: Double = 0.12

    /// Harmony score in `[0,1]` for two hex colors, from classical hue
    /// relationships: monochrome/analogous and complementary pairings are
    /// rewarded, the muddy mid-hue "clash zone" is penalized (more so as
    /// both colors get more saturated). Returns `0.5` (neutral, no opinion)
    /// if either hex is malformed — never a penalty, never a bonus.
    static func harmonyScore(_ hexA: String, _ hexB: String) -> Double {
        guard let a = hsl(fromHex: hexA), let b = hsl(fromHex: hexB) else { return 0.5 }

        // Either color being achromatic is always a safe pairing — neutrals
        // anchor any outfit regardless of the other color's hue.
        if a.s < achromaticSaturationThreshold || b.s < achromaticSaturationThreshold {
            return 0.85
        }

        let distance = hueDistance(a.h, b.h)
        let avgSaturation = (a.s + b.s) / 2

        switch distance {
        case 0..<15:
            // Monochrome — same hue family, always safe.
            return 0.9
        case 15..<40:
            // Analogous — adjacent hues, classically harmonious.
            return 0.8
        case 40..<60:
            // Transitional zone, interpolating down toward the clash floor.
            let t = (distance - 40) / 20
            return 0.8 - t * 0.3
        case 60..<150:
            // The "muddy" clash zone — penalize, more so as both colors get
            // more saturated (two vivid clashing hues read worse than two
            // muted versions of the same hues).
            return max(0.5 - avgSaturation * 0.3, 0.2)
        default:
            // 150...180 — complementary, bold and classic, rewarded.
            let t = (distance - 150) / 30
            return 0.65 + t * 0.3
        }
    }

    /// Compatibility score in `[0,1]` for two undertones. `nil` on either
    /// side (no derived/tagged undertone yet) scores neutral — "no signal,"
    /// not a penalty.
    static func undertoneCompatibility(_ a: Undertone?, _ b: Undertone?) -> Double {
        guard let a, let b else { return 0.5 }
        if a == b { return 1.0 }
        if a == .neutral || b == .neutral { return 0.75 }
        return 0.4 // warm vs. cool
    }
}
