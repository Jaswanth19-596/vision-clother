//
//  DailyAssistantViewModelTests.swift
//  Vision_clotherTests
//
//  Covers the primary LLM recommendation path (PRD §2.1a). Try-on generation
//  and `saveCombination` now run through
//  `Features/JobQueue/JobQueueStore.swift` — see JobQueueStoreTests.swift.
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

    // MARK: - Primary recommendation path (PRD §2.1a)

    @Test func happyPathUsesRecommendationServiceAndReturnsValidatedOutfits() async throws {
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

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            recommendationService: recommendationService
        )
        viewModel.prompt = "Casual Friday"

        await viewModel.requestOutfitIdeas()

        #expect(viewModel.candidates.count == 1)
        #expect(viewModel.candidates.first?.structuredRationale?.summary == "A clean, neutral pairing.")
        #expect(viewModel.extractionState == .idle)
    }

    // MARK: - Impression/Selection Event Capture

    @Test func successfulRoundRecordsAnImpressionPerCandidateInRankOrder() async throws {
        let repository = InMemoryWardrobeRepository()
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        repository.savedItems = [top, bottom, footwear]

        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.result = .success(OutfitRecommendationResponse(outfits: [
            makeWire(
                top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString,
                rationale: makeRationale("Strongest pick.")
            ),
            makeWire(
                top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString,
                rationale: makeRationale("Weaker pick.")
            ),
        ]))

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            recommendationService: recommendationService
        )
        viewModel.prompt = "Casual Friday"

        await viewModel.requestOutfitIdeas()

        #expect(repository.recordedImpressions.count == 1)
        let recorded = try #require(repository.recordedImpressions.first)
        #expect(recorded.outfits.map(\.id) == viewModel.candidates.map(\.id))
        #expect(repository.recordedSelections.isEmpty)
    }

    @Test func startingTryOnRecordsASelectionForThatOutfit() async throws {
        let repository = InMemoryWardrobeRepository()
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        repository.savedItems = [top, bottom, footwear]

        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.result = .success(OutfitRecommendationResponse(outfits: [
            makeWire(
                top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString,
                rationale: makeRationale("The pick.")
            ),
        ]))

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            recommendationService: recommendationService
        )
        viewModel.prompt = "Casual Friday"
        await viewModel.requestOutfitIdeas()

        let outfit = try #require(viewModel.candidates.first)
        viewModel.startTryOn(baseImageData: Data(), outfit: outfit)

        #expect(repository.recordedSelections == [outfit.id])
    }

    @Test func emptyCatalogReturnsFailure() async throws {
        // No items in the repository → empty catalog → .failure, not a crash.
        let repository = InMemoryWardrobeRepository()
        let recommendationService = ControllableOutfitRecommendationService()

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            recommendationService: recommendationService
        )
        viewModel.prompt = "Weekend brunch"

        await viewModel.requestOutfitIdeas()

        guard case .failed = viewModel.extractionState else {
            Issue.record("Expected .failed for empty catalog, got \(viewModel.extractionState)")
            return
        }
        #expect(recommendationService.callCount == 0) // never reached the LLM call
    }

    @Test func recommendationServiceThrowingReturnsFailure() async throws {
        let repository = InMemoryWardrobeRepository()
        repository.savedItems = [makeItem(slot: .top), makeItem(slot: .bottom), makeItem(slot: .footwear)]
        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.result = .failure(RecommendationFailure())

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            recommendationService: recommendationService
        )
        viewModel.prompt = "Weekend brunch"

        await viewModel.requestOutfitIdeas()

        guard case .failed = viewModel.extractionState else {
            Issue.record("Expected .failed when recommendation service throws")
            return
        }
    }

    @Test func unresolvableRecommendationIDsReturnsFailure() async throws {
        let repository = InMemoryWardrobeRepository()
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        repository.savedItems = [top, bottom, footwear]

        let recommendationService = ControllableOutfitRecommendationService()
        // References ids that don't exist in the inventory at all —
        // every outfit must fail validation, yielding an empty validated set → .failure.
        recommendationService.result = .success(OutfitRecommendationResponse(outfits: [
            makeWire(
                top: UUID().uuidString, bottom: UUID().uuidString,
                footwear: UUID().uuidString,
                rationale: makeRationale("Hallucinated.")
            ),
        ]))

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            recommendationService: recommendationService
        )
        viewModel.prompt = "Job interview"

        await viewModel.requestOutfitIdeas()

        guard case .failed = viewModel.extractionState else {
            Issue.record("Expected .failed when all recommended IDs fail validation")
            return
        }
    }

    @Test func resolvedConstraintsFromTheRecommendationResponseEnforceFormalityAlignmentOnTheLLMPath() async throws {
        // Stylist Intelligence Engine ADR: the LLM path previously passed
        // `constraints: nil` to the validator, so Tier 1 dress-code alignment
        // was only ever prompt guidance, never a deterministic check. Now the
        // recommendation response self-reports `resolved_constraints` and the
        // view model threads it through.
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

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            recommendationService: recommendationService
        )
        viewModel.prompt = "Black tie gala"

        await viewModel.requestOutfitIdeas()

        let candidate = try #require(viewModel.candidates.first)
        let scoreWithoutConstraints = OutfitRecommendationEngine.outfitScore(
            for: candidate.items, constraints: nil, history: FeedbackHistory()
        )

        #expect(candidate.score < scoreWithoutConstraints)
    }

    // MARK: - Clarification Loop (Stylist Intelligence Engine ADR, Phase 2)

    @Test func ambiguousOccasionEntersAwaitingClarificationState() async throws {
        let repository = InMemoryWardrobeRepository()
        repository.savedItems = [makeItem(slot: .top), makeItem(slot: .bottom), makeItem(slot: .footwear)]

        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.result = .success(OutfitRecommendationResponse(
            outfits: [],
            intentClear: false,
            followUpText: "What kind of event are you dressing for?",
            suggestedChips: ["Party", "Church", "Job Interview", "Casual Hangout"]
        ))

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
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
        #expect(recommendationService.receivedIsFinalTurnFlags == [false])
    }

    @Test func chipReplyContinuesTheSameConversationAndPassesFullHistoryToTheService() async throws {
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

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
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
    }

    @Test func turnCapForcesTheThirdCallAndHonorsTheForcedDecision() async throws {
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

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
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
    }

    @Test func modelDisobeyingTheForcedFinalTurnReturnsFailure() async throws {
        // Empty inventory forces an empty catalog → .failure before the LLM
        // is even called. This covers the edge case where the model can never
        // be reached, not just the disobedient-model case.
        let repository = InMemoryWardrobeRepository()

        let clarify = OutfitRecommendationResponse(
            outfits: [], intentClear: false, followUpText: "Still unclear.", suggestedChips: ["Party"]
        )

        let recommendationService = ControllableOutfitRecommendationService()
        // Provide two clarification responses followed by a disobedient final
        // that still has no valid outfits.
        let disobedientFinal = OutfitRecommendationResponse(
            outfits: [], intentClear: false, followUpText: "Still can't tell.", suggestedChips: ["Party"]
        )
        recommendationService.results = [.success(clarify), .success(clarify), .success(disobedientFinal)]

        // We need items in the inventory so the catalog is non-empty and the
        // LLM path is actually exercised.
        repository.savedItems = [makeItem(slot: .top), makeItem(slot: .bottom), makeItem(slot: .footwear)]

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            recommendationService: recommendationService
        )
        viewModel.prompt = "What should I wear?"
        await viewModel.requestOutfitIdeas()
        await viewModel.continueConversation(with: "Not sure")
        await viewModel.continueConversation(with: "Still not sure")

        // Disobedient model returns intentClear==false on a forced turn +
        // empty outfits → validation yields nothing → .failure, not an
        // infinite clarification loop.
        guard case .failed = viewModel.extractionState else {
            Issue.record("Expected .failed when disobedient model returns empty outfits on the forced turn")
            return
        }
        #expect(recommendationService.callCount == 3)
        #expect(recommendationService.receivedIsFinalTurnFlags == [false, false, true])
    }

    @Test func resetConversationReturnsToIdleAndClearsHistory() async throws {
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

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
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

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
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
    }

    @Test func refinementTurnsNeverForceAFinalDecisionRegardlessOfCount() async throws {
        let repository = InMemoryWardrobeRepository()
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        repository.savedItems = [top, bottom, footwear]

        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.result = .success(OutfitRecommendationResponse(outfits: [
            makeWire(top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString, rationale: makeRationale("Pick.")),
        ]))

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
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

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
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
        let repository = InMemoryWardrobeRepository()
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        repository.savedItems = [top, bottom, footwear]

        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.result = .success(OutfitRecommendationResponse(outfits: [
            makeWire(top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString, rationale: makeRationale("Pick.")),
        ]))

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            recommendationService: recommendationService
        )
        viewModel.prompt = "Casual Friday"
        await viewModel.requestOutfitIdeas()

        #expect(viewModel.rounds.count == 1)
        #expect(viewModel.extractionState == .idle)

        recommendationService.result = .failure(RecommendationFailure())
        await viewModel.continueConversation(with: "No bag please")

        guard case .failed = viewModel.extractionState else {
            Issue.record("Expected .failed after the recommendation service threw")
            return
        }
        // Today's Retry (`requestOutfitIdeas()`) would wipe the whole
        // conversation — `retryLastTurn()` must not.
        #expect(viewModel.rounds.count == 1)

        recommendationService.result = .success(OutfitRecommendationResponse(outfits: [
            makeWire(top: top.id.uuidString, bottom: bottom.id.uuidString, footwear: footwear.id.uuidString, rationale: makeRationale("Retry pick.")),
        ]))
        await viewModel.retryLastTurn()

        #expect(viewModel.extractionState == .idle)
        #expect(viewModel.rounds.count == 2)
        #expect(viewModel.rounds.last?.userText == "No bag please")
    }

    // MARK: - Prospective Purchase Evaluation (2026-07-15)

    @Test func purchaseCheckTagsThePhotoAndFlagsItInTheCatalogSentToTheLLM() async throws {
        let repository = InMemoryWardrobeRepository()
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        repository.savedItems = [bottom, footwear]

        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.resultBuilder = { catalog in
            guard let prospective = catalog.first(where: { $0.isProspectivePurchase }) else {
                return OutfitRecommendationResponse(outfits: [])
            }
            let wire = RecommendedOutfitWire(
                itemIDsBySlot: [.top: prospective.id, .bottom: bottom.id.uuidString, .footwear: footwear.id.uuidString],
                rationale: StructuredRationaleWire(summary: "Works well with what you own.", confidence: 80)
            )
            return OutfitRecommendationResponse(outfits: [wire])
        }

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            recommendationService: recommendationService
        )
        viewModel.attachedProspectiveImageData = Data([0x01])

        await viewModel.checkProspectiveItem()

        #expect(viewModel.extractionState == .idle)
        #expect(viewModel.rounds.count == 1)
        #expect(viewModel.attachedProspectiveImageData == nil)
        #expect(viewModel.isProspectivePurchaseMode == false)

        guard case .purchaseCheck(let item, let outfits, _) = viewModel.rounds.first?.outcome else {
            Issue.record("Expected a .purchaseCheck outcome")
            return
        }
        #expect(outfits.count == 1)
        #expect(outfits.first?.items.contains { $0.id == item.id } == true)
        // Matches MockVisionMetadataExtractionService's canned metadata.
        #expect(item.slot == .top)

        let sentCatalog = try #require(recommendationService.receivedCatalogs.last)
        #expect(sentCatalog.filter(\.isProspectivePurchase).count == 1)
        #expect(sentCatalog.first(where: { $0.isProspectivePurchase })?.id == item.id.uuidString)
    }

    @Test func outfitsThatOmitTheProspectiveItemAreFilteredOutEvenIfTheLLMReturnsThem() async throws {
        let repository = InMemoryWardrobeRepository()
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        let unrelatedTop = makeItem(slot: .top)
        repository.savedItems = [bottom, footwear, unrelatedTop]

        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.resultBuilder = { catalog in
            guard let prospective = catalog.first(where: { $0.isProspectivePurchase }) else {
                return OutfitRecommendationResponse(outfits: [])
            }
            let includesTheNewItem = RecommendedOutfitWire(
                itemIDsBySlot: [.top: prospective.id, .bottom: bottom.id.uuidString, .footwear: footwear.id.uuidString],
                rationale: StructuredRationaleWire(summary: "Includes the new item.", confidence: 80)
            )
            let omitsTheNewItem = RecommendedOutfitWire(
                itemIDsBySlot: [.top: unrelatedTop.id.uuidString, .bottom: bottom.id.uuidString, .footwear: footwear.id.uuidString],
                rationale: StructuredRationaleWire(summary: "Omits the new item.", confidence: 80)
            )
            return OutfitRecommendationResponse(outfits: [includesTheNewItem, omitsTheNewItem])
        }

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            recommendationService: recommendationService
        )
        viewModel.attachedProspectiveImageData = Data([0x01])

        await viewModel.checkProspectiveItem()

        guard case .purchaseCheck(let item, let outfits, _) = viewModel.rounds.first?.outcome else {
            Issue.record("Expected a .purchaseCheck outcome")
            return
        }
        #expect(outfits.count == 1)
        #expect(outfits.first?.items.contains { $0.id == item.id } == true)
    }

    @Test func noValidOutfitsSurfacesAsANoMatchVerdictNotAFailure() async throws {
        // Empty closet — nothing to pair a top with, so no valid outfit can
        // ever be built. This is a legitimate "doesn't pair" answer for this
        // mode, not the generic "wardrobe is empty" error the free-text flow
        // would show.
        let repository = InMemoryWardrobeRepository()
        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.resultBuilder = { _ in
            OutfitRecommendationResponse(outfits: [], followUpText: "Nothing in your closet pairs with a piece this formal.")
        }

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            recommendationService: recommendationService
        )
        viewModel.attachedProspectiveImageData = Data([0x01])

        await viewModel.checkProspectiveItem()

        #expect(viewModel.extractionState == .idle)
        guard case .purchaseCheck(_, let outfits, let note) = viewModel.rounds.first?.outcome else {
            Issue.record("Expected a .purchaseCheck outcome")
            return
        }
        #expect(outfits.isEmpty)
        #expect(note == "Nothing in your closet pairs with a piece this formal.")
    }

    @Test func addProspectiveItemToClosetPersistsTheExactTaggedItem() async throws {
        let repository = InMemoryWardrobeRepository()
        repository.savedItems = [makeItem(slot: .bottom), makeItem(slot: .footwear)]

        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.resultBuilder = { _ in OutfitRecommendationResponse(outfits: []) }

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            recommendationService: recommendationService
        )
        viewModel.attachedProspectiveImageData = Data([0x01])
        await viewModel.checkProspectiveItem()

        guard case .purchaseCheck(let item, _, _) = viewModel.rounds.first?.outcome else {
            Issue.record("Expected a .purchaseCheck outcome")
            return
        }

        let saved = viewModel.addProspectiveItemToCloset(item)

        #expect(saved)
        #expect(repository.savedItems.contains { $0.id == item.id })
    }

    @Test func discardProspectiveItemDeletesItsTemporaryPhotoFile() async throws {
        let repository = InMemoryWardrobeRepository()
        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.resultBuilder = { _ in OutfitRecommendationResponse(outfits: []) }

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            recommendationService: recommendationService
        )
        viewModel.attachedProspectiveImageData = Data([0x01])
        await viewModel.checkProspectiveItem()

        guard case .purchaseCheck(let item, _, _) = viewModel.rounds.first?.outcome else {
            Issue.record("Expected a .purchaseCheck outcome")
            return
        }
        let filename = try #require(item.imageAssetName)
        #expect(ImageStorage.loadData(for: filename) != nil)

        viewModel.discardProspectiveItem(item)

        #expect(ImageStorage.loadData(for: filename) == nil)
        #expect(!repository.savedItems.contains { $0.id == item.id })
    }

    @Test func retryLastTurnRetriesAFailedPurchaseCheckNotAStaleFreeTextTurn() async throws {
        let repository = InMemoryWardrobeRepository()
        let bottom = makeItem(slot: .bottom)
        let footwear = makeItem(slot: .footwear)
        repository.savedItems = [bottom, footwear]

        let recommendationService = ControllableOutfitRecommendationService()
        recommendationService.result = .failure(RecommendationFailure())

        let viewModel = DailyAssistantViewModel(
            repository: repository,
            jobQueueStore: makeJobQueueStore(repository: repository),
            recommendationService: recommendationService
        )
        viewModel.attachedProspectiveImageData = Data([0x01])
        await viewModel.checkProspectiveItem()

        guard case .failed = viewModel.extractionState else {
            Issue.record("Expected .failed when the recommendation service throws")
            return
        }

        recommendationService.result = .success(OutfitRecommendationResponse(outfits: []))
        await viewModel.retryLastTurn()

        #expect(viewModel.extractionState == .idle)
        #expect(viewModel.rounds.count == 1)
        guard case .purchaseCheck = viewModel.rounds.first?.outcome else {
            Issue.record("Expected retry to resolve as a .purchaseCheck round, not the free-text flow")
            return
        }
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
    func fetchFeedbackHistory() async throws -> FeedbackHistory { FeedbackHistory() }
    func recordOutfitFeedback(outfitID: UUID, likedOverall: Bool) throws {}
    func recordItemFeedback(itemID: UUID, likedFit: Bool) throws {}
    func recordPairFeedback(itemAID: UUID, itemBID: UUID, likedTogether: Bool) throws {}
    func recordItemRating(itemID: UUID, fit: FitRating, comfort: Int, colorLike: Int, patternLike: Int?, formalityFit: Int, styleIdentity: Int, wearAgain: Bool) throws {}
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
    func recordSwipe(sourcePhotoID: String, imageURLString: String, liked: Bool, embedding: [Float]) throws -> Double? { nil }
    func fetchVisualPreferenceState() throws -> VisualPreferenceState? { nil }
    func updateVisualPreferenceState(likedCentroids: [VisualCentroid], dislikedCentroids: [VisualCentroid], embeddingDimension: Int) throws {}
    func fetchWardrobeItemEmbedding(itemID: UUID) throws -> WardrobeItemEmbedding? { nil }
    func saveWardrobeItemEmbedding(itemID: UUID, vector: [Float], sourceFingerprint: String) throws {}

    private(set) var recordedImpressions: [(roundID: UUID, outfits: [OutfitCombination])] = []
    private(set) var recordedSelections: [UUID] = []
    func recordImpressions(roundID: UUID, outfits: [OutfitCombination]) throws {
        recordedImpressions.append((roundID, outfits))
    }
    func recordSelection(outfitID: UUID) throws {
        recordedSelections.append(outfitID)
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
    /// When set, builds the response dynamically from the actual catalog
    /// this call received instead of returning a fixed `result`/`results`
    /// script — needed for Prospective Purchase Evaluation tests, where the
    /// evaluated item's id is generated fresh inside the view model
    /// (`WardrobeItem.make`) and can't be hardcoded ahead of time.
    var resultBuilder: (([CatalogEntry]) -> OutfitRecommendationResponse)?
    private(set) var callCount = 0
    private(set) var receivedConversationHistories: [[ConversationTurn]] = []
    private(set) var receivedIsFinalTurnFlags: [Bool] = []
    private(set) var receivedCatalogs: [[CatalogEntry]] = []

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
        receivedCatalogs.append(catalog)
        if let resultBuilder {
            callCount += 1
            return resultBuilder(catalog)
        }
        let scriptedIndex = min(callCount, max(results.count - 1, 0))
        callCount += 1
        if !results.isEmpty {
            return try results[scriptedIndex].get()
        }
        return try result.get()
    }
}

private struct RecommendationFailure: Error {}
