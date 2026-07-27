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
    /// `WardrobeItem.colorProfile.undertone` for the rated item — feeds
    /// `undertoneAffinity`, keyed off the same color signal (`colorLike`).
    /// `nil` for items with no classified undertone.
    let undertone: Undertone?
    /// `WardrobeItem.material` for the rated item — feeds `materialAffinity`,
    /// keyed off the fabric-feel signal (`fabricComfort`), same as the vision
    /// LLM extracts it (`Services/VisionMetadataExtractionService.swift`).
    let material: String?
    /// `WardrobeItem.texture` for the rated item — feeds `textureAffinity`,
    /// also keyed off `fabricComfort` (texture is a tactile fabric property).
    let texture: String?
    /// `WardrobeItem.fit` (the free-form cut descriptor, e.g. "Slim",
    /// "Oversized") for the rated item — feeds `fitAffinity`, keyed off
    /// `fitLike` below. Distinct from `silhouetteTag`/`silhouetteAffinity`
    /// (shape) — fit is how the garment sits on the body.
    let fit: String?
    /// Signal for `fitAffinity`: `ItemRating.fit.centeredness` (1.0 = "just
    /// right") for owned items, or the swipe like/dislike signal for swipes.
    /// `nil` whenever `fit` is `nil`, so it never contributes alone.
    let fitLike: Double?
    // Expanded per-garment attributes (added 2026-07-27, surfaced 2026-07-27b)
    // — the five richer fields the vision extraction now returns
    // (`Models/WardrobeItem.swift`). Each reuses the closest existing rating
    // signal rather than asking the user a new question: pattern scale <-
    // `patternLike`, texture finish / fabric-weight detail <- `fabricComfort`,
    // silhouette cut / neckline-or-rise <- `fitLike`. `nil` for any item whose
    // ingestion predates these fields, so it simply doesn't contribute.
    let patternScale: PatternScale?
    let textureFinish: TextureFinish?
    let silhouetteCut: SilhouetteCut?
    let necklineOrRise: String?
    let fabricWeightDetail: FabricWeightDetail?

    /// Credit-assignment weight, `[0,1]`, composed multiplicatively with
    /// `build(from:)`'s exponential time-decay weight (added 2026-07-27) —
    /// `SwipeAttributeEvent.weight` (`1.0 / N` for an N-garment swiped photo)
    /// threaded through so a multi-garment swipe no longer injects N× the
    /// signal of a single-garment one. `= 1.0` default so every other call
    /// site (owned-item `ItemRating`s, tests) keeps contributing at full
    /// strength, unchanged from before this field existed.
    let weight: Double

    /// Explicit init (rather than relying on the synthesized memberwise
    /// init's default-value support) — with trailing defaulted parameters,
    /// SourceKit/xcodebuild inference for this struct's implicit memberwise
    /// init proved unreliable at call sites.
    init(
        colorLike: Double, patternLike: Double? = nil, formalityFit: Double,
        colorVibe: ColorVibe, pattern: GarmentPattern, formalityBand: Int,
        styleIdentity: Double = 0.5, styleTags: [String] = [], recordedAt: Date = .now, slot: Slot? = nil,
        silhouetteTag: String? = nil, silhouetteFit: Double? = nil,
        fabricWeight: FabricWeight = .medium, fabricComfort: Double = 0.5,
        undertone: Undertone? = nil, material: String? = nil, texture: String? = nil,
        fit: String? = nil, fitLike: Double? = nil,
        patternScale: PatternScale? = nil, textureFinish: TextureFinish? = nil,
        silhouetteCut: SilhouetteCut? = nil, necklineOrRise: String? = nil,
        fabricWeightDetail: FabricWeightDetail? = nil,
        weight: Double = 1.0
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
        self.undertone = undertone
        self.material = material
        self.texture = texture
        self.fit = fit
        self.fitLike = fitLike
        self.patternScale = patternScale
        self.textureFinish = textureFinish
        self.silhouetteCut = silhouetteCut
        self.necklineOrRise = necklineOrRise
        self.fabricWeightDetail = fabricWeightDetail
        self.weight = weight
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
    /// The rated item's `undertone`/`material`/`texture`/`fit` — feed the four
    /// affinity maps added 2026-07-24, reusing the closest existing outfit
    /// dimension as each one's signal: undertone <- Color Harmony,
    /// material/texture <- Weather Suitability+Practicality (`weatherFit`),
    /// fit <- Fit & Silhouette (`silhouette`). `nil` when the item lacks that
    /// attribute, so it simply doesn't contribute.
    let undertone: Undertone?
    let material: String?
    let texture: String?
    let fit: String?
    /// The five expanded per-garment attributes — same signal mapping as
    /// `RatedAttributes`, re-expressed against this struct's outfit-level
    /// dimensions: pattern scale <- `patternDissatisfaction` (the only
    /// outfit-level pattern signal), texture finish / fabric-weight detail <-
    /// `weatherFit`, silhouette cut / neckline-or-rise <- `silhouette`.
    let patternScale: PatternScale?
    let textureFinish: TextureFinish?
    let silhouetteCut: SilhouetteCut?
    let necklineOrRise: String?
    let fabricWeightDetail: FabricWeightDetail?
    /// Credit-assignment weight, mirroring `RatedAttributes.weight` and
    /// composed with time-decay the same way (multiplied, not substituted).
    /// `1.0` for the detailed-form path, where the user answered per-dimension
    /// questions about the outfit as a whole and every item genuinely carries
    /// the full signal. Below `1.0` for the combination-swipe fan-out added
    /// 2026-07-27, where one whole-look sentiment is split `1/N` across the
    /// garments in the look — the same reasoning that gives a multi-garment
    /// stock swipe `1/N` per detected garment.
    let weight: Double

    init(
        colorHarmony: Double, occasionMatch: Double, styleMatch: Double, silhouette: Double, weatherFit: Double,
        colorVibe: ColorVibe, styleTags: [String], silhouetteTag: String?, formalityBand: Int,
        fabricWeight: FabricWeight, pattern: GarmentPattern = .solid, patternDissatisfaction: Double? = nil,
        recordedAt: Date = .now, slot: Slot? = nil,
        undertone: Undertone? = nil, material: String? = nil, texture: String? = nil, fit: String? = nil,
        patternScale: PatternScale? = nil, textureFinish: TextureFinish? = nil,
        silhouetteCut: SilhouetteCut? = nil, necklineOrRise: String? = nil,
        fabricWeightDetail: FabricWeightDetail? = nil,
        weight: Double = 1.0
    ) {
        self.weight = weight
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
        self.undertone = undertone
        self.material = material
        self.texture = texture
        self.fit = fit
        self.patternScale = patternScale
        self.textureFinish = textureFinish
        self.silhouetteCut = silhouetteCut
        self.necklineOrRise = necklineOrRise
        self.fabricWeightDetail = fabricWeightDetail
    }
}

/// One whole-look combination swipe — either a `SwipeCombinationEvent`
/// (stock-photo swiped photo with 2+ detected garments) or, since 2026-07-27,
/// an owned-item combination rated via the swipe+comment flow
/// (`OutfitFeedback.inferredCombinationMetadata`) — both unified into this one
/// shape by the caller (`Data/WardrobeRepository.swift`) so this module never
/// touches SwiftData directly and never needs to know which source a rating
/// came from. Unlike every other rated-input struct, this has no owned-item
/// analogue for its color/style fields (`colorHarmonyAffinity` is a
/// pairing/whole-look signal, not a per-item one).
struct RatedCombination {
    let colorHarmony: ColorHarmonyDescriptor
    /// `SwipeCombinationEvent.styleCoherenceTags` — folded into the same
    /// `styleTagAffinity` map owned-item style tags already feed, rather than
    /// a parallel map.
    let styleTags: [String]
    /// `SwipeSentiment.ratingValue` for the swipe this combination came from,
    /// `[0,1]`.
    let signal: Double
    /// `SwipeCombinationEvent.recordedAt` — feeds `build(from:)`'s exponential
    /// time-decay weighting, same as every other rated-input struct.
    let recordedAt: Date

