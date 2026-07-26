//
//  TasteInsightsAggregator.swift
//  Vision_clother
//
//  Analytics & Insights — the read-side presentation of the unified taste
//  model. Every other Insights aggregator counts the *closet* (composition,
//  utilization, redundancy); this one is the only surface that shows the user
//  their own learned *preferences* — what they gravitate toward vs. avoid,
//  per attribute dimension — straight off the single `AttributePreferenceProfile`
//  that swipes AND ratings feed (Unified Preference Engine, 2026-07-24).
//
//  Pure, no SwiftUI (per Domain/CLAUDE.md). It re-expresses the profile's
//  affinity maps as ranked, human-labeled rows — deliberately in plain,
//  non-fashion language (e.g. "Bright & Bold", not "vibrant") with example
//  colour swatches (as hex strings — no SwiftUI Color here) so a normal user
//  can read it. Silhouette is intentionally NOT surfaced: it's unreliable
//  free-text AI output and overlaps with Fit.
//

import Foundation

struct TasteInsightsSnapshot: Equatable {
    /// One attribute dimension (e.g. Colors, Fit, Materials) the profile has
    /// learned something about, as a ranked list of its observed values.
    struct Dimension: Identifiable, Equatable {
        let id: String
        let title: String
        /// One-line plain-language explanation shown under the title, when the
        /// dimension needs one (e.g. "Color Warmth"). `nil` for self-evident
        /// dimensions.
        let caption: String?
        /// Ranked highest-affinity first; `affinity` in `[0,1]`, 0.5 neutral.
        let rows: [Row]
        /// Values the user gravitates toward (affinity > `lovedThreshold`),
        /// strongest first. Human-readable labels.
        let loved: [String]
        /// Values the user tends to avoid (affinity < `avoidThreshold`), most
        /// avoided first.
        let avoided: [String]
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let label: String
        let affinity: Double
        /// Representative colour swatches (hex strings) for colour-based
        /// dimensions, so the value is legible without fashion vocabulary.
        /// Empty for non-colour dimensions.
        let swatchHexes: [String]
    }

    /// Only dimensions with real (non-neutral) signal, in a fixed display order.
    let dimensions: [Dimension]
    /// Mirrors `AttributePreferenceProfile.hasSignal` — false for a brand-new
    /// user, which gates the "still learning" calibration state in the UI.
    let hasSignal: Bool
    /// One-line prose summary of the strongest leanings, for the Taste header
    /// and the compact taste callout on the other Insights tabs. Empty-safe.
    let fingerprint: String
}

enum TasteInsightsAggregator {
    /// Affinity above this reads as a genuine "like"; below `avoidThreshold`
    /// as a "dislike". Same > 0.6 / < 0.4 split `StylistBrain`'s symmetric
    /// taste injection uses when it builds the LLM's favorites/avoid lists, so
    /// what the user *sees* here matches what the recommender is told.
    static let lovedThreshold: Double = 0.6
    static let avoidThreshold: Double = 0.4

    /// A dimension whose every value sits within this of neutral 0.5 carries
    /// no real signal yet (Bayesian shrinkage seeds everything at 0.5), so it's
    /// dropped rather than shown as a flat all-50% chart.
    private static let neutralEpsilon: Double = 0.02

