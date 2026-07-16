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

    // MARK: - Embedding-ranked catalog retrieval (added 2026-07-14)

    @Test func oversizedSlotWithATrainedVisualProfilePrefersHigherAffinityItems() {
        let lovedItems = (0..<20).map { _ in makeItem(slot: .top) }
        let neutralItems = (0..<20).map { _ in makeItem(slot: .top) }

        var history = FeedbackHistory()
        history.visualProfile = VisualPreferenceProfile(likedCentroids: [VisualCentroid(vector: [1, 0, 0], weight: 5)])
        for item in lovedItems {
            history.itemEmbeddings[item.id] = [1, 0, 0]
        }
        // neutralItems intentionally have no cached embedding — they should
        // rank behind the loved ones, not crash or throw NaN into the sort.

        let (entries, _) = WardrobeCatalogBuilder.build(from: lovedItems + neutralItems, maxItems: 10, history: history)

        let survivingIDs = Set(entries.map(\.id))
        for item in lovedItems {
            #expect(survivingIDs.contains(item.id.uuidString))
        }
    }

    // MARK: - Prospective Purchase Evaluation (2026-07-15)

    @Test func prospectiveItemIsFlaggedInItsOwnCatalogEntryOnly() {
        let prospective = makeItem(slot: .top)
        let ordinary = makeItem(slot: .bottom)

        let (entries, _) = WardrobeCatalogBuilder.build(from: [prospective, ordinary], prospectiveItemID: prospective.id)

        #expect(entries.first { $0.id == prospective.id.uuidString }?.isProspectivePurchase == true)
        #expect(entries.first { $0.id == ordinary.id.uuidString }?.isProspectivePurchase == false)
    }

    @Test func noEntryIsFlaggedWhenProspectiveItemIDIsNil() {
        let item = makeItem(slot: .top)
        let (entries, _) = WardrobeCatalogBuilder.build(from: [item])
        #expect(entries.allSatisfy { !$0.isProspectivePurchase })
    }

    @Test func prospectiveItemSurvivesTheMaxItemsCapEvenWhenOutnumbered() {
        // 300 ordinary tops competing for a 10-item cap — without the
        // explicit exemption, the prospective item (added last, with no
        // learned-taste advantage) would very likely be capped away.
        let prospective = makeItem(slot: .top)
        let manyOtherTops = (0..<300).map { _ in makeItem(slot: .top) }

        let (entries, _) = WardrobeCatalogBuilder.build(from: [prospective] + manyOtherTops, maxItems: 10, prospectiveItemID: prospective.id)

        #expect(entries.contains { $0.id == prospective.id.uuidString && $0.isProspectivePurchase })
    }

    @Test func prospectiveItemSurvivesTheConstraintsPrefilterEvenWhenItDoesntMatch() {
        // The prospective item is out of season/formality for the supplied
        // constraints — an ordinary item would be silently prefiltered out,
        // but the whole point of this catalog build is to evaluate this
        // specific item, so it must never be the thing quietly dropped.
        let prospective = WardrobeItem(
            slot: .top, formalityScore: 5.0,
            colorProfile: ColorProfile(primaryHex: "#3A7CA5", secondaryHex: nil, category: .neutral),
            pattern: .solid, seasonality: [.winter], fabricWeight: .heavy
        )
        let matchingItem = makeItem(slot: .bottom)

        let constraints = StyleConstraints(
            formalityRange: FormalityRange(lowerBound: 1.0, upperBound: 2.0),
            weatherLayeringRequired: false,
            colorPaletteVibe: [.neutral],
            seasonSuitability: .summer
        )

        let (entries, _) = WardrobeCatalogBuilder.build(
            from: [prospective, matchingItem], constraints: constraints, prospectiveItemID: prospective.id
        )

        #expect(entries.contains { $0.id == prospective.id.uuidString })
    }

    @Test func coldStartWithNoLearnedTasteLeavesTruncationOrderUnchanged() {
        // Regression: an untrained (default, empty) `VisualPreferenceProfile`
        // must leave slot truncation byte-for-byte identical to building with
        // no history at all — every item scores a neutral 0, and Swift's
        // stable sort preserves original order for ties.
        let items = (0..<20).map { _ in makeItem(slot: .top) }

        let (withoutHistory, _) = WardrobeCatalogBuilder.build(from: items, maxItems: 10)
        let (withEmptyHistory, _) = WardrobeCatalogBuilder.build(from: items, maxItems: 10, history: FeedbackHistory())

        #expect(withoutHistory.map(\.id) == withEmptyHistory.map(\.id))
    }
}
