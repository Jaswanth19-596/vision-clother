//
//  SceneMetadata.swift
//  Vision_clother
//
//  Wire type returned by the vision-metadata LLM call when tagging a full
//  scene (Swipe-to-Learn taste, `Services/VisionMetadataExtractionService.swift`'s
//  `extractSceneMetadata`) rather than a single isolated garment. Reuses
//  `GarmentMetadata` unmodified for each detected garment — only the framing
//  prompt differs (`Config/ModelConfig.swift`'s `sceneMetadataSystemPrompt`).
//  Dependency-free per Models/CLAUDE.md.
//

import Foundation

struct SceneMetadata: Codable, Equatable {
    var garments: [GarmentMetadata]
    /// Whole-look signal — only present when 2+ garments were detected;
    /// `nil` for a single-garment photo (nothing to compare colors/formality
    /// across).
    var combination: CombinationMetadata?

    enum CodingKeys: String, CodingKey {
        case garments
        case combination
    }

    init(garments: [GarmentMetadata], combination: CombinationMetadata?) {
        self.garments = garments
        self.combination = combination
    }

    /// Tolerant decode: on the unstructured-fallback request path (see
    /// `VisionMetadataExtractionService.extractSceneMetadata`), enum fields
    /// aren't schema-enforced by the API — only advisory prompt text — so a
    /// busy multi-garment photo can come back with one out-of-enum value on
    /// just one of several detected garments. The default array decode would
    /// discard the entire (otherwise-good) response over that single bad
    /// element, so each garment is decoded independently via `superDecoder()`
    /// (which advances the unkeyed container's cursor regardless of whether
    /// the element itself decodes) and only the ones that fail are dropped.
    /// `combination` gets the same best-effort treatment for the same
    /// reason — a malformed sub-field (e.g. an enum spelling mismatch) must
    /// not discard an otherwise-good `garments` array. This is no longer a
    /// "narrative, don't-care" field, though (2026-07-27 correction —
    /// Chemistry Insights depends on it): `VisionMetadataExtractionService.performSceneRequest`
    /// treats a structured-mode response landing here with `combination ==
    /// nil` despite `garments.count >= 2` as a decode failure and retries via
    /// the unstructured fallback, specifically because this decoder can't
    /// tell "cleanly absent" apart from "present but swallowed" once it gets
    /// here — the retry-worthiness check has to live one layer up.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var garments: [GarmentMetadata] = []
        if var garmentsContainer = try? container.nestedUnkeyedContainer(forKey: .garments) {
            while !garmentsContainer.isAtEnd {
                let elementDecoder = try garmentsContainer.superDecoder()
                if let garment = try? GarmentMetadata(from: elementDecoder) {
                    garments.append(garment)
                }
            }
        }
        self.garments = garments
        self.combination = (try? container.decodeIfPresent(CombinationMetadata.self, forKey: .combination)) ?? nil
    }
}

struct CombinationMetadata: Codable, Equatable {
    var colorHarmony: ColorHarmonyDescriptor
    var styleCoherenceTags: [String]
    var formalityConsistency: FormalityConsistency
    var rationale: String

    // Relational styling attributes, round 2 (added 2026-07-27) — same
    // always-filled-best-effort posture as the four fields above; validity
    // (garments.count >= 2) is decided client-side, not by nullability here.
    var paletteArchetype: PaletteArchetype
    var contrastLevel: ContrastLevel
    var colorSandwiching: Bool
    var colorDistribution: String
    var proportionRatio: ProportionRatio
    var volumeBalance: VolumeBalance
    var textureContrast: TextureContrast
    var formalityBridge: FormalityBridge
    var overallAestheticVibe: String
    var complexityScore: Int

    enum CodingKeys: String, CodingKey {
        case colorHarmony = "color_harmony"
        case styleCoherenceTags = "style_coherence_tags"
        case formalityConsistency = "formality_consistency"
        case rationale
        case paletteArchetype = "palette_archetype"
        case contrastLevel = "contrast_level"
        case colorSandwiching = "color_sandwiching"
        case colorDistribution = "color_distribution"
        case proportionRatio = "proportion_ratio"
        case volumeBalance = "volume_balance"
        case textureContrast = "texture_contrast"
        case formalityBridge = "formality_bridge"
        case overallAestheticVibe = "overall_aesthetic_vibe"
        case complexityScore = "complexity_score"
    }
}

/// How the colors across a multi-garment outfit relate to one another.
enum ColorHarmonyDescriptor: String, Codable, CaseIterable {
    case monochrome
    case analogous
    case complementary
    case triadic
    case highContrast = "high_contrast"
    case clashing
}

/// Whether an outfit's formality reads as consistent across its garments, a
/// deliberate high/low contrast, or simply mismatched.
enum FormalityConsistency: String, Codable, CaseIterable {
    case consistent
    case intentionalContrast = "intentional_contrast"
    case mismatched
}

/// The color relationship an outfit's palette follows. Added 2026-07-27.
enum PaletteArchetype: String, Codable, CaseIterable {
    case monochromatic, tonal, complementary, analogous, triadic, clashing
    case neutralWithPop = "neutral_with_pop"
}

/// How much visual contrast the outfit carries overall. Added 2026-07-27.
enum ContrastLevel: String, Codable, CaseIterable {
    case lowTonal = "low_tonal"
    case mediumContrast = "medium_contrast"
    case highContrast = "high_contrast"
}

/// How the outfit's visual weight is proportioned top-to-bottom. Added
/// 2026-07-27.
enum ProportionRatio: String, Codable, CaseIterable {
    case ruleOfThirds = "rule_of_thirds"
    case halfAndHalf = "half_and_half"
    case oversizedLongline = "oversized_longline"
}

/// The fit/volume relationship between garments in the outfit. Added
/// 2026-07-27.
enum VolumeBalance: String, Codable, CaseIterable {
    case fittedTopLooseBottom = "fitted_top_loose_bottom"
    case looseTopFittedBottom = "loose_top_fitted_bottom"
    case allRelaxed = "all_relaxed"
    case allFitted = "all_fitted"
    case volumeSandwich = "volume_sandwich"
}

/// How much the garments' surface textures contrast with one another. Added
/// 2026-07-27.
enum TextureContrast: String, Codable, CaseIterable {
    case highContrast = "high_contrast"
    case mediumContrast = "medium_contrast"
    case uniformTexture = "uniform_texture"
}

/// Whether the outfit's formality levels are bridged consistently, as a
/// deliberate high/low pairing, or clash outright. Added 2026-07-27.
enum FormalityBridge: String, Codable, CaseIterable {
    case consistent
    case intentionalHighLow = "intentional_high_low"
    case mismatchedClash = "mismatched_clash"
}
