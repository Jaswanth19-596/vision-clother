//
//  ManualPairingViewModel.swift
//  Vision_clother
//
//  Manual Outfit Pairing with AI Virtual Try-On: the user picks a top and a
//  bottom from their own closet (real ingested items only — Ghost Elements
//  can't be sent to OpenRouter for a real render) and generates a try-on preview
//  of themselves wearing both, via Services/OpenRouterTryOnRenderService.swift.
//
//  The preview is fully ephemeral: nothing about the generated image is
//  persisted. "Save this outfit?" only records a positive signal through
//  the existing three-tier feedback tables (PRD §3.6) — no new SwiftData
//  schema, matching how `DailyAssistantViewModel.recordOutfitFeedback`
//  already works.
//

import Foundation
import Observation

@Observable
@MainActor
final class ManualPairingViewModel {
    enum State: Equatable {
        case idle
        case validatingPhoto
        case preparingImages
        case generatingPreview(TryOnStage)
        case success(imageURL: URL)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var hasPortrait: Bool
    /// Flipped once after a successful "Save this outfit?" — the view
    /// observes this to dismiss the screen, matching AddItemViewModel.didSave.
    private(set) var didSaveOutfit = false

    let availableTops: [WardrobeItem]
    let availableBottoms: [WardrobeItem]
    var selectedTop: WardrobeItem?
    var selectedBottom: WardrobeItem?

    private let repository: WardrobeRepository
    private let validationService: PersonPhotoValidationService
    private let tryOnService: TryOnRenderService
    private let photoLibrarySaver: PhotoLibrarySaver
    /// Quota visibility feature: optimistic combination-usage bump on a
    /// successful render — see `Data/UsageTracker.swift`.
    private let usageTracker: UsageTracker
    private var generationTask: Task<Void, Never>?
    /// Identifies the in-flight generation. `Task.cancel()` is cooperative —
    /// a stale callback can still land after a newer selection has already
    /// started a fresh generation. Checking this in `apply(_:generationID:)`
    /// guarantees a stale result can never overwrite a newer one, rather
    /// than relying on cancellation timing alone.
    private var currentGenerationID = UUID()

    init(
        repository: WardrobeRepository,
        validationService: PersonPhotoValidationService = MockPersonPhotoValidationService(),
        tryOnService: TryOnRenderService = MockTryOnRenderService(),
        photoLibrarySaver: PhotoLibrarySaver = MockPhotoLibrarySaver(),
        usageTracker: UsageTracker
    ) {
        self.repository = repository
        self.validationService = validationService
        self.tryOnService = tryOnService
        self.photoLibrarySaver = photoLibrarySaver
        self.usageTracker = usageTracker
        self.hasPortrait = UserPortraitStorage.exists

        let inventory = (try? repository.fetchInventory()) ?? []
        self.availableTops = inventory.filter { $0.slot == .top && !$0.isGhostElement }
        self.availableBottoms = inventory.filter { $0.slot == .bottom && !$0.isGhostElement }
    }

    /// Quota visibility feature: proactively blocks the same 0-guest-cap /
    /// exhausted-free-tier-cap condition the server would otherwise reject
    /// with `TryOnError.signInRequired`/`.quotaExceeded` — see
    /// `Data/UsageTracker.swift`.
    var canGeneratePreview: Bool {
        hasPortrait && selectedTop != nil && selectedBottom != nil && usageTracker.combinationsRemaining > 0
    }

    /// Selecting a different item mid-generation cancels whatever's in
    /// flight so a stale result can never overwrite a newer selection.
    func selectTop(_ item: WardrobeItem) {
        cancelGeneration()
        selectedTop = item
    }

    func selectBottom(_ item: WardrobeItem) {
        cancelGeneration()
        selectedBottom = item
    }

    /// Kicks off validate -> prepare -> generate. Safe to call again after
    /// `.failed` — that's the Retry affordance's path.
    func generatePreview() {
        guard let top = selectedTop, let bottom = selectedBottom else { return }
        guard usageTracker.combinationsRemaining > 0 else {
            state = .failed(usageTracker.isAnonymousQuota
                             ? "Sign in to try this on."
                             : "You've used all your combinations this month.")
            return
        }
        generationTask?.cancel()
        let generationID = UUID()
        currentGenerationID = generationID
        didSaveOutfit = false
        state = .validatingPhoto
        AppLog.info(.viewModel, "ManualPairingViewModel.generatePreview: generationID=\(generationID) top=\(top.id) bottom=\(bottom.id)")

        generationTask = Task { [weak self] in
            await self?.runPipeline(top: top, bottom: bottom, generationID: generationID)
        }
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        currentGenerationID = UUID()
        state = .idle
    }

