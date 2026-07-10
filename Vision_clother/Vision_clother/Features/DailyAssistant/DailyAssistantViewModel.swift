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
        case failed(IntentExtractionError)

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
    private var tryOnTask: Task<Void, Never>?
    /// Kept so the try-on retry button can resend without the caller
    /// re-selecting the card, and so `saveCombination` knows which top/bottom
    /// produced the current `tryOnState.succeeded` image.
    private var lastRenderedOutfit: OutfitCombination?

    init(
        repository: WardrobeRepository,
        intentService: IntentExtractionService = MockIntentExtractionService(),
        tryOnService: TryOnRenderService = MockTryOnRenderService(),
        photoLibrarySaver: PhotoLibrarySaver = MockPhotoLibrarySaver()
    ) {
        self.repository = repository
        self.intentService = intentService
        self.tryOnService = tryOnService
        self.photoLibrarySaver = photoLibrarySaver
    }

    /// Runs the full 3-stage local pipeline for the current `prompt`. Safe
    /// to call again while `.failed` — that's exactly the manual-retry path
    /// the UI's Retry button uses.
    func requestOutfitIdeas() async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        extractionState = .loading
        candidates = []

        do {
            let constraints = try await intentService.extractConstraints(prompt: trimmed, weather: nil)
            let inventory = try repository.fetchInventory()
            let history = try repository.fetchFeedbackHistory()
            candidates = OutfitRecommendationEngine.generateCandidates(
                inventory: inventory,
                constraints: constraints,
                history: history
            )
            extractionState = .idle
        } catch let error as IntentExtractionError {
            extractionState = .failed(error)
        } catch {
            extractionState = .failed(.decoding(error))
        }
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
