//
//  DailyAssistantViewModelTests.swift
//  Vision_clotherTests
//
//  Covers the primary recommendation path and its deterministic fallback
//  (PRD §2.1a). Try-on generation and `saveCombination` now run through
//  `Features/JobQueue/JobQueueStore.swift` — see JobQueueStoreTests.swift.
//
//  `RecommendationSettings.useAIRecommendations` is backed by real
//  `UserDefaults.standard` (one process-wide value, like
//  `UserPortraitStorage`'s single file — see ManualPairingViewModelTests.swift's
//  header) so tests that set it can't run concurrently with each other
//  without racing; this suite is serialized for that reason, matching that
//  file's convention.
//

import Foundation
import Testing
@testable import Vision_clother

@Suite(.serialized)
@MainActor
struct DailyAssistantViewModelTests {

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

    // MARK: - Primary recommendation path + deterministic fallback (PRD §2.1a)

    @Test func happyPathUsesRecommendationServiceAndSkipsTheFallbackEngine() async throws {
        RecommendationSettings.useAIRecommendations = true
        defer { RecommendationSettings.useAIRecommendations = true }

        let repository = InMemoryWardrobeRepository()
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        repository.savedItems = [top, bottom, footwear]

        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.result = .success(OutfitRecommendationResponse(outfits: [
            makeWire(
                top: top.id.uuidString, bottom: bottom.id.uuidString,
                footwear: footwear.id.uuidString,
                rationale: makeRationale("A clean, neutral pairing.")
            ),
        ]))
        let intentService = ControllableIntentExtractionService()

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            intentService: intentService,
            recommendationService: recommendationService
        )
        viewModel.prompt = "Casual Friday"

        await viewModel.requestOutfitIdeas()