    private func runPipeline(top: WardrobeItem, bottom: WardrobeItem, generationID: UUID) async {
        guard generationID == currentGenerationID else { return }
        guard let portraitData = UserPortraitStorage.load() else {
            state = .failed("Add a photo of yourself first.")
            return
        }

        do {
            try await validationService.validate(imageData: portraitData)
        } catch let error as PersonPhotoValidationError {
            guard generationID == currentGenerationID else { return }
            state = .failed(error.errorDescription ?? "That photo isn't usable.")
            return
        } catch {
            guard generationID == currentGenerationID else { return }
            state = .failed("Couldn't check that photo. Try again.")
            return
        }

        guard !Task.isCancelled, generationID == currentGenerationID else { return }
        state = .preparingImages

        guard !Task.isCancelled, generationID == currentGenerationID else { return }
        await tryOnService.renderTryOn(baseImageData: portraitData, items: [top, bottom]) { [weak self] tryOnState in
            Task { @MainActor in
                self?.apply(tryOnState, generationID: generationID)
            }
        }
    }

    private func apply(_ tryOnState: TryOnState, generationID: UUID) {
        guard generationID == currentGenerationID else { return }
        switch tryOnState {
        case .idle:
            break
        case .submitting(let stage), .polling(let stage, _):
            state = .generatingPreview(stage)
        case .succeeded(let imageURL):
            AppLog.info(.viewModel, "ManualPairingViewModel: generationID=\(generationID) succeeded")
            state = .success(imageURL: imageURL)
            usageTracker.recordCombinationUsed()
        case .failed(let error):
            AppLog.error(.viewModel, "ManualPairingViewModel: generationID=\(generationID) failed — \(String(describing: error))")
            state = .failed(error.errorDescription ?? "Couldn't generate that preview.")
        }
    }

    // MARK: - Save / discard

    /// Records the PRD §3.6 feedback signal — `liked` now reflects the
    /// user's actual Like/Dislike choice rather than being hardcoded to
    /// `true` — then durably persists the generated image itself via
    /// `ImageStorage` + `SavedCombination` (Data/CLAUDE.md's
    /// file-persistence boundary) and mirrors it to the Photos library. Both
    /// Like and Dislike always save, so a disliked pairing still gets a
    /// durable id for its feedback row to reference and still shows up in
    /// Combinations history. A Photos-write failure is non-fatal: the
    /// app-local save already succeeded by that point.
    func saveOutfit(liked: Bool) async {
        guard let top = selectedTop, let bottom = selectedBottom else { return }
        guard case .success(let imageURL) = state else { return }
        AppLog.info(.viewModel, "ManualPairingViewModel.saveOutfit: top=\(top.id) bottom=\(bottom.id) liked=\(liked)")

        try? repository.recordPairFeedback(itemAID: top.id, itemBID: bottom.id, likedTogether: liked)

        if let imageData = try? Data(contentsOf: imageURL) {
            if let assetName = try? ImageStorage.save(imageData) {
                // Generated up front (rather than left to `SavedCombination`'s
                // own default) so the outfit-level feedback event below can
                // reference the same durable id the Combinations tab reads —
                // previously this recorded a throwaway random UUID that could
                // never be looked back up against any saved combination.
                let combinationID = UUID()
                // Re-read rather than threading a `portraitData` param through
                // from `runPipeline` — `UserPortraitStorage.load()` is a cheap
                // on-device file read, and re-reading here guarantees the
                // fingerprint always reflects the exact bytes this generated
                // image was actually rendered against.
                let basePortraitFingerprint = UserPortraitStorage.load().map(ImageStorage.fingerprint)
                let combination = SavedCombination(
                    id: combinationID,
                    imageAssetName: assetName,
                    itemIDsBySlot: [.top: top.id, .bottom: bottom.id],
                    labelsBySlot: [.top: top.displayLabel, .bottom: bottom.displayLabel],
                    origin: "pairing",
                    basePortraitFingerprint: basePortraitFingerprint
                )
                try? repository.saveCombination(combination)
                try? repository.recordOutfitFeedback(outfitID: combinationID, likedOverall: liked)
            }
            try? await photoLibrarySaver.save(imageData: imageData)
        }

        didSaveOutfit = true
    }

    func discardPreview() {
        state = .idle
    }
}
