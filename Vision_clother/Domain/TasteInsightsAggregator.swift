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
        /// Category-partitioned taste (surfaced 2026-07-27b): the same ranked
        /// rows broken out per `Slot`, off the profile's `*BySlot` maps —
        /// "oversized" means something different for a top than for a bottom,
        /// and those maps already drove scoring
        /// (`AttributePreferenceProfile.matchDetail`) without ever being shown.
        /// Empty for a dimension with no per-slot signal yet, in which case
        /// the UI renders exactly the flat card it always did.
        let categories: [Category]
    }

    /// One `Slot`'s slice of a dimension — e.g. the Colors dimension's
    /// "Tops" breakdown.
    struct Category: Identifiable, Equatable {
        let id: String
        let slot: Slot
        /// Plural display name for the slot ("Tops", "Shoes").
        let title: String
        /// Ranked highest-affinity first, same scale as `Dimension.rows`.
        let rows: [Row]
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
                                 bySlot: profile.colorVibeAffinityBySlot,
                                 label: { colorVibeLabel($0) },
                                 swatches: { colorVibeSwatches($0) }) {
            dimensions.append(d)
        }
        // Undertone → "Color Warmth", the friendlier framing.
        if let d = makeDimension(id: "warmth", title: "Color Warmth",
                                 caption: "Whether your colours lean warm (golden-based) or cool (blue-based).",
                                 map: profile.undertoneAffinity,
                                 bySlot: profile.undertoneAffinityBySlot,
                                 label: { undertoneLabel($0) },
                                 swatches: { [undertoneSwatch($0)] }) {
            dimensions.append(d)
        }
        if let d = makeStringDimension(id: "patterns", title: "Patterns", caption: nil,
                                       map: enumKeyedToStrings(profile.patternAffinity) { prettify($0.rawValue) },
                                       bySlot: enumKeyedToStringsBySlot(profile.patternAffinityBySlot) { prettify($0.rawValue) }) {
            dimensions.append(d)
        }
        if let d = makeStringDimension(id: "fit", title: "Fit", caption: nil,
                                       map: profile.fitAffinity,
                                       bySlot: profile.fitAffinityBySlot) {
            dimensions.append(d)
        }
        // Silhouette deliberately omitted (unreliable free-text, overlaps Fit).
        if let d = makeStringDimension(id: "materials", title: "Materials", caption: nil,
                                       map: profile.materialAffinity,
                                       bySlot: profile.materialAffinityBySlot) {
            dimensions.append(d)
        }
        if let d = makeStringDimension(id: "texture", title: "Texture", caption: nil,
                                       map: profile.textureAffinity,
                                       bySlot: profile.textureAffinityBySlot) {
            dimensions.append(d)
        }
        if let d = makeStringDimension(id: "style", title: "Style", caption: nil,
                                       map: profile.styleTagAffinity,
                                       bySlot: profile.styleTagAffinityBySlot) {
            dimensions.append(d)
        }
        if let d = makeStringDimension(id: "fabric", title: "Fabric Weight", caption: nil,
                                       map: enumKeyedToStrings(profile.fabricWeightAffinity) { "\(prettify($0.rawValue)) weight" },
                                       bySlot: enumKeyedToStringsBySlot(profile.fabricWeightAffinityBySlot) { "\(prettify($0.rawValue)) weight" }) {
            dimensions.append(d)
        }
        // Formality is keyed by numeric band (0–5); collapse bands that share a
        // descriptor (Casual/Smart-Casual/Formal) into one row, averaging their
        // affinities, so the chart reads in words rather than raw band numbers.
        if let d = makeStringDimension(id: "formality", title: "Formality", caption: nil,
                                       map: mergedFormality(profile.formalityAffinity),
                                       bySlot: profile.formalityAffinityBySlot.mapValues { mergedFormality($0) }) {
            dimensions.append(d)
        }

        // Expanded per-garment attributes (2026-07-27b) — the five richer
        // fields the vision extraction returns, which until now were stored
        // and sent to the recommendation LLM but never learned or shown. Only
        // items ingested since that extraction expanded carry them, so these
        // cards stay hidden for a closet added before it.
        if let d = makeStringDimension(id: "pattern-scale", title: "Pattern Scale",
                                       caption: "How large the print reads on the garment, independent of which pattern it is.",
                                       map: enumKeyedToStrings(profile.patternScaleAffinity) { patternScaleLabel($0) },
                                       bySlot: enumKeyedToStringsBySlot(profile.patternScaleAffinityBySlot) { patternScaleLabel($0) }) {
            dimensions.append(d)
        }
        if let d = makeStringDimension(id: "finish", title: "Fabric Finish",
                                       caption: "The surface look of the fabric — matte, glossy, knitted, and so on.",
                                       map: enumKeyedToStrings(profile.textureFinishAffinity) { prettify($0.rawValue) },
                                       bySlot: enumKeyedToStringsBySlot(profile.textureFinishAffinityBySlot) { prettify($0.rawValue) }) {
            dimensions.append(d)
        }
        if let d = makeStringDimension(id: "cut", title: "Cut",
                                       caption: "How the garment is shaped — fitted, relaxed, oversized, cropped.",
                                       map: enumKeyedToStrings(profile.silhouetteCutAffinity) { prettify($0.rawValue) },
                                       bySlot: enumKeyedToStringsBySlot(profile.silhouetteCutAffinityBySlot) { prettify($0.rawValue) }) {
            dimensions.append(d)
        }
        if let d = makeStringDimension(id: "neckline-rise", title: "Neckline & Rise",
                                       caption: "Where a top opens at the neck, and where a bottom sits on the waist.",
                                       map: profile.necklineOrRiseAffinity,
                                       bySlot: profile.necklineOrRiseAffinityBySlot) {
            dimensions.append(d)
        }
        if let d = makeStringDimension(id: "drape", title: "Drape",
                                       caption: "How the fabric hangs — flowy and light, or structured and heavy.",
                                       map: enumKeyedToStrings(profile.fabricWeightDetailAffinity) { fabricWeightDetailLabel($0) },
                                       bySlot: enumKeyedToStringsBySlot(profile.fabricWeightDetailAffinityBySlot) { fabricWeightDetailLabel($0) }) {
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
        bySlot: [Slot: [Key: Double]] = [:],
        label: (Key) -> String,
        swatches: (Key) -> [String]
    ) -> TasteInsightsSnapshot.Dimension? {
        guard !map.isEmpty else { return nil }
        guard map.values.contains(where: { abs($0 - 0.5) > neutralEpsilon }) else { return nil }

        let entries = map.map { (label: label($0.key), affinity: $0.value, swatches: swatches($0.key)) }
        let categories = makeCategories(dimensionID: id, bySlot: bySlot) { slotMap in
            slotMap.map { (label: label($0.key), affinity: $0.value, swatches: swatches($0.key)) }
        }
        return assemble(id: id, title: title, caption: caption, entries: entries, categories: categories)
    }

    /// Shared per-`Slot` breakdown builder for both dimension builders — one
    /// `Category` per slot that has non-neutral signal, in `Slot.allCases`
    /// order so the sections read top-to-bottom the way an outfit does.
    private static func makeCategories<Key: Hashable>(
        dimensionID: String,
        bySlot: [Slot: [Key: Double]],
        entries: ([Key: Double]) -> [(label: String, affinity: Double, swatches: [String])]
    ) -> [TasteInsightsSnapshot.Category] {
        Slot.allCases.compactMap { slot -> TasteInsightsSnapshot.Category? in
            guard let slotMap = bySlot[slot], !slotMap.isEmpty,
                  slotMap.values.contains(where: { abs($0 - 0.5) > neutralEpsilon })
            else { return nil }
            let categoryID = "\(dimensionID)-\(slot.rawValue)"
            return TasteInsightsSnapshot.Category(
                id: categoryID,
                slot: slot,
                title: slotTitle(slot),
                rows: rank(entries(slotMap), idPrefix: categoryID)
            )
        }
    }

    /// Plural, plain-language slot names — the Insights tabs address the user
    /// about groups of garments ("your tops"), not one slot of one outfit.
    static func slotTitle(_ slot: Slot) -> String {
        switch slot {
        case .top: return "Tops"
        case .bottom: return "Bottoms"
        case .footwear: return "Shoes"
        case .outerwear: return "Outerwear"
        case .headwear: return "Headwear"
        case .accessory: return "Accessories"
        case .bag: return "Bags"
        }
    }

    /// String-keyed convenience that also case-folds keys so free-text values
    /// like "Cotton" and "cotton" don't render as two separate bars.
    private static func makeStringDimension(
        id: String,
        title: String,
        caption: String?,
        map: [String: Double],
        bySlot: [Slot: [String: Double]] = [:]
    ) -> TasteInsightsSnapshot.Dimension? {
        guard !map.isEmpty else { return nil }

        let entries = foldedEntries(map)
        guard !entries.isEmpty else { return nil }
        guard entries.contains(where: { abs($0.affinity - 0.5) > neutralEpsilon }) else { return nil }

        let categories = makeCategories(dimensionID: id, bySlot: bySlot) { foldedEntries($0) }
        return assemble(id: id, title: title, caption: caption, entries: entries, categories: categories)
    }

    /// Merges a free-text affinity map case-insensitively; canonical label is
    /// the prettified first-seen spelling, affinity the mean of the collided
    /// buckets — so "Cotton" and "cotton" don't render as two separate bars.
    private static func foldedEntries(_ map: [String: Double]) -> [(label: String, affinity: Double, swatches: [String])] {
        var grouped: [String: (labelSeed: String, total: Double, count: Int)] = [:]
        for (rawKey, affinity) in map {
            let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let foldKey = trimmed.lowercased()
            let existing = grouped[foldKey]
            grouped[foldKey] = (existing?.labelSeed ?? trimmed, (existing?.total ?? 0) + affinity, (existing?.count ?? 0) + 1)
        }
        return grouped.map { (label: prettify($0.value.labelSeed), affinity: $0.value.total / Double($0.value.count), swatches: [String]()) }
    }

    /// Highest affinity first; tie-break by label for a stable order.
    private static func rank(
        _ entries: [(label: String, affinity: Double, swatches: [String])],
        idPrefix: String
    ) -> [TasteInsightsSnapshot.Row] {
        entries
            .sorted { $0.affinity == $1.affinity ? $0.label < $1.label : $0.affinity > $1.affinity }
            .map { TasteInsightsSnapshot.Row(id: "\(idPrefix)-\($0.label)", label: $0.label, affinity: $0.affinity, swatchHexes: $0.swatches) }
    }

    /// Shared ranking + loved/avoided split for both dimension builders.
    private static func assemble(
        id: String,
        title: String,
        caption: String?,
        entries: [(label: String, affinity: Double, swatches: [String])],
        categories: [TasteInsightsSnapshot.Category]
    ) -> TasteInsightsSnapshot.Dimension {
        let rows = rank(entries, idPrefix: id)
        let loved = rows.filter { $0.affinity > lovedThreshold }.map(\.label)
        let avoided = rows.filter { $0.affinity < avoidThreshold }
            .sorted { $0.affinity < $1.affinity }
            .map(\.label)

        return TasteInsightsSnapshot.Dimension(id: id, title: title, caption: caption, rows: rows, loved: loved, avoided: avoided, categories: categories)
    }

    private static func enumKeyedToStrings<Key: Hashable>(_ map: [Key: Double], label: (Key) -> String) -> [String: Double] {
        var out: [String: Double] = [:]
        for (key, value) in map { out[label(key)] = value }
        return out
    }

    /// `enumKeyedToStrings` applied to each slot's map, so an enum-keyed
    /// dimension can reuse the string-keyed builder for its per-slot
    /// breakdown too.
    private static func enumKeyedToStringsBySlot<Key: Hashable>(
        _ bySlot: [Slot: [Key: Double]], label: (Key) -> String
    ) -> [Slot: [String: Double]] {
        bySlot.mapValues { enumKeyedToStrings($0, label: label) }
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

    /// Plain-language names for the expanded per-garment enums — same
    /// "no fashion vocabulary required" posture as `colorVibeLabel`.
    static func patternScaleLabel(_ scale: PatternScale) -> String {
        switch scale {
        case .solid: return "No print"
        case .microPattern: return "Tiny prints"
        case .mediumPattern: return "Medium prints"
        case .boldStatementPattern: return "Bold statement prints"
        }
    }

    static func fabricWeightDetailLabel(_ detail: FabricWeightDetail) -> String {
        switch detail {
        case .lightFlowy: return "Light & flowy"
        case .mediumStandard: return "Medium & standard"
        case .heavyStructured: return "Heavy & structured"
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
