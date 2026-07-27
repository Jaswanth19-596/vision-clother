//
//  CombinationMetadataSchema.swift
//  Vision_clother
//
//  The JSON schema for `CombinationMetadata` (`Models/SceneMetadata.swift`),
//  extracted to its own type so it can be shared verbatim by both
//  `VisionMetadataExtractionService`'s `sceneMetadataJSONSchema` (image-in,
//  scene-tagging) and `CombinationChemistryInferenceService` (text-in,
//  swipe+comment combination feedback) — one hand-maintained copy of the
//  ~15 properties instead of two that could drift out of sync.
//

import Foundation

enum CombinationMetadataSchema {
    /// Deliberately a plain required object, not a nullable one — see
    /// `VisionMetadataExtractionService.sceneMetadataJSONSchema`'s doc
    /// comment for why nullable *objects* aren't a reliably-honored pattern
    /// across OpenRouter vision models. Applicability (`garments.count >= 2`)
    /// is always decided client-side.
    static let objectSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "color_harmony": ["type": "string", "enum": ColorHarmonyDescriptor.allCases.map(\.rawValue)],
            "style_coherence_tags": ["type": "array", "items": ["type": "string"]],
            "formality_consistency": ["type": "string", "enum": FormalityConsistency.allCases.map(\.rawValue)],
            "rationale": ["type": "string"],
            "palette_archetype": ["type": "string", "enum": PaletteArchetype.allCases.map(\.rawValue)],
            "contrast_level": ["type": "string", "enum": ContrastLevel.allCases.map(\.rawValue)],
            "color_sandwiching": ["type": "boolean"],
            "color_distribution": ["type": "string"],
            "proportion_ratio": ["type": "string", "enum": ProportionRatio.allCases.map(\.rawValue)],
            "volume_balance": ["type": "string", "enum": VolumeBalance.allCases.map(\.rawValue)],
            "texture_contrast": ["type": "string", "enum": TextureContrast.allCases.map(\.rawValue)],
            "formality_bridge": ["type": "string", "enum": FormalityBridge.allCases.map(\.rawValue)],
            "overall_aesthetic_vibe": ["type": "string"],
            "complexity_score": ["type": "integer", "minimum": 1, "maximum": 8],
        ],
        "required": [
            "color_harmony", "style_coherence_tags", "formality_consistency", "rationale",
            "palette_archetype", "contrast_level", "color_sandwiching", "color_distribution",
            "proportion_ratio", "volume_balance", "texture_contrast", "formality_bridge",
            "overall_aesthetic_vibe", "complexity_score",
        ],
        "additionalProperties": false,
    ]

    /// Item-Level Feedback (2026-07-27): the same chemistry object plus
    /// per-garment notes extracted from the user's free-text comment.
    ///
    /// A *wrapper* around `objectSchema` rather than extra properties on it,
    /// deliberately: `objectSchema` is shared verbatim with
    /// `VisionMetadataExtractionService`'s stock-photo scene tagging, where
    /// there are no owned-item ids to attribute a note to. Only the text-only
    /// combination-feedback path (`CombinationChemistryInferenceService`) has
    /// real `WardrobeItem` ids in scope, so only it asks for this.
    static let chemistryWithItemNotesSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "chemistry": objectSchema,
            "item_notes": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "item_id": ["type": "string"],
                        "text": ["type": "string"],
                        "severity": ["type": "string", "enum": ItemNoteSeverity.allCases.map(\.rawValue)],
                        "context": ["type": "string", "enum": ItemNoteContext.allCases.map(\.rawValue)],
                    ],
                    "required": ["item_id", "text", "severity", "context"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["chemistry", "item_notes"],
        "additionalProperties": false,
    ]
}
