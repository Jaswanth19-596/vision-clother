//
//  GarmentAttributesEditorModel.swift
//  Vision_clother
//
//  The editable-fields backing store for the garment attributes form,
//  extracted from `AddItemViewModel` so the same form can drive both manual
//  entry (`AddItemView`) and edit-after-save (`EditItemView`).
//

import Foundation
import Observation

@Observable
@MainActor
final class GarmentAttributesEditorModel {
    var slot: Slot = .top
    var formalityScore: Double = 3.0
    var primaryHex: String = "#FFFFFF"
    var secondaryHex: String? = nil
    var colorCategory: ColorVibe = .neutral
    var undertone: Undertone? = nil
    var pattern: GarmentPattern = .solid
    var seasonality: [Season] = [.summer, .springFall, .winter]
    var fabricWeight: FabricWeight = .medium
    var itemDescription: String = ""
    var styleTags: [String] = []

    var garmentSubtype: String = ""
    var fit: String = ""
    var silhouette: String = ""
    var material: String = ""
    var texture: String = ""

    func reset(defaultSlot: Slot) {
        slot = defaultSlot
        formalityScore = 3.0
        primaryHex = "#FFFFFF"
        secondaryHex = nil
        colorCategory = .neutral
        undertone = nil
        pattern = .solid
        seasonality = [.summer, .springFall, .winter]
        fabricWeight = .medium
        itemDescription = ""
        styleTags = []
        garmentSubtype = ""
        fit = ""
        silhouette = ""
        material = ""
        texture = ""
    }

    func load(from metadata: GarmentMetadata) {
        slot = metadata.slot
        formalityScore = metadata.formalityScore
        primaryHex = metadata.colorProfile.primaryHex
        secondaryHex = metadata.colorProfile.secondaryHex
        colorCategory = metadata.colorProfile.category
        undertone = metadata.colorProfile.undertone
        pattern = metadata.pattern
        seasonality = metadata.seasonality
        fabricWeight = metadata.fabricWeight
        itemDescription = metadata.description
        styleTags = metadata.styleTags
        garmentSubtype = metadata.garmentSubtype ?? ""
        fit = metadata.fit ?? ""
        silhouette = metadata.silhouette ?? ""
        material = metadata.material ?? ""
        texture = metadata.texture ?? ""
    }

    func makeMetadata() -> GarmentMetadata {
        GarmentMetadata(
            slot: slot,
            formalityScore: formalityScore,
            colorProfile: GarmentMetadata.ColorProfileWire(
                primaryHex: primaryHex,
                secondaryHex: secondaryHex,
                category: colorCategory,
                undertone: undertone
            ),
            pattern: pattern,
            seasonality: seasonality,
            fabricWeight: fabricWeight,
            description: itemDescription,
            styleTags: styleTags,
            garmentSubtype: garmentSubtype,
            fit: fit,
            silhouette: silhouette,
            material: material,
            texture: texture
        )
    }
}
