//
//  WardrobeItem.swift
//  Vision_clother
//
//  Persisted wardrobe item, matching the ingestion metadata schema in
//  PRD.md §3.1. Backed by SwiftData (CLAUDE.md guardrail #3).
//

import Foundation
import SwiftData

enum Slot: String, Codable, CaseIterable, Identifiable {
    case top, bottom, footwear, outerwear
    case headwear, accessory, bag
    var id: String { rawValue }

    /// top/bottom/footwear are the only slots every `OutfitCombination` must
    /// contain. Everything else is conditionally included.
    var isRequired: Bool {
        switch self {
        case .top, .bottom, .footwear: return true
        case .outerwear, .headwear, .accessory, .bag: return false
        }
    }

    /// Whether `GhostElementProvider` backfills an empty instance of this
    /// slot with a placeholder item.
    var hasGhostDefault: Bool {
        switch self {
        case .top, .bottom, .footwear, .outerwear: return true
        case .headwear, .accessory, .bag: return false
        }
    }

    /// Wire key used by `RecommendedOutfitWire`'s custom Codable
    /// implementation and the recommendation LLM's JSON schema builder.
    var wireKey: String { "\(rawValue)_id" }
}

enum GarmentPattern: String, Codable, CaseIterable {
    case solid, striped, plaid, graphic, textured
}

enum Season: String, Codable, CaseIterable {
    case summer
    case springFall = "spring_fall"
    case winter
}

enum FabricWeight: String, Codable, CaseIterable {
    case light, medium, heavy
}

/// How bold a garment's pattern reads, independent of `GarmentPattern`'s
/// motif type — a striped shirt can be a subtle pinstripe or a bold Breton
/// stripe. Additive alongside `GarmentPattern`, added 2026-07-27.
enum PatternScale: String, Codable, CaseIterable {
    case solid
    case microPattern = "micro_pattern"
    case mediumPattern = "medium_pattern"
    case boldStatementPattern = "bold_statement_pattern"
}

/// Surface finish of the fabric — distinct from the free-text `texture`
/// field, added 2026-07-27.
enum TextureFinish: String, Codable, CaseIterable {
    case matte
    case sheenGloss = "sheen_gloss"
    case texturedKnit = "textured_knit"
    case roughLeather = "rough_leather"
    case denim
    case satin
    case other
}

/// Structural cut of the garment — distinct from the free-text `silhouette`
/// field, added 2026-07-27.
enum SilhouetteCut: String, Codable, CaseIterable {
    case fitted, regular, oversized, cropped, relaxed
    case wideLeg = "wide_leg"
}

/// How the fabric drapes — a more descriptive sibling to `FabricWeight`'s
/// coarse light/medium/heavy, kept as a separate field rather than new cases
/// on `FabricWeight` so no existing consumer's enum-switch needs to change.
/// Added 2026-07-27.
enum FabricWeightDetail: String, Codable, CaseIterable {
    case lightFlowy = "light_flowy"
    case mediumStandard = "medium_standard"
    case heavyStructured = "heavy_structured"
}

/// Shared vocabulary for both the vision-ingestion `color_profile.category`
/// (PRD §3.1) and the intent-extraction `color_palette_vibe` (PRD §3.3) —
/// one enum, reused for wardrobe items and constraints alike.
enum ColorVibe: String, Codable, CaseIterable {
    case neutral
    case earthTones = "earth_tones"
    case monochrome
    case vibrant
    case pastel
}

/// Personal-color undertone, captured both per-garment (ingestion, PRD §3.1)
/// and on the derived `UserStyleProfile` (PRD §3.8) — used by
/// `Domain/ColorHarmony.swift`'s `undertoneCompatibility` term.
enum Undertone: String, Codable, CaseIterable {
    case warm, cool, neutral
}

struct ColorProfile: Codable, Hashable {
    var primaryHex: String
    var secondaryHex: String?
    var category: ColorVibe
    /// Optional so existing persisted rows (pre-2026-07-10) decode as `nil`
    /// under SwiftData's automatic lightweight migration — no schema
    /// version bump needed. `nil` degrades gracefully wherever it's read.
    var undertone: Undertone? = nil
}

/// A garment in the user's wardrobe — either a real ingested item or a
/// virtual "Ghost Element" injected for an empty slot (PRD §3.2).
///
/// Ghost elements are scored through the exact same deterministic path as
/// real items (see `Domain/PairCompatibilityScoring.swift`) — `isGhostElement`
/// exists purely so the UI can label provenance, not to branch the math.
@Model
final class WardrobeItem {
    @Attribute(.unique) var id: UUID
    var slot: Slot
    /// 1.0 = Loungewear/Gym, 3.0 = Smart-Casual/Tech-Office, 5.0 = Black Tie.
    var formalityScore: Double
    var colorProfile: ColorProfile
    var pattern: GarmentPattern
    var seasonality: [Season]
    var fabricWeight: FabricWeight
    /// Filename of the background-isolated photo for this item, if ingested
    /// via the camera/photo-library flow — resolve with
    /// `ImageStorage.url(for:)`, not an asset-catalog lookup. `nil` for
    /// Ghost Elements, which render from `colorProfile` alone.
    var imageAssetName: String?
    var isGhostElement: Bool
    /// One concise natural-language sentence (≤140 chars), captured at
    /// ingestion (PRD §3.1) — this is the text a real (non-ghost) item
    /// contributes to `Domain/WardrobeCatalogBuilder.swift`'s catalog entry
    /// for the recommendation LLM. `nil` for items ingested before the
    /// 2026-07-10 reversal or via manual entry without a description.
    var itemDescription: String?
    /// Free-form style descriptors (e.g. "minimalist", "streetwear") from
    /// vision tagging — additional recommendation-nuance signal, unused by
    /// the deterministic scoring engine. Defaulted so old rows migrate
    /// automatically to `[]`.
    var styleTags: [String] = []

