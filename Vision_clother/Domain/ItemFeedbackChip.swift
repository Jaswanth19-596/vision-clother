//
//  ItemFeedbackChip.swift
//  Vision_clother
//
//  Item-Level Feedback (2026-07-27): the per-slot chip vocabulary the user
//  taps on an individual garment while rating a combination
//  (`Features/Rating/RateCombinationView.swift`), and its deterministic
//  mapping onto the two storage types.
//
//  Deliberately a lookup table, not an LLM call: a tapped chip has no
//  ambiguity to resolve, so routing it through inference would add latency and
//  cost for nothing. The free-text path
//  (`Services/CombinationChemistryInferenceService.swift`) is where the LLM
//  earns its place; chips are the zero-latency path to the same storage.
//
//  Chips are per-slot because a fixed global set would ask about sleeves on
//  footwear. The split between the two outcomes is the feature's core
//  distinction (see `Models/ItemNote.swift`): a *taste* chip generalizes and
//  decays, a *defect* chip attaches to that one garment forever.
//
//  Pure (Domain/CLAUDE.md) — this module never constructs an `ItemNote`
//  (a SwiftData `@Model`); it emits `PendingNote` value specs that
//  `Data/WardrobeRepository.swift` materializes.
//

import Foundation

/// One tappable chip. `id` is stable and persisted nowhere — it exists for
/// `Identifiable` and for test assertions.
struct ItemFeedbackChip: Identifiable, Equatable, Hashable {
    /// Which `ItemRating` axis a taste chip drives. Every other axis of the
    /// rating is left neutral, so a single tap teaches exactly the one thing
    /// it claims and nothing else.
    enum TasteAxis: String, Equatable, Hashable {
        case notMyStyle
        case wrongColor
        case uncomfortableFabric
        case love
    }

    enum Outcome: Equatable, Hashable {
        /// Writes an `ItemRating` only — generalizes to other garments sharing
        /// the attribute, decays on the usual half-life.
        case taste(TasteAxis)
        /// Writes an `ItemNote` only — attaches to this garment, never to the
        /// taste profile.
        case note(text: String, severity: ItemNoteSeverity, context: ItemNoteContext)
        /// Writes **both**: a fit complaint is a real `FitRating` signal (the
        /// axis `ItemRating` already models with two failure directions) *and*
        /// a durable fact about the garment worth telling the recommender.
        case fitComplaint(fit: FitRating, text: String)
    }

    let id: String
    let label: String
    let outcome: Outcome

    /// Whether this chip reads as positive — drives the UI's accent treatment
    /// so "Love this piece" doesn't look like a complaint.
    var isPositive: Bool {
        if case .taste(.love) = outcome { return true }
        return false
    }
}

/// A note the caller should persist, as a pure value — `Domain/` can't build
/// the SwiftData model itself.
struct PendingItemNote: Equatable, Hashable {
    let text: String
    let severity: ItemNoteSeverity
    let context: ItemNoteContext
}

/// What one garment's tapped chips resolve to.
struct ItemFeedbackResolution: Equatable {
    /// `nil` when no taste chip was tapped — a defect-only tap must not write
    /// a neutral rating, or every "runs loose" would dilute the item's
    /// preference tally with a meaningless mid score.
    let rating: ResolvedRating?
    let notes: [PendingItemNote]

    /// The `ItemRating` field values a chip set resolves to. Mirrors
    /// `ItemRating`'s initializer rather than constructing the `@Model` here.
    struct ResolvedRating: Equatable {
        let fit: FitRating
        let comfort: Int
        let colorLike: Int
        let patternLike: Int?
        let formalityFit: Int
        let styleIdentity: Int
        let wearAgain: Bool
    }
}

enum ItemFeedbackChipCatalog {
    /// Neutral answer on the 1...5 scales — an axis no chip spoke to
    /// contributes a 0.5 affinity, i.e. no bias, matching the convention
    /// `AttributePreferenceProfile` already uses for unrated attributes.
    static let neutralAnswer = 3
    private static let negativeAnswer = 1
    private static let positiveAnswer = 5

    /// Available on every slot — the four judgments that make sense about any
    /// garment. The first two are taste (they generalize); the third is
    /// taste about fabric feel; the fourth is the positive path the current
    /// flow can't express at item level at all.
    static let sharedChips: [ItemFeedbackChip] = [
        .init(id: "love", label: "Love this piece", outcome: .taste(.love)),
        .init(id: "not-my-style", label: "Not my style", outcome: .taste(.notMyStyle)),
        .init(id: "wrong-colour", label: "Wrong colour on me", outcome: .taste(.wrongColor)),
        .init(id: "uncomfortable", label: "Uncomfortable fabric", outcome: .taste(.uncomfortableFabric)),
    ]

