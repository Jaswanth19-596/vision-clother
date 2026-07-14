//
//  OutfitRecommendationServiceTests.swift
//  Vision_clotherTests
//
//  Covers `MockOutfitRecommendationService` — the keyless-Simulator path for
//  the primary recommendation call (PRD.md §3.7). Mocks only, zero network,
//  matching this project's testing convention for OpenRouter-backed services.
//

import Foundation
import Testing
@testable import Vision_clother

struct OutfitRecommendationServiceTests {

    private func turns(_ text: String) -> [ConversationTurn] {
        [ConversationTurn(role: .user, text: text)]
    }

    private func makeEntry(id: UUID = UUID(), slot: Slot) -> CatalogEntry {
        CatalogEntry(
            id: id.uuidString,
            slot: slot,
            formality: 2.0,
            colorCategory: .neutral,
            primaryHex: "#3A7CA5",
            secondaryHex: nil,
            undertone: nil,
            pattern: .solid,
            seasonality: Season.allCases,
            fabricWeight: .light,
            description: nil
        )
    }

    @Test func mockReturnsPicksThatReferenceRealCatalogIDs() async throws {
        let catalog = [
            makeEntry(slot: .top),
            makeEntry(slot: .bottom),
            makeEntry(slot: .footwear),
        ]
        let catalogIDs = Set(catalog.map(\.id))

        let response = try await MockOutfitRecommendationService().recommendOutfits(
            conversationHistory: turns("Casual Friday"), isFinalTurn: false, catalog: catalog, profile: nil, weather: nil, history: FeedbackHistory()
        )

        #expect(response.outfits.count == 1)
        let outfit = try #require(response.outfits.first)
        #expect(catalogIDs.contains(try #require(outfit.itemIDsBySlot[.top])))
        #expect(catalogIDs.contains(try #require(outfit.itemIDsBySlot[.bottom])))
        #expect(catalogIDs.contains(try #require(outfit.itemIDsBySlot[.footwear])))
        #expect(outfit.itemIDsBySlot[.outerwear] == nil)
        // The mock also self-reports resolved_constraints, matching the real
        // service's contract, so the validator's Tier 1 formality check
        // exercises the same code path on the keyless Simulator run.
        #expect(response.resolvedConstraints != nil)
    }

    @Test func mockResolvedConstraintsReflectColdWeatherAsLayeringRequired() async throws {
        let catalog = [makeEntry(slot: .top), makeEntry(slot: .bottom), makeEntry(slot: .footwear)]
        let cold = WeatherContext(temperatureFahrenheit: 20, conditions: "Snow")

        let response = try await MockOutfitRecommendationService().recommendOutfits(
            conversationHistory: turns("Winter errands"), isFinalTurn: false, catalog: catalog, profile: nil, weather: cold, history: FeedbackHistory()
        )

        #expect(response.resolvedConstraints?.weatherLayeringRequired == true)
    }

    @Test func mockIncludesOuterwearWhenWeatherIsProvidedAndAvailable() async throws {
        let catalog = [
            makeEntry(slot: .top),
            makeEntry(slot: .bottom),
            makeEntry(slot: .footwear),
            makeEntry(slot: .outerwear),
        ]
        let weather = WeatherContext(temperatureFahrenheit: 40, conditions: "Rain")

        let response = try await MockOutfitRecommendationService().recommendOutfits(
            conversationHistory: turns("Cold commute"), isFinalTurn: false, catalog: catalog, profile: nil, weather: weather, history: FeedbackHistory()
        )

        #expect(response.outfits.first?.itemIDsBySlot[.outerwear] != nil)
    }

    @Test func mockReturnsNoOutfitsWhenARequiredSlotIsMissingFromTheCatalog() async throws {
        // No footwear at all in the catalog — the mock must not fabricate
        // an id, it should return an empty outfits array instead.
        let catalog = [makeEntry(slot: .top), makeEntry(slot: .bottom)]

        let response = try await MockOutfitRecommendationService().recommendOutfits(
            conversationHistory: turns("Anything"), isFinalTurn: false, catalog: catalog, profile: nil, weather: nil, history: FeedbackHistory()
        )

        #expect(response.outfits.isEmpty)
    }
}
