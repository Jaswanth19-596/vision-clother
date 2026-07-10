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
    var id: String { rawValue }
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
        texture: String? = nil
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
    }

    /// Items may have no free-text description — this synthesizes a
    /// readable label (e.g. "Striped Vibrant Top") for contexts that need
    /// one, such as `SavedCombination`'s denormalized provenance display.
    var displayLabel: String {
        let colorLabel = colorProfile.category.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        return "\(pattern.rawValue.capitalized) \(colorLabel) \(slot.rawValue.capitalized)"
    }
}
