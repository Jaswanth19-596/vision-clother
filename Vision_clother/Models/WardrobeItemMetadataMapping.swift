//
//  WardrobeItemMetadataMapping.swift
//  Vision_clother
//
//  Single bidirectional mapping between the vision-LLM wire type
//  (`GarmentMetadata`) and the persisted `WardrobeItem` — used by manual
//  entry, the background upload job runner, and edit-after-save, so the
//  field list is assembled in exactly one place.
//

import Foundation

extension WardrobeItem {
    /// Fresh item, new UUID — used by manual entry and the upload job runner.
    static func make(from metadata: GarmentMetadata, imageAssetName: String?, isGhostElement: Bool = false) -> WardrobeItem {
        WardrobeItem(
            slot: metadata.slot,
            formalityScore: metadata.formalityScore,
            colorProfile: ColorProfile(
                primaryHex: metadata.colorProfile.primaryHex,
                secondaryHex: metadata.colorProfile.secondaryHex,
                category: metadata.colorProfile.category,
                undertone: metadata.colorProfile.undertone
            ),
            pattern: metadata.pattern,
            seasonality: metadata.seasonality,
            fabricWeight: metadata.fabricWeight,
            imageAssetName: imageAssetName,
            isGhostElement: isGhostElement,
            itemDescription: metadata.description.isEmpty ? nil : metadata.description,
            styleTags: metadata.styleTags,
            garmentSubtype: metadata.garmentSubtype?.isEmpty == true ? nil : metadata.garmentSubtype,
            fit: metadata.fit?.isEmpty == true ? nil : metadata.fit,
            silhouette: metadata.silhouette?.isEmpty == true ? nil : metadata.silhouette,
            material: metadata.material?.isEmpty == true ? nil : metadata.material,
            texture: metadata.texture?.isEmpty == true ? nil : metadata.texture
        )
    }

    /// In-place field overwrite — used by the edit-after-save flow.
    /// Deliberately leaves `id`, `imageAssetName`, `isGhostElement` untouched
    /// so every FK reference (ItemFeedback.itemID, SavedCombination.topItemID,
    /// etc.) stays valid.
    func apply(_ metadata: GarmentMetadata) {
        slot = metadata.slot
        formalityScore = metadata.formalityScore
        colorProfile = ColorProfile(
            primaryHex: metadata.colorProfile.primaryHex,
            secondaryHex: metadata.colorProfile.secondaryHex,
            category: metadata.colorProfile.category,
            undertone: metadata.colorProfile.undertone
        )
        pattern = metadata.pattern
        seasonality = metadata.seasonality
        fabricWeight = metadata.fabricWeight
        itemDescription = metadata.description.isEmpty ? nil : metadata.description
        styleTags = metadata.styleTags
        garmentSubtype = metadata.garmentSubtype?.isEmpty == true ? nil : metadata.garmentSubtype
        fit = metadata.fit?.isEmpty == true ? nil : metadata.fit
        silhouette = metadata.silhouette?.isEmpty == true ? nil : metadata.silhouette
        material = metadata.material?.isEmpty == true ? nil : metadata.material
        texture = metadata.texture?.isEmpty == true ? nil : metadata.texture
    }

    /// Inverse mapping — seeds the edit form from an existing item.
    var currentMetadataDraft: GarmentMetadata {
        GarmentMetadata(
            slot: slot,
            formalityScore: formalityScore,
            colorProfile: GarmentMetadata.ColorProfileWire(
                primaryHex: colorProfile.primaryHex,
                secondaryHex: colorProfile.secondaryHex,
                category: colorProfile.category,
                undertone: colorProfile.undertone
            ),
            pattern: pattern,
            seasonality: seasonality,
            fabricWeight: fabricWeight,
            description: itemDescription ?? "",
            styleTags: styleTags,
            garmentSubtype: garmentSubtype,
            fit: fit,
            silhouette: silhouette,
            material: material,
            texture: texture
        )
    }
}
