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

    private func makeRationale(_ text: String) -> StructuredRationaleWire {
        StructuredRationaleWire(summary: text, confidence: 90)
    }

    private func makeWire(
        top: String, bottom: String, footwear: String, outerwear: String? = nil,
        rationale: StructuredRationaleWire
    ) -> RecommendedOutfitWire {
        var itemIDsBySlot: [Slot: String] = [.top: top, .bottom: bottom, .footwear: footwear]
        itemIDsBySlot[.outerwear] = outerwear
        return RecommendedOutfitWire(itemIDsBySlot: itemIDsBySlot, rationale: rationale)
    }

    @Test func validPicksResolveToScoredOutfits() {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let index = makeIndex([top, bottom, footwear])

        let response = OutfitRecommendationResponse(outfits: [
            makeWire(
                top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString,
                rationale: makeRationale("A clean neutral look.")
            ),
        ])

        let validated = OutfitRecommendationValidator.validate(response, index: index)

        #expect(validated.count == 1)
        #expect(validated.first?.top.id == top.id)
        #expect(validated.first?.structuredRationale?.summary == "A clean neutral look.")
        #expect(!(validated.first?.score.isNaN ?? true))
    }

    @Test func unknownIDIsRejected() {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let index = makeIndex([top, bottom, footwear])

        let response = OutfitRecommendationResponse(outfits: [
            makeWire(
                top: UUID().uuidString, // not in the index
                bottom: bottom.id.uuidString,
                footwear: footwear.id.uuidString,
                rationale: makeRationale("Hallucinated id.")
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
            makeWire(
                // bottom's id placed in the top slot — mismatch.
                top: bottom.id.uuidString,
                bottom: bottom.id.uuidString,
                footwear: footwear.id.uuidString,
                rationale: makeRationale("Slot mismatch.")
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
            makeWire(
                top: top.id.uuidString,
                bottom: top.id.uuidString, // same id as top
                footwear: footwear.id.uuidString,
                rationale: makeRationale("Reused id.")
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
            makeWire(
                top: top.id.uuidString,
                bottom: bottom.id.uuidString,
                footwear: footwear.id.uuidString,
                rationale: makeRationale("Ghost picked by mistake.")
            ),
        ])

        #expect(OutfitRecommendationValidator.validate(response, index: index).isEmpty)
    }

    @Test func allInvalidOutfitsYieldsEmptyArray() {
        let index: [String: WardrobeItem] = [:]
        let response = OutfitRecommendationResponse(outfits: [
            makeWire(top: "x", bottom: "y", footwear: "z", rationale: makeRationale("n/a")),
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
            makeWire(
                top: top.id.uuidString, bottom: bottom.id.uuidString,
                footwear: footwear.id.uuidString, outerwear: outerwear.id.uuidString,
                rationale: makeRationale("Layered look.")
            ),
        ])
        let validated = OutfitRecommendationValidator.validate(validOuterwear, index: index)
        #expect(validated.count == 1)
        #expect(validated.first?.outerwear?.id == outerwear.id)

        let invalidOuterwear = OutfitRecommendationResponse(outfits: [
            makeWire(
                top: top.id.uuidString, bottom: bottom.id.uuidString,
                footwear: footwear.id.uuidString, outerwear: UUID().uuidString,
                rationale: makeRationale("Hallucinated outerwear.")
            ),
        ])
        #expect(OutfitRecommendationValidator.validate(invalidOuterwear, index: index).isEmpty)
    }

    // MARK: - Reason codes (validateVerbose) — additive, doesn't change validate()'s behavior.

    @Test func unknownIDRejectionIsTaggedWithTheExpectedSlot() {
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let index = makeIndex([bottom, footwear])

        let response = OutfitRecommendationResponse(outfits: [
            makeWire(
                top: UUID().uuidString,
                bottom: bottom.id.uuidString,
                footwear: footwear.id.uuidString,
                rationale: makeRationale("Hallucinated id.")
            ),
        ])

        let result = OutfitRecommendationValidator.validateVerbose(response, index: index)
        #expect(result.valid.isEmpty)
        #expect(result.rejections == [.unknownID(slot: .top)])
    }

    @Test func wrongSlotRejectionIsTaggedWithTheExpectedSlot() {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let index = makeIndex([top, bottom, footwear])

        let response = OutfitRecommendationResponse(outfits: [
            makeWire(
                top: bottom.id.uuidString, // wrong slot
                bottom: bottom.id.uuidString,
                footwear: footwear.id.uuidString,
                rationale: makeRationale("Slot mismatch.")
            ),
        ])

        let result = OutfitRecommendationValidator.validateVerbose(response, index: index)
        #expect(result.rejections == [.wrongSlot(slot: .top)])
    }

    @Test func ghostElementRejectionIsTaggedWithTheExpectedSlot() {
        let top = makeItem(slot: .top, isGhost: true)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let index = makeIndex([top, bottom, footwear])

        let response = OutfitRecommendationResponse(outfits: [
            makeWire(
                top: top.id.uuidString,
                bottom: bottom.id.uuidString,
                footwear: footwear.id.uuidString,
                rationale: makeRationale("Ghost picked by mistake.")
            ),
        ])

        let result = OutfitRecommendationValidator.validateVerbose(response, index: index)
        #expect(result.rejections == [.ghostElement(slot: .top)])
    }

    @Test func duplicateIDRejectionIsTagged() {
        let top = makeItem(slot: .top)
        let footwear = makeItem(slot: .footwear)
        let index = makeIndex([top, footwear])

        let response = OutfitRecommendationResponse(outfits: [
            makeWire(
                top: top.id.uuidString,
                bottom: top.id.uuidString,
                footwear: footwear.id.uuidString,
                rationale: makeRationale("Reused id.")
            ),
        ])

        let result = OutfitRecommendationValidator.validateVerbose(response, index: index)
        #expect(result.rejections == [.duplicateID])
    }

    @Test func validateVerboseAgreesWithValidateForSurvivors() {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let index = makeIndex([top, bottom, footwear])

        let response = OutfitRecommendationResponse(outfits: [
            makeWire(
                top: top.id.uuidString, bottom: bottom.id.uuidString,
                footwear: footwear.id.uuidString,
                rationale: makeRationale("A clean neutral look.")
            ),
        ])

        let plain = OutfitRecommendationValidator.validate(response, index: index)
        let verbose = OutfitRecommendationValidator.validateVerbose(response, index: index)

        #expect(verbose.rejections.isEmpty)
        #expect(plain.map(\.top.id) == verbose.valid.map(\.top.id))
        #expect(plain.map(\.score) == verbose.valid.map(\.score))
    }
}