    // Relational styling attributes, round 2 (added 2026-07-27) — mirrors
    // `CombinationMetadata`'s expanded schema. The first seven feed
    // recommendation-time scoring (`combinationAffinityBonus`); the last two
    // are Insights-only (never read by scoring) — see
    // `AttributePreferenceProfile.aestheticVibeAffinity`/`complexityScoreAffinity`.
    let paletteArchetype: PaletteArchetype?
    let contrastLevel: ContrastLevel?
    let colorSandwiching: Bool?
    let proportionRatio: ProportionRatio?
    let volumeBalance: VolumeBalance?
    let textureContrast: TextureContrast?
    let formalityBridge: FormalityBridge?
    let overallAestheticVibe: String?
    let complexityScore: Int?

    init(
        colorHarmony: ColorHarmonyDescriptor, styleTags: [String] = [], signal: Double, recordedAt: Date = .now,
        paletteArchetype: PaletteArchetype? = nil, contrastLevel: ContrastLevel? = nil,
        colorSandwiching: Bool? = nil, proportionRatio: ProportionRatio? = nil,
        volumeBalance: VolumeBalance? = nil, textureContrast: TextureContrast? = nil,
        formalityBridge: FormalityBridge? = nil, overallAestheticVibe: String? = nil, complexityScore: Int? = nil
    ) {
        self.colorHarmony = colorHarmony
        self.styleTags = styleTags
        self.signal = signal
        self.recordedAt = recordedAt
        self.paletteArchetype = paletteArchetype
        self.contrastLevel = contrastLevel
        self.colorSandwiching = colorSandwiching
        self.proportionRatio = proportionRatio
        self.volumeBalance = volumeBalance
        self.textureContrast = textureContrast
        self.formalityBridge = formalityBridge
        self.overallAestheticVibe = overallAestheticVibe
        self.complexityScore = complexityScore
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
    let undertone: Undertone?
    let material: String?
    let texture: String?
    let fit: String?
    /// The five expanded per-garment attributes — used purely as the
    /// closet-composition *baseline* for their affinity maps' dynamic
    /// shrinkage prior, exactly like every field above.
    let patternScale: PatternScale?
    let textureFinish: TextureFinish?
    let silhouetteCut: SilhouetteCut?
    let necklineOrRise: String?
    let fabricWeightDetail: FabricWeightDetail?

    init(colorCategory: ColorVibe, pattern: GarmentPattern, formalityBand: Int, styleTags: [String], silhouette: String?, fabricWeight: FabricWeight, slot: Slot, undertone: Undertone? = nil, material: String? = nil, texture: String? = nil, fit: String? = nil, patternScale: PatternScale? = nil, textureFinish: TextureFinish? = nil, silhouetteCut: SilhouetteCut? = nil, necklineOrRise: String? = nil, fabricWeightDetail: FabricWeightDetail? = nil) {
        self.colorCategory = colorCategory
        self.pattern = pattern
        self.formalityBand = formalityBand
        self.styleTags = styleTags
        self.silhouette = silhouette
        self.fabricWeight = fabricWeight
        self.slot = slot
        self.undertone = undertone
        self.material = material
        self.texture = texture
        self.fit = fit
        self.patternScale = patternScale
        self.textureFinish = textureFinish
        self.silhouetteCut = silhouetteCut
        self.necklineOrRise = necklineOrRise
        self.fabricWeightDetail = fabricWeightDetail
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
    /// Same shrunk affinity as `patternAffinity`, broken out per `Slot` —
    /// see `colorVibeAffinityBySlot`'s doc comment; every `*BySlot` map below
    /// follows the identical posture (additive sibling, populated only when
    /// the source rating's `slot` is known, generalized 2026-07-27 from the
    /// color-only precedent).
    var patternAffinityBySlot: [Slot: [GarmentPattern: Double]] = [:]
    var formalityAffinity: [Int: Double] = [:]
    var formalityAffinityBySlot: [Slot: [Int: Double]] = [:]
    /// Personal Style Match (Stylist Intelligence Engine Phase 1), keyed by
    /// `WardrobeItem.styleTags` — the first scoring consumer of that field,
    /// previously LLM-prompt-only.
    var styleTagAffinity: [String: Double] = [:]
    var styleTagAffinityBySlot: [Slot: [String: Double]] = [:]
    /// Fit & Silhouette, keyed by `WardrobeItem.silhouette`.
    var silhouetteAffinity: [String: Double] = [:]
    var silhouetteAffinityBySlot: [Slot: [String: Double]] = [:]
    /// Weather Suitability + Practicality (folded into one bucket), keyed by
    /// `WardrobeItem.fabricWeight`.
    var fabricWeightAffinity: [FabricWeight: Double] = [:]
    var fabricWeightAffinityBySlot: [Slot: [FabricWeight: Double]] = [:]
    /// Color undertone taste (warm/cool/neutral), keyed by
    /// `WardrobeItem.colorProfile.undertone` — added 2026-07-24 so the merged
    /// engine learns undertone, not just color vibe.
    var undertoneAffinity: [Undertone: Double] = [:]
    var undertoneAffinityBySlot: [Slot: [Undertone: Double]] = [:]
    /// Fabric material taste (e.g. "Linen", "Denim"), keyed by
    /// `WardrobeItem.material` — previously extracted by the vision LLM but
    /// never learned.
    var materialAffinity: [String: Double] = [:]
    var materialAffinityBySlot: [Slot: [String: Double]] = [:]
    /// Tactile surface-texture taste (e.g. "Ribbed", "Smooth"), keyed by
    /// `WardrobeItem.texture`.
    var textureAffinity: [String: Double] = [:]
    var textureAffinityBySlot: [Slot: [String: Double]] = [:]
    /// Fit/cut taste (e.g. "Slim", "Oversized"), keyed by `WardrobeItem.fit`
    /// — how the garment sits on the body, distinct from `silhouetteAffinity`
    /// (its shape).
    var fitAffinity: [String: Double] = [:]
    var fitAffinityBySlot: [Slot: [String: Double]] = [:]

    // Expanded per-garment attributes (surfaced 2026-07-27b) — the five
    // richer fields the vision extraction added earlier the same day, which
    // until now were stored on `WardrobeItem` and sent to the LLM catalog but
    // never *learned*. Same flat + per-slot pairing as every dimension above.
    // Only items ingested since the expanded extraction carry these, so for a
    // closet added before that these maps stay empty and every consumer below
    // behaves exactly as it did before they existed.
    var patternScaleAffinity: [PatternScale: Double] = [:]
    var patternScaleAffinityBySlot: [Slot: [PatternScale: Double]] = [:]
    var textureFinishAffinity: [TextureFinish: Double] = [:]
    var textureFinishAffinityBySlot: [Slot: [TextureFinish: Double]] = [:]
    var silhouetteCutAffinity: [SilhouetteCut: Double] = [:]
    var silhouetteCutAffinityBySlot: [Slot: [SilhouetteCut: Double]] = [:]
    /// Free-text (e.g. "Crew Neck", "High Rise"), so case-folded by the
    /// consumers the same way `materialAffinity`/`fitAffinity` are.
    var necklineOrRiseAffinity: [String: Double] = [:]
    var necklineOrRiseAffinityBySlot: [Slot: [String: Double]] = [:]
    var fabricWeightDetailAffinity: [FabricWeightDetail: Double] = [:]
    var fabricWeightDetailAffinityBySlot: [Slot: [FabricWeightDetail: Double]] = [:]
    /// Whole-look color-harmony taste (e.g. "monochrome" vs. "high contrast"),
    /// keyed by `ColorHarmonyDescriptor` — learned only from
    /// `RatedCombination` (Swipe-to-Learn multi-garment scenes), since a
    /// single owned item has no color harmony of its own to rate. Insights-only
    /// for now — not read by `matchDetail(for:)`/`affinityBonus`, which score
    /// one item at a time.
    var colorHarmonyAffinity: [ColorHarmonyDescriptor: Double] = [:]

    // Relational styling attributes, round 2 (added 2026-07-27) — learned
    // only from `RatedCombination`, same posture as `colorHarmonyAffinity`
    // above. The first seven are read by `combinationAffinityBonus`
    // (recommendation-time scoring against a deterministic on-device
    // estimate, `Domain/PairCompatibilityScoring.estimateCombinationHeuristics`);
    // `aestheticVibeAffinity`/`complexityScoreAffinity` stay Insights-only —
    // there's no reliable deterministic way to estimate a whole outfit's
    // "vibe" or visual complexity from item attributes alone the way contrast
    // or formality bridging can be, so they're never used for a recommendation
    // bonus.
    var paletteArchetypeAffinity: [PaletteArchetype: Double] = [:]
    var contrastLevelAffinity: [ContrastLevel: Double] = [:]
    var colorSandwichingAffinity: [Bool: Double] = [:]
    var proportionRatioAffinity: [ProportionRatio: Double] = [:]
    var volumeBalanceAffinity: [VolumeBalance: Double] = [:]
    var textureContrastAffinity: [TextureContrast: Double] = [:]
    var formalityBridgeAffinity: [FormalityBridge: Double] = [:]
    var aestheticVibeAffinity: [String: Double] = [:]
    var complexityScoreAffinity: [Int: Double] = [:]

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

    /// Folds one decay-weighted `(key, value)` observation into `sums`,
    /// nested under `slot` — a no-op when `slot` is `nil` (rating has no
    /// known slot, so it only contributes to the flat sums the caller tracks
    /// separately). Generalizes the original color-only `accumulateSlotColor`
    /// (2026-07-27) to every dimension — category-partitioned taste isn't
    /// just a color concern ("oversized" means something different for a top
    /// vs. a bottom).
    private static func accumulateSlot<Key: Hashable>(
        _ slot: Slot?, key: Key, value: Double, weight: Double,
        into sums: inout [Slot: [Key: (sum: Double, count: Double)]]
    ) {
        guard let slot else { return }
        var slotMap = sums[slot] ?? [:]
        var entry = slotMap[key] ?? (0, 0)
        entry.sum += value * weight
        entry.count += weight
        slotMap[key] = entry
        sums[slot] = slotMap
    }

    static func build(
        from ratings: [RatedAttributes],
        outfitDimensionRatings: [OutfitDimensionRatedAttributes] = [],
        combinationRatings: [RatedCombination] = [],
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
                slot: item.slot,
                undertone: item.colorProfile.undertone,
                material: item.material,
                texture: item.texture,
                fit: item.fit,
                patternScale: item.patternScale,
                textureFinish: item.textureFinish,
                silhouetteCut: item.silhouetteCut,
                necklineOrRise: item.necklineOrRise,
                fabricWeightDetail: item.fabricWeightDetail
            )
        }
        return build(
            from: ratings,
            outfitDimensionRatings: outfitDimensionRatings,
            combinationRatings: combinationRatings,
            inventorySnapshots: snapshots,
            now: now
        )
    }