    static func build(profile: AttributePreferenceProfile) -> TasteInsightsSnapshot {
        var dimensions: [TasteInsightsSnapshot.Dimension] = []

        // Colours — plain-language labels + example swatches keyed off the vibe.
        if let d = makeDimension(id: "colors", title: "Colors", caption: nil,
                                 map: profile.colorVibeAffinity,
                                 label: { colorVibeLabel($0) },
                                 swatches: { colorVibeSwatches($0) }) {
            dimensions.append(d)
        }
        // Undertone → "Color Warmth", the friendlier framing.
        if let d = makeDimension(id: "warmth", title: "Color Warmth",
                                 caption: "Whether your colours lean warm (golden-based) or cool (blue-based).",
                                 map: profile.undertoneAffinity,
                                 label: { undertoneLabel($0) },
                                 swatches: { [undertoneSwatch($0)] }) {
            dimensions.append(d)
        }
        if let d = makeStringDimension(id: "patterns", title: "Patterns", caption: nil,
                                       map: enumKeyedToStrings(profile.patternAffinity) { prettify($0.rawValue) }) {
            dimensions.append(d)
        }
        if let d = makeStringDimension(id: "fit", title: "Fit", caption: nil,
                                       map: profile.fitAffinity) {
            dimensions.append(d)
        }
        // Silhouette deliberately omitted (unreliable free-text, overlaps Fit).
        if let d = makeStringDimension(id: "materials", title: "Materials", caption: nil,
                                       map: profile.materialAffinity) {
            dimensions.append(d)
        }
        if let d = makeStringDimension(id: "texture", title: "Texture", caption: nil,
                                       map: profile.textureAffinity) {
            dimensions.append(d)
        }
        if let d = makeStringDimension(id: "style", title: "Style", caption: nil,
                                       map: profile.styleTagAffinity) {
            dimensions.append(d)
        }
        if let d = makeStringDimension(id: "fabric", title: "Fabric Weight", caption: nil,
                                       map: enumKeyedToStrings(profile.fabricWeightAffinity) { "\(prettify($0.rawValue)) weight" }) {
            dimensions.append(d)
        }
        // Formality is keyed by numeric band (0–5); collapse bands that share a
        // descriptor (Casual/Smart-Casual/Formal) into one row, averaging their
        // affinities, so the chart reads in words rather than raw band numbers.
        if let d = makeStringDimension(id: "formality", title: "Formality", caption: nil,
                                       map: mergedFormality(profile.formalityAffinity)) {
            dimensions.append(d)
        }

        return TasteInsightsSnapshot(
            dimensions: dimensions,
            hasSignal: profile.hasSignal,
            fingerprint: fingerprint(from: dimensions)
        )
    }

    // MARK: - Dimension construction

    /// Ranks an affinity map (any key type) into display rows via explicit
    /// label + swatch closures, or returns `nil` if the map is empty or carries
    /// no non-neutral signal.
    private static func makeDimension<Key: Hashable>(
        id: String,
        title: String,
        caption: String?,
        map: [Key: Double],
        label: (Key) -> String,
        swatches: (Key) -> [String]
    ) -> TasteInsightsSnapshot.Dimension? {
        guard !map.isEmpty else { return nil }
        guard map.values.contains(where: { abs($0 - 0.5) > neutralEpsilon }) else { return nil }

        let entries = map.map { (label: label($0.key), affinity: $0.value, swatches: swatches($0.key)) }
        return assemble(id: id, title: title, caption: caption, entries: entries)
    }

    /// String-keyed convenience that also case-folds keys so free-text values
    /// like "Cotton" and "cotton" don't render as two separate bars.
    private static func makeStringDimension(
        id: String,
        title: String,
        caption: String?,
        map: [String: Double]
    ) -> TasteInsightsSnapshot.Dimension? {
        guard !map.isEmpty else { return nil }

        // Merge case-insensitively; canonical label is the prettified form,
        // affinity is the mean of the collided buckets.
        var grouped: [String: (labelSeed: String, total: Double, count: Int)] = [:]
        for (rawKey, affinity) in map {
            let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let foldKey = trimmed.lowercased()
            let existing = grouped[foldKey]
            grouped[foldKey] = (existing?.labelSeed ?? trimmed, (existing?.total ?? 0) + affinity, (existing?.count ?? 0) + 1)
        }
        guard !grouped.isEmpty else { return nil }

        let merged = grouped.mapValues { $0.total / Double($0.count) }
        guard merged.values.contains(where: { abs($0 - 0.5) > neutralEpsilon }) else { return nil }

        let entries = grouped.map { (label: prettify($0.value.labelSeed), affinity: $0.value.total / Double($0.value.count), swatches: [String]()) }
        return assemble(id: id, title: title, caption: caption, entries: entries)
    }

    /// Shared ranking + loved/avoided split for both dimension builders.
    private static func assemble(
        id: String,
        title: String,
        caption: String?,
        entries: [(label: String, affinity: Double, swatches: [String])]
    ) -> TasteInsightsSnapshot.Dimension {
        // Highest affinity first; tie-break by label for a stable order.
        let ranked = entries.sorted { lhs, rhs in
            lhs.affinity == rhs.affinity ? lhs.label < rhs.label : lhs.affinity > rhs.affinity
        }

        let rows = ranked.map {
            TasteInsightsSnapshot.Row(id: "\(id)-\($0.label)", label: $0.label, affinity: $0.affinity, swatchHexes: $0.swatches)
        }
        let loved = ranked.filter { $0.affinity > lovedThreshold }.map(\.label)
        let avoided = ranked.filter { $0.affinity < avoidThreshold }
            .sorted { $0.affinity < $1.affinity }
            .map(\.label)

        return TasteInsightsSnapshot.Dimension(id: id, title: title, caption: caption, rows: rows, loved: loved, avoided: avoided)
    }

