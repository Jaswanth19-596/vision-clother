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

    init(repository: WardrobeRepository) {
        self.repository = repository
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