    static func build(
        from ratings: [RatedAttributes],
        outfitDimensionRatings: [OutfitDimensionRatedAttributes] = [],
        combinationRatings: [RatedCombination] = [],
        inventorySnapshots: [ItemAttributeSnapshot],
        now: Date = .now
    ) -> AttributePreferenceProfile {
        var colorSums: [ColorVibe: (sum: Double, count: Double)] = [:]
        var colorSumsBySlot: [Slot: [ColorVibe: (sum: Double, count: Double)]] = [:]
        var patternSums: [GarmentPattern: (sum: Double, count: Double)] = [:]
        var patternSumsBySlot: [Slot: [GarmentPattern: (sum: Double, count: Double)]] = [:]
        var formalitySums: [Int: (sum: Double, count: Double)] = [:]
        var formalitySumsBySlot: [Slot: [Int: (sum: Double, count: Double)]] = [:]
        var styleTagSums: [String: (sum: Double, count: Double)] = [:]
        var styleTagSumsBySlot: [Slot: [String: (sum: Double, count: Double)]] = [:]
        var silhouetteSums: [String: (sum: Double, count: Double)] = [:]
        var silhouetteSumsBySlot: [Slot: [String: (sum: Double, count: Double)]] = [:]
        var fabricWeightSums: [FabricWeight: (sum: Double, count: Double)] = [:]
        var fabricWeightSumsBySlot: [Slot: [FabricWeight: (sum: Double, count: Double)]] = [:]
        var undertoneSums: [Undertone: (sum: Double, count: Double)] = [:]
        var undertoneSumsBySlot: [Slot: [Undertone: (sum: Double, count: Double)]] = [:]
        var materialSums: [String: (sum: Double, count: Double)] = [:]
        var materialSumsBySlot: [Slot: [String: (sum: Double, count: Double)]] = [:]
        var textureSums: [String: (sum: Double, count: Double)] = [:]
        var textureSumsBySlot: [Slot: [String: (sum: Double, count: Double)]] = [:]
        var fitSums: [String: (sum: Double, count: Double)] = [:]
        var fitSumsBySlot: [Slot: [String: (sum: Double, count: Double)]] = [:]
        var patternScaleSums: [PatternScale: (sum: Double, count: Double)] = [:]
        var patternScaleSumsBySlot: [Slot: [PatternScale: (sum: Double, count: Double)]] = [:]
        var textureFinishSums: [TextureFinish: (sum: Double, count: Double)] = [:]
        var textureFinishSumsBySlot: [Slot: [TextureFinish: (sum: Double, count: Double)]] = [:]
        var silhouetteCutSums: [SilhouetteCut: (sum: Double, count: Double)] = [:]
        var silhouetteCutSumsBySlot: [Slot: [SilhouetteCut: (sum: Double, count: Double)]] = [:]
        var necklineOrRiseSums: [String: (sum: Double, count: Double)] = [:]
        var necklineOrRiseSumsBySlot: [Slot: [String: (sum: Double, count: Double)]] = [:]
        var fabricWeightDetailSums: [FabricWeightDetail: (sum: Double, count: Double)] = [:]
        var fabricWeightDetailSumsBySlot: [Slot: [FabricWeightDetail: (sum: Double, count: Double)]] = [:]
        var colorHarmonySums: [ColorHarmonyDescriptor: (sum: Double, count: Double)] = [:]
        var paletteArchetypeSums: [PaletteArchetype: (sum: Double, count: Double)] = [:]
        var contrastLevelSums: [ContrastLevel: (sum: Double, count: Double)] = [:]
        var colorSandwichingSums: [Bool: (sum: Double, count: Double)] = [:]
        var proportionRatioSums: [ProportionRatio: (sum: Double, count: Double)] = [:]
        var volumeBalanceSums: [VolumeBalance: (sum: Double, count: Double)] = [:]
        var textureContrastSums: [TextureContrast: (sum: Double, count: Double)] = [:]
        var formalityBridgeSums: [FormalityBridge: (sum: Double, count: Double)] = [:]
        var aestheticVibeSums: [String: (sum: Double, count: Double)] = [:]
        var complexityScoreSums: [Int: (sum: Double, count: Double)] = [:]

        for rating in ratings {
            // Composed multiplicatively, not replaced: `rating.weight` is the
            // 1/N garment-count credit-assignment factor
            // (`Data/WardrobeRepository.swift.recordSwipeAttributes`), decay
            // is the existing 60-day-half-life recency factor — a love'd
            // 4-garment photo swiped yesterday now counts less per-garment
            // than a love'd single-garment photo swiped yesterday, and both
            // still decay identically over time.
            let weight = decayWeight(recordedAt: rating.recordedAt, now: now) * rating.weight

            colorSums[rating.colorVibe, default: (0, 0)].sum += rating.colorLike * weight
            colorSums[rating.colorVibe, default: (0, 0)].count += weight
            accumulateSlot(rating.slot, key: rating.colorVibe, value: rating.colorLike, weight: weight, into: &colorSumsBySlot)

            if let patternLike = rating.patternLike {
                patternSums[rating.pattern, default: (0, 0)].sum += patternLike * weight
                patternSums[rating.pattern, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: rating.pattern, value: patternLike, weight: weight, into: &patternSumsBySlot)
            }

            formalitySums[rating.formalityBand, default: (0, 0)].sum += rating.formalityFit * weight
            formalitySums[rating.formalityBand, default: (0, 0)].count += weight
            accumulateSlot(rating.slot, key: rating.formalityBand, value: rating.formalityFit, weight: weight, into: &formalitySumsBySlot)

            for tag in rating.styleTags {
                styleTagSums[tag, default: (0, 0)].sum += rating.styleIdentity * weight
                styleTagSums[tag, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: tag, value: rating.styleIdentity, weight: weight, into: &styleTagSumsBySlot)
            }

            if let silhouetteTag = rating.silhouetteTag, let silhouetteFit = rating.silhouetteFit {
                silhouetteSums[silhouetteTag, default: (0, 0)].sum += silhouetteFit * weight
                silhouetteSums[silhouetteTag, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: silhouetteTag, value: silhouetteFit, weight: weight, into: &silhouetteSumsBySlot)
            }

            fabricWeightSums[rating.fabricWeight, default: (0, 0)].sum += rating.fabricComfort * weight
            fabricWeightSums[rating.fabricWeight, default: (0, 0)].count += weight
            accumulateSlot(rating.slot, key: rating.fabricWeight, value: rating.fabricComfort, weight: weight, into: &fabricWeightSumsBySlot)

            if let undertone = rating.undertone {
                undertoneSums[undertone, default: (0, 0)].sum += rating.colorLike * weight
                undertoneSums[undertone, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: undertone, value: rating.colorLike, weight: weight, into: &undertoneSumsBySlot)
            }
            if let material = rating.material {
                materialSums[material, default: (0, 0)].sum += rating.fabricComfort * weight
                materialSums[material, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: material, value: rating.fabricComfort, weight: weight, into: &materialSumsBySlot)
            }
            if let texture = rating.texture {
                textureSums[texture, default: (0, 0)].sum += rating.fabricComfort * weight
                textureSums[texture, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: texture, value: rating.fabricComfort, weight: weight, into: &textureSumsBySlot)
            }
            if let fit = rating.fit, let fitLike = rating.fitLike {
                fitSums[fit, default: (0, 0)].sum += fitLike * weight
                fitSums[fit, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: fit, value: fitLike, weight: weight, into: &fitSumsBySlot)
            }

            // Expanded per-garment attributes — each keyed off the closest
            // existing question rather than a new one (see `RatedAttributes`).
            if let patternScale = rating.patternScale, let patternLike = rating.patternLike {
                patternScaleSums[patternScale, default: (0, 0)].sum += patternLike * weight
                patternScaleSums[patternScale, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: patternScale, value: patternLike, weight: weight, into: &patternScaleSumsBySlot)
            }
            if let textureFinish = rating.textureFinish {
                textureFinishSums[textureFinish, default: (0, 0)].sum += rating.fabricComfort * weight
                textureFinishSums[textureFinish, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: textureFinish, value: rating.fabricComfort, weight: weight, into: &textureFinishSumsBySlot)
            }
            if let silhouetteCut = rating.silhouetteCut, let fitLike = rating.fitLike {
                silhouetteCutSums[silhouetteCut, default: (0, 0)].sum += fitLike * weight
                silhouetteCutSums[silhouetteCut, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: silhouetteCut, value: fitLike, weight: weight, into: &silhouetteCutSumsBySlot)
            }
            if let necklineOrRise = rating.necklineOrRise, let fitLike = rating.fitLike {
                necklineOrRiseSums[necklineOrRise, default: (0, 0)].sum += fitLike * weight
                necklineOrRiseSums[necklineOrRise, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: necklineOrRise, value: fitLike, weight: weight, into: &necklineOrRiseSumsBySlot)
            }
            if let fabricWeightDetail = rating.fabricWeightDetail {
                fabricWeightDetailSums[fabricWeightDetail, default: (0, 0)].sum += rating.fabricComfort * weight
                fabricWeightDetailSums[fabricWeightDetail, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: fabricWeightDetail, value: rating.fabricComfort, weight: weight, into: &fabricWeightDetailSumsBySlot)
            }
        }

        for rating in outfitDimensionRatings {
            let weight = decayWeight(recordedAt: rating.recordedAt, now: now) * rating.weight

            colorSums[rating.colorVibe, default: (0, 0)].sum += rating.colorHarmony * weight
            colorSums[rating.colorVibe, default: (0, 0)].count += weight
            accumulateSlot(rating.slot, key: rating.colorVibe, value: rating.colorHarmony, weight: weight, into: &colorSumsBySlot)

            formalitySums[rating.formalityBand, default: (0, 0)].sum += rating.occasionMatch * weight
            formalitySums[rating.formalityBand, default: (0, 0)].count += weight
            accumulateSlot(rating.slot, key: rating.formalityBand, value: rating.occasionMatch, weight: weight, into: &formalitySumsBySlot)

            if let patternDissatisfaction = rating.patternDissatisfaction {
                patternSums[rating.pattern, default: (0, 0)].sum += patternDissatisfaction * weight
                patternSums[rating.pattern, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: rating.pattern, value: patternDissatisfaction, weight: weight, into: &patternSumsBySlot)
            }

            for tag in rating.styleTags {
                styleTagSums[tag, default: (0, 0)].sum += rating.styleMatch * weight
                styleTagSums[tag, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: tag, value: rating.styleMatch, weight: weight, into: &styleTagSumsBySlot)
            }

            if let silhouetteTag = rating.silhouetteTag {
                silhouetteSums[silhouetteTag, default: (0, 0)].sum += rating.silhouette * weight
                silhouetteSums[silhouetteTag, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: silhouetteTag, value: rating.silhouette, weight: weight, into: &silhouetteSumsBySlot)
            }

            fabricWeightSums[rating.fabricWeight, default: (0, 0)].sum += rating.weatherFit * weight
            fabricWeightSums[rating.fabricWeight, default: (0, 0)].count += weight
            accumulateSlot(rating.slot, key: rating.fabricWeight, value: rating.weatherFit, weight: weight, into: &fabricWeightSumsBySlot)

            if let undertone = rating.undertone {
                undertoneSums[undertone, default: (0, 0)].sum += rating.colorHarmony * weight
                undertoneSums[undertone, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: undertone, value: rating.colorHarmony, weight: weight, into: &undertoneSumsBySlot)
            }
            if let material = rating.material {
                materialSums[material, default: (0, 0)].sum += rating.weatherFit * weight
                materialSums[material, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: material, value: rating.weatherFit, weight: weight, into: &materialSumsBySlot)
            }
            if let texture = rating.texture {
                textureSums[texture, default: (0, 0)].sum += rating.weatherFit * weight
                textureSums[texture, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: texture, value: rating.weatherFit, weight: weight, into: &textureSumsBySlot)
            }
            if let fit = rating.fit {
                fitSums[fit, default: (0, 0)].sum += rating.silhouette * weight
                fitSums[fit, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: fit, value: rating.silhouette, weight: weight, into: &fitSumsBySlot)
            }

            // Expanded per-garment attributes, outfit-level mapping — see the
            // doc comment on `OutfitDimensionRatedAttributes`.
            if let patternScale = rating.patternScale, let patternDissatisfaction = rating.patternDissatisfaction {
                patternScaleSums[patternScale, default: (0, 0)].sum += patternDissatisfaction * weight
                patternScaleSums[patternScale, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: patternScale, value: patternDissatisfaction, weight: weight, into: &patternScaleSumsBySlot)
            }
            if let textureFinish = rating.textureFinish {
                textureFinishSums[textureFinish, default: (0, 0)].sum += rating.weatherFit * weight
                textureFinishSums[textureFinish, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: textureFinish, value: rating.weatherFit, weight: weight, into: &textureFinishSumsBySlot)
            }
            if let silhouetteCut = rating.silhouetteCut {
                silhouetteCutSums[silhouetteCut, default: (0, 0)].sum += rating.silhouette * weight
                silhouetteCutSums[silhouetteCut, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: silhouetteCut, value: rating.silhouette, weight: weight, into: &silhouetteCutSumsBySlot)
            }
            if let necklineOrRise = rating.necklineOrRise {
                necklineOrRiseSums[necklineOrRise, default: (0, 0)].sum += rating.silhouette * weight
                necklineOrRiseSums[necklineOrRise, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: necklineOrRise, value: rating.silhouette, weight: weight, into: &necklineOrRiseSumsBySlot)
            }
            if let fabricWeightDetail = rating.fabricWeightDetail {
                fabricWeightDetailSums[fabricWeightDetail, default: (0, 0)].sum += rating.weatherFit * weight
                fabricWeightDetailSums[fabricWeightDetail, default: (0, 0)].count += weight
                accumulateSlot(rating.slot, key: fabricWeightDetail, value: rating.weatherFit, weight: weight, into: &fabricWeightDetailSumsBySlot)
            }
        }

        for rating in combinationRatings {
            let weight = decayWeight(recordedAt: rating.recordedAt, now: now)

            colorHarmonySums[rating.colorHarmony, default: (0, 0)].sum += rating.signal * weight
            colorHarmonySums[rating.colorHarmony, default: (0, 0)].count += weight

            for tag in rating.styleTags {
                styleTagSums[tag, default: (0, 0)].sum += rating.signal * weight
                styleTagSums[tag, default: (0, 0)].count += weight
            }

            if let paletteArchetype = rating.paletteArchetype {
                paletteArchetypeSums[paletteArchetype, default: (0, 0)].sum += rating.signal * weight
                paletteArchetypeSums[paletteArchetype, default: (0, 0)].count += weight
            }
            if let contrastLevel = rating.contrastLevel {
                contrastLevelSums[contrastLevel, default: (0, 0)].sum += rating.signal * weight
                contrastLevelSums[contrastLevel, default: (0, 0)].count += weight
            }
            if let colorSandwiching = rating.colorSandwiching {
                colorSandwichingSums[colorSandwiching, default: (0, 0)].sum += rating.signal * weight
                colorSandwichingSums[colorSandwiching, default: (0, 0)].count += weight
            }
            if let proportionRatio = rating.proportionRatio {
                proportionRatioSums[proportionRatio, default: (0, 0)].sum += rating.signal * weight
                proportionRatioSums[proportionRatio, default: (0, 0)].count += weight
            }
            if let volumeBalance = rating.volumeBalance {
                volumeBalanceSums[volumeBalance, default: (0, 0)].sum += rating.signal * weight
                volumeBalanceSums[volumeBalance, default: (0, 0)].count += weight
            }
            if let textureContrast = rating.textureContrast {
                textureContrastSums[textureContrast, default: (0, 0)].sum += rating.signal * weight
                textureContrastSums[textureContrast, default: (0, 0)].count += weight
            }
            if let formalityBridge = rating.formalityBridge {
                formalityBridgeSums[formalityBridge, default: (0, 0)].sum += rating.signal * weight
                formalityBridgeSums[formalityBridge, default: (0, 0)].count += weight
            }
            if let overallAestheticVibe = rating.overallAestheticVibe {
                let key = overallAestheticVibe.lowercased()
                aestheticVibeSums[key, default: (0, 0)].sum += rating.signal * weight
                aestheticVibeSums[key, default: (0, 0)].count += weight
            }
            if let complexityScore = rating.complexityScore {
                complexityScoreSums[complexityScore, default: (0, 0)].sum += rating.signal * weight
                complexityScoreSums[complexityScore, default: (0, 0)].count += weight
            }
        }

        var colorBaseline: [ColorVibe: Int] = [:]
        var colorBaselineBySlot: [Slot: [ColorVibe: Int]] = [:]
        var patternBaseline: [GarmentPattern: Int] = [:]
        var patternBaselineBySlot: [Slot: [GarmentPattern: Int]] = [:]
        var formalityBaseline: [Int: Int] = [:]
        var formalityBaselineBySlot: [Slot: [Int: Int]] = [:]
        var styleTagBaseline: [String: Int] = [:]
        var styleTagBaselineBySlot: [Slot: [String: Int]] = [:]
        var silhouetteBaseline: [String: Int] = [:]
        var silhouetteBaselineBySlot: [Slot: [String: Int]] = [:]
        var fabricWeightBaseline: [FabricWeight: Int] = [:]
        var fabricWeightBaselineBySlot: [Slot: [FabricWeight: Int]] = [:]
        var undertoneBaseline: [Undertone: Int] = [:]
        var undertoneBaselineBySlot: [Slot: [Undertone: Int]] = [:]
        var materialBaseline: [String: Int] = [:]
        var materialBaselineBySlot: [Slot: [String: Int]] = [:]
        var textureBaseline: [String: Int] = [:]
        var textureBaselineBySlot: [Slot: [String: Int]] = [:]
        var fitBaseline: [String: Int] = [:]
        var fitBaselineBySlot: [Slot: [String: Int]] = [:]
        var patternScaleBaseline: [PatternScale: Int] = [:]
        var patternScaleBaselineBySlot: [Slot: [PatternScale: Int]] = [:]
        var textureFinishBaseline: [TextureFinish: Int] = [:]
        var textureFinishBaselineBySlot: [Slot: [TextureFinish: Int]] = [:]
        var silhouetteCutBaseline: [SilhouetteCut: Int] = [:]
        var silhouetteCutBaselineBySlot: [Slot: [SilhouetteCut: Int]] = [:]
        var necklineOrRiseBaseline: [String: Int] = [:]
        var necklineOrRiseBaselineBySlot: [Slot: [String: Int]] = [:]
        var fabricWeightDetailBaseline: [FabricWeightDetail: Int] = [:]
        var fabricWeightDetailBaselineBySlot: [Slot: [FabricWeightDetail: Int]] = [:]

        func bump<Key: Hashable>(_ key: Key, slot: Slot, in bySlot: inout [Slot: [Key: Int]]) {
            var slotMap = bySlot[slot] ?? [:]
            slotMap[key, default: 0] += 1
            bySlot[slot] = slotMap
        }

        for item in inventorySnapshots {
            colorBaseline[item.colorCategory, default: 0] += 1
            bump(item.colorCategory, slot: item.slot, in: &colorBaselineBySlot)
            patternBaseline[item.pattern, default: 0] += 1
            bump(item.pattern, slot: item.slot, in: &patternBaselineBySlot)
            formalityBaseline[item.formalityBand, default: 0] += 1
            bump(item.formalityBand, slot: item.slot, in: &formalityBaselineBySlot)
            for tag in item.styleTags {
                styleTagBaseline[tag, default: 0] += 1
                bump(tag, slot: item.slot, in: &styleTagBaselineBySlot)
            }
            if let silhouette = item.silhouette {
                silhouetteBaseline[silhouette, default: 0] += 1
                bump(silhouette, slot: item.slot, in: &silhouetteBaselineBySlot)
            }
            fabricWeightBaseline[item.fabricWeight, default: 0] += 1
            bump(item.fabricWeight, slot: item.slot, in: &fabricWeightBaselineBySlot)
            if let undertone = item.undertone {
                undertoneBaseline[undertone, default: 0] += 1
                bump(undertone, slot: item.slot, in: &undertoneBaselineBySlot)
            }
            if let material = item.material {
                materialBaseline[material, default: 0] += 1
                bump(material, slot: item.slot, in: &materialBaselineBySlot)
            }
            if let texture = item.texture {
                textureBaseline[texture, default: 0] += 1
                bump(texture, slot: item.slot, in: &textureBaselineBySlot)
            }
            if let fit = item.fit {
                fitBaseline[fit, default: 0] += 1
                bump(fit, slot: item.slot, in: &fitBaselineBySlot)
            }
            if let patternScale = item.patternScale {
                patternScaleBaseline[patternScale, default: 0] += 1
                bump(patternScale, slot: item.slot, in: &patternScaleBaselineBySlot)
            }
            if let textureFinish = item.textureFinish {
                textureFinishBaseline[textureFinish, default: 0] += 1
                bump(textureFinish, slot: item.slot, in: &textureFinishBaselineBySlot)
            }
            if let silhouetteCut = item.silhouetteCut {
                silhouetteCutBaseline[silhouetteCut, default: 0] += 1
                bump(silhouetteCut, slot: item.slot, in: &silhouetteCutBaselineBySlot)
            }
            if let necklineOrRise = item.necklineOrRise {
                necklineOrRiseBaseline[necklineOrRise, default: 0] += 1
                bump(necklineOrRise, slot: item.slot, in: &necklineOrRiseBaselineBySlot)
            }
            if let fabricWeightDetail = item.fabricWeightDetail {
                fabricWeightDetailBaseline[fabricWeightDetail, default: 0] += 1
                bump(fabricWeightDetail, slot: item.slot, in: &fabricWeightDetailBaselineBySlot)
            }
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

        func affinityMapBySlot<Key: Hashable>(
            sumsBySlot: [Slot: [Key: (sum: Double, count: Double)]],
            baselineBySlot: [Slot: [Key: Int]]
        ) -> [Slot: [Key: Double]] {
            sumsBySlot.reduce(into: [Slot: [Key: Double]]()) { result, entry in
                let (slot, sums) = entry
                result[slot] = affinityMap(sums: sums, baseline: baselineBySlot[slot] ?? [:])
            }
        }

        var profile = AttributePreferenceProfile()
        profile.colorVibeAffinity = affinityMap(sums: colorSums, baseline: colorBaseline)
        profile.colorVibeAffinityBySlot = affinityMapBySlot(sumsBySlot: colorSumsBySlot, baselineBySlot: colorBaselineBySlot)
        profile.patternAffinity = affinityMap(sums: patternSums, baseline: patternBaseline)
        profile.patternAffinityBySlot = affinityMapBySlot(sumsBySlot: patternSumsBySlot, baselineBySlot: patternBaselineBySlot)
        profile.formalityAffinity = affinityMap(sums: formalitySums, baseline: formalityBaseline)
        profile.formalityAffinityBySlot = affinityMapBySlot(sumsBySlot: formalitySumsBySlot, baselineBySlot: formalityBaselineBySlot)
        profile.styleTagAffinity = affinityMap(sums: styleTagSums, baseline: styleTagBaseline)
        profile.styleTagAffinityBySlot = affinityMapBySlot(sumsBySlot: styleTagSumsBySlot, baselineBySlot: styleTagBaselineBySlot)
        profile.silhouetteAffinity = affinityMap(sums: silhouetteSums, baseline: silhouetteBaseline)
        profile.silhouetteAffinityBySlot = affinityMapBySlot(sumsBySlot: silhouetteSumsBySlot, baselineBySlot: silhouetteBaselineBySlot)
        profile.fabricWeightAffinity = affinityMap(sums: fabricWeightSums, baseline: fabricWeightBaseline)
        profile.fabricWeightAffinityBySlot = affinityMapBySlot(sumsBySlot: fabricWeightSumsBySlot, baselineBySlot: fabricWeightBaselineBySlot)
        profile.undertoneAffinity = affinityMap(sums: undertoneSums, baseline: undertoneBaseline)
        profile.undertoneAffinityBySlot = affinityMapBySlot(sumsBySlot: undertoneSumsBySlot, baselineBySlot: undertoneBaselineBySlot)
        profile.materialAffinity = affinityMap(sums: materialSums, baseline: materialBaseline)
        profile.materialAffinityBySlot = affinityMapBySlot(sumsBySlot: materialSumsBySlot, baselineBySlot: materialBaselineBySlot)
        profile.textureAffinity = affinityMap(sums: textureSums, baseline: textureBaseline)
        profile.textureAffinityBySlot = affinityMapBySlot(sumsBySlot: textureSumsBySlot, baselineBySlot: textureBaselineBySlot)
        profile.fitAffinity = affinityMap(sums: fitSums, baseline: fitBaseline)
        profile.fitAffinityBySlot = affinityMapBySlot(sumsBySlot: fitSumsBySlot, baselineBySlot: fitBaselineBySlot)
        profile.patternScaleAffinity = affinityMap(sums: patternScaleSums, baseline: patternScaleBaseline)
        profile.patternScaleAffinityBySlot = affinityMapBySlot(sumsBySlot: patternScaleSumsBySlot, baselineBySlot: patternScaleBaselineBySlot)
        profile.textureFinishAffinity = affinityMap(sums: textureFinishSums, baseline: textureFinishBaseline)
        profile.textureFinishAffinityBySlot = affinityMapBySlot(sumsBySlot: textureFinishSumsBySlot, baselineBySlot: textureFinishBaselineBySlot)
        profile.silhouetteCutAffinity = affinityMap(sums: silhouetteCutSums, baseline: silhouetteCutBaseline)
        profile.silhouetteCutAffinityBySlot = affinityMapBySlot(sumsBySlot: silhouetteCutSumsBySlot, baselineBySlot: silhouetteCutBaselineBySlot)
        profile.necklineOrRiseAffinity = affinityMap(sums: necklineOrRiseSums, baseline: necklineOrRiseBaseline)
        profile.necklineOrRiseAffinityBySlot = affinityMapBySlot(sumsBySlot: necklineOrRiseSumsBySlot, baselineBySlot: necklineOrRiseBaselineBySlot)
        profile.fabricWeightDetailAffinity = affinityMap(sums: fabricWeightDetailSums, baseline: fabricWeightDetailBaseline)
        profile.fabricWeightDetailAffinityBySlot = affinityMapBySlot(sumsBySlot: fabricWeightDetailSumsBySlot, baselineBySlot: fabricWeightDetailBaselineBySlot)
        // No owned-item baseline exists for a whole-look descriptor like
        // "monochrome" or "high contrast" — floors at the flat
        // `defaultPriorWeight`, same as every other dimension's fallback when
        // `baseline[key]` is absent (`dynamicPriorWeight(baselineCount: 0)`
        // already resolves to this same constant).
        profile.colorHarmonyAffinity = colorHarmonySums.reduce(into: [ColorHarmonyDescriptor: Double]()) { result, entry in
            result[entry.key] = shrunkAffinity(sum: entry.value.sum, count: entry.value.count, priorWeight: PairCompatibilityScoring.defaultPriorWeight)
        }

        // Same "no owned-item baseline" shrinkage as `colorHarmonyAffinity`
        // above — a whole-look descriptor has nothing in the closet to
        // baseline against.
        func combinationAffinityMap<Key: Hashable>(_ sums: [Key: (sum: Double, count: Double)]) -> [Key: Double] {
            sums.reduce(into: [Key: Double]()) { result, entry in
                result[entry.key] = shrunkAffinity(sum: entry.value.sum, count: entry.value.count, priorWeight: PairCompatibilityScoring.defaultPriorWeight)
            }
        }
        profile.paletteArchetypeAffinity = combinationAffinityMap(paletteArchetypeSums)
        profile.contrastLevelAffinity = combinationAffinityMap(contrastLevelSums)
        profile.colorSandwichingAffinity = combinationAffinityMap(colorSandwichingSums)
        profile.proportionRatioAffinity = combinationAffinityMap(proportionRatioSums)
        profile.volumeBalanceAffinity = combinationAffinityMap(volumeBalanceSums)
        profile.textureContrastAffinity = combinationAffinityMap(textureContrastSums)
        profile.formalityBridgeAffinity = combinationAffinityMap(formalityBridgeSums)
        profile.aestheticVibeAffinity = combinationAffinityMap(aestheticVibeSums)
        profile.complexityScoreAffinity = combinationAffinityMap(complexityScoreSums)
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
        matchDetail(for: item).bonus
    }

    /// Bounded, NaN-safe bias term for a whole candidate outfit's
    /// deterministically-estimated combination chemistry (added 2026-07-27,
    /// `Domain/PairCompatibilityScoring.estimateCombinationHeuristics`) —
    /// same `[-maxBonusMagnitude, +maxBonusMagnitude]` shape as
    /// `affinityBonus`. Only the 7 scoreable dimensions are read;
    /// `aestheticVibeAffinity`/`complexityScoreAffinity` stay Insights-only.
    /// Any dimension the estimate couldn't derive is simply skipped, not
    /// defaulted — an empty estimate (e.g. a 1-item "outfit") returns 0.
    func combinationAffinityBonus(for estimate: PairCompatibilityScoring.CombinationHeuristicEstimate) -> Double {
        var affinities: [Double] = []
        if let value = estimate.paletteArchetype { affinities.append(paletteArchetypeAffinity[value] ?? 0.5) }
        if let value = estimate.contrastLevel { affinities.append(contrastLevelAffinity[value] ?? 0.5) }
        if let value = estimate.colorSandwiching { affinities.append(colorSandwichingAffinity[value] ?? 0.5) }
        if let value = estimate.proportionRatio { affinities.append(proportionRatioAffinity[value] ?? 0.5) }
        if let value = estimate.volumeBalance { affinities.append(volumeBalanceAffinity[value] ?? 0.5) }
        if let value = estimate.textureContrast { affinities.append(textureContrastAffinity[value] ?? 0.5) }
        if let value = estimate.formalityBridge { affinities.append(formalityBridgeAffinity[value] ?? 0.5) }
        guard !affinities.isEmpty else { return 0 }
        let mean = affinities.reduce(0, +) / Double(affinities.count)
        return ((mean - 0.5) * 2.0 * Self.maxBonusMagnitude).clamped(to: -Self.maxBonusMagnitude...Self.maxBonusMagnitude)
    }

    // MARK: - Slot-aware accessors (backward-compatible with the flat maps)
    //
    // One explicit accessor per dimension, each preferring the per-`Slot`
    // breakdown when `slot` is supplied and that slot has data, falling back
    // to the flat map otherwise — so every existing caller that only reads
    // the flat maps directly keeps compiling and behaving unchanged, while
    // `matchDetail(for:)` below opts into the richer per-slot data.

    func colorVibeAffinity(_ vibe: ColorVibe, slot: Slot?) -> Double {
        if let slot, let value = colorVibeAffinityBySlot[slot]?[vibe] { return value }
        return colorVibeAffinity[vibe] ?? 0.5
    }

    func patternAffinity(_ pattern: GarmentPattern, slot: Slot?) -> Double {
        if let slot, let value = patternAffinityBySlot[slot]?[pattern] { return value }
        return patternAffinity[pattern] ?? 0.5
    }

    func formalityAffinity(_ band: Int, slot: Slot?) -> Double {
        if let slot, let value = formalityAffinityBySlot[slot]?[band] { return value }
        return formalityAffinity[band] ?? 0.5
    }

    func styleTagAffinity(_ tag: String, slot: Slot?) -> Double {
        if let slot, let value = styleTagAffinityBySlot[slot]?[tag] { return value }
        return styleTagAffinity[tag] ?? 0.5
    }

    func silhouetteAffinity(_ silhouette: String, slot: Slot?) -> Double {
        if let slot, let value = silhouetteAffinityBySlot[slot]?[silhouette] { return value }
        return silhouetteAffinity[silhouette] ?? 0.5
    }

    func fabricWeightAffinity(_ weight: FabricWeight, slot: Slot?) -> Double {
        if let slot, let value = fabricWeightAffinityBySlot[slot]?[weight] { return value }
        return fabricWeightAffinity[weight] ?? 0.5
    }

    func undertoneAffinity(_ undertone: Undertone, slot: Slot?) -> Double {
        if let slot, let value = undertoneAffinityBySlot[slot]?[undertone] { return value }
        return undertoneAffinity[undertone] ?? 0.5
    }

    func materialAffinity(_ material: String, slot: Slot?) -> Double {
        if let slot, let value = materialAffinityBySlot[slot]?[material] { return value }
        return materialAffinity[material] ?? 0.5
    }

    func textureAffinity(_ texture: String, slot: Slot?) -> Double {
        if let slot, let value = textureAffinityBySlot[slot]?[texture] { return value }
        return textureAffinity[texture] ?? 0.5
    }

    func fitAffinity(_ fit: String, slot: Slot?) -> Double {
        if let slot, let value = fitAffinityBySlot[slot]?[fit] { return value }
        return fitAffinity[fit] ?? 0.5
    }

    func patternScaleAffinity(_ scale: PatternScale, slot: Slot?) -> Double {
        if let slot, let value = patternScaleAffinityBySlot[slot]?[scale] { return value }
        return patternScaleAffinity[scale] ?? 0.5
    }

    func textureFinishAffinity(_ finish: TextureFinish, slot: Slot?) -> Double {
        if let slot, let value = textureFinishAffinityBySlot[slot]?[finish] { return value }
        return textureFinishAffinity[finish] ?? 0.5
    }

    func silhouetteCutAffinity(_ cut: SilhouetteCut, slot: Slot?) -> Double {
        if let slot, let value = silhouetteCutAffinityBySlot[slot]?[cut] { return value }
        return silhouetteCutAffinity[cut] ?? 0.5
    }

    func necklineOrRiseAffinity(_ value: String, slot: Slot?) -> Double {
        if let slot, let match = necklineOrRiseAffinityBySlot[slot]?[value] { return match }
        return necklineOrRiseAffinity[value] ?? 0.5
    }

    func fabricWeightDetailAffinity(_ detail: FabricWeightDetail, slot: Slot?) -> Double {
        if let slot, let value = fabricWeightDetailAffinityBySlot[slot]?[detail] { return value }
        return fabricWeightDetailAffinity[detail] ?? 0.5
    }

    /// Learned affinity for one whole-look color-harmony descriptor, `[0,1]`,
    /// 0.5 = neutral/unrated — deliberately not folded into `matchDetail(for:
    /// WardrobeItem)`, since color harmony describes a pairing/whole-look, not
    /// one item. Read by `Domain/OutfitChemistryAggregator.swift` (Chemistry
    /// Insights tab).
    func colorHarmonyAffinity(for descriptor: ColorHarmonyDescriptor) -> Double {
        colorHarmonyAffinity[descriptor] ?? 0.5
    }

    /// Whether the profile has learned anything at all yet — used by the
    /// "Test Your Style" verifier (`Features/Profile/StyleCheckViewModel.swift`)
    /// to distinguish "no signal to compare against" from a genuine neutral
    /// score.
    var hasSignal: Bool {
        !colorVibeAffinity.isEmpty || !patternAffinity.isEmpty || !formalityAffinity.isEmpty
            || !styleTagAffinity.isEmpty || !silhouetteAffinity.isEmpty || !fabricWeightAffinity.isEmpty
            || !undertoneAffinity.isEmpty || !materialAffinity.isEmpty || !textureAffinity.isEmpty
            || !fitAffinity.isEmpty || !colorHarmonyAffinity.isEmpty
            || !patternScaleAffinity.isEmpty || !textureFinishAffinity.isEmpty
            || !silhouetteCutAffinity.isEmpty || !necklineOrRiseAffinity.isEmpty
            || !fabricWeightDetailAffinity.isEmpty
    }

    /// Same bounded bias as `affinityBonus`, but also surfaces the per-attribute
    /// affinities it was blended from — so a human sanity-checking the model
    /// (`Features/Profile/StyleCheckViewModel.swift`) sees *why* an item does or
    /// doesn't match ("you lean cool neutrals; you tend to avoid bold prints"),
    /// not just a single percentage. `components` lists only the attributes the
    /// profile actually has data for (an unrated attribute defaults to a neutral
    /// 0.5 and is omitted, though it still contributes its neutral share to the
    /// blended `bonus`, keeping this identical to `affinityBonus`).
    func matchDetail(for item: WardrobeItem) -> AttributeMatchDetail {
        let category = item.colorProfile.category
        let pattern = item.pattern
        let formalityBand = Int(item.formalityScore.rounded())
        let slot = item.slot

        let colorAff = colorVibeAffinity(category, slot: slot)
        let patternAff = patternAffinity(pattern, slot: slot)
        let formalityAff = formalityAffinity(formalityBand, slot: slot)

        let matchedTags = item.styleTags.filter { styleTagAffinityBySlot[slot]?[$0] != nil || styleTagAffinity[$0] != nil }
        let matchingTagAffinities = matchedTags.map { styleTagAffinity($0, slot: slot) }
        let styleTagAff = matchingTagAffinities.isEmpty ? 0.5 : matchingTagAffinities.reduce(0, +) / Double(matchingTagAffinities.count)

        let silhouetteAff = item.silhouette.map { silhouetteAffinity($0, slot: slot) } ?? 0.5
        let fabricWeightAff = fabricWeightAffinity(item.fabricWeight, slot: slot)

        let undertoneAff = item.colorProfile.undertone.map { undertoneAffinity($0, slot: slot) } ?? 0.5
        let materialAff = item.material.map { materialAffinity($0, slot: slot) } ?? 0.5
        let textureAff = item.texture.map { textureAffinity($0, slot: slot) } ?? 0.5
        let fitAff = item.fit.map { fitAffinity($0, slot: slot) } ?? 0.5

        // Expanded per-garment attributes (2026-07-27b). Unlike the ten fixed
        // terms below, each of these joins the mean *only* if the profile has
        // learned anything at all for that dimension — for a closet ingested
        // before these fields existed every map is empty, so the mean stays
        // exactly the 10-way one it was and scoring is bit-for-bit unchanged.
        // Once items carrying them are rated, they start pulling their share
        // rather than diluting the established dimensions from day one.
        var extraAffinities: [Double] = []
        if !patternScaleAffinity.isEmpty || !patternScaleAffinityBySlot.isEmpty {
            extraAffinities.append(item.patternScale.map { patternScaleAffinity($0, slot: slot) } ?? 0.5)
        }
        if !textureFinishAffinity.isEmpty || !textureFinishAffinityBySlot.isEmpty {
            extraAffinities.append(item.textureFinish.map { textureFinishAffinity($0, slot: slot) } ?? 0.5)
        }
        if !silhouetteCutAffinity.isEmpty || !silhouetteCutAffinityBySlot.isEmpty {
            extraAffinities.append(item.silhouetteCut.map { silhouetteCutAffinity($0, slot: slot) } ?? 0.5)
        }
        if !necklineOrRiseAffinity.isEmpty || !necklineOrRiseAffinityBySlot.isEmpty {
            extraAffinities.append(item.necklineOrRise.map { necklineOrRiseAffinity($0, slot: slot) } ?? 0.5)
        }
        if !fabricWeightDetailAffinity.isEmpty || !fabricWeightDetailAffinityBySlot.isEmpty {
            extraAffinities.append(item.fabricWeightDetail.map { fabricWeightDetailAffinity($0, slot: slot) } ?? 0.5)
        }

        // Fixed 10-way mean (was 6-way before undertone/material/texture/fit
        // were learned, 2026-07-24) — an unrated attribute still contributes
        // its neutral 0.5, keeping `bonus` identical to `affinityBonus`; each
        // attribute's individual pull is correspondingly a touch smaller.
        let fixedAffinities = [colorAff, patternAff, formalityAff, styleTagAff, silhouetteAff, fabricWeightAff,
                               undertoneAff, materialAff, textureAff, fitAff]
        let allAffinities = fixedAffinities + extraAffinities
        let mean = allAffinities.reduce(0, +) / Double(allAffinities.count)
        let bonus = ((mean - 0.5) * 2.0 * Self.maxBonusMagnitude)
            .clamped(to: -Self.maxBonusMagnitude...Self.maxBonusMagnitude)

        var components: [AttributeMatchDetail.Component] = []
        if colorVibeAffinityBySlot[slot]?[category] != nil || colorVibeAffinity[category] != nil {
            components.append(.init(label: "\(Self.prettify(category.rawValue)) colors", affinity: colorAff))
        }
        if patternAffinityBySlot[slot]?[pattern] != nil || patternAffinity[pattern] != nil {
            components.append(.init(label: "\(Self.prettify(pattern.rawValue)) pattern", affinity: patternAff))
        }
        if formalityAffinityBySlot[slot]?[formalityBand] != nil || formalityAffinity[formalityBand] != nil {
            components.append(.init(label: "\(Self.formalityDescriptor(formalityBand)) formality", affinity: formalityAff))
        }
        if !matchingTagAffinities.isEmpty {
            components.append(.init(label: "Style: \(matchedTags.joined(separator: ", "))", affinity: styleTagAff))
        }
        if let silhouette = item.silhouette, silhouetteAffinityBySlot[slot]?[silhouette] != nil || silhouetteAffinity[silhouette] != nil {
            components.append(.init(label: "\(silhouette) silhouette", affinity: silhouetteAff))
        }
        if fabricWeightAffinityBySlot[slot]?[item.fabricWeight] != nil || fabricWeightAffinity[item.fabricWeight] != nil {
            components.append(.init(label: "\(Self.prettify(item.fabricWeight.rawValue)) fabric", affinity: fabricWeightAff))
        }
        if let undertone = item.colorProfile.undertone, undertoneAffinityBySlot[slot]?[undertone] != nil || undertoneAffinity[undertone] != nil {
            components.append(.init(label: "\(Self.prettify(undertone.rawValue)) undertone", affinity: undertoneAff))
        }
        if let material = item.material, materialAffinityBySlot[slot]?[material] != nil || materialAffinity[material] != nil {
            components.append(.init(label: "\(material) material", affinity: materialAff))
        }
        if let texture = item.texture, textureAffinityBySlot[slot]?[texture] != nil || textureAffinity[texture] != nil {
            components.append(.init(label: "\(texture) texture", affinity: textureAff))
        }
        if let fit = item.fit, fitAffinityBySlot[slot]?[fit] != nil || fitAffinity[fit] != nil {
            components.append(.init(label: "\(fit) fit", affinity: fitAff))
        }
        if let scale = item.patternScale, patternScaleAffinityBySlot[slot]?[scale] != nil || patternScaleAffinity[scale] != nil {
            components.append(.init(label: "\(Self.prettify(scale.rawValue)) scale", affinity: patternScaleAffinity(scale, slot: slot)))
        }
        if let finish = item.textureFinish, textureFinishAffinityBySlot[slot]?[finish] != nil || textureFinishAffinity[finish] != nil {
            components.append(.init(label: "\(Self.prettify(finish.rawValue)) finish", affinity: textureFinishAffinity(finish, slot: slot)))
        }
        if let cut = item.silhouetteCut, silhouetteCutAffinityBySlot[slot]?[cut] != nil || silhouetteCutAffinity[cut] != nil {
            components.append(.init(label: "\(Self.prettify(cut.rawValue)) cut", affinity: silhouetteCutAffinity(cut, slot: slot)))
        }
        if let neckline = item.necklineOrRise, necklineOrRiseAffinityBySlot[slot]?[neckline] != nil || necklineOrRiseAffinity[neckline] != nil {
            components.append(.init(label: neckline, affinity: necklineOrRiseAffinity(neckline, slot: slot)))
        }
        if let detail = item.fabricWeightDetail, fabricWeightDetailAffinityBySlot[slot]?[detail] != nil || fabricWeightDetailAffinity[detail] != nil {
            components.append(.init(label: "\(Self.prettify(detail.rawValue)) drape", affinity: fabricWeightDetailAffinity(detail, slot: slot)))
        }

        return AttributeMatchDetail(components: components, bonus: bonus)
    }

    private static func prettify(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Mirrors `ItemDetailView.formalityLabel`'s banding so the verifier's
    /// wording matches the rest of the app.
    private static func formalityDescriptor(_ band: Int) -> String {
        switch band {
        case ..<2: return "Casual"
        case 2..<4: return "Smart-Casual"
        default: return "Formal"
        }
    }
}

/// Per-attribute breakdown behind one `AttributePreferenceProfile.matchDetail`
/// call — each `Component` is one attribute the profile has data for, its
/// `affinity` in `[0,1]` (0.5 neutral), and `bonus` is the same clamped value
/// `affinityBonus` returns.
struct AttributeMatchDetail: Equatable {
    struct Component: Equatable {
        /// Human-readable attribute value, e.g. "Neutral colors".
        let label: String
        /// Learned affinity for that value, `[0,1]`, 0.5 = neutral.
        let affinity: Double
    }
    let components: [Component]
    let bonus: Double
}