        #expect(viewModel.candidates.count == 1)
        #expect(viewModel.candidates.first?.structuredRationale?.summary == "A clean, neutral pairing.")
        #expect(viewModel.extractionState == .idle)
        #expect(intentService.callCount == 0) // fallback pipeline never engaged
    }

    @Test func recommendationServiceThrowingFallsBackToTheDeterministicEngine() async throws {
        RecommendationSettings.useAIRecommendations = true
        defer { RecommendationSettings.useAIRecommendations = true }

        let repository = InMemoryWardrobeRepository()
        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.result = .failure(RecommendationFailure())
        let intentService = ControllableIntentExtractionService()

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            intentService: intentService,
            recommendationService: recommendationService
        )
        viewModel.prompt = "Weekend brunch"

        await viewModel.requestOutfitIdeas()

        // Empty inventory still produces ghost-backed candidates via the
        // fallback engine (see OutfitRecommendationEngineTests) — the point
        // here is that the fallback actually ran.
        #expect(!viewModel.candidates.isEmpty)
        #expect(viewModel.extractionState == .idle)
        #expect(intentService.callCount == 1)
    }

    @Test func unresolvableRecommendationIDsFallBackToTheDeterministicEngine() async throws {
        RecommendationSettings.useAIRecommendations = true
        defer { RecommendationSettings.useAIRecommendations = true }

        let repository = InMemoryWardrobeRepository()
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        repository.savedItems = [top, bottom, footwear]

        let recommendationService = ControllableOutfitRecommendationService()
        // References ids that don't exist in the inventory at all —
        // every outfit must fail validation.
        recommendationService.result = .success(OutfitRecommendationResponse(outfits: [
            makeWire(
                top: UUID().uuidString, bottom: UUID().uuidString,
                footwear: UUID().uuidString,
                rationale: makeRationale("Hallucinated.")
            ),
        ]))
        let intentService = ControllableIntentExtractionService()

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            intentService: intentService,
            recommendationService: recommendationService
        )
        viewModel.prompt = "Job interview"

        await viewModel.requestOutfitIdeas()

        #expect(!viewModel.candidates.isEmpty)
        #expect(viewModel.extractionState == .idle)
        #expect(intentService.callCount == 1)
    }

    @Test func resolvedConstraintsFromTheRecommendationResponseEnforceFormalityAlignmentOnTheLLMPath() async throws {
        // Stylist Intelligence Engine ADR: the LLM path previously passed
        // `constraints: nil` to the validator, so Tier 1 dress-code alignment
        // was only ever prompt guidance, never a deterministic check. Now the
        // recommendation response self-reports `resolved_constraints` and the
        // view model threads it through — without a second intent-extraction
        // call (`intentService.callCount` must stay 0, same as the existing
        // happy-path invariant).
        RecommendationSettings.useAIRecommendations = true
        defer { RecommendationSettings.useAIRecommendations = true }

        let repository = InMemoryWardrobeRepository()
        // All three items are mutually coherent (formality 2.0, small
        // pairwise deltas) so PairCompatibilityScoring's *internal*
        // formality-delta check alone wouldn't flag anything — only a
        // constraints-aware Tier 1 check against the resolved scenario band
        // (4.5-5.0) can catch this outfit being wildly under-formal for it.
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        repository.savedItems = [top, bottom, footwear]

        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.result = .success(OutfitRecommendationResponse(
            outfits: [
                makeWire(
                    top: top.id.uuidString, bottom: bottom.id.uuidString,
                    footwear: footwear.id.uuidString,
                    rationale: makeRationale("Black tie gala.")
                ),
            ],
            resolvedConstraints: StyleConstraints(
                formalityRange: FormalityRange(lowerBound: 4.5, upperBound: 5.0),
                weatherLayeringRequired: false,
                colorPaletteVibe: [.neutral],
                seasonSuitability: .summer
            )
        ))
        let intentService = ControllableIntentExtractionService()

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            intentService: intentService,
            recommendationService: recommendationService
        )
        viewModel.prompt = "Black tie gala"

        await viewModel.requestOutfitIdeas()

        let candidate = try #require(viewModel.candidates.first)
        let scoreWithoutConstraints = OutfitRecommendationEngine.outfitScore(
            for: candidate.items, constraints: nil, history: FeedbackHistory()
        )

        #expect(candidate.score < scoreWithoutConstraints)
        #expect(intentService.callCount == 0) // still no extra LLM round-trip on the happy path
    }

    @Test func privacyOptOutSkipsTheRecommendationServiceEntirely() async throws {
        RecommendationSettings.useAIRecommendations = false
        defer { RecommendationSettings.useAIRecommendations = true }

        let repository = InMemoryWardrobeRepository()
        let recommendationService = ControllableOutfitRecommendationService()
        let intentService = ControllableIntentExtractionService()

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            intentService: intentService,
            recommendationService: recommendationService
        )
        viewModel.prompt = "Grocery run"

        await viewModel.requestOutfitIdeas()

        #expect(recommendationService.callCount == 0)
        #expect(intentService.callCount == 1)
        #expect(!viewModel.candidates.isEmpty)
    }
}

// MARK: - Test helpers

@MainActor
private func makeJobQueueStore(repository: WardrobeRepository) -> JobQueueStore {
    JobQueueStore(
        repository: repository,
        backgroundIsolationService: MockBackgroundIsolationService(),
        imagePreprocessingService: MockBackgroundIsolationService(),
        visionMetadataService: MockVisionMetadataExtractionService(),
        tryOnService: MockTryOnRenderService(),
        photoLibrarySaver: MockPhotoLibrarySaver(),
        notificationService: MockJobNotificationService()
    )
}

private func makeItem(slot: Slot) -> WardrobeItem {
    WardrobeItem(
        slot: slot,
        formalityScore: 2.0,
        colorProfile: ColorProfile(primaryHex: "#000000", secondaryHex: nil, category: .neutral),
        pattern: .solid,
        seasonality: [.summer],
        fabricWeight: .light,
        imageAssetName: "\(UUID().uuidString).png"
    )
}

