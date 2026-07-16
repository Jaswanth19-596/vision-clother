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

    // MARK: - Multi-Accessory Outfits (Stylist Intelligence Engine ADR)

    private func makeWireWithAccessory(
        top: String, bottom: String, footwear: String,
        accessory: String? = nil, supplementaryAccessories: [String] = [],
        rationale: StructuredRationaleWire
    ) -> RecommendedOutfitWire {
        var itemIDsBySlot: [Slot: String] = [.top: top, .bottom: bottom, .footwear: footwear]
        itemIDsBySlot[.accessory] = accessory
        return RecommendedOutfitWire(
            itemIDsBySlot: itemIDsBySlot,
            supplementaryAccessoryIDs: supplementaryAccessories,
            rationale: rationale
        )
    }

    @Test func supplementaryAccessoriesUpToTheCapResolveAlongsideThePrimaryAccessory() {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let belt = makeItem(slot: .accessory)
        let watch = makeItem(slot: .accessory)
        let necklace = makeItem(slot: .accessory)
        let index = makeIndex([top, bottom, footwear, belt, watch, necklace])

        let response = OutfitRecommendationResponse(outfits: [
            makeWireWithAccessory(
                top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString,
                accessory: belt.id.uuidString,
                supplementaryAccessories: [watch.id.uuidString, necklace.id.uuidString],
                rationale: makeRationale("Layered accessories.")
            ),
        ])

        let validated = OutfitRecommendationValidator.validate(response, index: index)
        #expect(validated.count == 1)
        #expect(validated.first?.accessory?.id == belt.id)
        #expect(Set(validated.first?.supplementaryAccessories.map(\.id) ?? []) == [watch.id, necklace.id])
    }

    @Test func supplementaryAccessoriesBeyondTheCapAreTruncatedNotRejected() {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let extras = (0..<(FashionKnowledgeConstants.DressCode.maxSupplementaryAccessories + 1)).map { _ in makeItem(slot: .accessory) }
        let index = makeIndex([top, bottom, footwear] + extras)

        let response = OutfitRecommendationResponse(outfits: [
            makeWireWithAccessory(
                top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString,
                supplementaryAccessories: extras.map(\.id.uuidString),
                rationale: makeRationale("Too many accessories.")
            ),
        ])

        let validated = OutfitRecommendationValidator.validate(response, index: index)
        #expect(validated.first?.supplementaryAccessories.count == FashionKnowledgeConstants.DressCode.maxSupplementaryAccessories)
    }

    @Test func unknownSupplementaryAccessoryIDRejectsTheWholeOutfit() {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let index = makeIndex([top, bottom, footwear])

        let response = OutfitRecommendationResponse(outfits: [
            makeWireWithAccessory(
                top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString,
                supplementaryAccessories: [UUID().uuidString],
                rationale: makeRationale("Hallucinated supplementary accessory.")
            ),
        ])

        #expect(OutfitRecommendationValidator.validate(response, index: index).isEmpty)
    }

    @Test func supplementaryAccessoryDuplicatingThePrimaryAccessoryIsRejected() {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let belt = makeItem(slot: .accessory)
        let index = makeIndex([top, bottom, footwear, belt])

        let response = OutfitRecommendationResponse(outfits: [
            makeWireWithAccessory(
                top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString,
                accessory: belt.id.uuidString,
                supplementaryAccessories: [belt.id.uuidString], // same id as the primary accessory
                rationale: makeRationale("Duplicate accessory.")
            ),
        ])

        #expect(OutfitRecommendationValidator.validate(response, index: index).isEmpty)
    }

    @Test func wrongSlotSupplementaryAccessoryIsRejected() {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let bag = makeItem(slot: .bag)
        let index = makeIndex([top, bottom, footwear, bag])

        let response = OutfitRecommendationResponse(outfits: [
            makeWireWithAccessory(
                top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString,
                supplementaryAccessories: [bag.id.uuidString], // a bag, not an accessory
                rationale: makeRationale("Wrong slot supplementary item.")
            ),
        ])

        #expect(OutfitRecommendationValidator.validate(response, index: index).isEmpty)
    }

    @Test func emptySupplementaryAccessoriesResolveToAnEmptyArray() {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let index = makeIndex([top, bottom, footwear])

        let response = OutfitRecommendationResponse(outfits: [
            makeWireWithAccessory(
                top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString,
                rationale: makeRationale("No accessories.")
            ),
        ])

        let validated = OutfitRecommendationValidator.validate(response, index: index)
        #expect(validated.first?.supplementaryAccessories.isEmpty == true)
    }

    // MARK: - Prospective Purchase Evaluation (2026-07-15)

    @Test func mustIncludeItemIDDropsOutfitsThatOmitTheFlaggedItem() {
        let top = makeItem(slot: .top)
        let otherTop = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let index = makeIndex([top, otherTop, bottom, footwear])

        let response = OutfitRecommendationResponse(outfits: [
            makeWire(
                top: otherTop.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString,
                rationale: makeRationale("Omits the prospective item.")
            ),
        ])

        let validated = OutfitRecommendationValidator.validate(response, index: index, mustIncludeItemID: top.id)
        #expect(validated.isEmpty)
    }

    @Test func mustIncludeItemIDKeepsOutfitsThatIncludeTheFlaggedItem() {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let index = makeIndex([top, bottom, footwear])

        let response = OutfitRecommendationResponse(outfits: [
            makeWire(
                top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString,
                rationale: makeRationale("Includes the prospective item.")
            ),
        ])

        let validated = OutfitRecommendationValidator.validate(response, index: index, mustIncludeItemID: top.id)
        #expect(validated.count == 1)
    }

    @Test func mustIncludeItemIDAlsoMatchesASupplementaryAccessory() {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let watch = makeItem(slot: .accessory)
        let index = makeIndex([top, bottom, footwear, watch])

        let response = OutfitRecommendationResponse(outfits: [
            makeWireWithAccessory(
                top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString,
                supplementaryAccessories: [watch.id.uuidString],
                rationale: makeRationale("The prospective item is a supplementary accessory.")
            ),
        ])

        let validated = OutfitRecommendationValidator.validate(response, index: index, mustIncludeItemID: watch.id)
        #expect(validated.count == 1)
    }

    @Test func mustIncludeItemIDDefaultsToNilAndHasNoEffectOnOrdinaryRecommendations() {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let index = makeIndex([top, bottom, footwear])

        let response = OutfitRecommendationResponse(outfits: [
            makeWire(
                top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString,
                rationale: makeRationale("Ordinary recommendation, no prospective item involved.")
            ),
        ])

        #expect(OutfitRecommendationValidator.validate(response, index: index).count == 1)
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