    // Rich styling attributes (added 2026-07-10)
    var garmentSubtype: String? = nil
    var fit: String? = nil
    var silhouette: String? = nil
    var material: String? = nil
    var texture: String? = nil

    // Rich styling attributes, round 2 (added 2026-07-27)
    var patternScale: PatternScale? = nil
    var textureFinish: TextureFinish? = nil
    var silhouetteCut: SilhouetteCut? = nil
    var necklineOrRise: String? = nil
    var fabricWeightDetail: FabricWeightDetail? = nil

    /// Content fingerprint (`ImageStorage.fingerprint`) of the bytes at
    /// `imageAssetName`, captured once wherever those bytes are first
    /// written locally (ingestion, prospective-purchase save, Cloud Sync
    /// photo backfill) — lets `WardrobeRepository.fetchFeedbackHistory()`
    /// tell "embedding cache still valid" from a pure in-memory compare
    /// instead of re-reading and re-hashing every closet photo on every
    /// call. Optional/defaulted so pre-existing rows decode as `nil` under
    /// SwiftData's automatic lightweight migration (same pattern as
    /// `ColorProfile.undertone`) — `nil` just means "not backfilled yet,"
    /// resolved lazily and cached the next time that item is seen. Purely
    /// local/device-derived — deliberately not part of `WardrobeItemDTO`
    /// (`Data/Sync/FirestoreDTOs.swift`), same posture as the also-local-only
    /// `WardrobeItemEmbedding` table it exists to cheapen lookups against.
    var imageFingerprint: String? = nil

    /// Whether this item is currently in the laundry basket — excluded from
    /// the recommendation catalog (`Domain/WardrobeCatalogBuilder.swift`) and
    /// hard-rejected by the validator (`Domain/OutfitRecommendationValidator.swift`)
    /// when `true`. Defaulted so pre-existing rows decode as `false` under
    /// SwiftData's automatic lightweight migration.
    var inLaundry: Bool = false

    /// Denormalized total wear count, incremented alongside `WornLogEntry`
    /// inserts in `DailyAssistantViewModel.markWornToday` — a convenience for
    /// `ItemDetailView`'s display without re-aggregating the full log. Not
    /// the analytics source of truth (that remains
    /// `Domain/WardrobeInsightsAggregator`'s `WornLogEntry`-based computation).
    var wearCount: Int = 0

    /// When this item was last included in a "Worn Today" action — `nil`
    /// until the first wear. Used by `ItemDetailView` and future rotation
    /// heuristics. Defaulted so pre-existing rows decode as `nil` under
    /// SwiftData's automatic lightweight migration.
    var lastWornDate: Date? = nil

    init(
        id: UUID = UUID(),
        slot: Slot,
        formalityScore: Double,
        colorProfile: ColorProfile,
        pattern: GarmentPattern,
        seasonality: [Season],
        fabricWeight: FabricWeight,
        imageAssetName: String? = nil,
        isGhostElement: Bool = false,
        itemDescription: String? = nil,
        styleTags: [String] = [],
        garmentSubtype: String? = nil,
        fit: String? = nil,
        silhouette: String? = nil,
        material: String? = nil,
        texture: String? = nil,
        patternScale: PatternScale? = nil,
        textureFinish: TextureFinish? = nil,
        silhouetteCut: SilhouetteCut? = nil,
        necklineOrRise: String? = nil,
        fabricWeightDetail: FabricWeightDetail? = nil,
        imageFingerprint: String? = nil,
        inLaundry: Bool = false,
        wearCount: Int = 0,
        lastWornDate: Date? = nil
    ) {
        self.id = id
        self.slot = slot
        self.formalityScore = formalityScore
        self.colorProfile = colorProfile
        self.pattern = pattern
        self.seasonality = seasonality
        self.fabricWeight = fabricWeight
        self.imageAssetName = imageAssetName
        self.isGhostElement = isGhostElement
        self.itemDescription = itemDescription
        self.styleTags = styleTags
        self.garmentSubtype = garmentSubtype
        self.fit = fit
        self.silhouette = silhouette
        self.material = material
        self.texture = texture
        self.patternScale = patternScale
        self.textureFinish = textureFinish
        self.silhouetteCut = silhouetteCut
        self.necklineOrRise = necklineOrRise
        self.fabricWeightDetail = fabricWeightDetail
        self.imageFingerprint = imageFingerprint
        self.inLaundry = inLaundry
        self.wearCount = wearCount
        self.lastWornDate = lastWornDate
    }

    /// Items may have no free-text description — this synthesizes a
    /// readable label (e.g. "Striped Vibrant Top") for contexts that need
    /// one, such as `SavedCombination`'s denormalized provenance display.
    var displayLabel: String {
        let colorLabel = colorProfile.category.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        return "\(pattern.rawValue.capitalized) \(colorLabel) \(slot.rawValue.capitalized)"
    }
}