private func makeOutfit() -> OutfitCombination {
    OutfitCombination(
        itemsBySlot: [.top: makeItem(slot: .top), .bottom: makeItem(slot: .bottom), .footwear: makeItem(slot: .footwear)],
        score: 1.0
    )
}

// MARK: - Test doubles

@MainActor
private final class InMemoryWardrobeRepository: WardrobeRepository {
    var savedItems: [WardrobeItem] = []
    var savedCombinations: [SavedCombination] = []

    func fetchInventory() throws -> [WardrobeItem] { savedItems }
    func save(_ item: WardrobeItem) throws { savedItems.append(item) }
    func update(_ item: WardrobeItem) throws {}
    func delete(_ item: WardrobeItem) throws { savedItems.removeAll { $0.id == item.id } }
    func fetchFeedbackHistory() throws -> FeedbackHistory { FeedbackHistory() }
    func recordOutfitFeedback(outfitID: UUID, likedOverall: Bool) throws {}
    func recordItemFeedback(itemID: UUID, likedFit: Bool) throws {}
    func recordPairFeedback(itemAID: UUID, itemBID: UUID, likedTogether: Bool) throws {}
    func recordItemRating(itemID: UUID, fit: FitRating, comfort: Int, confidence: Int, wearAgain: Bool, versatility: Int, frequency: Int, styleIdentity: Int, qualityPerception: Int) throws {}
    func fetchItemRatings(for itemID: UUID) throws -> [ItemRating] { [] }
    func recordOutfitRating(outfitID: UUID, submission: OutfitRatingSubmission) throws {}
    func fetchOutfitFeedback(for outfitID: UUID) throws -> [OutfitFeedback] { [] }

    func fetchSavedCombinations() throws -> [SavedCombination] { savedCombinations }
    func saveCombination(_ combination: SavedCombination) throws { savedCombinations.append(combination) }
    func deleteCombination(_ combination: SavedCombination) throws {
        savedCombinations.removeAll { $0.id == combination.id }
    }

    var userProfile: UserStyleProfile?
    func fetchUserProfile() throws -> UserStyleProfile? { userProfile }
    func saveUserProfile(_ wire: UserStyleProfileWire) throws {
        userProfile = UserStyleProfile(
            skinTone: wire.skinTone,
            undertone: wire.undertone,
            bodyType: wire.bodyType,
            styleKeywords: wire.styleKeywords,
            recommendedColors: wire.recommendedColors,
            avoidColors: wire.avoidColors
        )
    }
}

/// Returns a fixed `OutfitRecommendationResponse` (or throws, if configured)
/// regardless of the catalog it's given — the tests build the catalog
/// themselves and assert on how the view model reacts to the response.
private final class ControllableOutfitRecommendationService: OutfitRecommendationService {
    var result: Result<OutfitRecommendationResponse, Error> = .success(OutfitRecommendationResponse(outfits: []))
    private(set) var callCount = 0

    func recommendOutfits(
        prompt: String,
        catalog: [CatalogEntry],
        profile: UserStyleProfile?,
        weather: WeatherContext?,
        history: FeedbackHistory
    ) async throws -> OutfitRecommendationResponse {
        callCount += 1
        return try result.get()
    }
}

private struct RecommendationFailure: Error {}

/// Spies on how many times the fallback intent-extraction path is actually
/// engaged — the assertion that matters across the primary/fallback tests
/// isn't just "candidates non-empty" (ghost elements guarantee that on
/// their own) but *which* pipeline produced them.
private final class ControllableIntentExtractionService: IntentExtractionService {
    private(set) var callCount = 0

    func extractConstraints(prompt: String, weather: WeatherContext?) async throws -> StyleConstraints {
        callCount += 1
        return StyleConstraints(
            formalityRange: FormalityRange(lowerBound: 1.0, upperBound: 5.0),
            weatherLayeringRequired: false,
            colorPaletteVibe: [.neutral],
            seasonSuitability: .summer
        )
    }
}
