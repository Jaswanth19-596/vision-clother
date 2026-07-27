//
//  OutfitChemistryAggregator.swift
//  Vision_clother
//
//  Analytics & Insights — "Chemistry" sub-tab. Every other Insights aggregator
//  reports on single-garment taste or closet composition; this is the one
//  surface built on genuinely new signal the app didn't have before
//  Multi-Garment "Discover Your Style": whole-look color harmony, style
//  coherence, and formality "rule-breaking" learned from swiped full-outfit
//  photos (`Models/SwipeDiscovery.swift`'s `SwipeCombinationEvent`).
//
//  Pure, no SwiftUI (per Domain/CLAUDE.md), NaN-safe for empty input.
//

import Foundation

/// Sendable projection of a `SwipeCombinationEvent` — the only subset this
/// aggregator reads. Used by `Features/Insights/OutfitChemistryView.swift` to
/// pass `@Query`-fetched rows across to the view model without transmitting
/// live `@Model` instances, mirroring `ItemAttributeSnapshot`'s role for
/// `WardrobeItem` in `Domain/AttributePreferenceProfile.swift`.
struct RatedCombinationSnapshot: Sendable {
    let colorHarmony: ColorHarmonyDescriptor
    let styleCoherenceTags: [String]
    let formalityConsistency: FormalityConsistency
    let rationale: String
    let sentiment: SwipeSentiment
    let recordedAt: Date

    // Relational styling attributes, round 2 (added 2026-07-27) — mirrors
    // `RatedCombination`'s expanded fields (`Domain/AttributePreferenceProfile.swift`)
    // so a row can represent either a `SwipeCombinationEvent` (stock-photo
    // swipe) or an `OutfitFeedback` new-flow row (owned-combination swipe).
    // Defaulted to `nil` so existing call sites keep compiling unchanged.
    var paletteArchetype: PaletteArchetype? = nil
    var contrastLevel: ContrastLevel? = nil
    var colorSandwiching: Bool? = nil
    var proportionRatio: ProportionRatio? = nil
    var volumeBalance: VolumeBalance? = nil
    var textureContrast: TextureContrast? = nil
    var formalityBridge: FormalityBridge? = nil
}

struct OutfitChemistrySnapshot: Equatable {
    struct Row: Identifiable, Equatable {
        let id: String
        let label: String
        /// `[0,1]`, 0.5 neutral — same shrunk-affinity scale every other
        /// Insights bar chart uses.
        let affinity: Double
    }

    /// Ranked highest-affinity first — which whole-look color pairings
    /// (`ColorHarmonyDescriptor`) the user's loved/liked full-outfit swipes
    /// lean toward.
    let colorHarmonyRows: [Row]
    /// Ranked highest-affinity first — the combo-level style identities
    /// (`SwipeCombinationEvent.styleCoherenceTags`) joined against the same
    /// `styleTagAffinity` the Taste tab already learns from single garments.
    let styleCoherenceRows: [Row]
    /// Share of loved/liked full-outfit swipes whose formality consistency
    /// was `.intentionalContrast` (e.g. blazer + sneakers) rather than
    /// `.consistent` or `.mismatched` — `[0,1]`.
    let intentionalContrastShare: Double
    /// A few sample rationale sentences from the user's most-loved outfit
    /// combinations, for the "Why These Work" card. Empty if none loved yet.
    let sampleRationales: [String]

    // Relational styling attributes, round 2 (added 2026-07-27) — same
    // ranked-row shape as `colorHarmonyRows`, read directly from the
    // profile's new `*Affinity` maps (already aggregated across both
    // stock-photo and owned-combination swipes by `AttributePreferenceProfile.build`).
    let paletteArchetypeRows: [Row]
    let contrastLevelRows: [Row]
    let proportionRatioRows: [Row]
    let volumeBalanceRows: [Row]
    let textureContrastRows: [Row]
    let formalityBridgeRows: [Row]
    /// Share of loved/liked combinations flagged `colorSandwiching == true`
    /// — mirrors `intentionalContrastShare`'s shape.
    let colorSandwichingShare: Double

    /// False for a brand-new user (no full-outfit swipes with real signal
    /// yet) — gates the empty state in the UI.
    let hasSignal: Bool
}

enum OutfitChemistryAggregator {
    /// At most this many sample rationales shown, keeping the card scannable.
    private static let maxSampleRationales = 3
    /// Mirrors `TasteInsightsAggregator.neutralEpsilon` — a value this close
    /// to neutral 0.5 carries no real signal yet.
    private static let neutralEpsilon: Double = 0.02

