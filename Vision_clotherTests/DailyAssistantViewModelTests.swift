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

    // MARK: - Clarification Loop (Stylist Intelligence Engine ADR, Phase 2)

    @Test func ambiguousOccasionEntersAwaitingClarificationStateWithoutEngagingTheFallback() async throws {
        RecommendationSettings.useAIRecommendations = true
        defer { RecommendationSettings.useAIRecommendations = true }

        let repository = InMemoryWardrobeRepository()
        repository.savedItems = [makeItem(slot: .top), makeItem(slot: .bottom), makeItem(slot: .footwear)]

        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.result = .success(OutfitRecommendationResponse(
            outfits: [],
            intentClear: false,
            followUpText: "What kind of event are you dressing for?",
            suggestedChips: ["Party", "Church", "Job Interview", "Casual Hangout"]
        ))
        let intentService = ControllableIntentExtractionService()

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            intentService: intentService,
            recommendationService: recommendationService
        )
        viewModel.prompt = "What should I wear today?"

        await viewModel.requestOutfitIdeas()

        guard case let .awaitingClarification(followUpText, chips) = viewModel.extractionState else {
            Issue.record("Expected .awaitingClarification, got \(viewModel.extractionState)")
            return
        }
        #expect(followUpText == "What kind of event are you dressing for?")
        #expect(chips == ["Party", "Church", "Job Interview", "Casual Hangout"])
        #expect(intentService.callCount == 0) // fallback pipeline never engaged
        #expect(recommendationService.receivedIsFinalTurnFlags == [false])
    }

    @Test func chipReplyContinuesTheSameConversationAndPassesFullHistoryToTheService() async throws {
        RecommendationSettings.useAIRecommendations = true
        defer { RecommendationSettings.useAIRecommendations = true }

        let repository = InMemoryWardrobeRepository()
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        repository.savedItems = [top, bottom, footwear]

        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.results = [
            .success(OutfitRecommendationResponse(
                outfits: [],
                intentClear: false,
                followUpText: "What kind of event are you dressing for?",
                suggestedChips: ["Party", "Funeral"]
            )),
            .success(OutfitRecommendationResponse(outfits: [
                makeWire(
                    top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString,
                    rationale: makeRationale("Solemn and respectful.")
                ),
            ])),
        ]
        let intentService = ControllableIntentExtractionService()

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            intentService: intentService,
            recommendationService: recommendationService
        )
        viewModel.prompt = "What should I wear today?"
        await viewModel.requestOutfitIdeas()

        guard case .awaitingClarification = viewModel.extractionState else {
            Issue.record("Expected .awaitingClarification after the first call")
            return
        }

        await viewModel.continueConversation(with: "Funeral")

        #expect(viewModel.extractionState == .idle)
        #expect(!viewModel.candidates.isEmpty)
        #expect(recommendationService.callCount == 2)
        let secondHistory = try #require(recommendationService.receivedConversationHistories.last)
        #expect(secondHistory.map(\.role) == [.user, .assistant, .user])
        #expect(secondHistory.map(\.text) == [
            "What should I wear today?", "What kind of event are you dressing for?", "Funeral",
        ])
        #expect(recommendationService.receivedIsFinalTurnFlags == [false, false])
        #expect(intentService.callCount == 0)
    }

    @Test func turnCapForcesTheThirdCallAndHonorsTheForcedDecision() async throws {
        RecommendationSettings.useAIRecommendations = true
        defer { RecommendationSettings.useAIRecommendations = true }

        let repository = InMemoryWardrobeRepository()
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        repository.savedItems = [top, bottom, footwear]

        let clarify = OutfitRecommendationResponse(
            outfits: [], intentClear: false,
            followUpText: "Still unclear — what's the occasion?", suggestedChips: ["Party", "Work"]
        )
        let final = OutfitRecommendationResponse(outfits: [
            makeWire(
                top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString,
                rationale: makeRationale("Best guess for an ambiguous ask.")
            ),
        ])

        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.results = [.success(clarify), .success(clarify), .success(final)]
        let intentService = ControllableIntentExtractionService()

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            intentService: intentService,
            recommendationService: recommendationService
        )
        viewModel.prompt = "What should I wear?"
        await viewModel.requestOutfitIdeas()
        await viewModel.continueConversation(with: "Still not sure")

        guard case .awaitingClarification = viewModel.extractionState else {
            Issue.record("Expected still awaiting clarification after the 2nd honored turn")
            return
        }

        await viewModel.continueConversation(with: "I really don't know")

        #expect(viewModel.extractionState == .idle)
        #expect(!viewModel.candidates.isEmpty)
        #expect(recommendationService.callCount == 3)
        #expect(recommendationService.receivedIsFinalTurnFlags == [false, false, true])
        #expect(intentService.callCount == 0) // still the AI path, forced to decide, never the fallback
    }

    @Test func modelDisobeyingTheForcedFinalTurnStillFallsBackDeterministically() async throws {
        RecommendationSettings.useAIRecommendations = true
        defer { RecommendationSettings.useAIRecommendations = true }

        // Empty inventory forces ghost-backed fallback candidates, same
        // pattern as recommendationServiceThrowingFallsBackToTheDeterministicEngine.
        let repository = InMemoryWardrobeRepository()

        let clarify = OutfitRecommendationResponse(
            outfits: [], intentClear: false, followUpText: "Still unclear.", suggestedChips: ["Party"]
        )
        // Disobeys the FINAL TURN instruction: still intentClear == false on
        // the 3rd (forced) call.
        let disobedientFinal = OutfitRecommendationResponse(
            outfits: [], intentClear: false, followUpText: "Still can't tell.", suggestedChips: ["Party"]
        )

        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.results = [.success(clarify), .success(clarify), .success(disobedientFinal)]
        let intentService = ControllableIntentExtractionService()

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            intentService: intentService,
            recommendationService: recommendationService
        )
        viewModel.prompt = "What should I wear?"
        await viewModel.requestOutfitIdeas()
        await viewModel.continueConversation(with: "Not sure")
        await viewModel.continueConversation(with: "Still not sure")

        #expect(viewModel.extractionState == .idle) // doesn't loop into a 4th clarification round
        #expect(!viewModel.candidates.isEmpty)
        #expect(recommendationService.callCount == 3)
        #expect(recommendationService.receivedIsFinalTurnFlags == [false, false, true])
        #expect(intentService.callCount == 1) // documented edge-case fallback, not a new invariant break
    }

    @Test func resetConversationReturnsToIdleAndClearsHistory() async throws {
        RecommendationSettings.useAIRecommendations = true
        defer { RecommendationSettings.useAIRecommendations = true }

        let repository = InMemoryWardrobeRepository()
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        repository.savedItems = [top, bottom, footwear]

        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.result = .success(OutfitRecommendationResponse(
            outfits: [], intentClear: false,
            followUpText: "What's the occasion?", suggestedChips: ["Party", "Work"]
        ))
        let intentService = ControllableIntentExtractionService()

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            intentService: intentService,
            recommendationService: recommendationService
        )
        viewModel.prompt = "What should I wear?"
        await viewModel.requestOutfitIdeas()

        guard case .awaitingClarification = viewModel.extractionState else {
            Issue.record("Expected awaitingClarification before reset")
            return
        }

        viewModel.resetConversation()

        #expect(viewModel.extractionState == .idle)
        #expect(viewModel.candidates.isEmpty)

        // A fresh request starts a genuinely new conversation — the
        // abandoned clarification must not carry over.
        recommendationService.results = [.success(OutfitRecommendationResponse(outfits: [
            makeWire(
                top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString,
                rationale: makeRationale("Fresh start.")
            ),
        ]))]
        viewModel.prompt = "Weekend brunch"
        await viewModel.requestOutfitIdeas()

        let lastHistory = try #require(recommendationService.receivedConversationHistories.last)
        #expect(lastHistory.count == 1)
        #expect(lastHistory.first?.text == "Weekend brunch")
    }

    // MARK: - Conversational Refinement Loop (Stylist Intelligence Engine ADR, Phase 2 addendum)

    @Test func refinementContinuesTheSameConversationAfterASuccessfulRound() async throws {
        RecommendationSettings.useAIRecommendations = true
        defer { RecommendationSettings.useAIRecommendations = true }

        let repository = InMemoryWardrobeRepository()
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let secondTop = makeItem(slot: .top)
        repository.savedItems = [top, bottom, footwear, secondTop]

        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.results = [
            .success(OutfitRecommendationResponse(outfits: [
                makeWire(top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString, rationale: makeRationale("Casual Friday pick.")),
            ])),
            .success(OutfitRecommendationResponse(outfits: [
                makeWire(top: secondTop.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString, rationale: makeRationale("No bag, different top.")),
            ])),
        ]
        let intentService = ControllableIntentExtractionService()

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            intentService: intentService,
            recommendationService: recommendationService
        )
        viewModel.prompt = "Casual Friday"
        await viewModel.requestOutfitIdeas()

        #expect(viewModel.rounds.count == 1)

        await viewModel.continueConversation(with: "No bag or graphic shirt, give me something else")

        #expect(viewModel.rounds.count == 2)
        #expect(viewModel.extractionState == .idle)
        #expect(viewModel.candidates.first?.structuredRationale?.summary == "No bag, different top.")
        #expect(recommendationService.callCount == 2)

        let secondHistory = try #require(recommendationService.receivedConversationHistories.last)
        #expect(secondHistory.map(\.role) == [.user, .assistant, .user])
        // The assistant turn is the compact machine-readable summary of the
        // first round's outfits (`assistantSummaryText`), not UI prose.
        #expect(secondHistory[1].text.contains("Outfit 1"))
        #expect(secondHistory.last?.text == "No bag or graphic shirt, give me something else")
        #expect(intentService.callCount == 0)
    }

    @Test func refinementTurnsNeverForceAFinalDecisionRegardlessOfCount() async throws {
        RecommendationSettings.useAIRecommendations = true
        defer { RecommendationSettings.useAIRecommendations = true }

        let repository = InMemoryWardrobeRepository()
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        repository.savedItems = [top, bottom, footwear]

        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.result = .success(OutfitRecommendationResponse(outfits: [
            makeWire(top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString, rationale: makeRationale("Pick.")),
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
        await viewModel.continueConversation(with: "No bag")
        await viewModel.continueConversation(with: "No graphic tops either")
        await viewModel.continueConversation(with: "Something warmer")

        // 1 initial call + 3 refinements — refinement turns don't touch
        // clarificationTurnCount/maxClarificationTurns, so none is ever forced.
        #expect(recommendationService.receivedIsFinalTurnFlags == [false, false, false, false])
        #expect(viewModel.rounds.count == 4)
    }

    @Test func roundsRecordBothClarificationAndOutfitsOutcomesInOrder() async throws {
        RecommendationSettings.useAIRecommendations = true
        defer { RecommendationSettings.useAIRecommendations = true }

        let repository = InMemoryWardrobeRepository()
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        repository.savedItems = [top, bottom, footwear]

        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.results = [
            .success(OutfitRecommendationResponse(
                outfits: [], intentClear: false,
                followUpText: "What's the occasion?", suggestedChips: ["Party", "Work"]
            )),
            .success(OutfitRecommendationResponse(outfits: [
                makeWire(top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString, rationale: makeRationale("Party pick.")),
            ])),
        ]
        let intentService = ControllableIntentExtractionService()

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            intentService: intentService,
            recommendationService: recommendationService
        )
        viewModel.prompt = "What should I wear?"
        await viewModel.requestOutfitIdeas()
        await viewModel.continueConversation(with: "Party")

        #expect(viewModel.rounds.count == 2)

        guard case .clarification(let followUpText, let chips) = viewModel.rounds[0].outcome else {
            Issue.record("Expected first round to be a clarification")
            return
        }
        #expect(followUpText == "What's the occasion?")
        #expect(chips == ["Party", "Work"])
        #expect(viewModel.rounds[0].userText == "What should I wear?")

        guard case .outfits(let outfits) = viewModel.rounds[1].outcome else {
            Issue.record("Expected second round to be resolved outfits")
            return
        }
        #expect(!outfits.isEmpty)
        #expect(viewModel.rounds[1].userText == "Party")
    }

    @Test func retryLastTurnResendsTheFailedTurnWithoutWipingPriorRounds() async throws {
        RecommendationSettings.useAIRecommendations = false
        defer { RecommendationSettings.useAIRecommendations = true }

        let repository = InMemoryWardrobeRepository()
        repository.savedItems = [makeItem(slot: .top), makeItem(slot: .bottom), makeItem(slot: .footwear)]

        let recommendationService = ControllableOutfitRecommendationService()
        let intentService = ControllableIntentExtractionService()

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            intentService: intentService,
            recommendationService: recommendationService
        )
        viewModel.prompt = "Casual Friday"
        await viewModel.requestOutfitIdeas()

        #expect(viewModel.rounds.count == 1)
        #expect(viewModel.extractionState == .idle)

        intentService.errorToThrow = RecommendationFailure()
        await viewModel.continueConversation(with: "No bag please")

        guard case .failed = viewModel.extractionState else {
            Issue.record("Expected .failed after the intent service threw")
            return
        }
        // Today's Retry (`requestOutfitIdeas()`) would wipe the whole
        // conversation — `retryLastTurn()` must not.
        #expect(viewModel.rounds.count == 1)

        intentService.errorToThrow = nil
        await viewModel.retryLastTurn()

        #expect(viewModel.extractionState == .idle)
        #expect(viewModel.rounds.count == 2)
        #expect(viewModel.rounds.last?.userText == "No bag please")
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
/// themselves and assert on how the view model reacts to the response. Set
/// `results` (a script indexed by call count, clamped to the last element
/// once exhausted) instead of `result` for multi-turn clarification-loop
/// tests that need call N to differ from call N+1.
private final class ControllableOutfitRecommendationService: OutfitRecommendationService {
    var result: Result<OutfitRecommendationResponse, Error> = .success(OutfitRecommendationResponse(outfits: []))
    var results: [Result<OutfitRecommendationResponse, Error>] = []
    private(set) var callCount = 0
    private(set) var receivedConversationHistories: [[ConversationTurn]] = []
    private(set) var receivedIsFinalTurnFlags: [Bool] = []

    func recommendOutfits(
        conversationHistory: [ConversationTurn],
        isFinalTurn: Bool,
        catalog: [CatalogEntry],
        profile: UserStyleProfile?,
        weather: WeatherContext?,
        history: FeedbackHistory
    ) async throws -> OutfitRecommendationResponse {
        receivedConversationHistories.append(conversationHistory)
        receivedIsFinalTurnFlags.append(isFinalTurn)
        let scriptedIndex = min(callCount, max(results.count - 1, 0))
        callCount += 1
        if !results.isEmpty {
            return try results[scriptedIndex].get()
        }
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
    /// Set to force this call to throw instead of returning — used to drive
    /// the ViewModel into `.failed` for retry-after-failure tests.
    var errorToThrow: Error?

    func extractConstraints(prompt: String, weather: WeatherContext?) async throws -> StyleConstraints {
        callCount += 1
        if let errorToThrow { throw errorToThrow }
        return StyleConstraints(
            formalityRange: FormalityRange(lowerBound: 1.0, upperBound: 5.0),
            weatherLayeringRequired: false,
            colorPaletteVibe: [.neutral],
            seasonSuitability: .summer
        )
    }
}
