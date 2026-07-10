//
//  OutfitRecommendationValidatorTests.swift
//  Vision_clotherTests
//
//  Covers the deterministic safety net for the primary recommendation LLM
//  path (PRD.md §2.1a) — no outfit surfaced to the user may reference a
//  garment the user doesn't own. See Domain/OutfitRecommendationValidator.swift.
//

import Foundation
import Testing
@testable import Vision_clother

struct OutfitRecommendationValidatorTests {

    private func makeItem(slot: Slot, isGhost: Bool = false) -> WardrobeItem {
        WardrobeItem(
            slot: slot,
            formalityScore: 2.0,
            colorProfile: ColorProfile(primaryHex: "#3A7CA5", secondaryHex: nil, category: .neutral),
            pattern: .solid,
            seasonality: Season.allCases,
            fabricWeight: .light,
            isGhostElement: isGhost
        )
    }

    private func makeIndex(_ items: [WardrobeItem]) -> [String: WardrobeItem] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id.uuidString, $0) })
    }

    @Test func validPicksResolveToScoredOutfits() {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let index = makeIndex([top, bottom, footwear])

        let response = OutfitRecommendationResponse(outfits: [
            RecommendedOutfitWire(
                topID: top.id.uuidString,
                bottomID: bottom.id.uuidString,
                footwearID: footwear.id.uuidString,
                outerwearID: nil,
                rationale: "A clean neutral look."
            ),
        ])

        let validated = OutfitRecommendationValidator.validate(response, index: index)

        #expect(validated.count == 1)
        #expect(validated.first?.top.id == top.id)
        #expect(validated.first?.rationale == "A clean neutral look.")
        #expect(!(validated.first?.score.isNaN ?? true))
    }

    @Test func unknownIDIsRejected() {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let index = makeIndex([top, bottom, footwear])

        let response = OutfitRecommendationResponse(outfits: [
            RecommendedOutfitWire(
                topID: UUID().uuidString, // not in the index
                bottomID: bottom.id.uuidString,
                footwearID: footwear.id.uuidString,
                outerwearID: nil,
                rationale: "Hallucinated id."
            ),
        ])

        #expect(OutfitRecommendationValidator.validate(response, index: index).isEmpty)
    }

    @Test func wrongSlotIsRejected() {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let index = makeIndex([top, bottom, footwear])

        let response = OutfitRecommendationResponse(outfits: [
            RecommendedOutfitWire(
                // bottom's id placed in the top_id slot — mismatch.
                topID: bottom.id.uuidString,
                bottomID: bottom.id.uuidString,
                footwearID: footwear.id.uuidString,
                outerwearID: nil,
                rationale: "Slot mismatch."
            ),
        ])

        #expect(OutfitRecommendationValidator.validate(response, index: index).isEmpty)
    }

    @Test func duplicateIDAcrossSlotsIsRejected() {
        // A hallucinated response can reuse the same item id across two
        // slot fields — e.g. the top's id also given as bottom_id. Every
        // real `WardrobeItem` has exactly one `slot`, so this is naturally
        // caught by the per-field slot check too, but the outcome that
        // matters is end-to-end: such an outfit must never validate.
        let top = makeItem(slot: .top)
        let footwear = makeItem(slot: .footwear)
        let index = makeIndex([top, footwear])

        let response = OutfitRecommendationResponse(outfits: [
            RecommendedOutfitWire(
                topID: top.id.uuidString,
                bottomID: top.id.uuidString, // same id as top_id
                footwearID: footwear.id.uuidString,
                outerwearID: nil,
                rationale: "Reused id."
            ),
        ])

        #expect(OutfitRecommendationValidator.validate(response, index: index).isEmpty)
    }

    @Test func ghostElementIsRejected() {
        let top = makeItem(slot: .top, isGhost: true)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let index = makeIndex([top, bottom, footwear])

        let response = OutfitRecommendationResponse(outfits: [
            RecommendedOutfitWire(
                topID: top.id.uuidString,
                bottomID: bottom.id.uuidString,
                footwearID: footwear.id.uuidString,
                outerwearID: nil,
                rationale: "Ghost picked by mistake."
            ),
        ])

        #expect(OutfitRecommendationValidator.validate(response, index: index).isEmpty)
    }

    @Test func allInvalidOutfitsYieldsEmptyArray() {
        let index: [String: WardrobeItem] = [:]
        let response = OutfitRecommendationResponse(outfits: [
            RecommendedOutfitWire(topID: "x", bottomID: "y", footwearID: "z", outerwearID: nil, rationale: "n/a"),
        ])

        #expect(OutfitRecommendationValidator.validate(response, index: index).isEmpty)
    }

    @Test func validOuterwearResolvesAndInvalidOuterwearRejectsTheWholeOutfit() {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let outerwear = makeItem(slot: .outerwear)
        let index = makeIndex([top, bottom, footwear, outerwear])

        let validOuterwear = OutfitRecommendationResponse(outfits: [
            RecommendedOutfitWire(
                topID: top.id.uuidString, bottomID: bottom.id.uuidString,
                footwearID: footwear.id.uuidString, outerwearID: outerwear.id.uuidString,
                rationale: "Layered look."
            ),
        ])
        let validated = OutfitRecommendationValidator.validate(validOuterwear, index: index)
        #expect(validated.count == 1)
        #expect(validated.first?.outerwear?.id == outerwear.id)

        let invalidOuterwear = OutfitRecommendationResponse(outfits: [
            RecommendedOutfitWire(
                topID: top.id.uuidString, bottomID: bottom.id.uuidString,
                footwearID: footwear.id.uuidString, outerwearID: UUID().uuidString,
                rationale: "Hallucinated outerwear."
            ),
        ])
        #expect(OutfitRecommendationValidator.validate(invalidOuterwear, index: index).isEmpty)
    }
}