    static func build(
        profile: AttributePreferenceProfile,
        combinations: [RatedCombinationSnapshot]
    ) -> OutfitChemistrySnapshot {
        let colorHarmonyRows = rankedColorHarmonyRows(profile: profile)
        let styleCoherenceRows = rankedStyleCoherenceRows(combinations: combinations, styleTagAffinity: profile.styleTagAffinity)
        let paletteArchetypeRows = rankedRows(profile.paletteArchetypeAffinity, idPrefix: "palette")
        let contrastLevelRows = rankedRows(profile.contrastLevelAffinity, idPrefix: "contrast")
        let proportionRatioRows = rankedRows(profile.proportionRatioAffinity, idPrefix: "proportion")
        let volumeBalanceRows = rankedRows(profile.volumeBalanceAffinity, idPrefix: "volume")
        let textureContrastRows = rankedRows(profile.textureContrastAffinity, idPrefix: "texture")
        let formalityBridgeRows = rankedRows(profile.formalityBridgeAffinity, idPrefix: "bridge")

        let lovedOrLiked = combinations.filter { $0.sentiment == .love || $0.sentiment == .like }
        let intentionalContrastShare = lovedOrLiked.isEmpty
            ? 0.0
            : Double(lovedOrLiked.filter { $0.formalityConsistency == .intentionalContrast }.count) / Double(lovedOrLiked.count)
        let colorSandwichingShare = lovedOrLiked.isEmpty
            ? 0.0
            : Double(lovedOrLiked.filter { $0.colorSandwiching == true }.count) / Double(lovedOrLiked.count)

        let sampleRationales = Array(
            combinations
                .filter { $0.sentiment == .love }
                .sorted { $0.recordedAt > $1.recordedAt }
                .map(\.rationale)
                .filter { !$0.isEmpty }
                .prefix(maxSampleRationales)
        )

        return OutfitChemistrySnapshot(
            colorHarmonyRows: colorHarmonyRows,
            styleCoherenceRows: styleCoherenceRows,
            intentionalContrastShare: intentionalContrastShare,
            sampleRationales: sampleRationales,
            paletteArchetypeRows: paletteArchetypeRows,
            contrastLevelRows: contrastLevelRows,
            proportionRatioRows: proportionRatioRows,
            volumeBalanceRows: volumeBalanceRows,
            textureContrastRows: textureContrastRows,
            formalityBridgeRows: formalityBridgeRows,
            colorSandwichingShare: colorSandwichingShare,
            hasSignal: !colorHarmonyRows.isEmpty || !styleCoherenceRows.isEmpty || !paletteArchetypeRows.isEmpty
                || !contrastLevelRows.isEmpty || !proportionRatioRows.isEmpty || !volumeBalanceRows.isEmpty
                || !textureContrastRows.isEmpty || !formalityBridgeRows.isEmpty
        )
    }

    /// Shared ranked-row builder for every `RawRepresentable<String>` enum
    /// dimension added 2026-07-27 (`paletteArchetypeAffinity`,
    /// `contrastLevelAffinity`, etc.) — mirrors `rankedColorHarmonyRows`'s
    /// filter/sort shape exactly, generalized since these six dimensions all
    /// have the identical "enum keyed, prettified rawValue label" posture.
    private static func rankedRows<Key: RawRepresentable & Hashable>(
        _ affinity: [Key: Double], idPrefix: String
    ) -> [OutfitChemistrySnapshot.Row] where Key.RawValue == String {
        affinity
            .filter { abs($0.value - 0.5) > neutralEpsilon }
            .map { OutfitChemistrySnapshot.Row(id: "\(idPrefix)-\($0.key.rawValue)", label: TasteInsightsAggregator.prettify($0.key.rawValue), affinity: $0.value) }
            .sorted { $0.affinity == $1.affinity ? $0.label < $1.label : $0.affinity > $1.affinity }
    }

    private static func rankedColorHarmonyRows(profile: AttributePreferenceProfile) -> [OutfitChemistrySnapshot.Row] {
        let entries = profile.colorHarmonyAffinity.filter { abs($0.value - 0.5) > neutralEpsilon }
        return entries
            .map { OutfitChemistrySnapshot.Row(id: "harmony-\($0.key.rawValue)", label: colorHarmonyLabel($0.key), affinity: $0.value) }
            .sorted { $0.affinity == $1.affinity ? $0.label < $1.label : $0.affinity > $1.affinity }
    }

    /// Joins each distinct combo-level style tag (case-folded, first-seen
    /// spelling as the display seed — same convention
    /// `TasteInsightsAggregator.makeStringDimension` uses) against the
    /// existing `styleTagAffinity` map. A tag with no match in that map
    /// (never independently rated) is skipped rather than shown at a
    /// meaningless neutral 0.5.
    private static func rankedStyleCoherenceRows(
        combinations: [RatedCombinationSnapshot],
        styleTagAffinity: [String: Double]
    ) -> [OutfitChemistrySnapshot.Row] {
        var foldedAffinity: [String: Double] = [:]
        for (rawKey, value) in styleTagAffinity {
            foldedAffinity[rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = value
        }

        var seenLabelSeeds: [String: String] = [:]
        for combo in combinations {
            for tag in combo.styleCoherenceTags {
                let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let key = trimmed.lowercased()
                if seenLabelSeeds[key] == nil { seenLabelSeeds[key] = trimmed }
            }
        }

        let entries = seenLabelSeeds.compactMap { key, seed -> OutfitChemistrySnapshot.Row? in
            guard let affinity = foldedAffinity[key], abs(affinity - 0.5) > neutralEpsilon else { return nil }
            return OutfitChemistrySnapshot.Row(id: "style-\(key)", label: TasteInsightsAggregator.prettify(seed), affinity: affinity)
        }
        return entries.sorted { $0.affinity == $1.affinity ? $0.label < $1.label : $0.affinity > $1.affinity }
    }

    static func colorHarmonyLabel(_ descriptor: ColorHarmonyDescriptor) -> String {
        switch descriptor {
        case .monochrome: return "Monochrome"
        case .analogous: return "Analogous"
        case .complementary: return "Complementary"
        case .triadic: return "Triadic"
        case .highContrast: return "High Contrast"
        case .clashing: return "Clashing"
        }
    }
}
