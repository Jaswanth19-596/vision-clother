//
//  ManualPairingViewModel.swift
//  Vision_clother
//
//  Manual Outfit Pairing with AI Virtual Try-On: the user picks garments from
//  their own closet (real ingested items only — Ghost Elements can't be sent
//  to OpenRouter for a real render) across any of the seven slots and
//  generates a try-on preview of themselves wearing them, via
//  Services/OpenRouterTryOnRenderService.swift.
//
//  Slot coverage (2026-07-25): previously hardcoded to a single top + bottom.
//  The underlying `TryOnRenderService.renderTryOn(items:)` already composes an
//  arbitrary number of garment images in one call (the recommendation-carousel
//  try-on path passes full multi-slot outfits), so this screen now offers one
//  picker per slot the user actually owns items in. At least one garment must
//  be selected to render — the base portrait already shows the user fully
//  dressed, so compositing even a single new piece (e.g. "how does this jacket
//  look on me?") is a valid try-on.
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

    /// Real (non-ghost) inventory grouped by slot — only slots the user owns
    /// at least one item in appear as pickers (see `orderedAvailableSlots`).
    let availableItemsBySlot: [Slot: [WardrobeItem]]
    /// The user's current pick per slot (absent = nothing chosen for that
    /// slot). Optional slots stay empty until the user taps one; a second tap
    /// on the same item clears it (see `selectItem`).
    var selected: [Slot: WardrobeItem] = [:]

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
        self.availableItemsBySlot = Dictionary(
            grouping: inventory.filter { !$0.isGhostElement },
            by: { $0.slot }
        )
    }

    /// Slots that have at least one selectable item, in the canonical
    /// `Slot.allCases` order (top → bottom → footwear → outerwear → headwear →
    /// accessory → bag) so the pickers always render in a stable, familiar
    /// order regardless of `Dictionary` iteration order.
    var orderedAvailableSlots: [Slot] {
        Slot.allCases.filter { !(availableItemsBySlot[$0]?.isEmpty ?? true) }
    }

    /// The picked garments in canonical slot order — what gets sent to the
    /// render service and used to build the saved combination.
    var orderedSelectedItems: [WardrobeItem] {
        Slot.allCases.compactMap { selected[$0] }
    }

    /// Quota visibility feature: proactively blocks the same 0-guest-cap /
    /// exhausted-free-tier-cap condition the server would otherwise reject
    /// with `TryOnError.signInRequired`/`.quotaExceeded` — see
    /// `Data/UsageTracker.swift`. Needs a portrait, at least one selected
    /// garment, and remaining try-on credits.
    var canGeneratePreview: Bool {
        hasPortrait && !selected.isEmpty && usageTracker.combinationsRemaining > 0
    }

    /// Toggling a garment: selecting a different item mid-generation cancels
    /// whatever's in flight so a stale result can never overwrite a newer
    /// selection. Tapping the already-selected item in a slot clears that slot
    /// (so an optional accent can be removed after being added).
    func selectItem(_ item: WardrobeItem) {
        cancelGeneration()
        if selected[item.slot]?.id == item.id {
            selected[item.slot] = nil
        } else {
            selected[item.slot] = item
        }
    }

    /// Kicks off validate -> prepare -> generate. Safe to call again after
    /// `.failed` — that's the Retry affordance's path.
    func generatePreview() {
        let items = orderedSelectedItems
        guard !items.isEmpty else { return }
        guard usageTracker.combinationsRemaining > 0 else {
            state = .failed(usageTracker.isAnonymousQuota
                             ? "Sign in to try this on."
                             : "You're out of credits for try-ons. Buy more in Profile.")
            return
        }
        generationTask?.cancel()
        let generationID = UUID()
        currentGenerationID = generationID
        didSaveOutfit = false
        state = .validatingPhoto
        AppLog.info(.viewModel, "ManualPairingViewModel.generatePreview: generationID=\(generationID) items=\(items.map(\.id))")

        generationTask = Task { [weak self] in
            await self?.runPipeline(items: items, generationID: generationID)
        }
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        currentGenerationID = UUID()
        state = .idle
    }

    private func runPipeline(items: [WardrobeItem], generationID: UUID) async {
        guard generationID == currentGenerationID else { return }
        guard let portraitData = UserPortraitStorage.load() else {
            state = .failed("Add a photo of yourself first.")
            return
        }

        // The bundled default body photo (Profile's "Use Default Image")
        // is a plastic mannequin, not a real person — Vision's human/pose
        // detectors have nothing to find on it, so `PersonPhotoValidationService`
        // would reject every generation. Skip validation for it; a real
        // user photo still goes through the same check as always.
        if !UserPortraitStorage.isDefaultBodyPhoto(portraitData) {
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
        }

        guard !Task.isCancelled, generationID == currentGenerationID else { return }
        state = .preparingImages

        guard !Task.isCancelled, generationID == currentGenerationID else { return }
        await tryOnService.renderTryOn(baseImageData: portraitData, items: items) { [weak self] tryOnState in
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

    /// Records the PRD §3.6 feedback signal — `liked` reflects the user's
    /// actual Like/Dislike choice — then durably persists the generated image
    /// itself via `ImageStorage` + `SavedCombination` (Data/CLAUDE.md's
    /// file-persistence boundary) and mirrors it to the Photos library. Both
    /// Like and Dislike always save, so a disliked pairing still gets a durable
    /// id for its feedback row to reference and still shows up in Combinations
    /// history. Pair feedback is recorded for every unordered pair of selected
    /// garments (not just top+bottom) so the Pair-Compatibility Scoring engine
    /// learns from the full multi-slot outfit. A Photos-write failure is
    /// non-fatal: the app-local save already succeeded by that point.
    func saveOutfit(liked: Bool) async {
        let items = orderedSelectedItems
        guard !items.isEmpty else { return }
        guard case .success(let imageURL) = state else { return }
        AppLog.info(.viewModel, "ManualPairingViewModel.saveOutfit: items=\(items.map(\.id)) liked=\(liked)")

        // Every unordered pair in the outfit — the pair engine is symmetric,
        // so record each pair once.
        for i in items.indices {
            for j in items.indices where j > i {
                try? repository.recordPairFeedback(itemAID: items[i].id, itemBID: items[j].id, likedTogether: liked)
            }
        }

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
                    itemIDsBySlot: selected.mapValues(\.id),
                    labelsBySlot: selected.mapValues(\.displayLabel),
                    origin: "pairing",
                    basePortraitFingerprint: basePortraitFingerprint
                )
                // `saveCombination` may return an existing row's id instead
                // of `combinationID` if this exact pairing is already saved
                // (never a duplicate row for the same outfit) — feedback must
                // reference whichever id is actually persisted.
                let persistedID = (try? repository.saveCombination(combination)) ?? combinationID
                try? repository.recordOutfitFeedback(outfitID: persistedID, likedOverall: liked)
            }
            try? await photoLibrarySaver.save(imageData: imageData)
        }

        didSaveOutfit = true
    }

    func discardPreview() {
        state = .idle
    }
}
