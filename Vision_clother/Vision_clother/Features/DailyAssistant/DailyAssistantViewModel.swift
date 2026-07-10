//
//  DailyAssistantViewModel.swift
//  Vision_clother
//
//  Drives PRD.md §2.1's full pipeline for Tab 1: free text -> intent
//  extraction (OpenRouter) -> local retrieval + scoring
//  (OutfitRecommendationEngine) -> optional try-on render (Fal).
//

import Foundation
import Observation

@Observable
@MainActor
final class DailyAssistantViewModel {
    enum ExtractionState: Equatable {
        case idle
        case loading
        /// Broadened from a single `IntentExtractionError` (pre-2026-07-10)
        /// to a pre-formatted message: the primary path
        /// (`Services/OutfitRecommendationService.swift`) and the fallback
        /// path (`Services/OpenRouterIntentExtractionService.swift`) each
        /// have their own error types, and the fallback itself only
        /// surfaces once *both* paths have failed — so there's no single
        /// error type left to hold here.
        case failed(String)

        static func == (lhs: ExtractionState, rhs: ExtractionState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading), (.failed, .failed):
                return true
            default:
                return false
            }
        }
    }

    var prompt: String = ""
    var extractionState: ExtractionState = .idle
    var candidates: [OutfitCombination] = []
    var tryOnState: TryOnState = .idle
    /// Item Rating & Preference Learning: the real (non-ghost) items from the
    /// outfit just saved via `saveCombination()`, offered to `RateOutfitView`.
    /// Ghost Elements are excluded — there's no real garment to rate. Cleared
    /// by the view once it's captured them for the rating sheet.
    private(set) var lastSavedRatableItems: [WardrobeItem] = []

    private let intentService: IntentExtractionService
    private let tryOnService: TryOnRenderService
    private let repository: WardrobeRepository
    private let photoLibrarySaver: PhotoLibrarySaver
    /// Primary recommendation path (PRD §2.1a, the 2026-07-10
    /// LLM-as-Recommender reversal — docs/decisions/resolved-v1.md).
    private let recommendationService: OutfitRecommendationService
    private let weatherProvider: CurrentWeatherProviding
    /// Backs the lazy profile backfill in `requestOutfitIdeas()` — derives
    /// once from an existing portrait if `fetchUserProfile()` is still nil,
    /// mirroring the eager derivation `ManualPairingViewModel.savePortrait`
    /// already does on a fresh portrait save.
    private let profileDerivationService: UserProfileDerivationService
    private var tryOnTask: Task<Void, Never>?
    /// Kept so the try-on retry button can resend without the caller
    /// re-selecting the card, and so `saveCombination` knows which top/bottom
    /// produced the current `tryOnState.succeeded` image.
    private var lastRenderedOutfit: OutfitCombination?

    init(
        repository: WardrobeRepository,
        intentService: IntentExtractionService = MockIntentExtractionService(),
        tryOnService: TryOnRenderService = MockTryOnRenderService(),
        photoLibrarySaver: PhotoLibrarySaver = MockPhotoLibrarySaver(),
        recommendationService: OutfitRecommendationService = MockOutfitRecommendationService(),
        weatherProvider: CurrentWeatherProviding = MockCurrentWeatherProvider(),
        profileDerivationService: UserProfileDerivationService = MockUserProfileDerivationService()
    ) {
        self.repository = repository
        self.intentService = intentService
        self.tryOnService = tryOnService
        self.photoLibrarySaver = photoLibrarySaver
        self.recommendationService = recommendationService
        self.weatherProvider = weatherProvider
        self.profileDerivationService = profileDerivationService
    }

    /// Primary path (PRD §2.1a): prompt + bounded wardrobe catalog + style
    /// profile + weather -> recommendation LLM -> validated outfits. Falls
    /// back to the fully deterministic §2.1 pipeline (intent extraction ->
    /// `OutfitRecommendationEngine`) when AI recommendations are disabled
    /// (`RecommendationSettings.useAIRecommendations`), the recommendation
    /// call fails, or validation yields nothing usable — so the app always
    /// produces an outfit when the inventory can support one. Safe to call
    /// again while `.failed` — that's exactly the manual-retry path the
    /// UI's Retry button uses.
    func requestOutfitIdeas() async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        extractionState = .loading
        candidates = []

        let weather = await weatherProvider.currentWeather()

        do {
            let inventory = try repository.fetchInventory()
            let history = try repository.fetchFeedbackHistory()
            let profile = await resolvedUserProfile()

            if RecommendationSettings.useAIRecommendations {
                let (catalog, index) = WardrobeCatalogBuilder.build(from: inventory)
                if !catalog.isEmpty,
                   let response = try? await recommendationService.recommendOutfits(
                       prompt: trimmed, catalog: catalog, profile: profile, weather: weather, history: history
                   ) {
                    let validated = OutfitRecommendationValidator.validate(
                        response,
                        index: index,
                        // Self-reported by the same call, not a second
                        // intent-extraction round-trip (Stylist Intelligence
                        // Engine ADR) — closes the gap where Tier 1 dress-code
                        // alignment was previously unenforced on the LLM path.
                        constraints: response.resolvedConstraints,
                        profile: profile,
                        weather: weather,
                        history: history
                    )
                    if !validated.isEmpty {
                        candidates = validated
                        extractionState = .idle
                        return
                    }
                }
                // Falls through to the deterministic pipeline below when the
                // recommendation call throws or every pick fails validation.
            }

            let constraints = try await intentService.extractConstraints(prompt: trimmed, weather: weather)
            candidates = OutfitRecommendationEngine.generateCandidates(
                inventory: inventory,
                constraints: constraints,
                profile: profile,
                weather: weather,
                history: history
            )
            extractionState = .idle
        } catch let error as IntentExtractionError {
            extractionState = .failed(error.errorDescription ?? "Couldn't understand that.")
        } catch {
            extractionState = .failed(error.localizedDescription)
        }
    }

    /// Reads the persisted style profile, lazily deriving it once from an
    /// existing portrait if none is saved yet (PRD §3.8). Best-effort: a
    /// derivation failure just means this and future calls proceed with
    /// `nil` until the user saves a fresh portrait (which derives eagerly,
    /// see `ManualPairingViewModel.savePortrait`).
    private func resolvedUserProfile() async -> UserStyleProfile? {
        if let existing = try? repository.fetchUserProfile() {
            return existing
        }
        guard let portraitData = UserPortraitStorage.load() else { return nil }
        guard let wire = try? await profileDerivationService.deriveProfile(portraitData: portraitData) else { return nil }
        try? repository.saveUserProfile(wire)
        return try? repository.fetchUserProfile()
    }

    // MARK: - Try-on

    func startTryOn(baseImageData: Data, outfit: OutfitCombination) {
        tryOnTask?.cancel()
        lastRenderedOutfit = outfit
        // OpenRouterTryOnRenderService), so there's no fixed `.submitting` value to
        // set synchronously here — the service's first onUpdate callback
        // (fired almost immediately once the Task starts) drives the first
        // real state instead.
        tryOnState = .idle

        tryOnTask = Task { [tryOnService] in
            await tryOnService.renderTryOn(baseImageData: baseImageData, items: outfit.items) { [weak self] state in
                Task { @MainActor in
                    self?.tryOnState = state
                }
            }
        }
    }

    func retryTryOn(baseImageData: Data) {
        guard let outfit = lastRenderedOutfit else { return }
        startTryOn(baseImageData: baseImageData, outfit: outfit)
    }

    /// Cancels the in-flight render — no server-side cancel call needed,
    /// Fal jobs simply expire unclaimed.
    func cancelTryOn() {
        tryOnTask?.cancel()
        tryOnTask = nil
        tryOnState = .idle
    }

    /// Persists the current `tryOnState.succeeded` image the same way
    /// `ManualPairingViewModel.saveOutfit()` does — via `ImageStorage` +
    /// `SavedCombination` — and mirrors it to the Photos library. A
    /// Photos-write failure is non-fatal: the app-local save already
    /// succeeded by that point.
    func saveCombination() async {
        guard let outfit = lastRenderedOutfit else { return }
        guard case .succeeded(let imageURL) = tryOnState else { return }
        guard let imageData = try? Data(contentsOf: imageURL) else { return }

        if let assetName = try? ImageStorage.save(imageData) {
            let combination = SavedCombination(
                imageAssetName: assetName,
                topItemID: outfit.top.id,
                bottomItemID: outfit.bottom.id,
                topLabel: outfit.top.displayLabel,
                bottomLabel: outfit.bottom.displayLabel,
                footwearItemID: outfit.footwear.id,
                footwearLabel: outfit.footwear.displayLabel,
                outerwearItemID: outfit.outerwear?.id,
                outerwearLabel: outfit.outerwear?.displayLabel,
                origin: "assistant"
            )
            try? repository.saveCombination(combination)
        }
        try? await photoLibrarySaver.save(imageData: imageData)

        lastSavedRatableItems = outfit.items.filter { !$0.isGhostElement }
    }

    /// The view calls this once it's captured `lastSavedRatableItems` for
    /// the rating sheet, so a later save doesn't re-trigger the prompt with
    /// stale items and re-opening the try-on sheet without a fresh save
    /// doesn't show it again either.
    func clearRatablePrompt() {
        lastSavedRatableItems = []
    }

    // MARK: - Feedback (PRD §3.6)

    func recordOutfitFeedback(_ outfit: OutfitCombination, liked: Bool) {
        try? repository.recordOutfitFeedback(outfitID: outfit.id, likedOverall: liked)
    }
}
