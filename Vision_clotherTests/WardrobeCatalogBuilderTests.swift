//
//  WardrobeCatalogBuilderTests.swift
//  Vision_clotherTests
//
//  Covers the bounded, text-only wardrobe catalog sent to the recommendation
//  LLM (PRD.md §3.7) — Ghost Elements must never appear, descriptions must
//  be truncated, and an oversized inventory must be capped rather than
//  silently overflowing the request payload.
//  See Domain/WardrobeCatalogBuilder.swift.
//

import Foundation
import Testing
@testable import Vision_clother

struct WardrobeCatalogBuilderTests {

    private func makeItem(
        slot: Slot,
        isGhost: Bool = false,
        description: String? = nil
    ) -> WardrobeItem {
        WardrobeItem(
            slot: slot,
            formalityScore: 2.0,
            colorProfile: ColorProfile(primaryHex: "#3A7CA5", secondaryHex: nil, category: .neutral),
            pattern: .solid,
            seasonality: Season.allCases,
            fabricWeight: .light,
            isGhostElement: isGhost,
            itemDescription: description
        )
    }

    @Test func ghostElementsAreExcluded() {
        let real = makeItem(slot: .top)
        let ghost = makeItem(slot: .bottom, isGhost: true)

        let (entries, index) = WardrobeCatalogBuilder.build(from: [real, ghost])

        #expect(entries.count == 1)
        #expect(entries.first?.id == real.id.uuidString)
        #expect(index[ghost.id.uuidString] == nil)
    }

    @Test func descriptionIsTruncatedToTheCharLimit() {
        let longDescription = String(repeating: "a", count: 300)
        let item = makeItem(slot: .top, description: longDescription)

        let (entries, _) = WardrobeCatalogBuilder.build(from: [item], descriptionCharLimit: 140)

        #expect(entries.first?.description?.count == 140)
    }

    @Test func nilOrEmptyDescriptionStaysNil() {
        let item = makeItem(slot: .top, description: nil)
        let (entries, _) = WardrobeCatalogBuilder.build(from: [item])
        #expect(entries.first?.description == nil)
    }

    @Test func indexMapsEveryEntryBackToItsRealItem() {
        let items = (0..<5).map { _ in makeItem(slot: .top) }
        let (entries, index) = WardrobeCatalogBuilder.build(from: items)

        #expect(entries.count == items.count)
        for entry in entries {
            #expect(index[entry.id]?.id.uuidString == entry.id)
        }
    }

    @Test func oversizedInventoryIsCappedAtMaxItems() {
        let items = (0..<400).map { i in makeItem(slot: i % 2 == 0 ? .top : .bottom) }

        let (entries, index) = WardrobeCatalogBuilder.build(from: items, maxItems: 50)

        #expect(entries.count <= 50)
        #expect(index.count == entries.count)
    }

    @Test func userRatingIsNilWithoutFeedbackHistory() {
        let item = makeItem(slot: .top)
        let (entries, _) = WardrobeCatalogBuilder.build(from: [item])
        #expect(entries.first?.userRating == nil)
    }

    @Test func userRatingIsNeutralFiftyWhenItemHasNoFeedback() {
        let item = makeItem(slot: .top)
        let (entries, _) = WardrobeCatalogBuilder.build(from: [item], history: FeedbackHistory())
        #expect(entries.first?.userRating == 50)
    }

    @Test func userRatingReflectsPoorFeedbackForThatItem() throws {
        let item = makeItem(slot: .top)
        var history = FeedbackHistory()
        history.itemFeedback[item.id] = (likes: 0, total: 10)

        let (entries, _) = WardrobeCatalogBuilder.build(from: [item], history: history)

        let rating = try #require(entries.first?.userRating)
        #expect(rating < 50)
    }

    @Test func slotBalancedSamplingKeepsEveryRequiredSlotRepresented() {
        // A closet dominated by tops shouldn't crowd out bottoms/footwear
        // entirely once the cap kicks in.
        let manyTops = (0..<300).map { _ in makeItem(slot: .top) }
        let fewBottoms = (0..<5).map { _ in makeItem(slot: .bottom) }
        let fewFootwear = (0..<5).map { _ in makeItem(slot: .footwear) }

        let (entries, _) = WardrobeCatalogBuilder.build(from: manyTops + fewBottoms + fewFootwear, maxItems: 60)

        let slotsPresent = Set(entries.map(\.slot))
        #expect(slotsPresent.contains(.bottom))
        #expect(slotsPresent.contains(.footwear))
    }
}
