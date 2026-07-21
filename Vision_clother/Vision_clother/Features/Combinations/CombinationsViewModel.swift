//
//  CombinationsViewModel.swift
//  Vision_clother
//
//  Tab 4: Combinations — every "Save this outfit?" the user has confirmed
//  from either Manual Pairing or Daily Assistant's try-on flow. See
//  Models/SavedCombination.swift for the persisted record and
//  Data/WardrobeRepository.swift for the query/save/delete methods.
//

import Foundation
import Observation

/// Deliberately holds no cached `combinations` array of its own — `CombinationsView`/
/// `CombinationDetailView` each read a live `@Query` instead (SwiftData
/// auto-updates it on every insert/delete, including ones `WardrobeSyncCoordinator`
/// makes during a background pull). A manually-cached snapshot here used to
/// go stale/detached out from under an open `CombinationDetailView` mid-pull,
/// crashing on the next property access — see `Data/WardrobeSyncCoordinator.swift`'s
/// pull-apply methods for the matching fix on the write side.
@Observable
@MainActor
final class CombinationsViewModel {
    private let repository: WardrobeRepository
    /// Anti-Repetition's "Generate Image" follow-up to a placeholder
    /// combination (Action A saved one with no render yet) — same
    /// service/quota dependencies `ManualPairingViewModel.generatePreview()`
    /// uses, since this is the identical render pipeline triggered from a
    /// different entry point.
    private let tryOnService: TryOnRenderService
    private let usageTracker: UsageTracker
    /// Keyed by `SavedCombination.id` — more than one detail page could
    /// in principle be generating at once (paging TabView keeps every page
    /// alive), so this can't be a single scalar the way `ManualPairingViewModel.state` is.
    private(set) var generationStateByCombinationID: [UUID: TryOnState] = [:]

    init(repository: WardrobeRepository, tryOnService: TryOnRenderService = MockTryOnRenderService(), usageTracker: UsageTracker) {
        self.repository = repository
        self.tryOnService = tryOnService
        self.usageTracker = usageTracker
    }

    func generationState(for combination: SavedCombination) -> TryOnState {
        generationStateByCombinationID[combination.id] ?? .idle
    }

    /// Runs the same try-on render pipeline `ManualPairingViewModel.generatePreview()`
    /// does, but against an already-saved placeholder combination's resolved
    /// items — on success, replaces the placeholder in place
    /// (`updateCombinationImage`) rather than creating a second
    /// `SavedCombination` row.
    func generateImage(for combination: SavedCombination) async {
        guard !AuthService.shared.isAnonymous else {
            generationStateByCombinationID[combination.id] = .failed(.signInRequired)
            return
        }
        guard usageTracker.combinationsRemaining > 0 else {
            generationStateByCombinationID[combination.id] = .failed(.quotaExceeded)
            return
        }
        guard let portraitData = UserPortraitStorage.load() else {
            generationStateByCombinationID[combination.id] = .failed(.renderFailed(reason: "Add a photo of yourself first."))
            return
        }
        let items = resolveItems(for: combination)
        guard !items.isEmpty else { return }

        AppLog.info(.viewModel, "CombinationsViewModel.generateImage: id=\(combination.id) items=\(items.count)")
        await tryOnService.renderTryOn(baseImageData: portraitData, items: items) { [weak self] state in
            Task { @MainActor in
                self?.apply(state, combination: combination)
            }
        }
    }

    private func apply(_ state: TryOnState, combination: SavedCombination) {
        generationStateByCombinationID[combination.id] = state
        switch state {
        case .succeeded(let imageURL):
            guard let imageData = try? Data(contentsOf: imageURL), let assetName = try? ImageStorage.save(imageData) else {
                generationStateByCombinationID[combination.id] = .failed(.renderFailed(reason: "Couldn't save the generated image."))
                return
            }
            do {
                try repository.updateCombinationImage(id: combination.id, assetName: assetName)
                usageTracker.recordCombinationUsed()
                AppLog.info(.viewModel, "CombinationsViewModel.generateImage: ok id=\(combination.id)")
            } catch {
                AppLog.error(.viewModel, "CombinationsViewModel.generateImage: failed id=\(combination.id) — \(String(describing: error))")
                generationStateByCombinationID[combination.id] = .failed(.renderFailed(reason: "Couldn't save the generated image."))
            }
        case .failed(let error):
            AppLog.error(.viewModel, "CombinationsViewModel.generateImage: failed id=\(combination.id) — \(String(describing: error))")
        case .idle, .submitting, .polling:
            break
        }
    }

    // MARK: - Anti-Repetition: permanent pair veto

    func banPair(_ itemA: WardrobeItem, _ itemB: WardrobeItem) {
        do {
            try repository.recordPairBan(itemAID: itemA.id, itemBID: itemB.id)
            AppLog.info(.viewModel, "CombinationsViewModel.banPair: ok \(itemA.id)+\(itemB.id)")
        } catch {
            AppLog.error(.viewModel, "CombinationsViewModel.banPair: failed — \(String(describing: error))")
        }
    }

    /// The "Wore this" quick action (Analytics & Insights, Phase 3) — logs a
    /// `WornLogEntry` for every item in the outfit. Deliberately no undo/dedupe:
    /// wearing the same outfit twice today, or logging it retroactively via a
    /// repeated tap, both just add another row — see `Models/WornLogEntry.swift`.
    func logWorn(_ combination: SavedCombination) {
        let itemIDs = Array(combination.itemIDsBySlot.values) + combination.supplementaryAccessoryItemIDs
        do {
            try repository.logWorn(savedCombinationID: combination.id, itemIDs: itemIDs)
            AppLog.info(.viewModel, "CombinationsViewModel.logWorn: ok id=\(combination.id) items=\(itemIDs.count)")
        } catch {
            AppLog.error(.viewModel, "CombinationsViewModel.logWorn: failed id=\(combination.id) — \(String(describing: error))")
        }
    }

    func delete(_ combination: SavedCombination) {
        do {
            try repository.deleteCombination(combination)
            AppLog.info(.viewModel, "CombinationsViewModel.delete: ok id=\(combination.id)")
        } catch {
            AppLog.error(.viewModel, "CombinationsViewModel.delete: failed id=\(combination.id) — \(String(describing: error))")
        }
    }

    /// Resolves `combination.itemIDsBySlot` back to real `WardrobeItem`s for
    /// `RateCombinationView` — including its Favorite/Weakest Item picker,
    /// which needs every real slot in the outfit, not just top/bottom. An id
    /// can be missing (deleted since save, or a slot a Manual Pairing save
    /// never populated) — those are silently skipped rather than surfaced as
    /// an error, since `SavedCombination` denormalizes labels/image
    /// precisely so it stays browsable even after a source item is gone.
    func resolveItems(for combination: SavedCombination) -> [WardrobeItem] {
        guard let inventory = try? repository.fetchInventory() else { return [] }
        let itemsByID = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })
        // `itemIDsBySlot` is an unordered Dictionary — iterate `Slot.allCases`
        // for a deterministic order, same pattern as `SavedCombination.displayTitle`.
        let slotItems = Slot.allCases.compactMap { combination.itemIDsBySlot[$0] }.compactMap { itemsByID[$0] }
        let supplementaryAccessories = combination.supplementaryAccessoryItemIDs.compactMap { itemsByID[$0] }
        return slotItems + supplementaryAccessories
    }
}