    /// Slot-specific complaints. All of these are facts about the garment, so
    /// they write notes (and, for the two fit directions, a `FitRating` too).
    static func slotChips(for slot: Slot) -> [ItemFeedbackChip] {
        switch slot {
        case .top:
            return [
                .init(id: "top-loose", label: "Too loose", outcome: .fitComplaint(fit: .tooLoose, text: "runs loose")),
                .init(id: "top-tight", label: "Too tight", outcome: .fitComplaint(fit: .tooTight, text: "runs tight")),
                .init(id: "top-sleeves", label: "Sleeves wrong", outcome: .note(text: "sleeve length is off", severity: .conditional, context: .formalOccasions)),
                .init(id: "top-neckline", label: "Neckline wrong", outcome: .note(text: "neckline doesn't sit right", severity: .conditional, context: .formalOccasions)),
            ]
        case .bottom:
            return [
                .init(id: "bottom-loose", label: "Too loose", outcome: .fitComplaint(fit: .tooLoose, text: "runs loose")),
                .init(id: "bottom-tight", label: "Too tight", outcome: .fitComplaint(fit: .tooTight, text: "runs tight")),
                .init(id: "bottom-short", label: "Too short", outcome: .note(text: "too short", severity: .conditional, context: .formalOccasions)),
                .init(id: "bottom-long", label: "Too long", outcome: .note(text: "too long", severity: .conditional, context: .formalOccasions)),
                .init(id: "bottom-rise", label: "Rise wrong", outcome: .note(text: "rise sits wrong", severity: .conditional, context: .formalOccasions)),
            ]
        case .footwear:
            return [
                .init(id: "shoe-tight", label: "Too tight", outcome: .fitComplaint(fit: .tooTight, text: "runs tight")),
                .init(id: "shoe-rubs", label: "Rubs / blisters", outcome: .note(text: "rubs after a while", severity: .conditional, context: .extendedWear)),
                .init(id: "shoe-walking", label: "Hard to walk in", outcome: .note(text: "hard to walk in", severity: .conditional, context: .extendedWear)),
            ]
        case .outerwear:
            return [
                .init(id: "outer-bulky", label: "Too bulky", outcome: .note(text: "bulky over layers", severity: .conditional, context: .extendedWear)),
                .init(id: "outer-cold", label: "Not warm enough", outcome: .note(text: "not warm enough", severity: .conditional, context: .coldWeather)),
                .init(id: "outer-warm", label: "Too warm", outcome: .note(text: "too warm", severity: .conditional, context: .hotWeather)),
            ]
        case .headwear:
            return [
                .init(id: "head-face", label: "Doesn't suit my face", outcome: .note(text: "doesn't suit my face", severity: .conditional, context: .none)),
                .init(id: "head-fit", label: "Poor fit", outcome: .fitComplaint(fit: .tooLoose, text: "doesn't sit properly")),
            ]
        case .accessory:
            return [
                .init(id: "acc-flashy", label: "Too flashy", outcome: .note(text: "too flashy", severity: .conditional, context: .formalOccasions)),
                .init(id: "acc-plain", label: "Too plain", outcome: .note(text: "too plain", severity: .conditional, context: .none)),
            ]
        case .bag:
            return [
                .init(id: "bag-small", label: "Too small", outcome: .note(text: "too small to be practical", severity: .conditional, context: .extendedWear)),
                .init(id: "bag-bulky", label: "Too bulky", outcome: .note(text: "bulky to carry", severity: .conditional, context: .extendedWear)),
            ]
        }
    }

    static func chips(for slot: Slot) -> [ItemFeedbackChip] {
        sharedChips + slotChips(for: slot)
    }

    /// Folds a garment's tapped chips into the rows to persist.
    ///
    /// - Parameter outfitSentiment: the whole-look swipe this garment was part
    ///   of. Supplies `wearAgain` (the one `ItemRating` field no chip speaks
    ///   to) so the rating isn't forced to guess — a garment in an outfit the
    ///   user loved is one they'd wear again unless a chip says otherwise.
    static func resolve(
        chips: [ItemFeedbackChip],
        outfitSentiment: SwipeSentiment,
        itemPattern: GarmentPattern
    ) -> ItemFeedbackResolution {
        var notes: [PendingItemNote] = []
        var tasteAxes: [ItemFeedbackChip.TasteAxis] = []
        var fitOverride: FitRating?

        for chip in chips {
            switch chip.outcome {
            case .taste(let axis):
                tasteAxes.append(axis)
            case .note(let text, let severity, let context):
                notes.append(PendingItemNote(text: text, severity: severity, context: context))
            case .fitComplaint(let fit, let text):
                fitOverride = fit
                notes.append(PendingItemNote(text: text, severity: .conditional, context: .formalOccasions))
            }
        }

        // A defect-only tap writes no rating at all — see `ItemFeedbackResolution.rating`.
        guard !tasteAxes.isEmpty || fitOverride != nil else {
            return ItemFeedbackResolution(rating: nil, notes: notes)
        }

        let loved = tasteAxes.contains(.love)
        var comfort = neutralAnswer
        var colorLike = neutralAnswer
        var formalityFit = neutralAnswer
        var styleIdentity = neutralAnswer

        if loved {
            comfort = positiveAnswer
            colorLike = positiveAnswer
            formalityFit = positiveAnswer
            styleIdentity = positiveAnswer
        }
        // Applied after the `love` block so a contradictory pair (loved the
        // piece, but the colour is wrong) resolves to the specific complaint
        // rather than being silently overwritten by the blanket positive.
        if tasteAxes.contains(.uncomfortableFabric) { comfort = negativeAnswer }
        if tasteAxes.contains(.wrongColor) { colorLike = negativeAnswer }
        if tasteAxes.contains(.notMyStyle) { styleIdentity = negativeAnswer }

        let rating = ItemFeedbackResolution.ResolvedRating(
            fit: fitOverride ?? .justRight,
            comfort: comfort,
            colorLike: colorLike,
            // Nothing in this vocabulary asks about pattern, and a solid item
            // has nothing to ask — `nil` in both cases, which makes
            // `FitRating.normalizedRating` average over the remaining six
            // axes rather than assume a neutral answer.
            patternLike: itemPattern == .solid ? nil : neutralAnswer,
            formalityFit: formalityFit,
            styleIdentity: styleIdentity,
            wearAgain: loved || (outfitSentiment.liked && !tasteAxes.contains(.notMyStyle))
        )
        return ItemFeedbackResolution(rating: rating, notes: notes)
    }
}