    private static func enumKeyedToStrings<Key: Hashable>(_ map: [Key: Double], label: (Key) -> String) -> [String: Double] {
        var out: [String: Double] = [:]
        for (key, value) in map { out[label(key)] = value }
        return out
    }

    /// Collapses the numeric formality bands into their descriptor buckets,
    /// averaging the affinity of any bands that share a descriptor.
    private static func mergedFormality(_ map: [Int: Double]) -> [String: Double] {
        var sums: [String: (total: Double, count: Int)] = [:]
        for (band, affinity) in map {
            let key = formalityDescriptor(band)
            let existing = sums[key] ?? (0, 0)
            sums[key] = (existing.total + affinity, existing.count + 1)
        }
        return sums.mapValues { $0.total / Double($0.count) }
    }

    // MARK: - Fingerprint

    /// Weaves the single strongest loved value from a few high-signal
    /// dimensions into one sentence. Empty-safe.
    private static func fingerprint(from dimensions: [TasteInsightsSnapshot.Dimension]) -> String {
        func phrase(_ id: String, _ loved: String) -> String {
            switch id {
            case "colors": return "\(loved.lowercased()) colours"
            case "fit": return "\(loved.lowercased()) fits"
            case "materials": return "\(loved.lowercased()) materials"
            case "patterns": return "\(loved.lowercased()) patterns"
            default: return loved.lowercased()
            }
        }

        let priority = ["colors", "fit", "materials", "patterns"]
        var phrases: [String] = []
        for id in priority {
            guard let dim = dimensions.first(where: { $0.id == id }), let top = dim.loved.first else { continue }
            phrases.append(phrase(id, top))
            if phrases.count == 3 { break }
        }

        guard !phrases.isEmpty else {
            return "Your taste is still taking shape — keep swiping and rating to sharpen it."
        }
        return "You gravitate toward \(conjoin(phrases))."
    }

    /// "a", "a and b", or "a, b, and c".
    private static func conjoin(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return "\(items.dropLast().joined(separator: ", ")), and \(items.last!)"
        }
    }

    // MARK: - Plain-language colour labels + swatches

    static func colorVibeLabel(_ vibe: ColorVibe) -> String {
        switch vibe {
        case .neutral: return "Neutrals"
        case .earthTones: return "Earthy"
        case .monochrome: return "Black & White"
        case .vibrant: return "Bright & Bold"
        case .pastel: return "Soft & Light"
        }
    }

    static func colorVibeSwatches(_ vibe: ColorVibe) -> [String] {
        switch vibe {
        case .neutral: return ["#1C1C1E", "#FFFFFF", "#8E8E93", "#1C2A3A"]
        case .earthTones: return ["#8B5A2B", "#6B8E23", "#B7410E", "#C19A6B"]
        case .monochrome: return ["#000000", "#808080", "#FFFFFF"]
        case .vibrant: return ["#E4002B", "#0057FF", "#FFD400"]
        case .pastel: return ["#F7CAC9", "#B5EAD7", "#AEC6CF"]
        }
    }

    static func undertoneLabel(_ undertone: Undertone) -> String {
        switch undertone {
        case .warm: return "Warm"
        case .cool: return "Cool"
        case .neutral: return "Balanced"
        }
    }

    static func undertoneSwatch(_ undertone: Undertone) -> String {
        switch undertone {
        case .warm: return "#E8B04B"
        case .cool: return "#5B8DEF"
        case .neutral: return "#A9A197"
        }
    }

    // MARK: - Labels

    static func prettify(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Mirrors `AttributePreferenceProfile.formalityDescriptor` (private there)
    /// so the wording matches the rest of the app.
    static func formalityDescriptor(_ band: Int) -> String {
        switch band {
        case ..<2: return "Casual"
        case 2..<4: return "Smart-Casual"
        default: return "Formal"
        }
    }
}
